import Combine
import Foundation
import QuartzCore
import simd
import SwiftUI

/// Presentation-side view of the fracture, published at a low rate so the
/// telemetry overlay never becomes a per-frame main-actor cost.
struct SignalFractureTelemetry: Equatable, Sendable {
    var phase = SignalFracturePhase.idle
    var midpoint = CGPoint(x: 0.5, y: 0.5)
    var pointA = CGPoint(x: 0.5, y: 0.5)
    var pointB = CGPoint(x: 0.5, y: 0.5)
    var delta = 0
    var sampleNumber: UInt64 = 0
    var openness = 0.0
    var showsRestored = false
}

/// Owns the fracture lifecycle: gesture intake, the violent self-repair, the
/// rare complete break, and the haptic punctuation.
///
/// Continuous animation is *not* driven from here. The controller publishes a
/// phase and its start time; the renderer derives repair, seam and break
/// progress from the GPU clock, so there is no 60 Hz main-thread timer.
@MainActor
final class SignalFractureController: ObservableObject {
    @Published private(set) var telemetry = SignalFractureTelemetry()

    let mailbox = SignalFractureMailbox()

    private var state = SignalFractureState.idle
    private var lastMoveTime: CFTimeInterval = 0
    private var lastMidpoint = SIMD2<Float>(0.5, 0.5)
    private var lastAngle: Float = 0
    private var baseAngle: Float = 0
    private var beyondThresholdSince: CFTimeInterval?
    private var lifecycleTask: Task<Void, Never>?
    private var publishThrottle: CFTimeInterval = 0

    var isEngaged: Bool {
        state.phase.isEngaged
    }

    deinit {
        lifecycleTask?.cancel()
    }

    // MARK: - Gesture intake

    func began(a pointA: CGPoint, b pointB: CGPoint) {
        lifecycleTask?.cancel()
        lifecycleTask = nil

        let now = CACurrentMediaTime()
        state = SignalFractureState(
            phase: .locked,
            pointA: SIMD2<Float>(Float(pointA.x), Float(pointA.y)),
            pointB: SIMD2<Float>(Float(pointB.x), Float(pointB.y)),
            openness: 0,
            rotation: 0,
            velocity: 0,
            stillness: 1,
            phaseStart: now,
            sampleNumber: state.sampleNumber &+ 1
        )
        baseAngle = angle(state.pointA, state.pointB)
        lastAngle = baseAngle
        lastMidpoint = state.midpoint
        lastMoveTime = now
        beyondThresholdSince = nil
        commit(force: true)
    }

    func moved(a pointA: CGPoint, b pointB: CGPoint) {
        guard state.phase == .locked || state.phase == .tearing else { return }
        let now = CACurrentMediaTime()
        let newA = SIMD2<Float>(Float(pointA.x), Float(pointA.y))
        let newB = SIMD2<Float>(Float(pointB.x), Float(pointB.y))

        let delta = max(Float(now - lastMoveTime), 1 / 240)
        let travel = simd_distance((newA + newB) * 0.5, lastMidpoint) +
            abs(simd_distance(newA, newB) - state.separation)
        let instantaneous = min(travel / delta / 2.2, 1)

        state.pointA = newA
        state.pointB = newB
        state.openness = SignalFractureController.openness(for: state.separation)
        state.rotation = shortestAngle(angle(newA, newB) - baseAngle)
        // Violent movement corrupts; holding still stabilises.
        state.velocity = state.velocity * 0.72 + instantaneous * 0.28
        state.stillness = state.stillness * 0.86 + (1 - min(state.velocity * 2.4, 1)) * 0.14
        state.sampleNumber &+= 1

        if state.openness > 0.02, state.phase == .locked {
            state.phase = .tearing
            state.phaseStart = now
            // Fires once, on the transition into tearing, and is shaped by the
            // gesture that opened it: pitch from how far it was pulled, pan
            // from where on the frame, level from how hard. Retriggering per
            // frame would turn the tear into a buzz.
            GVSoundEngine.shared.playModulated(
                .signalTear,
                openness: state.openness,
                position: state.midpoint.x,
                rotation: state.rotation,
                velocity: state.velocity
            )
        }

        // Alternate release: pull far and hold.
        if state.separation >= SignalFractureTiming.breakThreshold {
            let since = beyondThresholdSince ?? now
            beyondThresholdSince = since
            if now - since >= SignalFractureTiming.breakHoldSeconds, state.phase == .tearing {
                enterBreak(now: now)
                lastMoveTime = now
                lastMidpoint = state.midpoint
                lastAngle = state.rotation
                return
            }
        } else {
            beyondThresholdSince = nil
        }

        lastMoveTime = now
        lastMidpoint = state.midpoint
        lastAngle = state.rotation
        commit(force: false)
    }

    func ended() {
        guard state.phase == .locked || state.phase == .tearing else { return }
        guard state.openness > 0.01 else {
            reset()
            return
        }
        beginRepair()
    }

    func cancelled() {
        guard state.phase != .broken else { return }
        guard state.phase.isEngaged else { return }
        beginRepair()
    }

    /// Hard reset. Used on interruption, scene phase change, camera restart and
    /// renderer teardown so the pipeline can never be stranded mid-tear.
    func reset() {
        lifecycleTask?.cancel()
        lifecycleTask = nil
        beyondThresholdSince = nil
        state = SignalFractureState(
            phase: .idle,
            pointA: state.pointA,
            pointB: state.pointB,
            openness: 0,
            rotation: 0,
            velocity: 0,
            stillness: 1,
            phaseStart: CACurrentMediaTime(),
            sampleNumber: state.sampleNumber
        )
        mailbox.reset()
        telemetry = SignalFractureTelemetry(sampleNumber: state.sampleNumber)
    }

    // MARK: - Lifecycle

    private func beginRepair() {
        let now = CACurrentMediaTime()
        state.phase = .repairing
        state.phaseStart = now
        beyondThresholdSince = nil
        commit(force: true)

        lifecycleTask?.cancel()
        lifecycleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(SignalFractureTiming.repairSeconds * 1000)))
            guard !Task.isCancelled, let self, state.phase == .repairing else { return }
            // The snap lands exactly when the two sides reconnect.
            GVBootHaptics.signalSnap()
            telemetry.showsRestored = true

            let seam = Int(SignalFractureTiming.seamSeconds * 1000)
            try? await Task.sleep(for: .milliseconds(seam + 420))
            guard !Task.isCancelled else { return }
            self.reset()
        }
    }

    private func enterBreak(now: CFTimeInterval) {
        state.phase = .broken
        state.phaseStart = now
        state.openness = 1
        commit(force: true)
        GVBootHaptics.signalBreak()

        lifecycleTask?.cancel()
        lifecycleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(SignalFractureTiming.breakSeconds * 1000)))
            guard !Task.isCancelled, let self else { return }
            reset()
        }
    }

    // MARK: - Publishing

    private func commit(force: Bool) {
        mailbox.publish(state)

        let now = CACurrentMediaTime()
        guard force || now - publishThrottle >= 1 / 20 else { return }
        publishThrottle = now

        telemetry = SignalFractureTelemetry(
            phase: state.phase,
            midpoint: CGPoint(x: Double(state.midpoint.x), y: Double(state.midpoint.y)),
            pointA: CGPoint(x: Double(state.pointA.x), y: Double(state.pointA.y)),
            pointB: CGPoint(x: Double(state.pointB.x), y: Double(state.pointB.y)),
            delta: Int((state.separation * 1000).rounded()),
            sampleNumber: state.sampleNumber,
            openness: Double(state.openness),
            showsRestored: false
        )
    }

    static func openness(for separation: Float) -> Float {
        let engage = SignalFractureTiming.engageSeparation
        let full = SignalFractureTiming.fullSeparation
        return min(max((separation - engage) / max(full - engage, 0.0001), 0), 1)
    }

    private func angle(_ pointA: SIMD2<Float>, _ pointB: SIMD2<Float>) -> Float {
        atan2(pointB.y - pointA.y, pointB.x - pointA.x)
    }

    private func shortestAngle(_ value: Float) -> Float {
        var result = value
        while result > .pi {
            result -= 2 * .pi
        }
        while result < -.pi {
            result += 2 * .pi
        }
        return result
    }
}
