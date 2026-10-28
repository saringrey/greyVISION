import Foundation
import Metal

/// HOLD locks source pixels; FREEZE also stops the simulation. Neither clears memory.
struct GVDatamoshTransport: Equatable, Sendable {
    enum Mode: String, Sendable { case live, hold, freeze }
    enum Action { case hold, release, freeze, reset }
    private(set) var mode: Mode = .live
    private(set) var resetRevision: UInt64 = 0

    mutating func send(_ action: Action) {
        switch action {
        case .hold: mode = .hold
        case .release: mode = .live
        case .freeze: mode = .freeze
        case .reset:
            mode = .live
            resetRevision &+= 1
        }
    }
}

/// GPU frame transport, approximating directional datamosh rather than a codec bitstream.
/// One instance per graph slot; all encodes run on the renderer's serial command queue.
final class GVFrameDatamosh {
    struct Settings {
        var persistence: Float = 0.998
        var strength: Float = 0.55
        var direction: Float = 0.5
        var velocityDecay: Float = 0.18
        var residual: Float = 0.0015
        var blockSize = 16
        var blend: Float = 1
    }

    private struct Uniforms {
        var motion: SIMD4<Float>
        var timing: SIMD4<Float>
        var layout: SIMD4<Float>
        var touch: SIMD4<Float>
        var flags: SIMD4<UInt32>
    }

    private let device: MTLDevice
    private let sourcePipeline: MTLComputePipelineState
    private let velocityPipeline: MTLComputePipelineState
    private let feedbackPipeline: MTLComputePipelineState
    private(set) var sourceReference: MTLTexture?
    private var images: [MTLTexture] = []
    private var velocities: [MTLTexture] = []
    private var readIndex = 0
    private var velocityReadIndex = 0
    private var previousMode: GVDatamoshTransport.Mode = .live
    private var resetRevision: UInt64 = 0
    private var elapsed: Float = 0
    private var liveMix: Float = 1
    private(set) var encodedFrames: UInt64 = 0
    private(set) var allocationCount = 0

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw NSError(domain: "GVFrameDatamosh", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Missing Metal function \(name)"])
            }
            return try device.makeComputePipelineState(function: function)
        }
        sourcePipeline = try pipeline("gvDatamoshSource")
        velocityPipeline = try pipeline("gvDatamoshVelocity")
        feedbackPipeline = try pipeline("gvDatamoshFeedback")
    }

    @discardableResult
    func encode(commandBuffer: MTLCommandBuffer, source: MTLTexture, destination: MTLTexture,
                settings: Settings, transport: GVDatamoshTransport, deltaTime: Float,
                touch: SIMD4<Float> = .zero, drag: SIMD2<Float> = .zero) -> Bool {
        func unit(_ v: Float, _ fallback: Float) -> Float { v.isFinite ? min(max(v, 0), 1) : fallback }
        let dt = deltaTime.isFinite ? min(max(deltaTime, 1 / 240), 1 / 15) : 1 / 60
        let block = [8, 16, 32].contains(settings.blockSize) ? settings.blockSize : 16
        let width = destination.width, height = destination.height
        let seed = encodedFrames == 0 || resetRevision != transport.resetRevision
        var uniforms = Uniforms(
            motion: SIMD4(unit(settings.persistence, 0.998), unit(settings.strength, 0.55),
                          (unit(settings.direction, 0.5) * 2 - 1) * .pi, unit(settings.velocityDecay, 0.18)),
            timing: SIMD4(dt, elapsed, unit(settings.residual, 0.0015), 1),
            layout: SIMD4(Float(width), Float(height), Float(block), unit(settings.blend, 1)),
            touch: SIMD4(touch.x.isFinite ? touch.x : 0.5, touch.y.isFinite ? touch.y : 0.5,
                         drag.x.isFinite ? min(max(drag.x, -4), 4) : 0,
                         drag.y.isFinite ? min(max(drag.y, -4), 4) : 0),
            flags: SIMD4(seed ? 1 : 0, transport.mode == .freeze ? 1 : 0, touch.w > 0 ? 1 : 0, 0))

        // Resize preserves both the held reference and accumulated pixels (e.g. recording starts).
        if sourceReference?.width != width || sourceReference?.height != height {
            guard let reference = texture(width, height, "Source"),
                  let a = texture(width, height, "Feedback A"),
                  let b = texture(width, height, "Feedback B") else { return false }
            var copy = uniforms
            copy.flags.x = 1
            guard encode(sourcePipeline, commandBuffer, [sourceReference ?? source, reference], &copy, reference),
                  encode(sourcePipeline, commandBuffer, [images.isEmpty ? source : images[readIndex], a], &copy, a)
            else { return false }
            sourceReference = reference
            images = [a, b]
            readIndex = 0
        }
        let columns = (width + block - 1) / block, rows = (height + block - 1) / block
        if velocities.first?.width != columns || velocities.first?.height != rows {
            guard let a = texture(columns, rows, "Velocity A"),
                  let b = texture(columns, rows, "Velocity B") else { return false }
            if !velocities.isEmpty {
                var copy = uniforms
                copy.flags.x = 1
                guard encode(sourcePipeline, commandBuffer, [velocities[velocityReadIndex], a], &copy, a) else { return false }
            } else {
                uniforms.flags.x = 1
            }
            velocities = [a, b]
            velocityReadIndex = 0
        }
        guard let reference = sourceReference else { return false }
        if transport.mode != .live { liveMix = 0 }
        else { liveMix = min(liveMix + dt / 0.45, 1) }
        uniforms.timing.w = seed ? 1 : liveMix
        let capture = transport.mode == .hold && previousMode == .live
        if seed || capture || transport.mode == .live {
            var update = uniforms
            update.flags.x = seed || capture ? 1 : 0
            guard encode(sourcePipeline, commandBuffer, [source, reference], &update, reference) else { return false }
        }
        if transport.mode != .freeze || seed {
            guard encode(velocityPipeline, commandBuffer,
                         [velocities[velocityReadIndex], velocities[1 - velocityReadIndex]],
                         &uniforms, velocities[1 - velocityReadIndex]) else { return false }
            velocityReadIndex = 1 - velocityReadIndex
        }
        // Image seeding is independent of a new velocity grid.
        uniforms.flags.x = seed ? 1 : 0
        guard encode(feedbackPipeline, commandBuffer,
                     [reference, images[readIndex], velocities[velocityReadIndex], images[1 - readIndex], destination],
                     &uniforms, destination) else { return false }
        readIndex = 1 - readIndex
        if transport.mode != .freeze { elapsed += dt }
        previousMode = transport.mode
        resetRevision = transport.resetRevision
        encodedFrames &+= 1
        return true
    }

    private func texture(_ width: Int, _ height: Int, _ label: String) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = "Datamosh \(label)"
        if texture != nil { allocationCount += 1 }
        return texture
    }

    private func encode(_ pipeline: MTLComputePipelineState, _ buffer: MTLCommandBuffer,
                        _ textures: [MTLTexture], _ uniforms: inout Uniforms, _ target: MTLTexture) -> Bool {
        guard let encoder = buffer.makeComputeCommandEncoder() else { return false }
        encoder.label = pipeline.label ?? "Datamosh feedback"
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        let width = pipeline.threadExecutionWidth
        encoder.dispatchThreads(MTLSize(width: target.width, height: target.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: min(8, pipeline.maxTotalThreadsPerThreadgroup / width), depth: 1))
        encoder.endEncoding()
        return true
    }
}
