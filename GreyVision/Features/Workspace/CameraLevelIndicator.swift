import CoreMotion
import SwiftUI
import UIKit

/// Which deviation a gauge reports.
enum GVLevelAxis {
    /// Tilt forward and back. Drawn vertically on the right edge.
    case pitch
    /// Roll left and right. Drawn horizontally under the dock.
    case roll
}

/// Tilt gauge. One component, two orientations.
///
/// Pitch runs down the right edge and roll runs under the dock, so between
/// them the frame is bracketed on the two axes that matter when levelling a
/// shot. Both latch inside a dead band rather than trembling around zero,
/// which is what a physical spirit level does and the reason one is trusted.
///
/// Level is reported on three channels at once — position, colour and a haptic
/// tick — so the state never rests on colour alone.
struct CameraLevelIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var motion: CameraLevelMotion

    let axis: GVLevelAxis

    /// Travel from centre to either end, in points.
    private var halfTravel: CGFloat { axis == .pitch ? 52 : 64 }
    /// Degrees mapped to full deflection.
    private let range: Double = 30

    private var degrees: Double {
        axis == .pitch ? motion.pitchDegrees : motion.rollDegrees
    }

    /// Both gauges read level off the same state, so they light together.
    private var level: Bool { motion.isLevel }

    var body: some View {
        let clamped = min(max(degrees / range, -1), 1)
        // Pitch rises as the top tips away; roll follows the horizon.
        let travel = CGFloat(clamped) * halfTravel * (axis == .pitch ? -1 : 1)
        // Sustained sub-point tremor while level. Reads as a needle sitting on
        // its detent and stops the locked state from looking frozen.
        let buzz = level && !reduceMotion ? motion.tremor : 0

        Group {
            if axis == .pitch {
                VStack(spacing: GVMetrics.gapTight) {
                    readout
                    gauge(travel: travel, buzz: buzz)
                }
            } else {
                HStack(spacing: GVMetrics.gapTight) {
                    readout
                    gauge(travel: travel, buzz: buzz)
                }
            }
        }
        .padding(.vertical, axis == .pitch ? GVMetrics.gapTight : 4)
        .padding(.horizontal, axis == .pitch ? 4 : GVMetrics.gapTight)
        // Half transparent. These are reference instruments sitting over the
        // frame; at full opacity they were reading as part of the image.
        //
        // Down to a sixth once the shot is level and the hand is still. A
        // spirit level earns its place by being there when the frame is being
        // set; sitting at full weight over a settled composition it is just
        // furniture.
        .opacity(motion.isDormant ? 0.16 : 0.5)
        .animation(.easeInOut(duration: 0.55), value: motion.isDormant)
        .background(
            RoundedRectangle(cornerRadius: GVMetrics.radiusTight, style: .continuous)
                .fill(GVTheme.surfaceSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: GVMetrics.radiusTight, style: .continuous)
                        .strokeBorder(
                            level ? GVTheme.acid.opacity(0.5) : GVTheme.separator,
                            lineWidth: GVMetrics.hairline
                        )
                )
        )
        .animation(GVMotion.micro, value: level)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(axis == .pitch ? "Pitch level" : "Roll level")
        .accessibilityValue(level ? "Level" : String(format: "%.0f degrees", degrees))
    }

    private var readout: some View {
        Text(level ? "LVL" : String(format: "%+.0f", degrees))
            .gvMono(GVMetrics.textMicro, .black)
            .monospacedDigit()
            .tracking(0.6)
            .foregroundStyle(level ? GVTheme.acid : GVTheme.ash)
            // Fixed width, so crossing from one digit to two cannot shove the
            // track sideways.
            .frame(width: 22, alignment: axis == .pitch ? .center : .trailing)
    }

    private func gauge(travel: CGFloat, buzz: CGFloat) -> some View {
        ZStack {
            track
            centreMark
            marker
                .offset(
                    x: axis == .roll ? travel + buzz : buzz,
                    y: axis == .pitch ? travel : 0
                )
                .animation(
                    .interactiveSpring(response: 0.24, dampingFraction: 0.82),
                    value: travel
                )
        }
        .frame(
            width: axis == .pitch ? 15 : halfTravel * 2 + 12,
            height: axis == .pitch ? halfTravel * 2 + 12 : 15
        )
    }

    /// Graduated rail. Without ticks the marker is motion but not measurement.
    @ViewBuilder private var track: some View {
        if axis == .pitch {
            VStack(spacing: 0) { tickMarks }
                .frame(height: halfTravel * 2)
        } else {
            HStack(spacing: 0) { tickMarks }
                .frame(width: halfTravel * 2)
        }
    }

    private var tickMarks: some View {
        ForEach(0 ..< 9, id: \.self) { index in
            let major = index % 4 == 0
            Rectangle()
                .fill(GVTheme.violetDeep.opacity(major ? 0.5 : 0.24))
                .frame(
                    width: axis == .pitch ? (major ? 9 : 5) : GVMetrics.hairline,
                    height: axis == .pitch ? GVMetrics.hairline : (major ? 9 : 5)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var centreMark: some View {
        Rectangle()
            .fill((level ? GVTheme.acid : GVTheme.violetDeep).opacity(level ? 0.9 : 0.55))
            .frame(
                width: axis == .pitch ? 15 : GVMetrics.hairline,
                height: axis == .pitch ? GVMetrics.hairline : 15
            )
    }

    private var marker: some View {
        Capsule(style: .continuous)
            .fill(level ? GVTheme.acid : GVTheme.bone)
            .frame(
                width: axis == .pitch ? 13 : 3,
                height: axis == .pitch ? 3 : 13
            )
            .shadow(color: level ? GVTheme.acid.opacity(0.6) : .clear, radius: 4)
    }
}

/// Shared device-motion source for both gauges.
///
/// One `CMMotionManager` for the workspace. Two gauges each starting their own
/// would run the sensor twice and could disagree about level, which is the one
/// thing an instrument like this must never do.
@MainActor
final class CameraLevelMotion: ObservableObject {
    @Published private(set) var pitchDegrees: Double = 0
    @Published private(set) var rollDegrees: Double = 0
    /// Sub-point oscillation applied to both markers while level.
    @Published private(set) var tremor: CGFloat = 0
    /// True once the phone has been level and still long enough that the
    /// gauges have nothing left to say. They recede rather than disappearing —
    /// an instrument that vanishes is one the operator stops trusting is there.
    @Published private(set) var isDormant = false

    /// Within this many degrees of upright the gauges report level. Wide
    /// enough to settle in the hand, tight enough to still mean something.
    private let deadBand: Double = 1.4

    var isLevel: Bool {
        abs(pitchDegrees) <= deadBand && abs(rollDegrees) <= deadBand
    }

    private let manager = CMMotionManager()
    private let lock = UIImpactFeedbackGenerator(style: .rigid)
    private var wasLevel = false
    private var tick = 0
    /// Frames of continuous stillness. At 30 Hz, 75 is 2.5 seconds — long
    /// enough that a deliberate pause while framing does not dim the gauge,
    /// short enough that a settled shot clears the frame quickly.
    private var stillFrames = 0
    private var lastPitch: Double = 0
    private var lastRoll: Double = 0

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        lock.prepare()
        manager.deviceMotionUpdateInterval = 1 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            // Read off gravity, not Euler angles.
            //
            // `attitude.pitch` is bounded to ±90°, so held upright — which is
            // exactly how the phone is held to shoot — the gauge sat on the
            // boundary: tipping the top toward you and away from you both
            // *decreased* pitch, and roll flipped 180° as it crossed. The
            // vertical gauge therefore could not tell forward tilt from back
            // and jittered at rest. The gravity vector has no such
            // discontinuity anywhere in the range.
            //
            // Device axes: +x right, +y up the screen, +z out of the glass.
            // Upright portrait puts gravity at (0, -1, 0).
            let gravity = motion.gravity
            let pitch = atan2(-gravity.z, -gravity.y) * 180 / .pi
            let roll = atan2(gravity.x, -gravity.y) * 180 / .pi
            // Light smoothing. Raw attitude jitters enough at rest that the
            // markers would twitch and read as an unreliable instrument.
            pitchDegrees += (pitch - pitchDegrees) * 0.28
            rollDegrees += (roll - rollDegrees) * 0.28

            // Dormancy is about the hand, not the angle: a phone held
            // deliberately off-level is still being aimed, and dimming the
            // gauge mid-adjustment is the opposite of helpful.
            let movement = abs(pitch - lastPitch) + abs(roll - lastRoll)
            lastPitch = pitch
            lastRoll = roll
            if movement > 0.25 {
                stillFrames = 0
            } else {
                stillFrames &+= 1
            }
            let dormant = stillFrames > 75 && isLevel
            if dormant != isDormant {
                isDormant = dormant
            }

            let level = isLevel
            if level {
                // ±0.5pt at 15Hz. Small enough to read as a needle resting on
                // its detent rather than as a broken animation.
                tick &+= 1
                tremor = tick.isMultiple(of: 2) ? 0.5 : -0.5
            } else if tremor != 0 {
                tremor = 0
            }
            // One tick on arrival. Firing continuously while level would turn
            // a confirmation into a nuisance.
            if level, !wasLevel {
                lock.impactOccurred(intensity: 0.7)
            }
            wasLevel = level
        }
    }

    func stop() {
        guard manager.isDeviceMotionActive else { return }
        manager.stopDeviceMotionUpdates()
        tremor = 0
        wasLevel = false
        stillFrames = 0
        isDormant = false
    }
}
