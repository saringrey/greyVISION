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
    @EnvironmentObject private var audioRuntime: AudioReactiveRuntime

    func makeCoordinator() -> Coordinator {
        Coordinator(
            mailbox: runtime.mailbox,
            audioMailbox: audioRuntime.snapshotMailbox,
            modelStore: runtime.modelStore,
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
            occlusion: runtime.occlusionEnabled,
            selectedObjectID: runtime.selectedObjectID,
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
        let audioMailbox: AudioReactiveSnapshotMailbox
        let modelStore: ARUserModelStore
        let onPlaceObject: (CGPoint, CGSize) -> Void
        let onManipulate: (ARManipulation) -> Void
        fileprivate var renderer: ARObjectRenderer?

        init(
            mailbox: LatestARObjectFrameMailbox,
            audioMailbox: AudioReactiveSnapshotMailbox,
            modelStore: ARUserModelStore,
            onPlaceObject: @escaping (CGPoint, CGSize) -> Void,
            onManipulate: @escaping (ARManipulation) -> Void
        ) {
            self.mailbox = mailbox
            self.audioMailbox = audioMailbox
            self.modelStore = modelStore
            self.onPlaceObject = onPlaceObject
            self.onManipulate = onManipulate
        }

        func attach(to view: ARObjectMetalView) {
            guard let device = view.device,
                  let renderer = ARObjectRenderer(
                      device: device,
                      colorPixelFormat: view.colorPixelFormat,
                      mailbox: mailbox,
                      audioMailbox: audioMailbox,
                      modelStore: modelStore
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
    var onDrag: ((CGPoint, CGSize, UIGestureRecognizer.State) -> Void)?
    var onScale: ((CGFloat, UIGestureRecognizer.State) -> Void)?
    var onRotate: ((CGFloat, UIGestureRecognizer.State) -> Void)?
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

        pinch.delegate = self
        rotate.delegate = self

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0.55
        addGestureRecognizer(press)

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
    let occlusion: Bool
    let selectedObjectID: UUID?
    let orientation: CapturedFrameOrientation
    let recording: GVRealtimeRecordingSession?
}

private struct ARBackgroundUniforms {
    var viewport: SIMD4<Float>
    /// x = orientation-independent flags: 1 scene depth, 2 person depth.
    var options: SIMD4<UInt32>
    /// The projection's depth terms (c2.z, c3.z, c2.w, c3.w), so metric depth
    /// lands in the depth buffer exactly where the objects' own depth does.
    var depthProjection: SIMD4<Float>
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
    let sceneDepth: MTLTexture?
    let personDepth: MTLTexture?
    let personMask: MTLTexture?
    let leases: [CVMetalTexture]

    init(luma: MTLTexture, chroma: MTLTexture, sceneDepth: MTLTexture?, personDepth: MTLTexture?,
         personMask: MTLTexture?, leases: [CVMetalTexture]) {
        self.luma = luma
        self.chroma = chroma
        self.sceneDepth = sceneDepth
        self.personDepth = personDepth
        self.personMask = personMask
        self.leases = leases
    }
}

// swiftlint:disable type_body_length
private final class ARObjectRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private let mailbox: LatestARObjectFrameMailbox
    private let audioMailbox: AudioReactiveSnapshotMailbox
    private let modelStore: ARUserModelStore
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
    private var occlusion = true
    private var selectedObjectID: UUID?
    /// The last frame's depth textures, kept between camera frames so the
    /// occlusion does not flicker off on draws without a new ARFrame.
    private var depthLease: ARObjectFrameLease?
    /// Bound when a depth source is absent, so the shader never reads an
    /// unbound slot; the flags tell it not to trust them.
    private lazy var emptyDepthTexture: MTLTexture? = Self.placeholder(device: device, format: .r32Float)
    private lazy var emptyMaskTexture: MTLTexture? = Self.placeholder(device: device, format: .r8Unorm)

    private static func placeholder(device: MTLDevice, format: MTLPixelFormat) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }
    private var orientation = CapturedFrameOrientation.portrait
    private var latestFrame: ARObjectFrame?
    private var backgroundTexture: MTLTexture?
    private var recordingSession: GVRealtimeRecordingSession?
    private var meshes: [ARObjectShape: MTKMesh] = [:]
    private var userModelMeshes: [UUID: MTKMesh] = [:]
    private var failedUserModelIDs: Set<UUID> = []
    private var didReportFirstFrame = false

    init?(
        device: MTLDevice,
        colorPixelFormat: MTLPixelFormat,
        mailbox: LatestARObjectFrameMailbox,
        audioMailbox: AudioReactiveSnapshotMailbox,
        modelStore: ARUserModelStore
    ) {
        guard let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let yuvFunction = library.makeFunction(name: "gvCameraYUVToLinear"),
              let backgroundVertex = library.makeFunction(name: "gvARBackgroundVertex"),
              let backgroundFragment = library.makeFunction(name: "gvARBackgroundFragment"),
              let objectVertex = library.makeFunction(name: "gvARObjectVertex"),
              let objectFragment = library.makeFunction(name: "gvARObjectFragment")
        else {
            GVLog.rendering.error("AR renderer: queue, library or shader function missing")
            return nil
        }
        let yuvPipeline: MTLComputePipelineState
        do {
            yuvPipeline = try device.makeComputePipelineState(function: yuvFunction)
        } catch {
            GVLog.rendering.error("AR renderer: YUV pipeline failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let backgroundDescriptor = MTLRenderPipelineDescriptor()
        backgroundDescriptor.label = "greyVISION AR Background"
        backgroundDescriptor.vertexFunction = backgroundVertex
        backgroundDescriptor.fragmentFunction = backgroundFragment
        backgroundDescriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        backgroundDescriptor.depthAttachmentPixelFormat = .depth32Float

        let solidDescriptor = MTLRenderPipelineDescriptor()
        solidDescriptor.label = "greyVISION AR Object Solid"
        solidDescriptor.vertexFunction = objectVertex
        solidDescriptor.fragmentFunction = objectFragment
        if let colorAttachment = solidDescriptor.colorAttachments[0] {
            colorAttachment.pixelFormat = colorPixelFormat
            colorAttachment.isBlendingEnabled = true
            colorAttachment.sourceRGBBlendFactor = .sourceAlpha
            colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            colorAttachment.sourceAlphaBlendFactor = .one
            colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        solidDescriptor.depthAttachmentPixelFormat = .depth32Float
        solidDescriptor.vertexDescriptor = MTKMetalVertexDescriptorFromModelIO(Self.meshVertexDescriptor)

        let backgroundPipeline: MTLRenderPipelineState
        let objectSolidPipeline: MTLRenderPipelineState
        do {
            backgroundPipeline = try device.makeRenderPipelineState(descriptor: backgroundDescriptor)
            objectSolidPipeline = try device.makeRenderPipelineState(descriptor: solidDescriptor)
        } catch {
            GVLog.rendering.error("AR renderer: render pipeline failed: \(String(describing: error), privacy: .public)")
            return nil
        }

        let backgroundDepthDescriptor = MTLDepthStencilDescriptor()
        backgroundDepthDescriptor.depthCompareFunction = .always
        // The background writes the real world's depth (far where unknown),
        // which is what lets placed objects pass behind real things.
        backgroundDepthDescriptor.isDepthWriteEnabled = true

        let objectDepthDescriptor = MTLDepthStencilDescriptor()
        objectDepthDescriptor.depthCompareFunction = .lessEqual
        objectDepthDescriptor.isDepthWriteEnabled = true

        guard let backgroundDepthState = device.makeDepthStencilState(descriptor: backgroundDepthDescriptor),
              let objectDepthState = device.makeDepthStencilState(descriptor: objectDepthDescriptor)
        else {
            GVLog.rendering.error("AR renderer: depth state failed")
            return nil
        }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache
        else {
            GVLog.rendering.error("AR renderer: texture cache failed")
            return nil
        }

        self.mailbox = mailbox
        self.audioMailbox = audioMailbox
        self.modelStore = modelStore
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
        occlusion: Bool,
        selectedObjectID: UUID?,
        orientation: CapturedFrameOrientation,
        recording: GVRealtimeRecordingSession?
    ) {
        settingsLock.withLock {
            self.objects = objects
            self.parameters = parameters.sanitized
            self.occlusion = occlusion
            self.selectedObjectID = selectedObjectID
            self.orientation = orientation
            recordingSession = recording
        }
    }

    func shutdown() {
        latestFrame = nil
        depthLease = nil
        backgroundTexture = nil
        recordingSession = nil
        meshes.removeAll()
        userModelMeshes.removeAll()
        failedUserModelIDs.removeAll()
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
                occlusion: occlusion,
                selectedObjectID: selectedObjectID,
                orientation: orientation,
                recording: recordingSession
            )
        }

        var frameLease: ARObjectFrameLease?
        if let frame = mailbox.consumeLatest() {
            latestFrame = frame
            if let textures = makeTextures(frame: frame) {
                frameLease = textures
                depthLease = textures
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
        let projection: simd_float4x4
        let viewMatrix: simd_float4x4
        if let arCamera = latestFrame.camera {
            projection = arCamera.projectionMatrix(
                for: interfaceOrientation,
                viewportSize: view.drawableSize,
                zNear: 0.001,
                zFar: 25
            )
            viewMatrix = arCamera.viewMatrix(for: interfaceOrientation)
        } else {
            projection = ARObjectSource.syntheticProjectionMatrix(
                viewportSize: view.drawableSize,
                zNear: 0.001,
                zFar: 25
            )
            viewMatrix = latestFrame.cameraTransform.inverse
        }
        let viewProjection = projection * viewMatrix
        let cameraTransform = latestFrame.cameraTransform
        let cameraPosition = SIMD3(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        // Objects take the room's light: dimmer in a dark room, a little
        // brighter in daylight, so they sit in the scene instead of glowing
        // at one fixed level over it. Emissive glow is left alone.
        let roomLight = latestFrame.ambientIntensity.map { min(max($0 / 1000, 0.35), 1.25) } ?? 1
        let audioSnap = audioMailbox.latest
        let audioLevel = Float(settings.parameters.audioReactivity)
            * min(max(audioSnap.rms * 2.2, audioSnap.peak), 1.5)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            return
        }
        encoder.label = "greyVISION AR Objects Scene"

        // Live camera background, drawn with depth always so geometry sits on top.
        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.setDepthStencilState(backgroundDepthState)
        // Occlusion: the background also writes the real world's depth, so
        // the objects' ordinary depth test hides them behind whatever is
        // physically nearer — a pole, a couch, a person.
        let depthTextures = settings.occlusion ? depthLease : nil
        var depthFlags: UInt32 = 0
        if depthTextures?.sceneDepth != nil { depthFlags |= 1 }
        if depthTextures?.personDepth != nil, depthTextures?.personMask != nil { depthFlags |= 2 }
        var backgroundUniforms = ARBackgroundUniforms(
            viewport: SIMD4<Float>(
                Float(view.drawableSize.width),
                Float(view.drawableSize.height),
                Float(backgroundTexture.width),
                Float(backgroundTexture.height)
            ),
            options: SIMD4<UInt32>(depthFlags, UInt32(settings.orientation.rawValue), 0, 0),
            depthProjection: SIMD4(projection.columns.2.z, projection.columns.3.z,
                                   projection.columns.2.w, projection.columns.3.w)
        )
        encoder.setFragmentTexture(backgroundTexture, index: 0)
        encoder.setFragmentTexture(depthTextures?.sceneDepth ?? emptyDepthTexture, index: 1)
        encoder.setFragmentTexture(depthTextures?.personDepth ?? emptyDepthTexture, index: 2)
        encoder.setFragmentTexture(depthTextures?.personMask ?? emptyMaskTexture, index: 3)
        encoder.setFragmentBytes(
            &backgroundUniforms,
            length: MemoryLayout<ARBackgroundUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // Placed geometry.
        encoder.setDepthStencilState(objectDepthState)
        encoder.setRenderPipelineState(objectSolidPipeline)
        let anchored = settings.parameters.physicsMode == .anchored

        for object in settings.objects {
            guard let resolvedMesh = resolveMesh(for: object) else { continue }
            let model = Self.modelMatrix(
                for: object,
                time: now,
                audioBoost: audioLevel,
                anchored: anchored
            )
            let tintRGB: SIMD3<Float>
            let glowScaled: Float
            let materialRaw: UInt32
            if object.isBlackHole {
                tintRGB = SIMD3(0.05, 0.0, 0.18)
                glowScaled = max(object.glow * 2.4, 1.7)
                materialRaw = ARObjectMaterialMode.solidRim.rawValue
            } else {
                tintRGB = ARObjectPalette.resolveTint(for: object) * roomLight
                glowScaled = object.glow
                materialRaw = object.material.rawValue
            }

            let isSelected = (settings.selectedObjectID != nil && settings.selectedObjectID == object.id)
            var uniforms = ARObjectUniforms(
                model: model,
                viewProjection: viewProjection,
                cameraPosition: SIMD4(cameraPosition, audioLevel),
                tint: SIMD4(tintRGB, object.opacity),
                tuning: SIMD4(
                    Float(now.truncatingRemainder(dividingBy: 3600)),
                    object.metallic,
                    glowScaled,
                    object.rimSharpness
                ),
                options: SIMD4<UInt32>(
                    materialRaw,
                    0,
                    0,
                    isSelected ? 1 : 0
                )
            )

            for (index, buffer) in resolvedMesh.vertexBuffers.enumerated() {
                encoder.setVertexBuffer(buffer.buffer, offset: buffer.offset, index: index)
            }

            let isWireframeMode = (object.material == .wireframe)
            encoder.setTriangleFillMode(isWireframeMode ? .lines : .fill)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<ARObjectUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ARObjectUniforms>.stride, index: 0)
            for submesh in resolvedMesh.submeshes {
                encoder.drawIndexedPrimitives(
                    type: submesh.primitiveType,
                    indexCount: submesh.indexCount,
                    indexType: submesh.indexType,
                    indexBuffer: submesh.indexBuffer.buffer,
                    indexBufferOffset: submesh.indexBuffer.offset
                )
            }

            // Optional wireframe lattice overlay on top of solid/shaded materials
            if object.wire, !isWireframeMode {
                uniforms.options.y = 1
                encoder.setTriangleFillMode(.lines)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<ARObjectUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ARObjectUniforms>.stride, index: 0)
                for submesh in resolvedMesh.submeshes {
                    encoder.drawIndexedPrimitives(
                        type: submesh.primitiveType,
                        indexCount: submesh.indexCount,
                        indexType: submesh.indexType,
                        indexBuffer: submesh.indexBuffer.buffer,
                        indexBufferOffset: submesh.indexBuffer.offset
                    )
                }
            }
        }
        encoder.setTriangleFillMode(.fill)
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
        if !didReportFirstFrame {
            didReportFirstFrame = true
            GVLog.rendering.notice("AR objects renderer drew its first frame: \(settings.objects.count, privacy: .public) objects")
        }
    }

    private struct ARObjectRecordLease: @unchecked Sendable {
        let cacheLease: CVMetalTexture
        let texture: MTLTexture
        let pixelBuffer: CVPixelBuffer
    }

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
        var leases = [lumaLease.0, chromaLease.0]
        func single(_ buffer: CVPixelBuffer?, _ format: MTLPixelFormat) -> MTLTexture? {
            guard let buffer,
                  let made = makeTexture(pixelBuffer: buffer, pixelFormat: format, plane: 0,
                                         width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            else { return nil }
            leases.append(made.0)
            return made.1
        }
        let sceneDepth = single(frame.sceneDepth, .r32Float)
        let personDepth = single(frame.personDepth, .r32Float)
        let personMask = single(frame.personMask, .r8Unorm)
        return ARObjectFrameLease(
            luma: lumaLease.1,
            chroma: chromaLease.1,
            sceneDepth: sceneDepth,
            personDepth: personDepth,
            personMask: personMask,
            leases: leases
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

    private func resolveMesh(for object: ARObjectDescriptor) -> MTKMesh? {
        if let modelID = object.userModelID {
            if let cached = userModelMeshes[modelID] {
                return cached
            }
            if !failedUserModelIDs.contains(modelID),
               let url = modelStore.fileURL(for: modelID),
               let loaded = Self.makeUserModelMesh(from: url, device: device)
            {
                userModelMeshes[modelID] = loaded
                return loaded
            } else {
                failedUserModelIDs.insert(modelID)
            }
        }
        return mesh(for: object.shape)
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

    /// Interleaved position + normal, 24-byte stride, buffer 0 — the layout
    /// `GVARObjectVertexIn` reads and the object pipeline declares.
    static var meshVertexDescriptor: MDLVertexDescriptor {
        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(
            name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0
        )
        descriptor.attributes[1] = MDLVertexAttribute(
            name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0
        )
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: 24)
        return descriptor
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func makeMesh(shape: ARObjectShape, device: MTLDevice) -> MTKMesh? {
        let allocator = MTKMeshBufferAllocator(device: device)
        let mesh: MDLMesh? = switch shape {
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
            MDLMesh.newBox(
                withDimensions: SIMD3<Float>(1.10, 0.68, 0.06),
                segments: SIMD3<UInt32>(1, 1, 1),
                geometryType: .triangles,
                inwardNormals: false,
                allocator: allocator
            )
        case .torus:
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
            MDLMesh.newCylinder(
                withHeight: 0.96,
                radii: SIMD2<Float>(0.44, 0.44),
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
        case .torusKnot:
            makeTorusKnot(p: 2, q: 3, allocator: allocator)
        case .octahedron:
            makeBipyramid(sides: 4, radius: 0.52, halfHeight: 0.56, allocator: allocator)
        case .tetrahedron:
            MDLMesh.newEllipticalCone(
                withHeight: 0.92,
                radii: SIMD2<Float>(0.54, 0.54),
                radialSegments: 3,
                verticalSegments: 1,
                geometryType: .triangles,
                inwardNormals: false,
                allocator: allocator
            )
        case .pyramid:
            MDLMesh.newEllipticalCone(
                withHeight: 0.92,
                radii: SIMD2<Float>(0.54, 0.54),
                radialSegments: 4,
                verticalSegments: 1,
                geometryType: .triangles,
                inwardNormals: false,
                allocator: allocator
            )
        case .stellated:
            makeStellatedStar(allocator: allocator)
        case .helix:
            makeHelix(allocator: allocator)
        case .mobius:
            makeMobiusStrip(allocator: allocator)
        case .gyroscope:
            makeGyroscope(allocator: allocator)
        case .crystal:
            makeCrystal(allocator: allocator)
        case .waveGrid:
            makeWaveGrid(allocator: allocator)
        case .asteroid:
            makeAsteroid(allocator: allocator)
        case .baby, .melissa:
            loadScannedMeshOrProceduralFallback(shape: shape, allocator: allocator)
        case .vase, .pear, .column, .screw, .dna, .spaceFrame, .oliveTree, .interchange:
            GVStillLifeMeshes.make(shape, allocator: allocator)
        }

        guard let mesh else { return nil }
        mesh.vertexDescriptor = meshVertexDescriptor
        return try? MTKMesh(mesh: mesh, device: device)
    }

    // MARK: - Procedural & Parametric Mesh Generators

    private static func buildInterleavedMesh(
        vertices: [Float],
        indices: [UInt32],
        allocator: MTKMeshBufferAllocator
    ) -> MDLMesh {
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
        return MDLMesh(
            vertexBuffer: vertexBuffer,
            vertexCount: vertices.count / 6,
            descriptor: meshVertexDescriptor,
            submeshes: [submesh]
        )
    }

    private static func appendFlatTriangle(
        _ a: SIMD3<Float>,
        _ b: SIMD3<Float>,
        _ c: SIMD3<Float>,
        vertices: inout [Float],
        indices: inout [UInt32]
    ) {
        let edge1 = b - a
        let edge2 = c - a
        let crossVec = simd_cross(edge1, edge2)
        let len = simd_length(crossVec)
        let normal = len > 0.00001 ? crossVec / len : SIMD3<Float>(0, 1, 0)
        let baseIndex = UInt32(vertices.count / 6)
        for pt in [a, b, c] {
            vertices.append(contentsOf: [pt.x, pt.y, pt.z, normal.x, normal.y, normal.z])
        }
        indices.append(contentsOf: [baseIndex, baseIndex + 1, baseIndex + 2])
    }

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
        return buildInterleavedMesh(vertices: vertices, indices: indices, allocator: allocator)
    }

    private static func makeTorusKnot(
        p: Int,
        q: Int,
        tubularSegments: Int = 128,
        radialSegments: Int = 16,
        tubeRadius: Float = 0.095,
        allocator: MTKMeshBufferAllocator
    ) -> MDLMesh {
        func knotPoint(_ t: Float) -> SIMD3<Float> {
            let pf = Float(p)
            let qf = Float(q)
            let r = 0.30 * (1.0 + 0.42 * cos(qf * t))
            return SIMD3<Float>(
                r * cos(pf * t),
                0.30 * 0.48 * sin(qf * t),
                r * sin(pf * t)
            )
        }

        var vertices: [Float] = []
        var indices: [UInt32] = []
        let eps: Float = 0.002

        for i in 0 ... tubularSegments {
            let t = Float(i) / Float(tubularSegments) * 2.0 * .pi
            let center = knotPoint(t)
            let nextCenter = knotPoint(t + eps)
            let tangent = simd_normalize(nextCenter - center)
            let upGuess = abs(tangent.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
            let normalAxis = simd_normalize(simd_cross(tangent, upGuess))
            let binormalAxis = simd_normalize(simd_cross(tangent, normalAxis))

            for j in 0 ... radialSegments {
                let v = Float(j) / Float(radialSegments) * 2.0 * .pi
                let n = normalAxis * cos(v) + binormalAxis * sin(v)
                let pos = center + n * tubeRadius
                vertices.append(contentsOf: [pos.x, pos.y, pos.z, n.x, n.y, n.z])
            }
        }

        let ring = UInt32(radialSegments + 1)
        for i in 0 ..< UInt32(tubularSegments) {
            for j in 0 ..< UInt32(radialSegments) {
                let a = i * ring + j
                let b = a + ring
                indices.append(contentsOf: [a, b, a + 1, a + 1, b, b + 1])
            }
        }
        return buildInterleavedMesh(vertices: vertices, indices: indices, allocator: allocator)
    }

    private static func makeBipyramid(
        sides: Int,
        radius: Float,
        halfHeight: Float,
        allocator: MTKMeshBufferAllocator
    ) -> MDLMesh {
        var vertices: [Float] = []
        var indices: [UInt32] = []
        let top = SIMD3<Float>(0, halfHeight, 0)
        let bottom = SIMD3<Float>(0, -halfHeight, 0)

        for i in 0 ..< sides {
            let a0 = Float(i) / Float(sides) * 2.0 * .pi
            let a1 = Float(i + 1) / Float(sides) * 2.0 * .pi
            let p0 = SIMD3<Float>(cos(a0) * radius, 0, sin(a0) * radius)
            let p1 = SIMD3<Float>(cos(a1) * radius, 0, sin(a1) * radius)
            appendFlatTriangle(top, p1, p0, vertices: &vertices, indices: &indices)
            appendFlatTriangle(bottom, p0, p1, vertices: &vertices, indices: &indices)
        }
        return buildInterleavedMesh(vertices: vertices, indices: indices, allocator: allocator)
    }

    private static func makeCrystal(allocator: MTKMeshBufferAllocator) -> MDLMesh {
        var vertices: [Float] = []
        var indices: [UInt32] = []
        let sides = 6
        let r: Float = 0.28
        let waist: Float = 0.28
        let tip: Float = 0.58
        let topApex = SIMD3<Float>(0, tip, 0)
        let botApex = SIMD3<Float>(0, -tip, 0)

        for i in 0 ..< sides {
            let a0 = Float(i) / Float(sides) * 2.0 * .pi
            let a1 = Float(i + 1) / Float(sides) * 2.0 * .pi
            let t0 = SIMD3<Float>(cos(a0) * r, waist, sin(a0) * r)
            let t1 = SIMD3<Float>(cos(a1) * r, waist, sin(a1) * r)
            let b0 = SIMD3<Float>(cos(a0) * r, -waist, sin(a0) * r)
            let b1 = SIMD3<Float>(cos(a1) * r, -waist, sin(a1) * r)

            appendFlatTriangle(topApex, t1, t0, vertices: &vertices, indices: &indices)
            appendFlatTriangle(t0, t1, b1, vertices: &vertices, indices: &indices)
            appendFlatTriangle(t0, b1, b0, vertices: &vertices, indices: &indices)
            appendFlatTriangle(botApex, b0, b1, vertices: &vertices, indices: &indices)
        }
        return buildInterleavedMesh(vertices: vertices, indices: indices, allocator: allocator)
    }

    private static func makeStellatedStar(allocator: MTKMeshBufferAllocator) -> MDLMesh {
        let phi: Float = (1.0 + sqrt(5.0)) * 0.5
        let rawVerts: [SIMD3<Float>] = [
            SIMD3(-1, phi, 0), SIMD3(1, phi, 0), SIMD3(-1, -phi, 0), SIMD3(1, -phi, 0),
            SIMD3(0, -1, phi), SIMD3(0, 1, phi), SIMD3(0, -1, -phi), SIMD3(0, 1, -phi),
            SIMD3(phi, 0, -1), SIMD3(phi, 0, 1), SIMD3(-phi, 0, -1), SIMD3(-phi, 0, 1)
        ].map { simd_normalize($0) * 0.26 }

        let faces: [(Int, Int, Int)] = [
            (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
            (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
            (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
            (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)
        ]

        var vertices: [Float] = []
        var indices: [UInt32] = []
        for (i0, i1, i2) in faces {
            let v0 = rawVerts[i0]
            let v1 = rawVerts[i1]
            let v2 = rawVerts[i2]
            let center = simd_normalize((v0 + v1 + v2) / 3.0) * 0.56
            appendFlatTriangle(v0, v1, center, vertices: &vertices, indices: &indices)
            appendFlatTriangle(v1, v2, center, vertices: &vertices, indices: &indices)
            appendFlatTriangle(v2, v0, center, vertices: &vertices, indices: &indices)
        }
        return buildInterleavedMesh(vertices: vertices, indices: indices, allocator: allocator)
    }

    private static func makeHelix(allocator: MTKMeshBufferAllocator) -> MDLMesh {
        let segs = 96
        let radSegs = 12
        let coilRadius: Float = 0.30
        let tubeRadius: Float = 0.068
        let turns: Float = 3.0
        let height: Float = 0.96

        func centerAt(_ s: Float) -> SIMD3<Float> {
            let a = s * turns * 2.0 * .pi
            return SIMD3<Float>(cos(a) * coilRadius, (s - 0.5) * height, sin(a) * coilRadius)
        }

        var vertices: [Float] = []
        var indices: [UInt32] = []
        for i in 0 ... segs {
            let s = Float(i) / Float(segs)
            let c0 = centerAt(s)
            let c1 = centerAt(s + 0.002)
            let tangent = simd_normalize(c1 - c0)
            let nAxis = simd_normalize(simd_cross(tangent, SIMD3<Float>(0, 1, 0)))
            let bAxis = simd_normalize(simd_cross(tangent, nAxis))
            for j in 0 ... radSegs {
                let v = Float(j) / Float(radSegs) * 2.0 * .pi
                let n = nAxis * cos(v) + bAxis * sin(v)
                let p = c0 + n * tubeRadius
                vertices.append(contentsOf: [p.x, p.y, p.z, n.x, n.y, n.z])
            }
        }

        let ring = UInt32(radSegs + 1)
        for i in 0 ..< UInt32(segs) {
            for j in 0 ..< UInt32(radSegs) {
                let a = i * ring + j
                let b = a + ring
                indices.append(contentsOf: [a, b, a + 1, a + 1, b, b + 1])
            }
        }
        return buildInterleavedMesh(vertices: vertices, indices: indices, allocator: allocator)
    }

    private static func makeMobiusStrip(allocator: MTKMeshBufferAllocator) -> MDLMesh {
        let uSegs = 64
        let vSegs = 14
        let radius: Float = 0.40
        let halfWidth: Float = 0.16
        var vertices: [Float] = []
        var indices: [UInt32] = []

        func eval(_ u: Float, _ v: Float) -> SIMD3<Float> {
            let halfU = u * 0.5
            let r = radius + v * cos(halfU)
            return SIMD3<Float>(r * cos(u), v * sin(halfU), r * sin(u))
        }

        for i in 0 ..< uSegs {
            let u0 = Float(i) / Float(uSegs) * 2.0 * .pi
            let u1 = Float(i + 1) / Float(uSegs) * 2.0 * .pi
            for j in 0 ..< vSegs {
                let v0 = (Float(j) / Float(vSegs) * 2.0 - 1.0) * halfWidth
                let v1 = (Float(j + 1) / Float(vSegs) * 2.0 - 1.0) * halfWidth
                let p00 = eval(u0, v0)
                let p10 = eval(u1, v0)
                let p11 = eval(u1, v1)
                let p01 = eval(u0, v1)
                // Double-sided so non-orientable strip is lit from both sides
                appendFlatTriangle(p00, p10, p11, vertices: &vertices, indices: &indices)
                appendFlatTriangle(p00, p11, p01, vertices: &vertices, indices: &indices)
                appendFlatTriangle(p00, p11, p10, vertices: &vertices, indices: &indices)
                appendFlatTriangle(p00, p01, p11, vertices: &vertices, indices: &indices)
            }
        }
        return buildInterleavedMesh(vertices: vertices, indices: indices, allocator: allocator)
    }

    private static func makeGyroscope(allocator: MTKMeshBufferAllocator) -> MDLMesh {
        var vertices: [Float] = []
        var indices: [UInt32] = []
        let rings: [(Float, Float, simd_float3x3)] = [
            (0.48, 0.042, matrix_identity_float3x3),
            (0.38, 0.040, simd_float3x3(columns: (
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(0, 0, 1),
                SIMD3<Float>(0, -1, 0)
            ))),
            (0.28, 0.038, simd_float3x3(columns: (
                SIMD3<Float>(0, 1, 0),
                SIMD3<Float>(-1, 0, 0),
                SIMD3<Float>(0, 0, 1)
            )))
        ]
        let majorSegs = 40
        let minorSegs = 12
        let ringStride = UInt32(minorSegs + 1)

        for (majorR, minorR, rot) in rings {
            let baseVertex = UInt32(vertices.count / 6)
            for major in 0 ... majorSegs {
                let u = Float(major) / Float(majorSegs) * 2 * .pi
                let cosU = cos(u)
                let sinU = sin(u)
                for minor in 0 ... minorSegs {
                    let v = Float(minor) / Float(minorSegs) * 2 * .pi
                    let cosV = cos(v)
                    let sinV = sin(v)
                    let n = rot * SIMD3<Float>(cosU * cosV, sinV, sinU * cosV)
                    let p = rot * SIMD3<Float>(
                        (majorR + minorR * cosV) * cosU,
                        minorR * sinV,
                        (majorR + minorR * cosV) * sinU
                    )
                    vertices.append(contentsOf: [p.x, p.y, p.z, n.x, n.y, n.z])
                }
            }
            for major in 0 ..< UInt32(majorSegs) {
                for minor in 0 ..< UInt32(minorSegs) {
                    let a = baseVertex + major * ringStride + minor
                    let b = a + ringStride
                    indices.append(contentsOf: [a, b, a + 1, a + 1, b, b + 1])
                }
            }
        }
        return buildInterleavedMesh(vertices: vertices, indices: indices, allocator: allocator)
    }

    private static func makeWaveGrid(allocator: MTKMeshBufferAllocator) -> MDLMesh {
        let cols = 24
        let rows = 24
        var vertices: [Float] = []
        var indices: [UInt32] = []

        func wavePoint(_ ix: Int, _ iz: Int) -> SIMD3<Float> {
            let x = (Float(ix) / Float(cols) - 0.5) * 0.96
            let z = (Float(iz) / Float(rows) - 0.5) * 0.96
            let r = sqrt(x * x + z * z)
            let y = sin(r * 14.0) * 0.14 * cos(x * 4.0)
            return SIMD3<Float>(x, y, z)
        }

        for iz in 0 ..< rows {
            for ix in 0 ..< cols {
                let p00 = wavePoint(ix, iz)
                let p10 = wavePoint(ix + 1, iz)
                let p11 = wavePoint(ix + 1, iz + 1)
                let p01 = wavePoint(ix, iz + 1)
                appendFlatTriangle(p00, p10, p11, vertices: &vertices, indices: &indices)
                appendFlatTriangle(p00, p11, p01, vertices: &vertices, indices: &indices)
                appendFlatTriangle(p00, p11, p10, vertices: &vertices, indices: &indices)
                appendFlatTriangle(p00, p01, p11, vertices: &vertices, indices: &indices)
            }
        }
        return buildInterleavedMesh(vertices: vertices, indices: indices, allocator: allocator)
    }

    private static func makeAsteroid(allocator: MTKMeshBufferAllocator) -> MDLMesh {
        let latSegs = 20
        let lonSegs = 28
        var vertices: [Float] = []
        var indices: [UInt32] = []

        func displaced(_ theta: Float, _ phi: Float) -> SIMD3<Float> {
            let dir = SIMD3<Float>(
                sin(theta) * cos(phi),
                cos(theta),
                sin(theta) * sin(phi)
            )
            let noise = 0.08 * sin(dir.x * 7.0 + dir.y * 5.0)
                + 0.05 * cos(dir.z * 9.0 - dir.x * 4.0)
                + 0.04 * sin(dir.y * 11.0 + dir.z * 6.0)
            return dir * (0.44 + noise)
        }

        for i in 0 ..< latSegs {
            let t0 = Float(i) / Float(latSegs) * .pi
            let t1 = Float(i + 1) / Float(latSegs) * .pi
            for j in 0 ..< lonSegs {
                let p0 = Float(j) / Float(lonSegs) * 2.0 * .pi
                let p1 = Float(j + 1) / Float(lonSegs) * 2.0 * .pi
                let v00 = displaced(t0, p0)
                let v10 = displaced(t1, p0)
                let v11 = displaced(t1, p1)
                let v01 = displaced(t0, p1)
                appendFlatTriangle(v00, v10, v11, vertices: &vertices, indices: &indices)
                appendFlatTriangle(v00, v11, v01, vertices: &vertices, indices: &indices)
            }
        }
        return buildInterleavedMesh(vertices: vertices, indices: indices, allocator: allocator)
    }

    private static func makeSculptedBustFallback(
        isRelic: Bool,
        allocator: MTKMeshBufferAllocator
    ) -> MDLMesh {
        let stacks = 28
        let slices = 24
        var vertices: [Float] = []
        var indices: [UInt32] = []

        func profile(_ u: Float, _ v: Float) -> SIMD3<Float> {
            let y = (v - 0.5) * 1.0
            let angle = u * 2.0 * .pi
            if isRelic {
                let twist = v * .pi * 2.2
                let baseR = 0.26 + 0.14 * sin(v * .pi * 3.0)
                let crown = (Int(u * 12) % 2 == 0) ? Float(1.16) : Float(0.88)
                let r = baseR * crown * (1.0 - 0.35 * pow(abs(v - 0.5) * 1.8, 2))
                return SIMD3<Float>(cos(angle + twist) * r, y, sin(angle + twist) * r)
            } else {
                // Cranial bust silhouette: pedestal, neck, cranium
                let r: Float = if v < 0.22 {
                    0.34 - (v * 0.6)
                } else if v < 0.42 {
                    0.18 + 0.04 * sin((v - 0.22) * 15.0)
                } else {
                    0.33 * sin(min(max((v - 0.35) / 0.65, 0.05), 0.98) * .pi)
                }
                let jaw: Float = (v > 0.42 && v < 0.72) ? (1.0 + 0.14 * cos(angle)) : 1.0
                return SIMD3<Float>(cos(angle) * r * jaw, y, sin(angle) * r)
            }
        }

        for i in 0 ..< stacks {
            let v0 = Float(i) / Float(stacks)
            let v1 = Float(i + 1) / Float(stacks)
            for j in 0 ..< slices {
                let u0 = Float(j) / Float(slices)
                let u1 = Float(j + 1) / Float(slices)
                let p00 = profile(u0, v0)
                let p10 = profile(u1, v0)
                let p11 = profile(u1, v1)
                let p01 = profile(u0, v1)
                appendFlatTriangle(p00, p10, p11, vertices: &vertices, indices: &indices)
                appendFlatTriangle(p00, p11, p01, vertices: &vertices, indices: &indices)
            }
        }
        return buildInterleavedMesh(vertices: vertices, indices: indices, allocator: allocator)
    }

    private static func loadScannedMeshOrProceduralFallback(
        shape: ARObjectShape,
        allocator: MTKMeshBufferAllocator
    ) -> MDLMesh? {
        let name: String? = switch shape {
        case .baby: "gv_baby"
        case .melissa: "gv_melissa"
        default: nil
        }
        if let name,
           let url = Bundle.main.url(forResource: name, withExtension: "usdz"),
           let loaded = loadNormalizedMDLMesh(from: url, allocator: allocator)
        {
            return loaded
        }
        return makeSculptedBustFallback(isRelic: shape == .melissa, allocator: allocator)
    }

    // MARK: - User Model Loader (Multi-Mesh Normalized)

    static func makeUserModelMesh(from url: URL, device: MTLDevice) -> MTKMesh? {
        let allocator = MTKMeshBufferAllocator(device: device)
        guard let mdlMesh = loadNormalizedMDLMesh(from: url, allocator: allocator) else {
            return nil
        }
        mdlMesh.vertexDescriptor = meshVertexDescriptor
        return try? MTKMesh(mesh: mdlMesh, device: device)
    }

    private static func loadNormalizedMDLMesh(
        from url: URL,
        allocator: MTKMeshBufferAllocator
    ) -> MDLMesh? {
        let sourceMeshes = ARUserModelStore.loadAllMeshes(from: url, allocator: allocator)
        guard !sourceMeshes.isEmpty else { return nil }

        // If single mesh, normalize directly in-place
        if sourceMeshes.count == 1, let single = sourceMeshes.first {
            if single.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal) == nil {
                single.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.2)
            }
            single.vertexDescriptor = meshVertexDescriptor
            normalizePositionsInPlace(single)
            return single
        }

        // Multi-mesh asset: conform each child mesh and merge into one normalized MDLMesh
        var combinedVertices: [Float] = []
        var combinedIndices: [UInt32] = []

        for mesh in sourceMeshes {
            if mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal) == nil {
                mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.2)
            }
            mesh.vertexDescriptor = meshVertexDescriptor
            guard let posData = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition),
                  let normData = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal)
            else { continue }

            let baseVertex = UInt32(combinedVertices.count / 6)
            let vCount = mesh.vertexCount
            for idx in 0 ..< vCount {
                let pPtr = posData.dataStart.advanced(by: idx * posData.stride).assumingMemoryBound(to: Float.self)
                let nPtr = normData.dataStart.advanced(by: idx * normData.stride).assumingMemoryBound(to: Float.self)
                combinedVertices.append(contentsOf: [
                    pPtr[0], pPtr[1], pPtr[2],
                    nPtr[0], nPtr[1], nPtr[2]
                ])
            }

            if let submeshes = mesh.submeshes as? [MDLSubmesh] {
                for sub in submeshes where sub.geometryType == .triangles {
                    let map = sub.indexBuffer.map()
                    let rawPtr = map.bytes
                    switch sub.indexType {
                    case .uInt16:
                        let ptr = rawPtr.assumingMemoryBound(to: UInt16.self)
                        for k in 0 ..< sub.indexCount {
                            combinedIndices.append(baseVertex + UInt32(ptr[k]))
                        }
                    case .uInt32:
                        let ptr = rawPtr.assumingMemoryBound(to: UInt32.self)
                        for k in 0 ..< sub.indexCount {
                            combinedIndices.append(baseVertex + ptr[k])
                        }
                    case .uInt8:
                        let ptr = rawPtr.assumingMemoryBound(to: UInt8.self)
                        for k in 0 ..< sub.indexCount {
                            combinedIndices.append(baseVertex + UInt32(ptr[k]))
                        }
                    default:
                        break
                    }
                }
            }
        }

        guard !combinedVertices.isEmpty, !combinedIndices.isEmpty else {
            if let fallback = sourceMeshes.first {
                normalizePositionsInPlace(fallback)
                return fallback
            }
            return nil
        }

        // Normalize combined vertices into unit box
        var minB = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxB = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        let vTotal = combinedVertices.count / 6
        for i in 0 ..< vTotal {
            let p = SIMD3<Float>(combinedVertices[i * 6], combinedVertices[i * 6 + 1], combinedVertices[i * 6 + 2])
            minB = simd_min(minB, p)
            maxB = simd_max(maxB, p)
        }
        let extent = maxB - minB
        let longest = max(extent.x, max(extent.y, extent.z), 0.0001)
        let center = (minB + maxB) * 0.5
        let scale = 1.0 / longest
        for i in 0 ..< vTotal {
            combinedVertices[i * 6] = (combinedVertices[i * 6] - center.x) * scale
            combinedVertices[i * 6 + 1] = (combinedVertices[i * 6 + 1] - center.y) * scale
            combinedVertices[i * 6 + 2] = (combinedVertices[i * 6 + 2] - center.z) * scale
        }

        return buildInterleavedMesh(
            vertices: combinedVertices,
            indices: combinedIndices,
            allocator: allocator
        )
    }

    private static func normalizePositionsInPlace(_ mesh: MDLMesh) {
        let bounds = mesh.boundingBox
        let extent = bounds.maxBounds - bounds.minBounds
        let longest = max(extent.x, max(extent.y, extent.z))
        guard longest > 0 else { return }
        let centre = (bounds.maxBounds + bounds.minBounds) * 0.5
        let normalise = 1.0 / longest

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
    }

    // MARK: - Transform Matrix

    private static func modelMatrix(
        for object: ARObjectDescriptor,
        time: TimeInterval,
        audioBoost: Float,
        anchored: Bool
    ) -> simd_float4x4 {
        let elapsed = Float(max(time - object.birthTime, 0))
        let angle = object.spinSpeed * elapsed * (1.0 + audioBoost * 0.5)
        let bob = anchored ? 0.0 : sin(elapsed * object.bobSpeed + object.phase) * object.bobAmplitude * object.scale
        let pulse = 1.0 + sin(elapsed * 2.4 + object.phase) * object.pulseAmount * 0.35 + audioBoost * 0.28
        let effectiveScale = object.scale * max(0.15, pulse)

        let degToRad: Float = .pi / 180.0
        let staticPitch = object.orientationDegrees.x * degToRad
        let staticYaw = object.orientationDegrees.y * degToRad + object.phase
        let staticRoll = object.orientationDegrees.z * degToRad

        let spinMatrix: simd_float4x4 = switch object.spinAxis {
        case .yaw:
            rotationYMatrix(angle)
        case .pitch:
            rotationXMatrix(angle)
        case .roll:
            rotationZMatrix(angle)
        case .tumble:
            rotationYMatrix(angle) * rotationXMatrix(angle * 0.73) * rotationZMatrix(angle * 0.41)
        case .none:
            matrix_identity_float4x4
        }

        var transform = translationMatrix(object.position + SIMD3<Float>(0, bob, 0))
        transform = transform * spinMatrix
        transform = transform * rotationYMatrix(staticYaw) * rotationXMatrix(staticPitch) * rotationZMatrix(staticRoll)
        let nonUniform = object.stretch * effectiveScale
        return transform * nonUniformScaleMatrix(nonUniform)
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

    private static func rotationZMatrix(_ angle: Float) -> simd_float4x4 {
        let cosine = cos(angle)
        let sine = sin(angle)
        return simd_float4x4(columns: (
            SIMD4<Float>(cosine, sine, 0, 0),
            SIMD4<Float>(-sine, cosine, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    private static func nonUniformScaleMatrix(_ scale: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(scale.x, 0, 0, 0),
            SIMD4<Float>(0, scale.y, 0, 0),
            SIMD4<Float>(0, 0, scale.z, 0),
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
