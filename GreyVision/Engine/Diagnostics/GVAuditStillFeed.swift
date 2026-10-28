#if DEBUG
    import Foundation
    import Metal
    import MetalKit

    /// A photograph standing in for the camera on the simulator, so effects can be
    /// judged on real texture, colour and motion instead of the test card.
    ///
    /// Debug builds only, and only when launched with
    /// `--synthetic-still <file>`, where the file sits in the app's Documents
    /// directory. The still goes through `gvCameraSyntheticStill`, which writes
    /// the same linear working frame the camera feed does — everything after it
    /// is the production graph, untouched.
    final class GVAuditStillFeed {
        static let argument = "--synthetic-still"

        private let texture: MTLTexture
        private let pipeline: MTLComputePipelineState
        /// `--synthetic-still-static`: no pan, no moving light — a tripod shot.
        private let isStatic = ProcessInfo.processInfo.arguments.contains("--synthetic-still-static")

        private init(texture: MTLTexture, pipeline: MTLComputePipelineState) {
            self.texture = texture
            self.pipeline = pipeline
        }

        static func load(device: MTLDevice, library: MTLLibrary,
                         arguments: [String] = ProcessInfo.processInfo.arguments) -> GVAuditStillFeed?
        {
            guard let flag = arguments.firstIndex(of: argument), arguments.indices.contains(flag + 1),
                  let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                  let function = library.makeFunction(name: "gvCameraSyntheticStill"),
                  let pipeline = try? device.makeComputePipelineState(function: function)
            else { return nil }
            let url = documents.appendingPathComponent(arguments[flag + 1])
            do {
                let texture = try MTKTextureLoader(device: device).newTexture(URL: url, options: [
                    .SRGB: true,
                    .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                    .textureStorageMode: MTLStorageMode.private.rawValue,
                ])
                GVLog.capture.notice("Audit still feed loaded \(url.lastPathComponent, privacy: .public)")
                return GVAuditStillFeed(texture: texture, pipeline: pipeline)
            } catch {
                GVLog.capture.error("Audit still feed failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        func encode(into destination: MTLTexture, commandBuffer: MTLCommandBuffer, time: Float) {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
            var time = isStatic ? 0 : time.truncatingRemainder(dividingBy: 3_600)
            encoder.label = "greyVISION Audit Still Feed"
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(texture, index: 0)
            encoder.setTexture(destination, index: 1)
            encoder.setBytes(&time, length: MemoryLayout<Float>.stride, index: 0)
            let width = pipeline.threadExecutionWidth
            let height = max(pipeline.maxTotalThreadsPerThreadgroup / width, 1)
            encoder.dispatchThreads(MTLSize(width: destination.width, height: destination.height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
            encoder.endEncoding()
        }
    }
#endif
