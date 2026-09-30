import Foundation
import Metal
import simd

/// Fixed 60 Hz chemical clock: two Euler steps per tick, at most four per render.
/// Excess time is dropped after stalls, avoiding an unbounded catch-up workload.
struct CameraReactionClock {
    private var previousTime: TimeInterval?
    private var accumulator: TimeInterval = 0

    mutating func steps(at time: TimeInterval, held: Bool) -> Int {
        defer { previousTime = time }
        guard !held else { accumulator = 0; return 0 }
        guard let previousTime else { return 0 }
        accumulator += min(max(time - previousTime, 0), 1.0 / 30.0)
        let ticks = min(Int((accumulator + 1e-9) * 60), 2)
        accumulator = max(accumulator - Double(ticks) / 60, 0)
        return ticks * 2
    }
}

struct CameraReactionUniforms {
    var controls: SIMD4<Float>
    var touch: SIMD4<Float>
}

/// Each graph slot owns exactly two private RG16F concentration fields.
final class CameraReactionDiffusion {
    private let device: MTLDevice
    private let seedPipeline: MTLComputePipelineState
    private let stepPipeline: MTLComputePipelineState
    private let compositePipeline: MTLComputePipelineState
    private let resizePipeline: MTLComputePipelineState
    private var fieldA: MTLTexture?
    private var fieldB: MTLTexture?
    private var clock = CameraReactionClock()
    private var needsSeed = true
    private(set) var completedStepCount: UInt64 = 0

    init?(device: MTLDevice, library: MTLLibrary) {
        guard let seed = library.makeFunction(name: "gvReactionSeed"),
              let step = library.makeFunction(name: "gvReactionStep"),
              let composite = library.makeFunction(name: "gvReactionComposite"),
              let resize = library.makeFunction(name: "gvReactionResize"),
              let resizePipeline = try? device.makeComputePipelineState(function: resize),
              let seedPipeline = try? device.makeComputePipelineState(function: seed),
              let stepPipeline = try? device.makeComputePipelineState(function: step),
              let compositePipeline = try? device.makeComputePipelineState(function: composite) else { return nil }
        self.device = device
        self.seedPipeline = seedPipeline
        self.stepPipeline = stepPipeline
        self.compositePipeline = compositePipeline
        self.resizePipeline = resizePipeline
    }

    func reset() {
        fieldA = nil
        fieldB = nil
        clock = CameraReactionClock()
        needsSeed = true
        completedStepCount = 0
    }

    static func gridSize(width: Int, height: Int, maximumEdge: Int = 256) -> SIMD2<Int> {
        let scale = min(Double(min(max(maximumEdge, 64), 256)) / Double(max(width, height, 1)), 1)
        return SIMD2(max(Int(Double(width) * scale), 1), max(Int(Double(height) * scale), 1))
    }

    func encode(commandBuffer: MTLCommandBuffer, source: MTLTexture, destination: MTLTexture,
                parameters: CameraEffectParameters, touch: SIMD4<Float>, time: TimeInterval, held: Bool, maximumEdge: Int = 256) -> Bool
    {
        let size = Self.gridSize(width: source.width, height: source.height, maximumEdge: maximumEdge)
        if fieldA?.width != size.x || fieldA?.height != size.y {
            let previousField = fieldA
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float,
                                                                      width: size.x, height: size.y, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            fieldA = device.makeTexture(descriptor: descriptor)
            fieldB = device.makeTexture(descriptor: descriptor)
            fieldA?.label = "Reaction Garden A"
            fieldB?.label = "Reaction Garden B"
            if let previousField, let fieldA, !needsSeed,
               let resize = commandBuffer.makeComputeCommandEncoder()
            {
                resize.setComputePipelineState(resizePipeline)
                resize.setTexture(previousField, index: 0)
                resize.setTexture(fieldA, index: 1)
                dispatch(resize, pipeline: resizePipeline, texture: fieldA)
                resize.endEncoding()
            } else {
                needsSeed = true
            }
        }
        guard var current = fieldA, var next = fieldB,
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encoder.label = "Reaction Garden"
        var uniforms = CameraReactionUniforms(controls: SIMD4(Float(parameters.primary),
                                                              Float(parameters.secondary), Float(parameters.tertiary), Float(parameters.blend)), touch: touch)
        encoder.setBytes(&uniforms, length: MemoryLayout<CameraReactionUniforms>.stride, index: 0)
        encoder.setTexture(source, index: 0)
        if needsSeed {
            encoder.setComputePipelineState(seedPipeline)
            encoder.setTexture(current, index: 2)
            dispatch(encoder, pipeline: seedPipeline, texture: current)
            needsSeed = false
        }
        let steps = clock.steps(at: time, held: held)
        for _ in 0 ..< steps {
            encoder.setComputePipelineState(stepPipeline)
            encoder.setTexture(current, index: 1)
            encoder.setTexture(next, index: 2)
            dispatch(encoder, pipeline: stepPipeline, texture: next)
            swap(&current, &next)
        }
        completedStepCount += UInt64(steps)
        fieldA = current
        fieldB = next
        encoder.setComputePipelineState(compositePipeline)
        encoder.setTexture(current, index: 1)
        encoder.setTexture(destination, index: 2)
        dispatch(encoder, pipeline: compositePipeline, texture: destination)
        encoder.endEncoding()
        return true
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, texture: MTLTexture) {
        let width = pipeline.threadExecutionWidth
        encoder.dispatchThreads(MTLSize(width: texture.width, height: texture.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width,
                                                               height: max(min(pipeline.maxTotalThreadsPerThreadgroup / width, 8), 1), depth: 1))
    }
}
