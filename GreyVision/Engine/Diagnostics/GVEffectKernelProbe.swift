#if DEBUG
    import CoreImage
    import Foundation
    import Metal
    import simd

    /// Measures the effect kernels in isolation, for audits. Debug builds only.
    ///
    /// Two probes over the production kernels — the same `gvCameraStyleEffect`
    /// specialisations and `gvCameraTemporalEffect` the renderer dispatches:
    ///
    /// - **Cost**: GPU time per kernel at a phone-drawable working size. The live
    ///   renderer's own timer reads flat on the simulator, so this is the only
    ///   honest ranking there. Absolute numbers belong to whatever GPU runs it;
    ///   the ranking is what carries to the phone. Multi-pass stages (flow,
    ///   fluid, reaction, codec) are timed by their effect kernel alone.
    /// - **Signature**: every kernel over a real photograph at default controls,
    ///   written as one PNG each with its mean change from the source. Effects
    ///   that barely move the frame at their defaults, and effects whose output
    ///   is nearly another's, become numbers instead of a judgement call.
    ///
    /// Run from the app with `--effect-probe <still in Documents>`; results land
    /// in `Documents/effect-probe/`. The unit test wraps the same calls.
    final class GVEffectKernelProbe {
        static let argument = "--effect-probe"

        private let device: MTLDevice
        private let library: MTLLibrary
        private let queue: MTLCommandQueue
        private var stylePipelines: [UInt32: MTLComputePipelineState] = [:]
        private let temporalPipeline: MTLComputePipelineState

        init(device: MTLDevice, library: MTLLibrary) throws {
            guard let queue = device.makeCommandQueue(),
                  let temporal = library.makeFunction(name: CameraMetalShaderNames.temporalEffect)
            else { throw GVEffectKernelProbeError.metalUnavailable }
            self.device = device
            self.library = library
            self.queue = queue
            temporalPipeline = try device.makeComputePipelineState(function: temporal)
        }

        /// Launch hook. Runs both probes off the main thread and writes the
        /// results next to the PNGs, so a script can collect them with simctl.
        static func runIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
            guard let flag = arguments.firstIndex(of: argument), arguments.indices.contains(flag + 1),
                  let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            else { return }
            let still = documents.appendingPathComponent(arguments[flag + 1])
            let output = documents.appendingPathComponent("effect-probe", isDirectory: true)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard let device = MTLCreateSystemDefaultDevice(), let library = device.makeDefaultLibrary() else {
                        throw GVEffectKernelProbeError.metalUnavailable
                    }
                    let probe = try GVEffectKernelProbe(device: device, library: library)
                    try? FileManager.default.removeItem(at: output)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    let signatures = try probe.writeSignatures(still: still, to: output)
                    let costs = try probe.rankByCost()
                    let lines = costs.map { String(format: "GVBENCH %@ %.4f", $0.0.rawValue, $0.1) }
                        + signatures.map { String(format: "GVSIG %@ %.4f", $0.0.rawValue, $0.1) }
                    try lines.joined(separator: "\n").write(to: output.appendingPathComponent("results.txt"),
                                                            atomically: true, encoding: .utf8)
                    GVLog.capture.notice("GVPROBE DONE \(lines.count, privacy: .public)")
                } catch {
                    GVLog.capture.error("GVPROBE FAILED \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // MARK: - Cost

        func rankByCost(width: Int = 1179, height: Int = 2556, iterations: Int = 12) throws
            -> [(WorkspaceAdjustableEffect, Double)]
        {
            let textures = try Textures(device: device, width: width, height: height, storage: .private)
            var results: [(WorkspaceAdjustableEffect, Double)] = []
            for effect in WorkspaceAdjustableEffect.allCases {
                guard let pass = try encoding(for: effect, textures: textures, width: width, height: height) else { continue }
                try results.append((effect, time(pass, output: textures.output, iterations: iterations)))
            }
            return results.sorted { $0.1 > $1.1 }
        }

        // MARK: - Signature

        func writeSignatures(still: URL, to directory: URL, width: Int = 360, height: Int = 640) throws
            -> [(WorkspaceAdjustableEffect, Double)]
        {
            guard let image = CIImage(contentsOf: still),
                  let linear = CGColorSpace(name: CGColorSpace.linearSRGB),
                  let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
            else { throw GVEffectKernelProbeError.stillUnreadable }
            let context = CIContext(mtlDevice: device)
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let fill = max(CGFloat(width) / image.extent.width, CGFloat(height) / image.extent.height)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
            let framed = scaled.transformed(by: CGAffineTransform(
                translationX: -scaled.extent.minX - (scaled.extent.width - CGFloat(width)) / 2,
                y: -scaled.extent.minY - (scaled.extent.height - CGFloat(height)) / 2
            )).cropped(to: bounds)

            let textures = try Textures(device: device, width: width, height: height, storage: .shared)
            context.render(framed, to: textures.source, commandBuffer: nil, bounds: bounds, colorSpace: linear)
            // History stands in for the previous frame: the same scene a few
            // pixels away, as a slow pan would leave it.
            let shifted = framed.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: 12, y: -6)).cropped(to: bounds)
            context.render(shifted, to: textures.history, commandBuffer: nil, bounds: bounds, colorSpace: linear)
            let reference = Self.read(textures.source)

            var results: [(WorkspaceAdjustableEffect, Double)] = []
            for effect in WorkspaceAdjustableEffect.allCases {
                guard let pass = try encoding(for: effect, textures: textures, width: width, height: height) else { continue }
                _ = try time(pass, output: textures.output, iterations: 1)
                let pixels = Self.read(textures.output)
                var change = 0.0
                for index in stride(from: 0, to: pixels.count, by: 4) {
                    for channel in 0 ..< 3 {
                        change += Double(abs(pixels[index + channel] - reference[index + channel]))
                    }
                }
                results.append((effect, change / Double(width * height * 3)))
                guard let output = CIImage(mtlTexture: textures.output, options: [.colorSpace: linear]) else { continue }
                try context.writePNGRepresentation(of: output, to: directory.appendingPathComponent("\(effect.rawValue).png"),
                                                   format: .RGBA8, colorSpace: sRGB)
            }
            if let source = CIImage(mtlTexture: textures.source, options: [.colorSpace: linear]) {
                try context.writePNGRepresentation(of: source, to: directory.appendingPathComponent("_source.png"),
                                                   format: .RGBA8, colorSpace: sRGB)
            }
            return results
        }

        // MARK: - Encoding

        private struct Textures {
            let source: MTLTexture
            let history: MTLTexture
            let output: MTLTexture
            let state: MTLTexture
            let ring: MTLTexture

            init(device: MTLDevice, width: Int, height: Int, storage: MTLStorageMode) throws {
                func make(_ width: Int, _ height: Int, array: Bool = false) throws -> MTLTexture {
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
                    )
                    descriptor.storageMode = storage
                    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
                    if array {
                        descriptor.textureType = .type2DArray
                        descriptor.arrayLength = 1
                    }
                    guard let texture = device.makeTexture(descriptor: descriptor) else {
                        throw GVEffectKernelProbeError.metalUnavailable
                    }
                    return texture
                }
                source = try make(width, height)
                history = try make(width, height)
                output = try make(width, height)
                state = try make(max(width / 8, 1), max(height / 8, 1))
                ring = try make(1, 1, array: true)
            }
        }

        private typealias Pass = (pipeline: MTLComputePipelineState, bind: (MTLComputeCommandEncoder) -> Void)

        /// The renderer's bindings for one effect, or nil for effects with no
        /// single kernel to time (RGB split, fluid, reaction).
        private func encoding(for effect: WorkspaceAdjustableEffect, textures: Textures,
                              width: Int, height: Int) throws -> Pass?
        {
            let uniforms = Self.uniforms(for: effect, width: width, height: height)
            if let mode = effect.styleMode {
                let pipeline = try stylePipeline(mode)
                return (pipeline, { encoder in
                    var uniforms = uniforms
                    encoder.setTexture(textures.source, index: 0)
                    encoder.setTexture(textures.output, index: 1)
                    encoder.setBytes(&uniforms, length: MemoryLayout<CameraStyleEffectUniforms>.stride, index: 0)
                })
            }
            guard effect.temporalMode != nil else { return nil }
            return (temporalPipeline, { encoder in
                var uniforms = uniforms
                var timestamp: Float = -1e9
                var info = TemporalRingUniforms(slotCount: 0, head: 0, validCount: 0, isPrimed: 0,
                                                currentTime: 0, historySpan: 0, padding: .zero)
                encoder.setTexture(textures.source, index: 0)
                encoder.setTexture(textures.history, index: 1)
                encoder.setTexture(textures.output, index: 2)
                for index in 3 ... 7 {
                    encoder.setTexture(textures.history, index: index)
                }
                encoder.setTexture(textures.ring, index: 8)
                encoder.setTexture(textures.state, index: 9)
                encoder.setTexture(textures.state, index: 10)
                encoder.setTexture(textures.source, index: 11)
                encoder.setBytes(&uniforms, length: MemoryLayout<CameraStyleEffectUniforms>.stride, index: 0)
                encoder.setBytes(&timestamp, length: MemoryLayout<Float>.stride, index: 1)
                encoder.setBytes(&info, length: MemoryLayout<TemporalRingUniforms>.stride, index: 2)
            })
        }

        private func stylePipeline(_ mode: UInt32) throws -> MTLComputePipelineState {
            if let cached = stylePipelines[mode] { return cached }
            var constant = mode
            let constants = MTLFunctionConstantValues()
            constants.setConstantValue(&constant, type: .uint, index: 0)
            let function = try library.makeFunction(name: CameraMetalShaderNames.styleEffect, constantValues: constants)
            let pipeline = try device.makeComputePipelineState(function: function)
            stylePipelines[mode] = pipeline
            return pipeline
        }

        /// One warm-up buffer, then a buffer of back-to-back dispatches; returns
        /// GPU milliseconds per dispatch.
        private func time(_ pass: Pass, output: MTLTexture, iterations: Int) throws -> Double {
            var elapsed = 0.0
            for warm in [true, false] {
                guard let command = queue.makeCommandBuffer(),
                      let encoder = command.makeComputeCommandEncoder()
                else { throw GVEffectKernelProbeError.metalUnavailable }
                encoder.setComputePipelineState(pass.pipeline)
                pass.bind(encoder)
                let width = pass.pipeline.threadExecutionWidth
                let group = MTLSize(width: width, height: max(pass.pipeline.maxTotalThreadsPerThreadgroup / width, 1), depth: 1)
                let count = warm ? 1 : iterations
                for _ in 0 ..< count {
                    encoder.dispatchThreads(MTLSize(width: output.width, height: output.height, depth: 1),
                                            threadsPerThreadgroup: group)
                }
                encoder.endEncoding()
                command.commit()
                command.waitUntilCompleted()
                elapsed = (command.gpuEndTime - command.gpuStartTime) * 1000 / Double(count)
            }
            return elapsed
        }

        private static func read(_ texture: MTLTexture) -> [Float] {
            var values = [Float16](repeating: 0, count: texture.width * texture.height * 4)
            values.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 8,
                                 from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            }
            return values.map(Float.init)
        }

        /// Default controls with live-looking audio and touch, so audio- and
        /// touch-gated branches are taken rather than skipped.
        static func uniforms(for effect: WorkspaceAdjustableEffect, width: Int, height: Int) -> CameraStyleEffectUniforms {
            let values = effect.defaultCameraParameters.sanitized
            let mode = effect.styleMode ?? effect.temporalMode ?? 0
            return CameraStyleEffectUniforms(
                mode: SIMD4(mode, 0, 1092, 0),
                parameters: SIMD4(Float(values.primary), Float(values.secondary), Float(values.tertiary), 2.4),
                viewport: SIMD4(Float(width), Float(height), 1 / Float(width), 1 / Float(height)),
                extra: SIMD4(Float(values.blend), 0.5, 0.5, 0),
                audio: SIMD4(0.65, 0.45, 0.3, 0.8), touch: SIMD4(0.45, 0.5, 0.25, 1),
                touchImpact: SIMD4(0.45, 0.5, 0.15, 1), touchDrag: SIMD4(0.1, 0.05, 0, 1),
                audioDynamics: SIMD4(0.5, 0.8, 0.6, 0.4),
                blob0: SIMD4(0.4, 0.5, 0.2, 1), blob1: .zero, blob2: .zero, blob3: .zero,
                spectrum0: SIMD4(0.7, 0.85, 0.6, 0.4), spectrum1: SIMD4(0.55, 0.3, 0.5, 0.25),
                spectrum2: SIMD4(0.3, 0.4, 0.2, 0.15), spectrum3: SIMD4(0.2, 0.12, 0.18, 0.08),
                worldReprojection: matrix_identity_float3x3
            )
        }
    }

    enum GVEffectKernelProbeError: Error {
        case metalUnavailable
        case stillUnreadable
    }
#endif
