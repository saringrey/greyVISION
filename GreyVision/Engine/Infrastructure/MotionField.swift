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
