import Foundation
import Metal
import simd

enum MotionFieldSource: String, Codable, CaseIterable, Sendable {
    case camera
    case opticalFlow
    case blockMatching
    case touch
    case procedural
    case deviceMotion
    case audioImpulse
    case external
}

struct MotionFieldConfiguration: Codable, Equatable, Sendable {
    var gain: Float = 1
    var decay: Float = 0.88
    var momentum: Float = 0.72
    var resolutionScale: Float = 0.25
}

struct MotionFieldSnapshot: @unchecked Sendable {
    let vectorTexture: MTLTexture?
    let size: RenderDimensions
    let aggregateVector: SIMD2<Float>
    let sourceVectors: [MotionFieldSource: SIMD2<Float>]
    let configuration: MotionFieldConfiguration

    static let empty = MotionFieldSnapshot(
        vectorTexture: nil,
        size: RenderDimensions(width: 0, height: 0),
        aggregateVector: .zero,
        sourceVectors: [:],
        configuration: MotionFieldConfiguration()
    )
}

/// Shared motion representation. Camera optical flow remains GPU-resident in
/// `vectorTexture`; sparse gesture/gyro/audio forces are combined as uniforms.
final class MotionField: @unchecked Sendable {
    private let lock = NSLock()
    private var vectorTexture: MTLTexture?
    private var size = RenderDimensions(width: 0, height: 0)
    private var sourceVectors: [MotionFieldSource: SIMD2<Float>] = [:]
    private var aggregate = SIMD2<Float>.zero
    private var velocity = SIMD2<Float>.zero
    private(set) var configuration: MotionFieldConfiguration

    init(configuration: MotionFieldConfiguration = MotionFieldConfiguration()) {
        self.configuration = configuration
    }

    func bindPrimaryVectorTexture(_ texture: MTLTexture?) {
        lock.withLock {
            vectorTexture = texture
            size = RenderDimensions(width: texture?.width ?? 0, height: texture?.height ?? 0)
        }
    }

    func setVector(_ vector: SIMD2<Float>, for source: MotionFieldSource) {
        lock.withLock { sourceVectors[source] = Self.finite(vector) }
    }

    func update(deltaTime: TimeInterval) {
        lock.withLock {
            let dt = Float(min(max(deltaTime.isFinite ? deltaTime : 1 / 60, 1 / 240), 0.25))
            let input = sourceVectors.values.reduce(SIMD2<Float>.zero, +) * configuration.gain
            let momentum = min(max(configuration.momentum, 0), 0.999)
            velocity = velocity * momentum + input * (1 - momentum)
            let decay = pow(min(max(configuration.decay, 0), 1), dt * 60)
            aggregate = aggregate * decay + velocity * dt
        }
    }

    func snapshot() -> MotionFieldSnapshot {
        lock.withLock {
            MotionFieldSnapshot(
                vectorTexture: vectorTexture,
                size: size,
                aggregateVector: aggregate,
                sourceVectors: sourceVectors,
                configuration: configuration
            )
        }
    }

    func reset() {
        lock.withLock {
            sourceVectors.removeAll(keepingCapacity: true)
            aggregate = .zero
            velocity = .zero
        }
    }

    private static func finite(_ vector: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2<Float>(
            vector.x.isFinite ? vector.x : 0,
            vector.y.isFinite ? vector.y : 0
        )
    }
}

enum MotionFieldDebugMode: UInt32, Sendable {
    case magnitude
    case direction
}

/// Developer-only vector visualizer. It compiles once when explicitly created;
/// production UI does not instantiate it and its default `isEnabled` is false.
final class MotionFieldDebugRenderer: @unchecked Sendable {
    var isEnabled = false
    var mode = MotionFieldDebugMode.direction
    private let pipeline: MTLComputePipelineState

    init?(device: MTLDevice) {
        #if DEBUG
            let source = """
            #include <metal_stdlib>
            using namespace metal;
            kernel void gvMotionFieldDebug(
                texture2d<half, access::sample> flow [[texture(0)]],
                texture2d<half, access::write> output [[texture(1)]],
                constant uint &mode [[buffer(0)]],
                uint2 gid [[thread_position_in_grid]]) {
                if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
                constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
                float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
                float2 v = float2(flow.sample(s, uv).rg);
                float magnitude = min(length(v) * 8.0, 1.0);
                float3 color = mode == 0 ? float3(magnitude) :
                    float3(0.5 + 0.5 * normalize(v + float2(1e-6)).x,
                           0.5 + 0.5 * normalize(v + float2(1e-6)).y,
                           magnitude);
                output.write(half4(half3(color), half(1.0)), gid);
            }
            """
            guard let library = try? device.makeLibrary(source: source, options: nil),
                  let function = library.makeFunction(name: "gvMotionFieldDebug"),
                  let pipeline = try? device.makeComputePipelineState(function: function)
            else { return nil }
            self.pipeline = pipeline
        #else
            return nil
        #endif
    }

    @discardableResult
    func encode(field: MTLTexture, destination: MTLTexture, commandBuffer: MTLCommandBuffer) -> Bool {
        guard isEnabled, let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        var rawMode = mode.rawValue
        encoder.label = "greyVISION motion field debug"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(field, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&rawMode, length: MemoryLayout<UInt32>.stride, index: 0)
        let width = max(pipeline.threadExecutionWidth, 1)
        let height = max(pipeline.maxTotalThreadsPerThreadgroup / width, 1)
        encoder.dispatchThreads(
            MTLSize(width: destination.width, height: destination.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
        )
        encoder.endEncoding()
        return true
    }
}
