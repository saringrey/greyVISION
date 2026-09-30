import CoreVideo
import MetalKit
import simd
import SwiftUI

struct DepthMetalSurface: UIViewRepresentable {
    @ObservedObject var runtime: DepthRuntime

    func makeCoordinator() -> Coordinator {
        Coordinator(mailbox: runtime.mailbox)
    }

    func makeUIView(context: Context) -> DepthMetalView {
        let view = DepthMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.backgroundColor = .black
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.colorPixelFormat = .bgra8Unorm
        // A point cloud without a depth buffer paints in vertex order, so far
        // points overwrite near ones and the geometry never reads as solid.
        // This is the single biggest reason the cloud looked like a gimmick.
        view.depthStencilPixelFormat = .depth32Float
        view.clearDepth = 1.0
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.autoResizeDrawable = true
        context.coordinator.attach(to: view)
        view.accessibilityLabel = "LiDAR scene depth preview"
        view.accessibilityIdentifier = "depth.metal.preview"
        return view
    }

    func updateUIView(_ view: DepthMetalView, context: Context) {
        context.coordinator.renderer?.update(
            effect: runtime.effect,
            parameters: runtime.parameters
        )
        view.isPaused = runtime.snapshot.state != .running
    }

    static func dismantleUIView(_ view: DepthMetalView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
        view.onTap = nil
        coordinator.renderer?.shutdown()
        coordinator.renderer = nil
    }

    final class Coordinator {
        let mailbox: LatestDepthFrameMailbox
        let touchMailbox: CameraTouchMailbox
        fileprivate var renderer: DepthMetalRenderer?

        init(mailbox: LatestDepthFrameMailbox) {
            self.mailbox = mailbox
            touchMailbox = CameraTouchMailbox()
        }

        @MainActor
        func attach(to view: DepthMetalView) {
            guard let device = view.device,
                  let renderer = DepthMetalRenderer(
                      device: device,
                      colorPixelFormat: view.colorPixelFormat,
                      mailbox: mailbox,
                      touchMailbox: touchMailbox
                  )
            else {
                GVLog.rendering.error("LiDAR Metal renderer initialization failed")
                return
            }
            self.renderer = renderer
            view.delegate = renderer
            view.onTap = { [touchMailbox] point, size in
                // A tap is an impact: depth effects pulse from the touched point.
                guard size.width > 0, size.height > 0 else { return }
                let normalized = SIMD2<Float>(
                    Float(min(max(point.x / size.width, 0), 1)),
                    Float(min(max(point.y / size.height, 0), 1))
                )
                touchMailbox.began(position: normalized, velocity: .zero)
                touchMailbox.ended()
            }
            view.onTouchChanged = { [touchMailbox] event in
                switch event {
                case let .began(position, velocity):
                    touchMailbox.began(position: position, velocity: velocity)
                case let .moved(position, velocity):
                    touchMailbox.moved(position: position, velocity: velocity)
                case .ended:
                    touchMailbox.ended()
                }
            }
        }
    }
}

final class DepthMetalView: MTKView {
    var onTap: ((CGPoint, CGSize) -> Void)?
    var onTouchChanged: ((CameraTouchEvent) -> Void)?

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        let touch = UIPanGestureRecognizer(target: self, action: #selector(handleTouchPan(_:)))
        touch.minimumNumberOfTouches = 1
        touch.maximumNumberOfTouches = 1
        touch.cancelsTouchesInView = false
        addGestureRecognizer(touch)
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("DepthMetalView does not support Interface Builder")
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        onTap?(recognizer.location(in: self), bounds.size)
    }

    @objc private func handleTouchPan(_ recognizer: UIPanGestureRecognizer) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let location = recognizer.location(in: self)
        let normalized = SIMD2<Float>(
            Float(min(max(location.x / bounds.width, 0), 1)),
            Float(min(max(location.y / bounds.height, 0), 1))
        )
        let velocity = recognizer.velocity(in: self)
        let normalizedVelocity = SIMD2<Float>(
            Float(velocity.x / bounds.width),
            Float(velocity.y / bounds.height)
        )
        switch recognizer.state {
        case .began:
            onTouchChanged?(.began(normalized, normalizedVelocity))
        case .changed:
            onTouchChanged?(.moved(normalized, normalizedVelocity))
        case .ended, .cancelled, .failed:
            onTouchChanged?(.ended(normalized))
        default:
            break
        }
    }
}

struct DepthMetalUniforms {
    var intrinsics: SIMD4<Float>
    var viewport: SIMD4<Float>
    var tuning: SIMD4<Float>
    var pose: SIMD4<Float>
    var controls: SIMD4<Float>
    var interaction: SIMD4<Float>
    var source: SIMD4<UInt32>
    var options: SIMD4<UInt32>
    var worldFromCamera: simd_float4x4
    var scanOriginAge: SIMD4<Float>
}

private struct DepthSubmissionKey: Equatable {
    let timestamp: TimeInterval
    let effect: DepthEffectMode
    let parameters: DepthEffectParameters
    let viewport: CGSize
    let touch: CameraTouchSnapshot
}

private struct DepthRenderSettings {
    let effect: DepthEffectMode
    let parameters: DepthEffectParameters
    let touch: CameraTouchSnapshot
}

private final class DepthTextureSet: @unchecked Sendable {
    let frame: DepthFrame
    let luma: MTLTexture
    let chroma: MTLTexture
    let depth: MTLTexture
    let confidence: MTLTexture?
    let leases: [CVMetalTexture]

    init(
        frame: DepthFrame,
        luma: MTLTexture,
        chroma: MTLTexture,
        depth: MTLTexture,
        confidence: MTLTexture?,
        leases: [CVMetalTexture]
    ) {
        self.frame = frame
        self.luma = luma
        self.chroma = chroma
        self.depth = depth
        self.confidence = confidence
        self.leases = leases
    }
}

private final class DepthMaskTextureLease: @unchecked Sendable {
    let lease: CVMetalTexture

    init(_ lease: CVMetalTexture) {
        self.lease = lease
    }
}

private final class DepthMetalRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private let mailbox: LatestDepthFrameMailbox
    private let touchMailbox: CameraTouchMailbox
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let compositePipeline: MTLRenderPipelineState
    private let pointPipeline: MTLRenderPipelineState
    /// Depth test for the cloud; fullscreen passes use `flatDepthState`.
    private let pointDepthState: MTLDepthStencilState?
    private let flatDepthState: MTLDepthStencilState?
    private let presentPipeline: MTLRenderPipelineState
    private let settingsLock = NSLock()
    private let textureCache: CVMetalTextureCache
    private let fallbackConfidenceTexture: MTLTexture
    private let fallbackPersonMaskTexture: MTLTexture
    private let colorPixelFormat: MTLPixelFormat
    private let personAnalyzer = VisionPersonMaskAnalyzer()

    private let inFlight = DispatchSemaphore(value: 2)
    private var lastSubmission: DepthSubmissionKey?
    private var sessionGeneration: UInt64 = 0
    private var scanOrigin: SIMD3<Float>?
    private var scanStartedAt: TimeInterval = 0
    private var lastImpactTime: TimeInterval?
    private let animationEpoch = ProcessInfo.processInfo.systemUptime

    private var effect = DepthEffectMode.pointCloud
    private var parameters = DepthEffectParameters.defaults
    private var textureSet: DepthTextureSet?
    private var personMaskLease: DepthMaskTextureLease?
    private var personMaskTexture: MTLTexture?
    private var personMaskSequence: UInt64 = 0
    private var subjectOutputTexture: MTLTexture?
    private var subjectHistoryTexture: MTLTexture?
    private var hasSubjectHistory = false

    init?(
        device: MTLDevice,
        colorPixelFormat: MTLPixelFormat,
        mailbox: LatestDepthFrameMailbox,
        touchMailbox: CameraTouchMailbox
    ) {
        guard let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let fullscreenVertex = library.makeFunction(name: "gvDepthFullscreenVertex"),
              let compositeFragment = library.makeFunction(name: "gvDepthCompositeFragment"),
              let pointVertex = library.makeFunction(name: "gvDepthPointVertex"),
              let pointFragment = library.makeFunction(name: "gvDepthPointFragment"),
              let presentFragment = library.makeFunction(name: "gvDepthPresentFragment")
        else {
            return nil
        }

        let compositeDescriptor = MTLRenderPipelineDescriptor()
        compositeDescriptor.label = "greyVISION Depth Composite"
        compositeDescriptor.vertexFunction = fullscreenVertex
        compositeDescriptor.fragmentFunction = compositeFragment
        compositeDescriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        // Fullscreen offscreen feedback has no depth attachment.
        compositeDescriptor.depthAttachmentPixelFormat = .invalid

        let pointDescriptor = MTLRenderPipelineDescriptor()
        pointDescriptor.label = "greyVISION Depth Point Cloud"
        pointDescriptor.vertexFunction = pointVertex
        pointDescriptor.fragmentFunction = pointFragment
        pointDescriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        pointDescriptor.depthAttachmentPixelFormat = .depth32Float
        pointDescriptor.inputPrimitiveTopology = .point

        let presentDescriptor = MTLRenderPipelineDescriptor()
        presentDescriptor.label = "greyVISION Depth Present"
        presentDescriptor.vertexFunction = fullscreenVertex
        presentDescriptor.fragmentFunction = presentFragment
        presentDescriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        presentDescriptor.depthAttachmentPixelFormat = .depth32Float

        guard let compositePipeline = try? device.makeRenderPipelineState(descriptor: compositeDescriptor),
              let pointPipeline = try? device.makeRenderPipelineState(descriptor: pointDescriptor),
              let presentPipeline = try? device.makeRenderPipelineState(descriptor: presentDescriptor)
        else {
            return nil
        }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache
        else {
            return nil
        }

        let fallbackDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Uint,
            width: 1,
            height: 1,
            mipmapped: false
        )
        fallbackDescriptor.storageMode = .shared
        fallbackDescriptor.usage = .shaderRead
        guard let fallbackConfidenceTexture = device.makeTexture(descriptor: fallbackDescriptor) else {
            return nil
        }
        var maximumConfidence: UInt8 = 2
        fallbackConfidenceTexture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &maximumConfidence,
            bytesPerRow: MemoryLayout<UInt8>.stride
        )

        let maskDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        maskDescriptor.storageMode = .shared
        maskDescriptor.usage = .shaderRead
        guard let fallbackPersonMaskTexture = device.makeTexture(descriptor: maskDescriptor) else {
            return nil
        }
        var emptyMask: UInt8 = 0
        fallbackPersonMaskTexture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &emptyMask,
            bytesPerRow: MemoryLayout<UInt8>.stride
        )

        self.mailbox = mailbox
        self.touchMailbox = touchMailbox
        self.device = device
        self.commandQueue = commandQueue
        self.compositePipeline = compositePipeline
        let pointDepth = MTLDepthStencilDescriptor()
        pointDepth.depthCompareFunction = .less
        pointDepth.isDepthWriteEnabled = true
        pointDepthState = device.makeDepthStencilState(descriptor: pointDepth)

        let flatDepth = MTLDepthStencilDescriptor()
        flatDepth.depthCompareFunction = .always
        flatDepth.isDepthWriteEnabled = false
        flatDepthState = device.makeDepthStencilState(descriptor: flatDepth)

        self.pointPipeline = pointPipeline
        self.presentPipeline = presentPipeline
        textureCache = cache
        self.fallbackConfidenceTexture = fallbackConfidenceTexture
        self.fallbackPersonMaskTexture = fallbackPersonMaskTexture
        self.colorPixelFormat = colorPixelFormat
        super.init()
    }

    func update(effect: DepthEffectMode, parameters: DepthEffectParameters) {
        settingsLock.withLock {
            self.effect = effect
            self.parameters = parameters.sanitized
        }
    }

    func shutdown() {
        touchMailbox.clear()
        personAnalyzer.reset()
        textureSet = nil
        personMaskLease = nil
        personMaskTexture = nil
        subjectOutputTexture = nil
        subjectHistoryTexture = nil
        hasSubjectHistory = false
        scanOrigin = nil
        lastSubmission = nil
        lastImpactTime = nil
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}

    func draw(in view: MTKView) {
        // Dropping a render opportunity keeps capture and the UI responsive.
        guard inFlight.wait(timeout: .now()) == .success else { return }
        var submitted = false
        defer { if !submitted { inFlight.signal() } }
        let generation = mailbox.sessionGeneration
        if generation != sessionGeneration {
            sessionGeneration = generation
            scanOrigin = nil
            lastImpactTime = nil
            lastSubmission = nil
            textureSet = nil
            hasSubjectHistory = false
            personAnalyzer.reset()
            personMaskTexture = nil
            personMaskLease = nil
            personMaskSequence = 0
        }
        let settings = settingsLock.withLock {
            DepthRenderSettings(
                effect: effect,
                parameters: parameters,
                touch: touchMailbox.latest
            )
        }
        if let frame = mailbox.consumeLatest() {
            if settings.effect == .subjectDecay {
                personAnalyzer.submit(frame.capturedImage, orientation: frame.orientation)
            }
            if let textures = makeTextures(frame: frame) {
                textureSet = textures
            }
        }
        if settings.effect == .subjectDecay { updatePersonMaskTexture() }
        guard let textureSet, view.drawableSize.width.isFinite, view.drawableSize.height.isFinite,
              view.drawableSize.width > 0, view.drawableSize.height > 0 else { return }
        let key = DepthSubmissionKey(timestamp: textureSet.frame.timestamp, effect: settings.effect,
                                     parameters: settings.parameters, viewport: view.drawableSize, touch: settings.touch)
        guard DepthEffectCatalog.isAnimated(settings.effect) || key != lastSubmission else { return }
        if lastSubmission?.effect != settings.effect {
            hasSubjectHistory = false
            if settings.effect != .subjectDecay {
                subjectOutputTexture = nil
                subjectHistoryTexture = nil
                personAnalyzer.reset()
                personMaskTexture = nil
                personMaskLease = nil
                personMaskSequence = 0
            }
        }
        if settings.effect == .sonarPulse {
            updateScanOrigin(frame: textureSet.frame, settings: settings, viewport: view.drawableSize)
        }

        guard let drawable = view.currentDrawable,
              let renderPass = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        if settings.effect == .subjectDecay {
            guard ensureSubjectTextures(size: view.drawableSize),
                  let subjectOutputTexture,
                  let subjectHistoryTexture
            else { return }
            let subjectPass = MTLRenderPassDescriptor()
            subjectPass.colorAttachments[0].texture = subjectOutputTexture
            subjectPass.colorAttachments[0].loadAction = .clear
            subjectPass.colorAttachments[0].storeAction = .store
            subjectPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            guard encodeScene(
                pass: subjectPass,
                textureSet: textureSet,
                settings: settings,
                viewportSize: view.drawableSize,
                commandBuffer: commandBuffer,
                historyTexture: subjectHistoryTexture,
                hasTemporalHistory: hasSubjectHistory
            ) else { return }

            guard let presentEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return }
            presentEncoder.label = "greyVISION Subject Decay Present"
            presentEncoder.setRenderPipelineState(presentPipeline)
            presentEncoder.setDepthStencilState(flatDepthState)
            presentEncoder.setFragmentTexture(subjectOutputTexture, index: 0)
            presentEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            presentEncoder.endEncoding()
            // Command queue order protects the two textures across submissions.
            self.subjectOutputTexture = subjectHistoryTexture
            self.subjectHistoryTexture = subjectOutputTexture
            hasSubjectHistory = true
        } else {
            guard encodeScene(
                pass: renderPass,
                textureSet: textureSet,
                settings: settings,
                viewportSize: view.drawableSize,
                commandBuffer: commandBuffer,
                historyTexture: subjectHistoryTexture ?? fallbackPersonMaskTexture,
                hasTemporalHistory: false
            ) else { return }
        }

        let retainedTextureSet = textureSet
        let retainedMaskLease = personMaskLease
        commandBuffer.present(drawable)
        let limiter = inFlight
        commandBuffer.addCompletedHandler { _ in
            _ = retainedTextureSet
            _ = retainedMaskLease
            limiter.signal()
        }
        lastSubmission = key
        submitted = true
        commandBuffer.commit()
    }

    private func encodeScene(
        pass: MTLRenderPassDescriptor,
        textureSet: DepthTextureSet,
        settings: DepthRenderSettings,
        viewportSize: CGSize,
        commandBuffer: MTLCommandBuffer,
        historyTexture: MTLTexture,
        hasTemporalHistory: Bool
    ) -> Bool {
        if settings.effect != .pointCloud || settings.parameters.intensity == 0 {
            pass.depthAttachment.texture = nil
            pass.stencilAttachment.texture = nil
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var uniforms = makeUniforms(
            frame: textureSet.frame,
            depthTexture: textureSet.depth,
            viewportSize: viewportSize,
            settings: settings,
            hasConfidence: textureSet.confidence != nil,
            hasTemporalHistory: hasTemporalHistory
        )

        encoder.label = "greyVISION LiDAR Effect"
        encoder.setVertexTexture(textureSet.luma, index: 0)
        encoder.setVertexTexture(textureSet.chroma, index: 1)
        encoder.setVertexTexture(textureSet.depth, index: 2)
        encoder.setVertexTexture(textureSet.confidence ?? fallbackConfidenceTexture, index: 3)
        encoder.setFragmentTexture(textureSet.luma, index: 0)
        encoder.setFragmentTexture(textureSet.chroma, index: 1)
        encoder.setFragmentTexture(textureSet.depth, index: 2)
        encoder.setFragmentTexture(textureSet.confidence ?? fallbackConfidenceTexture, index: 3)
        encoder.setFragmentTexture(personMaskTexture ?? fallbackPersonMaskTexture, index: 4)
        encoder.setFragmentTexture(historyTexture, index: 5)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<DepthMetalUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DepthMetalUniforms>.stride, index: 0)

        if settings.effect == .pointCloud, settings.parameters.intensity > 0 {
            encoder.setRenderPipelineState(pointPipeline)
            encoder.setDepthStencilState(pointDepthState)
            let stride = max(1, Int(settings.parameters.sampleStride.rounded()))
            let columns = (textureSet.depth.width + stride - 1) / stride
            let rows = (textureSet.depth.height + stride - 1) / stride
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: columns * rows)
        } else {
            encoder.setRenderPipelineState(compositePipeline)
            encoder.setDepthStencilState(flatDepthState)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        return true
    }

    private func makeUniforms(
        frame: DepthFrame,
        depthTexture: MTLTexture,
        viewportSize: CGSize,
        settings: DepthRenderSettings,
        hasConfidence: Bool,
        hasTemporalHistory: Bool
    ) -> DepthMetalUniforms {
        let effect = settings.effect
        let touch = settings.touch
        let parameters = settings.parameters
        let imageWidth = max(Float(frame.imageDimensions.width), 1)
        let imageHeight = max(Float(frame.imageDimensions.height), 1)
        let depthWidth = Float(depthTexture.width)
        let depthHeight = Float(depthTexture.height)
        let scaleX = depthWidth / imageWidth
        let scaleY = depthHeight / imageHeight
        let cameraIntrinsics = frame.intrinsics
        let intrinsics = SIMD4<Float>(
            cameraIntrinsics.columns.0.x * scaleX,
            cameraIntrinsics.columns.1.y * scaleY,
            cameraIntrinsics.columns.2.x * scaleX,
            cameraIntrinsics.columns.2.y * scaleY
        )
        let orientation = UInt32(frame.orientation.rawValue)
        return DepthMetalUniforms(
            intrinsics: intrinsics,
            viewport: SIMD4<Float>(
                Float(viewportSize.width),
                Float(viewportSize.height),
                imageWidth,
                imageHeight
            ),
            tuning: SIMD4<Float>(
                Float(parameters.nearMeters),
                Float(max(parameters.farMeters, parameters.nearMeters + 0.05)),
                Float(parameters.intensity),
                Float(parameters.pointSize)
            ),
            pose: SIMD4<Float>(
                Float(parameters.yawDegrees * .pi / 180),
                Float(parameters.pitchDegrees * .pi / 180),
                min(max(touch.velocity.x, -2), 2),
                min(max(touch.velocity.y, -2), 2)
            ),
            controls: parameters.packedControls(for: settings.effect),
            interaction: SIMD4<Float>(
                touch.position.x,
                touch.position.y,
                Float(ProcessInfo.processInfo.systemUptime - animationEpoch),
                touch.isActive ? 1 : 0
            ),
            source: SIMD4<UInt32>(
                UInt32(depthTexture.width),
                UInt32(depthTexture.height),
                UInt32(max(1, Int(parameters.sampleStride.rounded()))),
                UInt32(min(max(Int(parameters.confidenceThreshold.rounded()), 0), 2))
            ),
            options: SIMD4<UInt32>(
                effect.rawValue,
                orientation,
                hasConfidence ? 1 : 0,
                hasTemporalHistory ? 1 : 0
            ),
            worldFromCamera: frame.cameraTransform,
            scanOriginAge: SIMD4(scanOrigin?.x ?? 0, scanOrigin?.y ?? 0, scanOrigin?.z ?? 0,
                                 scanOrigin == nil ? -1 : Float(max(0, ProcessInfo.processInfo.systemUptime - scanStartedAt)))
        )
    }

    private func updateScanOrigin(frame: DepthFrame, settings: DepthRenderSettings, viewport: CGSize) {
        let size = SIMD2(Float(viewport.width), Float(viewport.height))
        if let impactTime = settings.touch.impactTime, impactTime != lastImpactTime {
            lastImpactTime = impactTime
            if let position = settings.touch.impactPosition,
               let anchor = DepthGeometry.anchor(viewUV: position, viewport: size, frame: frame, parameters: settings.parameters)
            {
                scanOrigin = anchor
                scanStartedAt = ProcessInfo.processInfo.systemUptime
            }
        }
        if scanOrigin == nil,
           let anchor = DepthGeometry.anchor(viewUV: SIMD2(repeating: 0.5), viewport: size, frame: frame, parameters: settings.parameters)
        {
            scanOrigin = anchor
            scanStartedAt = ProcessInfo.processInfo.systemUptime
        }
    }

    private func updatePersonMaskTexture() {
        guard let maskFrame = personAnalyzer.latestMask(), maskFrame.sequence != personMaskSequence else {
            return
        }
        let pixelBuffer = maskFrame.pixelBuffer
        guard let texture = makeTexture(
            pixelBuffer: pixelBuffer,
            pixelFormat: .r8Unorm,
            plane: 0,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        ) else { return }
        personMaskLease = DepthMaskTextureLease(texture.0)
        personMaskTexture = texture.1
        personMaskSequence = maskFrame.sequence
    }

    private func ensureSubjectTextures(size: CGSize) -> Bool {
        let width = max(Int(size.width.rounded()), 1)
        let height = max(Int(size.height.rounded()), 1)
        let texturesMatch = subjectOutputTexture?.width == width
            && subjectOutputTexture?.height == height
            && subjectHistoryTexture?.width == width
            && subjectHistoryTexture?.height == height
        if texturesMatch {
            return true
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorPixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let output = device.makeTexture(descriptor: descriptor),
              let history = device.makeTexture(descriptor: descriptor)
        else { return false }
        output.label = "greyVISION Subject Decay Output"
        history.label = "greyVISION Subject Decay History"
        subjectOutputTexture = output
        subjectHistoryTexture = history
        hasSubjectHistory = false
        return true
    }

    private func makeTextures(frame: DepthFrame) -> DepthTextureSet? {
        guard CVPixelBufferGetPlaneCount(frame.capturedImage) >= 2,
              let lumaLease = makeTexture(
                  pixelBuffer: frame.capturedImage,
                  pixelFormat: .r8Unorm,
                  plane: 0,
                  width: CVPixelBufferGetWidthOfPlane(frame.capturedImage, 0),
                  height: CVPixelBufferGetHeightOfPlane(frame.capturedImage, 0)
              ),
              let chromaLease = makeTexture(
                  pixelBuffer: frame.capturedImage,
                  pixelFormat: .rg8Unorm,
                  plane: 1,
                  width: CVPixelBufferGetWidthOfPlane(frame.capturedImage, 1),
                  height: CVPixelBufferGetHeightOfPlane(frame.capturedImage, 1)
              ),
              let depthLease = makeTexture(
                  pixelBuffer: frame.depthMap,
                  pixelFormat: .r32Float,
                  plane: 0,
                  width: CVPixelBufferGetWidth(frame.depthMap),
                  height: CVPixelBufferGetHeight(frame.depthMap)
              )
        else {
            return nil
        }

        let confidenceLease = frame.confidenceMap.flatMap { confidenceMap in
            makeTexture(
                pixelBuffer: confidenceMap,
                pixelFormat: .r8Uint,
                plane: 0,
                width: CVPixelBufferGetWidth(confidenceMap),
                height: CVPixelBufferGetHeight(confidenceMap)
            )
        }
        let leases = [lumaLease.0, chromaLease.0, depthLease.0] + [confidenceLease?.0].compactMap(\.self)
        return DepthTextureSet(
            frame: frame,
            luma: lumaLease.1,
            chroma: chromaLease.1,
            depth: depthLease.1,
            confidence: confidenceLease?.1,
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
}
