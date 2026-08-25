import Foundation
import QuartzCore
import simd

/// Lifecycle of a signal fracture.
enum SignalFracturePhase: UInt32, Sendable, Equatable {
    /// Nothing is touching the membrane.
    case idle = 0
    /// Two contacts acquired; the signal line is drawn but nothing has torn.
    case locked = 1
    /// The user is pulling the signal apart.
    case tearing = 2
    /// The release: the signal violently repairs itself.
    case repairing = 3
    /// The rare complete break, followed by a macroblock reconstruction.
    case broken = 4

    var isEngaged: Bool {
        self != .idle
    }

    var label: String {
        switch self {
        case .idle: "IDLE"
        case .locked: "LOCKED"
        case .tearing: "OPEN"
        case .repairing: "REPAIR"
        case .broken: "NO SIGNAL"
        }
    }
}

/// Immutable snapshot handed to the renderer.
///
/// Coordinates are normalised to the preview view (0...1, origin top-left);
/// the renderer converts them into texture space using the same aspect-fill
/// crop the preview fragment applies, so the tear lands under the fingers.
struct SignalFractureState: Sendable, Equatable {
    var phase = SignalFracturePhase.idle
    var pointA = SIMD2<Float>(0.5, 0.5)
    var pointB = SIMD2<Float>(0.5, 0.5)
    /// 0 = closed, 1 = fully separated.
    var openness: Float = 0
    /// Relative finger rotation in radians.
    var rotation: Float = 0
    /// Recent movement speed, 0...1. Drives macroblock corruption.
    var velocity: Float = 0
    /// Inverse of velocity, smoothed. Drives clarity of exposed frames.
    var stillness: Float = 0
    /// Host time at which the current phase began.
    var phaseStart: CFTimeInterval = 0
    /// Monotonic gesture frame counter for the telemetry readout.
    var sampleNumber: UInt64 = 0

    static let idle = SignalFractureState()

    var separation: Float {
        simd_distance(pointA, pointB)
    }

    var midpoint: SIMD2<Float> {
        (pointA + pointB) * 0.5
    }
}

/// Thread-safe handoff between the main-actor gesture controller and the
/// renderer's draw callback.
final class SignalFractureMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var state = SignalFractureState.idle
    private var updatedAt: CFTimeInterval = 0

    var latest: SignalFractureState {
        lock.withLock { state }
    }

    /// Age of the newest publish, used by the renderer to fail safe if the
    /// gesture pipeline is interrupted mid-tear.
    var age: CFTimeInterval {
        lock.withLock { CACurrentMediaTime() - updatedAt }
    }

    func publish(_ state: SignalFractureState) {
        lock.withLock {
            self.state = state
            updatedAt = CACurrentMediaTime()
        }
    }

    func reset() {
        lock.withLock {
            state = .idle
            updatedAt = CACurrentMediaTime()
        }
    }
}

/// Timing constants shared by the renderer, the repair animation and the
/// telemetry overlay so they cannot drift apart.
enum SignalFractureTiming {
    /// Length of the violent self-repair.
    static let repairSeconds: CFTimeInterval = 0.34
    /// How long the bright seam survives after the signal reconnects.
    static let seamSeconds: CFTimeInterval = 0.10
    /// Hold time beyond the break threshold before the signal gives way.
    static let breakHoldSeconds: CFTimeInterval = 0.70
    /// Separation, in normalised view units, past which a break can occur.
    static let breakThreshold: Float = 0.62
    /// Total length of the complete-break reconstruction.
    static let breakSeconds: CFTimeInterval = 0.85
    /// Separation at which the membrane starts to open at all.
    static let engageSeparation: Float = 0.08
    /// Separation mapped to full openness.
    static let fullSeparation: Float = 0.52
}
