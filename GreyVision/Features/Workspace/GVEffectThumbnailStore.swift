import CoreImage
import Foundation
import Metal
import simd
import UIKit

/// Lazy, cached samples of the shipping effects, never captures of the user's
/// camera. One utility-queue job at a time bounds GPU and codec contention.
@MainActor
final class GVEffectThumbnailStore: ObservableObject {
    static let shared = GVEffectThumbnailStore()
    nonisolated static let side = 256

    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "greyvision.thumbnails", qos: .utility)
    private var inFlight: Set<WorkspaceAdjustableEffect> = []
    private var unavailable: Set<WorkspaceAdjustableEffect> = []
    private var reference: CGImage?
    private let directory: URL
    // Accessed only from the serial thumbnail queue, including initialization.
    private nonisolated(unsafe) static let renderer = GVEffectSampleRenderer()

    private init() {
        cache.countLimit = 320
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("EffectThumbnails-Metal-v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func image(for effect: WorkspaceAdjustableEffect) -> UIImage? {
        cache.object(forKey: effect.rawValue as NSString)
    }

    func isUnavailable(_ effect: WorkspaceAdjustableEffect) -> Bool {
        unavailable.contains(effect)
    }

    func request(_ effect: WorkspaceAdjustableEffect) {
        guard image(for: effect) == nil, !inFlight.contains(effect), !unavailable.contains(effect) else { return }
        if reference == nil { reference = Self.makeReferenceStill() }
        guard let reference else { return }
        let url = directory.appendingPathComponent("\(effect.rawValue).png")
        inFlight.insert(effect)
        queue.async { [weak self] in
            autoreleasepool {
                let stored = UIImage(contentsOfFile: url.path)
                let image = stored ?? Self.renderer?.render(effect, over: reference)
                // Disk encoding/writes belong off the main thread too.
                if stored == nil, let data = image?.pngData() {
                    try? data.write(to: url, options: .atomic)
                }
                Task { @MainActor [weak self] in
                    self?.finish(effect, with: image)
                }
            }
        }
    }

    private func finish(_ effect: WorkspaceAdjustableEffect, with image: UIImage?) {
        objectWillChange.send()
        inFlight.remove(effect)
        if let image {
            cache.setObject(image, forKey: effect.rawValue as NSString)
        } else {
            unavailable.insert(effect)
        }
    }

    /// A shared test scene gives thresholds, color, blur and geometry the same
    /// recognizable subject. Audio effects receive illustrative FFT uniforms.
    static func makeReferenceStill() -> CGImage? {
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let colors = [
                UIColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1).cgColor,
                UIColor(red: 0.55, green: 0.48, blue: 0.62, alpha: 1).cgColor,
                UIColor(red: 0.95, green: 0.86, blue: 0.70, alpha: 1).cgColor,
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            cg.setFillColor(UIColor.white.withAlphaComponent(0.92).cgColor)
            cg.fillEllipse(in: CGRect(x: size.width * 0.18, y: size.height * 0.24,
                                     width: size.width * 0.30, height: size.height * 0.30))
            cg.setFillColor(UIColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 1).cgColor)
            for index in 0 ..< 5 {
                cg.fill(CGRect(x: size.width * (0.56 + Double(index) * 0.08), y: size.height * 0.12,
                               width: size.width * 0.06, height: size.height * 0.76))
            }
        }.cgImage
    }
}

/// Queue-confined offscreen renderer. Uses the production shader ABI and
/// default parameters. History, touch and audio inputs are sample data, not
/// live analysis; temporal stills cannot communicate an effect's full motion.
final class GVEffectSampleRenderer {
    private let device: MTLDevice
    private let library: MTLLibrary
    private let queue: MTLCommandQueue
    private let context: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var pipelines: [String: MTLComputePipelineState] = [:]

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = try? device.makeDefaultLibrary(bundle: Bundle(for: AppModel.self)),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.library = library
        self.queue = queue
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    }

    func render(_ effect: WorkspaceAdjustableEffect, over image: CGImage) -> UIImage? {
        guard let source = texture(image.width, image.height),
              let output = texture(image.width, image.height) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let input = CIImage(cgImage: image)
        context.render(input, to: source, commandBuffer: nil, bounds: bounds, colorSpace: colorSpace)
        let values = effect.defaultCameraParameters.sanitized
        if let variant = codecVariant(effect) {
            return renderCodec(variant, values: values, input: input, source: source, bounds: bounds)
        }
        guard let command = queue.makeCommandBuffer() else { return nil }
        if effect == .fluid || effect == .reactionGarden {
            let fluid = effect == .fluid ? CameraFluidSolver(device: device, library: library) : nil
            let reaction = effect == .reactionGarden ? CameraReactionDiffusion(device: device, library: library) : nil
            for frame in 0 ..< 24 {
                let touch = SIMD4<Float>(0.35 + Float(frame) * 0.012, 0.5, 0, 1)
                let encoded: Bool
                if let fluid {
                    encoded = fluid.encode(commandBuffer: command, source: source, destination: output,
                                           touch: touch, parameters: CameraFluidParameters(drag: values.primary,
                                           persistence: values.secondary, swirl: values.tertiary),
                                           blend: Float(values.blend), deltaTime: 1 / 60, quality: .efficient)
                } else if let reaction {
                    encoded = reaction.encode(commandBuffer: command, source: source, destination: output,
                                              parameters: values, touch: touch, time: Double(frame) / 60,
                                              held: false, maximumEdge: 128)
                } else { return nil }
                guard encoded else { return nil }
            }
        } else {
            let name = effect == .rgbSplit ? CameraMetalShaderNames.rgbSplit
                : (effect.temporalMode == nil ? CameraMetalShaderNames.styleEffectGeneric : CameraMetalShaderNames.temporalEffect)
            guard let pipeline = pipeline(name) else { return nil }
            // Prepare CPU/CI resources before opening a compute encoder.
            var history: MTLTexture?
            var stateA: MTLTexture?
            var stateB: MTLTexture?
            var ring: MTLTexture?
            if effect.temporalMode != nil {
                history = texture(image.width, image.height)
                stateA = texture(max(image.width / 8, 1), max(image.height / 8, 1))
                stateB = texture(max(image.width / 8, 1), max(image.height / 8, 1))
                ring = texture(1, 1, array: true)
                guard let history, let stateA, let stateB, let ring else { return nil }
                let shifted = input.clampedToExtent()
                    .transformed(by: CGAffineTransform(translationX: 18, y: -8)).cropped(to: bounds)
                context.render(shifted, to: history, commandBuffer: nil, bounds: bounds, colorSpace: colorSpace)
                clear(stateA)
                clear(stateB)
                clear(ring)
            }
            guard let encoder = command.makeComputeCommandEncoder() else { return nil }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(source, index: 0)
            if effect == .rgbSplit {
                let defaults = RGBSplitEffectParameters.activeDefaults
                let radians = Float(defaults.angleDegrees * .pi / 180)
                var rgb = CameraRGBSplitUniforms(parameters: SIMD4(Float(defaults.amount), cos(radians), sin(radians), Float(defaults.mix)))
                encoder.setTexture(output, index: 1)
                encoder.setBytes(&rgb, length: MemoryLayout<CameraRGBSplitUniforms>.stride, index: 0)
            } else {
                guard let mode = effect.styleMode ?? effect.temporalMode else { return nil }
                var uniforms = CameraStyleEffectUniforms(
                    mode: SIMD4(mode, 0, 1092, 0),
                    parameters: SIMD4(Float(values.primary), Float(values.secondary), Float(values.tertiary), 2.4),
                    viewport: SIMD4(Float(image.width), Float(image.height), 1 / Float(image.width), 1 / Float(image.height)),
                    extra: SIMD4(Float(values.blend), Float(values.overlayX), Float(values.overlayY), 0),
                    audio: SIMD4(0.65, 0.45, 0.3, 0.8), touch: SIMD4(0.45, 0.5, 0.25, 1),
                    touchImpact: SIMD4(0.45, 0.5, 0.15, 1), touchDrag: SIMD4(0.1, 0.05, 0, 1),
                    audioDynamics: SIMD4(0.5, 0.8, 0.6, 0.4),
                    blob0: SIMD4(0.4, 0.5, 0.2, 1), blob1: .zero, blob2: .zero, blob3: .zero,
                    spectrum0: SIMD4(0.7, 0.85, 0.6, 0.4), spectrum1: SIMD4(0.55, 0.3, 0.5, 0.25),
                    spectrum2: SIMD4(0.3, 0.4, 0.2, 0.15), spectrum3: SIMD4(0.2, 0.12, 0.18, 0.08),
                    worldReprojection: matrix_identity_float3x3
                )
                if let history, let stateA, let stateB, let ring {
                    encoder.setTexture(history, index: 1)
                    encoder.setTexture(output, index: 2)
                    for index in 3 ... 7 { encoder.setTexture(history, index: index) }
                    encoder.setTexture(ring, index: 8)
                    encoder.setTexture(stateA, index: 9)
                    encoder.setTexture(stateB, index: 10)
                    encoder.setTexture(source, index: 11)
                    var timestamp: Float = -1e9
                    var info = TemporalRingUniforms(slotCount: 0, head: 0, validCount: 0,
                                                    isPrimed: 0, currentTime: 0, historySpan: 0, padding: .zero)
                    uniforms.extra = SIMD4(Float(values.blend), 0, 0, 0)
                    encoder.setBytes(&timestamp, length: MemoryLayout<Float>.stride, index: 1)
                    encoder.setBytes(&info, length: MemoryLayout<TemporalRingUniforms>.stride, index: 2)
                } else {
                    encoder.setTexture(output, index: 1)
                }
                encoder.setBytes(&uniforms, length: MemoryLayout<CameraStyleEffectUniforms>.stride, index: 0)
            }
            dispatch(encoder, pipeline: pipeline, texture: output)
            encoder.endEncoding()
        }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        return makeImage(output)
    }

    private func codecVariant(_ effect: WorkspaceAdjustableEffect) -> GVDatamoshEngine.Variant? {
        switch effect {
        case .datamosh: .datamosh
        case .liquidMosh: .liquidMosh
        case .heavyMosh: .heavyMosh
        default: nil
        }
    }

    /// A short, bounded real encode/decode of a moving sample, not a fake
    /// reconstruction. Failure leaves an explicit unavailable tile.
    private func renderCodec(_ variant: GVDatamoshEngine.Variant, values: CameraEffectParameters,
                             input: CIImage, source: MTLTexture, bounds: CGRect) -> UIImage? {
        guard let engine = GVDatamoshEngine(device: device),
              let stagePipeline = pipeline(CameraMetalShaderNames.datamoshStage) else { return nil }
        let configuration = GVDatamoshEngine.configuration(variant: variant, primary: values.primary,
                                                          secondary: values.secondary, tertiary: values.tertiary,
                                                          maximumEncodeEdge: 128)
        let deadline = Date().addingTimeInterval(2)
        for frame in 0 ..< 40 {
            guard Date() < deadline else { break }
            guard let staging = engine.beginFrame(configuration: configuration, sourceSize: bounds.size),
                  let command = queue.makeCommandBuffer() else { continue }
            let moving = input.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: CGFloat(frame * 3), y: CGFloat(frame))).cropped(to: bounds)
            context.render(moving, to: source, commandBuffer: nil, bounds: bounds, colorSpace: colorSpace)
            guard let encoder = command.makeComputeCommandEncoder() else { return nil }
            let decoded = engine.latestDecodedFrame
            var uniforms = SampleCodecStageUniforms(recycle: configuration.recycle, decodeReady: decoded == nil ? 0 : 1)
            encoder.setComputePipelineState(stagePipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(decoded?.texture ?? source, index: 1)
            encoder.setTexture(staging.texture, index: 2)
            encoder.setBytes(&uniforms, length: MemoryLayout<SampleCodecStageUniforms>.stride, index: 0)
            dispatch(encoder, pipeline: stagePipeline, texture: staging.texture)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else { return nil }
            engine.endFrame(staging, configuration: configuration)
            Thread.sleep(forTimeInterval: 0.004)
        }
        // Allow the last asynchronously submitted frame to arrive, bounded.
        while engine.latestDecodedFrame == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let decoded = engine.latestDecodedFrame else { return nil }
        return makeImage(decoded.texture)
    }

    private func makeImage(_ texture: MTLTexture) -> UIImage? {
        guard let result = CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace]),
              let image = context.createCGImage(result, from: result.extent) else { return nil }
        return UIImage(cgImage: image)
    }

    private func pipeline(_ name: String) -> MTLComputePipelineState? {
        if let cached = pipelines[name] { return cached }
        guard let function = library.makeFunction(name: name),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        pipelines[name] = pipeline
        return pipeline
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, texture: MTLTexture) {
        let width = pipeline.threadExecutionWidth
        encoder.dispatchThreads(MTLSize(width: texture.width, height: texture.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: min(pipeline.maxTotalThreadsPerThreadgroup / width, 4), depth: 1))
    }

    private func texture(_ width: Int, _ height: Int, array: Bool = false) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                 width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        if array { descriptor.textureType = .type2DArray; descriptor.arrayLength = 1 }
        return device.makeTexture(descriptor: descriptor)
    }

    private func clear(_ texture: MTLTexture) {
        let values = [UInt8](repeating: 0, count: texture.width * texture.height * 8)
        values.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: texture.width * 8)
        }
    }
}

/// Mirrors GVDatamoshStageUniforms in CameraShaders.metal.
private struct SampleCodecStageUniforms {
    var recycle: Float
    var decodeReady: UInt32
}
