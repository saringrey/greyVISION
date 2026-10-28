#if DEBUG
    import Foundation
    import Metal

    /// Measures how much the effect graph changes each frame. Debug builds only,
    /// and only while an effect audit switches it on.
    ///
    /// The renderer calls `encode` with the clean source and the graph output;
    /// the result is the mean absolute per-channel difference over a 64×64
    /// lattice, 0...1, published when the command buffer completes. An effect
    /// whose energy stays at zero is an effect that does nothing.
    final class GVEffectEnergyProbe {
        nonisolated(unsafe) static var isEnabled = false
        private static let lock = NSLock()
        private nonisolated(unsafe) static var value: Double = 0

        static var latest: Double { lock.withLock { value } }

        private let pipeline: MTLComputePipelineState
        private let buffers: [MTLBuffer]
        private var slot = 0

        init?(device: MTLDevice, library: MTLLibrary) {
            guard let function = library.makeFunction(name: "gvEffectEnergy"),
                  let pipeline = try? device.makeComputePipelineState(function: function)
            else { return nil }
            let buffers = (0 ..< 3).compactMap { _ in device.makeBuffer(length: 4, options: .storageModeShared) }
            guard buffers.count == 3 else { return nil }
            self.pipeline = pipeline
            self.buffers = buffers
        }

        func encode(source: MTLTexture, output: MTLTexture, commandBuffer: MTLCommandBuffer) {
            guard Self.isEnabled else { return }
            let buffer = buffers[slot]
            slot = (slot + 1) % buffers.count
            buffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.setBuffer(buffer, offset: 0, index: 0)
            encoder.dispatchThreads(MTLSize(width: 64, height: 64, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            encoder.endEncoding()
            commandBuffer.addCompletedHandler { _ in
                let sum = buffer.contents().load(as: UInt32.self)
                let mean = Double(sum) / 65535.0 / 4096.0
                Self.lock.withLock { Self.value = mean }
            }
        }
    }
#endif
