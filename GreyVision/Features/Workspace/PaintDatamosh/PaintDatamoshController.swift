import Foundation
import QuartzCore
import simd
import SwiftUI

/// One brush stamp of hand-painted motion.
struct GVPaintStroke: Sendable, Equatable {
    /// Brush centre in normalised preview coordinates.
    var point = SIMD2<Float>(0.5, 0.5)
    /// Painted velocity, normalised units per second, clamped.
    var velocity = SIMD2<Float>.zero
    /// Rotational component derived from how much the finger is curling.
    var spin: Float = 0
    /// Brush radius in normalised units.
    var radius: Float = 0.16
    /// 0 when nothing is being painted this frame.
    var strength: Float = 0

    static let inactive = GVPaintStroke()
}

final class GVPaintMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = GVPaintStroke.inactive
    private var updatedAt: CFTimeInterval = 0

    /// Consuming clears the stroke so a single stamp is never applied twice.
    func consume() -> GVPaintStroke {
        lock.withLock {
            let stroke = value
            value.strength = 0
            return stroke
        }
    }

    func publish(_ stroke: GVPaintStroke) {
        lock.withLock {
            value = stroke
            updatedAt = CACurrentMediaTime()
        }
    }

    func clear() {
        lock.withLock {
            value = .inactive
            updatedAt = CACurrentMediaTime()
        }
    }
}

/// Turns a single-finger drag into painted motion vectors.
///
/// Drag right and pixels smear right; spiral and the region develops rotational
/// corruption. Speed controls deposit strength, so a flick damages more than a
/// slow stroke. The field decays continuously in the shader, so painted damage
/// repairs itself without any explicit clear.
@MainActor
final class PaintDatamoshController: ObservableObject {
    @Published private(set) var isPainting = false
    @Published private(set) var lastPoint = CGPoint(x: 0.5, y: 0.5)

    let mailbox = GVPaintMailbox()

    private var previousPoint: SIMD2<Float>?
    private var previousVelocity = SIMD2<Float>.zero
    private var previousTime: CFTimeInterval = 0

    /// True while the paint effect is the armed selection, which is what gates
    /// the gesture so normal tap-to-focus is unaffected the rest of the time.
    var isArmed = false

    func began(at point: CGPoint) {
        guard isArmed else { return }
        isPainting = true
        lastPoint = point
        previousPoint = SIMD2<Float>(Float(point.x), Float(point.y))
        previousVelocity = .zero
        previousTime = CACurrentMediaTime()
    }

    func moved(to point: CGPoint) {
        guard isArmed, isPainting else { return }
        let now = CACurrentMediaTime()
        let current = SIMD2<Float>(Float(point.x), Float(point.y))
        guard let previous = previousPoint else {
            previousPoint = current
            previousTime = now
            return
        }

        let elapsed = Float(max(now - previousTime, 1.0 / 240))
        let delta = current - previous
        let velocity = delta / elapsed

        // Spin is how much the direction is turning: a spiral produces a large
        // cross product between successive velocity vectors.
        let cross = previousVelocity.x * velocity.y - previousVelocity.y * velocity.x
        let spin = max(min(cross * 0.35, 1), -1)

        let speed = simd_length(velocity)
        let strength = min(speed * 0.55, 1)

        mailbox.publish(
            GVPaintStroke(
                point: current,
                velocity: SIMD2<Float>(
                    max(min(velocity.x * 0.35, 1), -1),
                    max(min(velocity.y * 0.35, 1), -1)
                ),
                spin: spin,
                radius: 0.10 + min(speed * 0.03, 0.12),
                strength: max(strength, 0.18)
            )
        )

        lastPoint = point
        previousPoint = current
        previousVelocity = velocity
        previousTime = now
    }

    func ended() {
        isPainting = false
        previousPoint = nil
        previousVelocity = .zero
        mailbox.clear()
    }

    func reset() {
        isArmed = false
        ended()
    }
}
