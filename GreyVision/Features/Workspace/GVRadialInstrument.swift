import CoreHaptics
import SwiftUI
import UIKit

/// Hold the image, and the camera's controls come to the finger.
///
/// Four spokes around the touch point. Sliding toward one selects it; carrying
/// on past it drives the value. Release commits and the ring collapses.
///
/// Every spoke maps to something `CameraRuntime` actually exposes — two
/// continuous (zoom, exposure bias) and two latching (torch, white balance
/// lock). There is deliberately no ISO spoke: auto-exposure owns ISO and there
/// is no setter for it, so a spoke would be a dial connected to nothing.
struct GVRadialInstrument: View {
    /// A spoke and the pipeline capability behind it.
    enum Spoke: CaseIterable {
        case zoom
        case exposure
        case torch
        case whiteBalanceLock

        var label: String {
            switch self {
            case .zoom: "ZOOM"
            case .exposure: "EXP"
            case .torch: "LIGHT"
            case .whiteBalanceLock: "WB"
            }
        }

        /// Continuous spokes track the finger; latching ones fire on release.
        var isContinuous: Bool {
            self == .zoom || self == .exposure
        }

        /// Compass position, clockwise from twelve.
        var angle: Angle {
            switch self {
            case .zoom: .degrees(-90)
            case .exposure: .degrees(0)
            case .torch: .degrees(90)
            case .whiteBalanceLock: .degrees(180)
            }
        }
    }

    @EnvironmentObject private var cameraRuntime: CameraRuntime
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the finger went down, in the viewport's coordinate space.
    let origin: CGPoint
    /// Live finger position.
    let current: CGPoint
    /// Drives the entry animation without a second state object.
    let progress: Double

    private let radius: CGFloat = 96
    /// Travel past the ring before a continuous spoke starts changing.
    private let deadZone: CGFloat = 34

    /// The spoke the finger is pointing at, if it has left the dead zone.
    var selected: Spoke? {
        Self.spoke(from: origin, to: current, deadZone: deadZone)
    }

    static func spoke(from origin: CGPoint, to current: CGPoint, deadZone: CGFloat) -> Spoke? {
        let dx = current.x - origin.x
        let dy = current.y - origin.y
        guard hypot(dx, dy) > deadZone else { return nil }
        // Quadrant by dominant axis: a compass read is more forgiving than
        // angular sectors when the finger is close in.
        if abs(dx) > abs(dy) {
            return dx > 0 ? .exposure : .whiteBalanceLock
        }
        return dy > 0 ? .torch : .zoom
    }

    var body: some View {
        ZStack {
            ring
            ForEach(Array(Spoke.allCases.enumerated()), id: \.offset) { _, spoke in
                spokeLabel(spoke)
            }
            hub
        }
        .position(origin)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Parts

    private var ring: some View {
        Circle()
            .stroke(GVTheme.violet.opacity(0.55), lineWidth: 1)
            .frame(width: radius * 2, height: radius * 2)
            .scaleEffect(0.82 + progress * 0.18)
            .opacity(progress)
            .shadow(color: GVTheme.violet.opacity(0.4), radius: 10)
    }

    /// The centre reads back whatever is being driven, so the value the finger
    /// is changing is under the finger rather than at the edge of the screen.
    private var hub: some View {
        let snapshot = cameraRuntime.snapshot
        return Group {
            if let selected {
                Text(hubValue(selected, snapshot: snapshot))
                    .gvFont(.control)
                    .monospacedDigit()
                    .foregroundStyle(GVTheme.bone)
                    .shadow(color: .black.opacity(0.9), radius: 3)
            } else {
                Circle()
                    .fill(GVTheme.violet.opacity(0.8))
                    .frame(width: 5, height: 5)
                    .shadow(color: GVTheme.violet, radius: 6)
            }
        }
        .opacity(progress)
    }

    private func spokeLabel(_ spoke: Spoke) -> some View {
        let isSelected = selected == spoke
        let distance = radius * (0.78 + progress * 0.22)
        let offset = CGSize(
            width: cos(spoke.angle.radians) * distance,
            height: sin(spoke.angle.radians) * distance
        )

        return VStack(spacing: 1) {
            Text(spoke.label)
                .gvFont(.diagnostic)
                .tracking(GVTheme.TypeLevel.diagnostic.tracking)
                .foregroundStyle(isSelected ? GVTheme.violet : GVTheme.ash)

            Text(spokeDetail(spoke))
                .gvMono(GVMetrics.textBody, .bold)
                .monospacedDigit()
                .foregroundStyle(isSelected ? GVTheme.bone : GVTheme.ash.opacity(0.7))
        }
        .shadow(color: .black.opacity(0.9), radius: 3)
        .scaleEffect(isSelected ? 1.12 : 1)
        .offset(offset)
        .opacity(progress)
        .animation(GVMotion.resolved(GVMotion.snap, reduceMotion: reduceMotion), value: isSelected)
    }

    // MARK: - Readouts

    private func hubValue(_ spoke: Spoke, snapshot: CameraRuntimeSnapshot) -> String {
        switch spoke {
        case .zoom: String(format: "%.2f×", snapshot.zoom)
        case .exposure: String(format: "%+.1f EV", snapshot.exposureBias)
        case .torch: snapshot.torchEnabled ? "LIGHT ON" : "LIGHT OFF"
        case .whiteBalanceLock: snapshot.whiteBalanceLocked ? "WB LOCK" : "WB AUTO"
        }
    }

    private func spokeDetail(_ spoke: Spoke) -> String {
        let snapshot = cameraRuntime.snapshot
        switch spoke {
        case .zoom: return String(format: "%.2f", snapshot.zoom)
        case .exposure: return String(format: "%+.1f", snapshot.exposureBias)
        case .torch: return snapshot.torchAvailable ? (snapshot.torchEnabled ? "ON" : "OFF") : "N/A"
        case .whiteBalanceLock: return snapshot.whiteBalanceLocked ? "LOCK" : "AUTO"
        }
    }
}

/// Applies radial output to the capture pipeline, and ticks on detents.
///
/// Kept out of the view so the drag handler has one place to call and the
/// haptic cadence is decided once. Continuous spokes tick per detent crossed,
/// never per frame — a haptic on every drag update is a buzz, not feedback.
@MainActor
final class GVRadialDriver {
    private let selection = UISelectionFeedbackGenerator()
    private let commit = UIImpactFeedbackGenerator(style: .rigid)
    private var lastDetent: Int?
    private var lastSpoke: GVRadialInstrument.Spoke?
    /// Where the value sat when this spoke was picked up, as 0...1.
    ///
    /// Captured once rather than read per update: reading the live value each
    /// time would feed the change back into its own baseline, and the control
    /// would accelerate away under a steady finger.
    private var startFraction: Double?

    func prepare() {
        selection.prepare()
        commit.prepare()
    }

    func spokeChanged(to spoke: GVRadialInstrument.Spoke?, runtime: CameraRuntime) {
        guard spoke != lastSpoke else { return }
        lastSpoke = spoke
        lastDetent = nil
        startFraction = spoke.map { baseline($0, runtime.snapshot) }
        if spoke != nil { selection.selectionChanged() }
    }

    /// `travel` is signed distance past the dead zone, in points.
    func drive(_ spoke: GVRadialInstrument.Spoke, travel: CGFloat, runtime: CameraRuntime) {
        guard spoke.isContinuous else { return }
        let snapshot = runtime.snapshot
        guard let start = startFraction else { return }
        // 160pt of travel covers the full range. Enough that a deliberate
        // sweep lands where intended, short enough to reach in one motion.
        let target = clamp(start + Double(travel / 160))

        switch spoke {
        case .zoom:
            let span = snapshot.maximumZoom - snapshot.minimumZoom
            guard span > 0 else { return }
            runtime.setZoom(snapshot.minimumZoom + span * target)
        case .exposure:
            let span = snapshot.maximumExposureBias - snapshot.minimumExposureBias
            guard span > 0 else { return }
            runtime.setExposureBias(snapshot.minimumExposureBias + span * target)
        default:
            return
        }

        let detent = Int(travel / 20)
        if detent != lastDetent {
            lastDetent = detent
            selection.selectionChanged()
        }
    }

    /// Latching spokes fire once, on release, so a pass-through on the way to
    /// another spoke cannot toggle the torch.
    func commitLatch(_ spoke: GVRadialInstrument.Spoke, runtime: CameraRuntime) {
        let snapshot = runtime.snapshot
        switch spoke {
        case .torch:
            guard snapshot.torchAvailable else { return }
            runtime.setTorchEnabled(!snapshot.torchEnabled)
            commit.impactOccurred(intensity: 0.8)
        case .whiteBalanceLock:
            runtime.setWhiteBalanceLocked(!snapshot.whiteBalanceLocked)
            commit.impactOccurred(intensity: 0.8)
        default:
            break
        }
    }

    func reset() {
        lastDetent = nil
        lastSpoke = nil
        startFraction = nil
    }

    private func baseline(_ spoke: GVRadialInstrument.Spoke, _ snapshot: CameraRuntimeSnapshot) -> Double {
        switch spoke {
        case .zoom:
            let span = max(snapshot.maximumZoom - snapshot.minimumZoom, 0.0001)
            return (snapshot.zoom - snapshot.minimumZoom) / span
        case .exposure:
            let span = max(snapshot.maximumExposureBias - snapshot.minimumExposureBias, 0.0001)
            return (snapshot.exposureBias - snapshot.minimumExposureBias) / span
        default:
            return 0
        }
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
