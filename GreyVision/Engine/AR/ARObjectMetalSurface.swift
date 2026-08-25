// swiftlint:disable file_length
import CoreVideo
import MetalKit
import ModelIO
import QuartzCore
import simd
import SwiftUI
import UIKit

struct ARObjectMetalSurface: UIViewRepresentable {
    @ObservedObject var runtime: ARObjectRuntime

    func makeCoordinator() -> Coordinator {
        Coordinator(
            mailbox: runtime.mailbox,
            onPlaceObject: { point, size in
                Task { @MainActor in
                    await runtime.placeObject(at: point, viewportSize: size)
                }
            },
            onManipulate: { manipulation in
                Task { @MainActor in
                    switch manipulation {
                    case let .drag(point, size, phase):
                        await runtime.dragObject(at: point, viewportSize: size, phase: phase)
                    case let .scale(factor, phase):
                        runtime.scaleObject(factor, phase: phase)
                    case let .rotate(radians, phase):
                        runtime.rotateObject(radians, phase: phase)
                    case let .remove(point, size):
                        await runtime.removeObject(at: point, viewportSize: size)
                    }
                }
            }
        )
    }

    func makeUIView(context: Context) -> ARObjectMetalView {
        let view = ARObjectMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.backgroundColor = .black
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        // The drawable must be blittable so finished frames can be copied into
        // the recording writer's pixel buffer pool.
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.autoResizeDrawable = true
        view.isAccessibilityElement = true
        view.accessibilityLabel = "AR objects preview. Tap to place geometry."
        view.accessibilityIdentifier = "objects.metal.preview"
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: ARObjectMetalView, context: Context) {
        context.coordinator.renderer?.update(
            objects: runtime.objects,
            parameters: runtime.parameters,
            orientation: runtime.snapshot.orientation,
            recording: runtime.activeRecordingSession
        )
        runtime.consumeStartRequest(size: view.drawableSize)
        view.isPaused = runtime.snapshot.state != .running
    }

    static func dismantleUIView(_ view: ARObjectMetalView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
        view.onTap = nil
        view.onDrag = nil
        view.onScale = nil
        view.onRotate = nil
        view.onRemove = nil
        coordinator.renderer?.shutdown()
        coordinator.renderer = nil
    }

    @MainActor
    final class Coordinator {
        let mailbox: LatestARObjectFrameMailbox
        let onPlaceObject: (CGPoint, CGSize) -> Void
        let onManipulate: (ARManipulation) -> Void
        fileprivate var renderer: ARObjectRenderer?

        init(
            mailbox: LatestARObjectFrameMailbox,
            onPlaceObject: @escaping (CGPoint, CGSize) -> Void,
            onManipulate: @escaping (ARManipulation) -> Void
        ) {
            self.mailbox = mailbox
            self.onPlaceObject = onPlaceObject
            self.onManipulate = onManipulate
        }

        func attach(to view: ARObjectMetalView) {
            guard let device = view.device,
                  let renderer = ARObjectRenderer(
                      device: device,
                      colorPixelFormat: view.colorPixelFormat,
                      mailbox: mailbox
                  )
            else {
                GVLog.rendering.error("AR objects Metal renderer initialization failed")
                return
            }
            self.renderer = renderer
            view.delegate = renderer
            view.onTap = { [onPlaceObject] point, size in
                onPlaceObject(point, size)
            }
            view.onDrag = { [onManipulate] point, size, state in
                guard let phase = ARManipulationPhase(state) else { return }
                onManipulate(.drag(point: point, size: size, phase: phase))
            }
            view.onScale = { [onManipulate] factor, state in
                guard let phase = ARManipulationPhase(state) else { return }
                onManipulate(.scale(factor: factor, phase: phase))
            }
            view.onRotate = { [onManipulate] radians, state in
                guard let phase = ARManipulationPhase(state) else { return }
                onManipulate(.rotate(radians: radians, phase: phase))
            }
            view.onRemove = { [onManipulate] point, size in
                onManipulate(.remove(point: point, size: size))
            }
        }
    }
}

/// One direct-manipulation event, flattened so the view layer never has to
/// know which runtime method to call.
enum ARManipulation: Sendable {
    case drag(point: CGPoint, size: CGSize, phase: ARManipulationPhase)
    case scale(factor: CGFloat, phase: ARManipulationPhase)
    case rotate(radians: CGFloat, phase: ARManipulationPhase)
    case remove(point: CGPoint, size: CGSize)
}

extension ARManipulationPhase {
    /// UIKit states that carry no meaning here (`possible`) are dropped.
    init?(_ state: UIGestureRecognizer.State) {
        switch state {
        case .began: self = .began
        case .changed: self = .changed
        case .ended, .cancelled, .failed: self = .ended
        default: return nil
        }
    }
}

final class ARObjectMetalView: MTKView {
    var onTap: ((CGPoint, CGSize) -> Void)?
    /// Drag on an existing object: re-raycasts to move it along the world plane.
    var onDrag: ((CGPoint, CGSize, UIGestureRecognizer.State) -> Void)?
    /// Pinch scale, relative to the object's size when the gesture began.
    var onScale: ((CGFloat, UIGestureRecognizer.State) -> Void)?
    /// Two-finger twist, in radians.
    var onRotate: ((CGFloat, UIGestureRecognizer.State) -> Void)?
    /// Long press removes the object under the finger.
    var onRemove: ((CGPoint, CGSize) -> Void)?

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
        addGestureRecognizer(rotate)

        // Pinch and twist are performed together constantly; without this only
        // whichever recognised first would ever fire.
        pinch.delegate = self
        rotate.delegate = self

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0.55
        addGestureRecognizer(press)

        // A drag must not also register as a tap and place a second object.
        tap.require(toFail: pan)
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("ARObjectMetalView does not support Interface Builder")
    }

    @objc
    private func handleTap(_ recognizer: UITapGestureRecognizer) {
        onTap?(recognizer.location(in: self), bounds.size)
    }

    @objc
    private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        onDrag?(recognizer.location(in: self), bounds.size, recognizer.state)
    }

    @objc
    private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        onScale?(recognizer.scale, recognizer.state)
    }

    @objc
    private func handleRotate(_ recognizer: UIRotationGestureRecognizer) {
        onRotate?(recognizer.rotation, recognizer.state)
    }

    @objc
    private func handlePress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        onRemove?(recognizer.location(in: self), bounds.size)
    }
}

extension ARObjectMetalView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

private struct ARObjectSettings {
    let objects: [ARObjectDescriptor]
    let parameters: ARObjectParameters
    let orientation: CapturedFrameOrientation
    let recording: GVRealtimeRecordingSession?
}

private struct ARBackgroundUniforms {
    var viewport: SIMD4<Float>
    var options: SIMD4<UInt32>
}

private struct ARObjectUniforms {
    var model: simd_float4x4
    var viewProjection: simd_float4x4
    var cameraPosition: SIMD4<Float>
    var tint: SIMD4<Float>
    var tuning: SIMD4<Float>
    var options: SIMD4<UInt32>
}

private struct ARConversionUniforms {
    var source: SIMD4<UInt32>
    var tuning: SIMD4<Float>
}

private final class ARObjectFrameLease: @unchecked Sendable {
    let luma: MTLTexture
    let chroma: MTLTexture
    let leases: [CVMetalTexture]

    init(luma: MTLTexture, chroma: MTLTexture, leases: [CVMetalTexture]) {
        self.luma = luma
        self.chroma = chroma
        self.leases = leases
    }
}

// swiftlint:disable type_body_length
private final class ARObjectRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private let mailbox: LatestARObjectFrameMailbox
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let yuvPipeline: MTLComputePipelineState
    private let backgroundPipeline: MTLRenderPipelineState
    private let objectSolidPipeline: MTLRenderPipelineState
    private let backgroundDepthState: MTLDepthStencilState
    private let objectDepthState: MTLDepthStencilState
    private let textureCache: CVMetalTextureCache
    private let settingsLock = NSLock()

    private var objects: [ARObjectDescriptor] = []
    private var parameters = ARObjectParameters.defaults
    private var orientation = CapturedFrameOrientation.portrait
    private var latestFrame: ARObjectFrame?
    private var backgroundTexture: MTLTexture?
    private var recordingSession: GVRealtimeRecordingSession?
    private var meshes: [ARObjectShape: MTKMesh] = [:]

    init?(
        device: MTLDevice,
        colorPixelFormat: MTLPixelFormat,
        mailbox: LatestARObjectFrameMailbox
    ) {
        guard let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let yuvFunction = library.makeFunction(name: "gvCameraYUVToLinear"),
              let backgroundVertex = library.makeFunction(name: "gvARBackgroundVertex"),
              let backgroundFragment = library.makeFunction(name: "gvARBackgroundFragment"),
              let objectVertex = library.makeFunction(name: "gvARObjectVertex"),
              let objectFragment = library.makeFunction(name: "gvARObjectFragment"),
              let yuvPipeline = try? device.makeComputePipelineState(function: yuvFunction)
        else {
            return nil
        }

        let backgroundDescriptor = MTLRenderPipelineDescriptor()
        backgroundDescriptor.label = "greyVISION AR Background"
        backgroundDescriptor.vertexFunction = backgroundVertex
        backgroundDescriptor.fragmentFunction = backgroundFragment
        backgroundDescriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        // The view carries a depth attachment, so every pipeline used in that
        // pass must declare the matching format. Without it the background draw
        // fails validation and only the clear colour reaches the screen — which
        // is why AR objects rendered as a black frame.
        backgroundDescriptor.depthAttachmentPixelFormat = .depth32Float

        let solidDescriptor = MTLRenderPipelineDescriptor()
        solidDescriptor.label = "greyVISION AR Object Solid"
        solidDescriptor.vertexFunction = objectVertex
        solidDescriptor.fragmentFunction = objectFragment
        solidDescriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        solidDescriptor.depthAttachmentPixelFormat = .depth32Float

        guard let backgroundPipeline = try? device.makeRenderPipelineState(descriptor: backgroundDescriptor),
              let objectSolidPipeline = try? device.makeRenderPipelineState(descriptor: solidDescriptor)
        else {
            return nil
        }

        let backgroundDepthDescriptor = MTLDepthStencilDescriptor()
        backgroundDepthDescriptor.depthCompareFunction = .always
        backgroundDepthDescriptor.isDepthWriteEnabled = false

        let objectDepthDescriptor = MTLDepthStencilDescriptor()
        objectDepthDescriptor.depthCompareFunction = .less
        objectDepthDescriptor.isDepthWriteEnabled = true

        guard let backgroundDepthState = device.makeDepthStencilState(descriptor: backgroundDepthDescriptor),
              let objectDepthState = device.makeDepthStencilState(descriptor: objectDepthDescriptor)
        else {
            return nil
        }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache
        else {
            return nil
        }

        self.mailbox = mailbox
        self.device = device
        self.commandQueue = commandQueue
        self.yuvPipeline = yuvPipeline
        self.backgroundPipeline = backgroundPipeline
        self.objectSolidPipeline = objectSolidPipeline
        self.backgroundDepthState = backgroundDepthState
        self.objectDepthState = objectDepthState
        textureCache = cache
        super.init()
        commandQueue.label = "greyVISION AR Objects Command Queue"
    }

    func update(
        objects: [ARObjectDescriptor],
        parameters: ARObjectParameters,
        orientation: CapturedFrameOrientation,
        recording: GVRealtimeRecordingSession?
    ) {
        settingsLock.withLock {
            self.objects = objects
            self.parameters = parameters.sanitized
            self.orientation = orientation
            recordingSession = recording
        }
    }

    func shutdown() {
        latestFrame = nil
        backgroundTexture = nil
        recordingSession = nil
        meshes.removeAll()
        CVMetalTextureCacheFlush(textureCache, 0)
        GVLog.rendering.notice("AR objects renderer stopped")
    }

    func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func draw(in view: MTKView) {
        let settings = settingsLock.withLock {
            ARObjectSettings(
                objects: objects,
                parameters: parameters,
                orientation: orientation,
                recording: recordingSession
            )
        }

        var frameLease: ARObjectFrameLease?
        if let frame = mailbox.consumeLatest() {
            latestFrame = frame
            if let textures = makeTextures(frame: frame) {
                frameLease = textures
            }
        }

        guard let latestFrame,
              let drawable = view.currentDrawable,
              let renderPass = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }

        if let frameLease {
            ensureBackgroundTexture(width: frameLease.luma.width, height: frameLease.luma.height)
            encodeYUVConversion(
                luma: frameLease.luma,
                chroma: frameLease.chroma,
                into: backgroundTexture,
                commandBuffer: commandBuffer
            )
        }
        guard let backgroundTexture else { return }

        let now = CACurrentMediaTime()
        let interfaceOrientation = Self.interfaceOrientation(for: settings.orientation)
        let projection = latestFrame.camera.projectionMatrix(
            for: interfaceOrientation,
            viewportSize: view.drawableSize,
            zNear: 0.001,
            zFar: 25
        )
        let viewMatrix = latestFrame.camera.viewMatrix(for: interfaceOrientation)
        let viewProjection = projection * viewMatrix
        let cameraPosition = SIMD3(
            latestFrame.camera.transform.columns.3.x,
            latestFrame.camera.transform.columns.3.y,
            latestFrame.camera.transform.columns.3.z
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            return
        }
        encoder.label = "greyVISION AR Objects Scene"

        // Live camera background, drawn with depth always so geometry sits on top.
        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.setDepthStencilState(backgroundDepthState)
        var backgroundUniforms = ARBackgroundUniforms(
            viewport: SIMD4<Float>(
                Float(view.drawableSize.width),
                Float(view.drawableSize.height),
                Float(backgroundTexture.width),
                Float(backgroundTexture.height)
            ),
            options: SIMD4<UInt32>(0, UInt32(settings.orientation.rawValue), 0, 0)
        )
        encoder.setFragmentTexture(backgroundTexture, index: 0)
        encoder.setFragmentBytes(
            &backgroundUniforms,
            length: MemoryLayout<ARBackgroundUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // Placed geometry.
        encoder.setDepthStencilState(objectDepthState)
        let sizeScale = Float(parameters.size)
        let glow = Float(parameters.glow)
        for object in settings.objects {
            guard let mesh = mesh(for: object.shape) else { continue }
            let model = Self.modelMatrix(
                for: object,
                time: now,
                scale: object.scale * sizeScale,
                spin: Float(parameters.spin)
            )
            let tint: SIMD4<Float>
            let glowScaled: Float
            if object.isBlackHole {
                // Dark violet core with a hot rim: the constellation's appetite.
                tint = SIMD4(SIMD3(0.05, 0.0, 0.18), 1)
                glowScaled = max(glow * 2.4, 1.7)
            } else {
                tint = SIMD4(ARObjectPalette.colors[object.tintIndex % ARObjectPalette.colors.count], 1)
                glowScaled = glow
            }
            var uniforms = ARObjectUniforms(
                model: model,
                viewProjection: viewProjection,
                cameraPosition: SIMD4(cameraPosition, 1),
                tint: tint,
                tuning: SIMD4(Float(now.truncatingRemainder(dividingBy: 3600)), 0, glowScaled, 0),
                options: SIMD4<UInt32>(object.wire ? 1 : 0, 0, 0, 0)
            )
            encoder.setRenderPipelineState(objectSolidPipeline)
            for (index, buffer) in mesh.vertexBuffers.enumerated() {
                encoder.setVertexBuffer(buffer.buffer, offset: buffer.offset, index: index)
            }
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<ARObjectUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ARObjectUniforms>.stride, index: 0)
            for submesh in mesh.submeshes {
                encoder.drawIndexedPrimitives(
                    type: submesh.primitiveType,
                    indexCount: submesh.indexCount,
                    indexType: submesh.indexType,
                    indexBuffer: submesh.indexBuffer.buffer,
                    indexBufferOffset: submesh.indexBuffer.offset
                )
            }
        }
        encoder.endEncoding()

        // Recording: blit the finished frame into a pixel buffer from the
        // writer's pool, then append once the GPU has finished writing.
        var recordLease: ARObjectRecordLease?
        let recordTimestamp = latestFrame.timestamp
        if let lease = makeRecordLease(
            recording: settings.recording,
            size: CGSize(width: CGFloat(drawable.texture.width), height: CGFloat(drawable.texture.height))
        ) {
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.label = "greyVISION AR Record Copy"
                blit.copy(
                    from: drawable.texture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: .init(x: 0, y: 0, z: 0),
                    sourceSize: .init(
                        width: drawable.texture.width,
                        height: drawable.texture.height,
                        depth: 1
                    ),
                    to: lease.texture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: .init(x: 0, y: 0, z: 0)
                )
                blit.endEncoding()
            }
            recordLease = lease
        }

        let retainedLease = frameLease
        let retainedRecordLease = recordLease
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak recording = settings.recording] _ in
            _ = retainedLease
            guard let recording,
                  let pixelBuffer = retainedRecordLease?.pixelBuffer
            else {
                return
            }
            recording.append(pixelBuffer, timestamp: recordTimestamp)
        }
        commandBuffer.commit()
    }

    /// Keeps the recording pixel buffer's texture cache lease alive until the
    /// command buffer completes and the encoder has consumed the pixels; it is
    /// handed to the command-buffer completion handler once the GPU has
    /// finished writing, and only that handler reads the pixels afterwards.
    private struct ARObjectRecordLease: @unchecked Sendable {
        let cacheLease: CVMetalTexture
        let texture: MTLTexture
        let pixelBuffer: CVPixelBuffer
    }

    /// Prepares a recording pool pixel buffer for the finished frame, or nil
    /// when recording is inactive, the drawable size changed, or the encoder
    /// is backed up.
    private func makeRecordLease(
        recording: GVRealtimeRecordingSession?,
        size: CGSize
    ) -> ARObjectRecordLease? {
        guard let recording,
              recording.size == size,
              let pixelBuffer = recording.nextPixelBuffer(),
              let textures = makeRecordingTexture(pixelBuffer: pixelBuffer)
        else {
            return nil
        }
        return ARObjectRecordLease(
            cacheLease: textures.0,
            texture: textures.1,
            pixelBuffer: pixelBuffer
        )
    }

    /// Wraps a recording pool pixel buffer so the GPU can write into it
    /// directly. The lease must stay alive until the command completes.
    private func makeRecordingTexture(
        pixelBuffer: CVPixelBuffer
    ) -> (CVMetalTexture, MTLTexture)? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var lease: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm_srgb,
            width,
            height,
            0,
            &lease
        )
        guard result == kCVReturnSuccess,
              let lease,
              let texture = CVMetalTextureGetTexture(lease)
        else {
            return nil
        }
        return (lease, texture)
    }

    private func ensureBackgroundTexture(width: Int, height: Int) {
        if backgroundTexture?.width == width, backgroundTexture?.height == height {
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }
        texture.label = "greyVISION AR Background Linear"
        backgroundTexture = texture
    }

    private func encodeYUVConversion(
        luma: MTLTexture,
        chroma: MTLTexture,
        into destination: MTLTexture?,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let destination,
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return
        }
        var uniforms = ARConversionUniforms(
            source: SIMD4<UInt32>(
                UInt32(luma.width),
                UInt32(luma.height),
                1,
                0
            ),
            tuning: SIMD4<Float>(1, 0, 0, 0)
        )
        encoder.label = "greyVISION AR YUV to Linear"
        encoder.setComputePipelineState(yuvPipeline)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.setTexture(destination, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<ARConversionUniforms>.stride, index: 0)
        let width = max(1, yuvPipeline.threadExecutionWidth)
        let height = max(1, yuvPipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: destination.width, height: destination.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
        )
        encoder.endEncoding()
    }

    private func makeTextures(frame: ARObjectFrame) -> ARObjectFrameLease? {
        let pixelBuffer = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
              let lumaLease = makeTexture(
                  pixelBuffer: pixelBuffer,
                  pixelFormat: .r8Unorm,
                  plane: 0,
                  width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                  height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
              ),
              let chromaLease = makeTexture(
                  pixelBuffer: pixelBuffer,
                  pixelFormat: .rg8Unorm,
                  plane: 1,
                  width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                  height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
              )
        else {
            return nil
        }
        return ARObjectFrameLease(
            luma: lumaLease.1,
            chroma: chromaLease.1,
            leases: [lumaLease.0, chromaLease.0]
        )
    }

    private func makeTexture(
        pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        plane: Int,
        width: Int,
        height: Int
    ) -> (CVMetalTexture, MTLTexture)? {
        var lease: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            plane,
            &lease
        )
        guard result == kCVReturnSuccess,
              let lease,
              let texture = CVMetalTextureGetTexture(lease)
        else {
            return nil
        }
        return (lease, texture)
    }

    private func mesh(for shape: ARObjectShape) -> MTKMesh? {
        if let existing = meshes[shape] {
            return existing
        }
        guard let mesh = Self.makeMesh(shape: shape, device: device) else {
            return nil
        }
        meshes[shape] = mesh
        return mesh
    }

    private static func makeMesh(shape: ARObjectShape, device: MTLDevice) -> MTKMesh? {
        let allocator = MTKMeshBufferAllocator(device: device)
        let mesh = switch shape {
        case .icosahedron:
            MDLMesh.newIcosahedron(withRadius: 0.5, inwardNormals: false, allocator: allocator)
        case .box:
            MDLMesh.newBox(
                withDimensions: SIMD3<Float>(0.82, 0.82, 0.82),
                segments: SIMD3<UInt32>(1, 1, 1),
                geometryType: .triangles,
                inwardNormals: false,
                allocator: allocator
            )
        case .cone:
            MDLMesh.newEllipticalCone(
                withHeight: 0.92,
                radii: SIMD2<Float>(0.42, 0.42),
                radialSegments: 40,
                verticalSegments: 1,
                geometryType: .triangles,
                inwardNormals: false,
                allocator: allocator
            )
        case .cylinder:
            MDLMesh.newCylinder(
                withHeight: 0.92,
                radii: SIMD2<Float>(0.40, 0.40),
                radialSegments: 40,
                verticalSegments: 1,
                geometryType: .triangles,
                inwardNormals: false,
                allocator: allocator
            )
        case .ellipsoid:
            MDLMesh.newEllipsoid(
                withRadii: SIMD3<Float>(0.45, 0.60, 0.45),
                radialSegments: 32,
                verticalSegments: 16,
                geometryType: .triangles,
                inwardNormals: false,
                hemisphere: false,
                allocator: allocator
            )
        case .sphere:
            MDLMesh.newEllipsoid(
                withRadii: SIMD3<Float>(0.52, 0.52, 0.52),
                radialSegments: 40,
                verticalSegments: 24,
                geometryType: .triangles,
                inwardNormals: false,
                hemisphere: false,
                allocator: allocator
            )
        case .plate:
            // A thin slab reads far better than a flat plane once it is
            // spinning — it catches an edge highlight every half turn.
            MDLMesh.newBox(
                withDimensions: SIMD3<Float>(1.10, 0.68, 0.06),
                segments: SIMD3<UInt32>(1, 1, 1),
                geometryType: .triangles,
                inwardNormals: false,
                allocator: allocator
            )
        case .torus:
            // ModelIO has no torus primitive, so it is generated directly into
            // the same interleaved position+normal layout the others use.
            makeTorus(majorRadius: 0.42, minorRadius: 0.16, allocator: allocator)
        case .capsule:
            MDLMesh.newCapsule(
                withHeight: 1.0,
                radii: SIMD2<Float>(0.30, 0.30),
                radialSegments: 32,
                verticalSegments: 12,
                hemisphereSegments: 10,
                geometryType: .triangles,
                inwardNormals: false,
                allocator: allocator
            )
        case .prism:
            // Six radial segments on a cone gives a hard-faceted crystal
            // rather than a smooth cone — much stronger under the flat shading.
            MDLMesh.newEllipticalCone(
                withHeight: 1.05,
                radii: SIMD2<Float>(0.48, 0.48),
                radialSegments: 6,
                verticalSegments: 1,
                geometryType: .triangles,
                inwardNormals: false,
                allocator: allocator
            )
        case .hemisphere:
            MDLMesh.newEllipsoid(
                withRadii: SIMD3<Float>(0.55, 0.55, 0.55),
                radialSegments: 36,
                verticalSegments: 18,
                geometryType: .triangles,
                inwardNormals: false,
                hemisphere: true,
                allocator: allocator
            )
        case .ring:
            // Thin torus: a halo rather than a doughnut.
            makeTorus(majorRadius: 0.48, minorRadius: 0.055, allocator: allocator)
        case .spike:
            MDLMesh.newEllipticalCone(
                withHeight: 1.25,
                radii: SIMD2<Float>(0.20, 0.20),
                radialSegments: 24,
                verticalSegments: 1,
                geometryType: .triangles,
                inwardNormals: false,
                allocator: allocator
            )
        case .slab:
            MDLMesh.newBox(
                withDimensions: SIMD3<Float>(0.34, 1.15, 0.34),
                segments: SIMD3<UInt32>(1, 1, 1),
                geometryType: .triangles,
                inwardNormals: false,
                allocator: allocator
            )
        case .baby, .melissa:
            loadScannedMesh(shape: shape, allocator: allocator)
        }

        guard let mesh else { return nil }

        let vertexDescriptor = MDLVertexDescriptor()
        vertexDescriptor.attributes[0] = MDLVertexAttribute(
            name: MDLVertexAttributePosition,
            format: .float3,
            offset: 0,
            bufferIndex: 0
        )
        vertexDescriptor.attributes[1] = MDLVertexAttribute(
            name: MDLVertexAttributeNormal,
            format: .float3,
            offset: 12,
            bufferIndex: 0
        )
        vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: 24)
        mesh.vertexDescriptor = vertexDescriptor
        return try? MTKMesh(mesh: mesh, device: device)
    }

    /// Builds a torus as interleaved float3 position + float3 normal.
    ///
    /// Written by hand because ModelIO ships no torus primitive, and a ring is
    /// the one silhouette none of the other shapes can approximate.
    private static func makeTorus(
        majorRadius: Float,
        minorRadius: Float,
        majorSegments: Int = 48,
        minorSegments: Int = 20,
        allocator: MTKMeshBufferAllocator
    ) -> MDLMesh {
        var vertices: [Float] = []
        vertices.reserveCapacity((majorSegments + 1) * (minorSegments + 1) * 6)

        for major in 0 ... majorSegments {
            let u = Float(major) / Float(majorSegments) * 2 * .pi
            let cosU = cos(u)
            let sinU = sin(u)
            for minor in 0 ... minorSegments {
                let v = Float(minor) / Float(minorSegments) * 2 * .pi
                let cosV = cos(v)
                let sinV = sin(v)
                // Normal points away from the tube's centre circle.
                let normal = SIMD3<Float>(cosU * cosV, sinV, sinU * cosV)
                let position = SIMD3<Float>(
                    (majorRadius + minorRadius * cosV) * cosU,
                    minorRadius * sinV,
                    (majorRadius + minorRadius * cosV) * sinU
                )
                vertices.append(contentsOf: [
                    position.x, position.y, position.z,
                    normal.x, normal.y, normal.z
                ])
            }
        }

        var indices: [UInt32] = []
        let ring = UInt32(minorSegments + 1)
        for major in 0 ..< UInt32(majorSegments) {
            for minor in 0 ..< UInt32(minorSegments) {
                let a = major * ring + minor
                let b = a + ring
                indices.append(contentsOf: [a, b, a + 1, a + 1, b, b + 1])
            }
        }

        let vertexBuffer = allocator.newBuffer(
            with: Data(bytes: vertices, count: vertices.count * MemoryLayout<Float>.size),
            type: .vertex
        )
        let indexBuffer = allocator.newBuffer(
            with: Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size),
            type: .index
        )
        let submesh = MDLSubmesh(
            indexBuffer: indexBuffer,
            indexCount: indices.count,
            indexType: .uInt32,
            geometryType: .triangles,
            material: nil
        )

        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(
            name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0
        )
        descriptor.attributes[1] = MDLVertexAttribute(
            name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0
        )
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: 24)

        return MDLMesh(
            vertexBuffer: vertexBuffer,
            vertexCount: vertices.count / 6,
            descriptor: descriptor,
            submeshes: [submesh]
        )
    }

    /// Loads a bundled USDZ and normalises it into the same unit box the
    /// primitives occupy.
    ///
    /// Scanned assets arrive at arbitrary scale and origin, so without this a
    /// model lands either invisible or the size of a room. The mesh is
    /// recentred on its bounding box and uniformly scaled to a ~1 unit extent,
    /// which is what lets the SIZE parameter mean the same thing for every
    /// shape.
    private static func loadScannedMesh(
        shape: ARObjectShape,
        allocator: MTKMeshBufferAllocator
    ) -> MDLMesh? {
        let name: String? = switch shape {
        case .baby: "gv_baby"
        case .melissa: "gv_melissa"
        default: nil
        }
        guard let name else { return nil }
        guard let url = Bundle.main.url(forResource: name, withExtension: "usdz") else {
            GVLog.rendering.error("scanned mesh missing from bundle: \(name).usdz")
            return nil
        }

        let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: allocator)
        asset.loadTextures()
        guard let mesh = asset.childObjects(of: MDLMesh.self).first as? MDLMesh else {
            GVLog.rendering.error("scanned mesh has no MDLMesh: \(name)")
            return nil
        }

        // Shading is flat position+normal, so missing normals would render the
        // model as a silhouette.
        if mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal) == nil {
            mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.2)
        }

        let bounds = mesh.boundingBox
        let extent = bounds.maxBounds - bounds.minBounds
        let longest = max(extent.x, max(extent.y, extent.z))
        guard longest > 0 else { return mesh }
        let centre = (bounds.maxBounds + bounds.minBounds) * 0.5
        let normalise = 1.0 / longest

        // Rewrite positions in place: cheaper than a transform node and keeps
        // the descriptor identical to the procedural shapes.
        if let positions = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition) {
            let stride = positions.stride
            let pointer = positions.dataStart
            for index in 0 ..< mesh.vertexCount {
                let slot = pointer.advanced(by: index * stride)
                    .assumingMemoryBound(to: Float.self)
                slot[0] = (slot[0] - centre.x) * normalise
                slot[1] = (slot[1] - centre.y) * normalise
                slot[2] = (slot[2] - centre.z) * normalise
            }
        }
        return mesh
    }

    /// Anchor transform with a slow spin, gentle bob, and per-object phase so
    /// placed geometry never sits perfectly still.
    private static func modelMatrix(
        for object: ARObjectDescriptor,
        time: TimeInterval,
        scale: Float,
        spin: Float
    ) -> simd_float4x4 {
        let elapsed = Float(max(time - object.birthTime, 0))
        let angle = spin * object.spinSpeed * elapsed
        let bob = sin(elapsed * 1.1 + object.phase) * 0.05 * scale
        var transform = translationMatrix(object.position + SIMD3<Float>(0, bob, 0))
        transform = transform * rotationYMatrix(angle) * rotationXMatrix(object.phase * 3.0)
        return transform * scaleMatrix(scale)
    }

    private static func translationMatrix(_ vector: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(vector, 1)
        ))
    }

    private static func rotationYMatrix(_ angle: Float) -> simd_float4x4 {
        let cosine = cos(angle)
        let sine = sin(angle)
        return simd_float4x4(columns: (
            SIMD4<Float>(cosine, 0, -sine, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(sine, 0, cosine, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    private static func rotationXMatrix(_ angle: Float) -> simd_float4x4 {
        let cosine = cos(angle)
        let sine = sin(angle)
        return simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, cosine, sine, 0),
            SIMD4<Float>(0, -sine, cosine, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    private static func scaleMatrix(_ scale: Float) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(scale, 0, 0, 0),
            SIMD4<Float>(0, scale, 0, 0),
            SIMD4<Float>(0, 0, scale, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    private static func interfaceOrientation(for orientation: CapturedFrameOrientation) -> UIInterfaceOrientation {
        switch orientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        }
    }
}

// swiftlint:enable type_body_length
// swiftlint:enable file_length
