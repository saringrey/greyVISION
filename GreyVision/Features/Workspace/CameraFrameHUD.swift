import SwiftUI

/// Instrument furniture around the live camera frame.
///
/// Four hairline corner brackets plus small technical readouts, deliberately
/// asymmetric: vertical telemetry down the left edge, a frame counter at the
/// upper right, a narrow audio waveform creeping up one edge, and occasional
/// microscopic system messages.
///
/// Everything is read from the render and capture mailboxes inside a single
/// `TimelineView` running at 6 Hz, so the HUD never publishes per frame.
struct CameraFrameHUD: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var cameraRuntime: CameraRuntime
    @EnvironmentObject private var audioRuntime: AudioReactiveRuntime

    /// Normalised coordinate of the most recent touch interaction, if any.
    let touchPoint: CGPoint?

    private let inset: CGFloat = 16

    /// Vertical clearance for the capture row.
    ///
    /// RECORD, the roll gauge and SCREENSHOT occupy a 62pt band above the home
    /// indicator. Anything printed at the frame's bottom edge ends up
    /// underneath them.
    private let captureRowClearance: CGFloat = 112

    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 1 : 1 / 6)) { timeline in
            let snapshot = cameraRuntime.snapshot

            ZStack(alignment: .topLeading) {
                waveformEdge()

                if let touchPoint {
                    coordinateReadout(at: touchPoint)
                }

                if let message = systemMessage(at: timeline.date, snapshot: snapshot) {
                    label(message, size: GVMetrics.textMicro, opacity: 0.5, color: GVTheme.violet)
                        .padding(.leading, inset + 14)
                        .padding(.top, 132)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Narrow waveform creeping up the trailing edge when audio is live.
    private func waveformEdge() -> some View {
        let snapshot = audioRuntime.snapshot
        let bands: [Float] = [snapshot.bass, snapshot.mid, snapshot.treble, snapshot.rms, snapshot.peak]

        return VStack(spacing: 2) {
            ForEach(Array(bands.enumerated()), id: \.offset) { _, value in
                Capsule()
                    .fill(GVTheme.violet.opacity(audioRuntime.isEnabled ? 0.55 : 0.10))
                    .frame(width: 1.4, height: 4 + CGFloat(value) * 30)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(.trailing, 5)
    }

    private func coordinateReadout(at point: CGPoint) -> some View {
        GeometryReader { geometry in
            label(
                String(format: "X%0.3f Y%0.3f", point.x, point.y),
                size: GVMetrics.textMicro,
                opacity: 0.42
            )
            .position(
                x: min(max(point.x * geometry.size.width + 34, 40), geometry.size.width - 40),
                y: min(max(point.y * geometry.size.height + 16, 20), geometry.size.height - 20)
            )
        }
    }

    /// Microscopic system messages that appear temporarily.
    private func systemMessage(at date: Date, snapshot: CameraRuntimeSnapshot) -> String? {
        guard snapshot.state == .running else { return nil }
        let tick = Int(date.timeIntervalSinceReferenceDate) % 24
        return switch tick {
        case 3: "SYS// FRAME HEAP NOMINAL"
        case 9: "SYS// TEMPORAL RING BOUNDED"
        case 15: "SYS// SIGNAL PATH LOCAL"
        default: nil
        }
    }

    private func label(
        _ text: String,
        size: CGFloat,
        opacity: Double,
        color: Color = GVTheme.bone,
        weight: Font.Weight = .bold
    ) -> some View {
        Text(text)
            .gvMono(size, weight)
            .tracking(0.9)
            .foregroundStyle(color.opacity(opacity))
            .shadow(color: .black.opacity(0.85), radius: 2)
            .fixedSize()
    }
}
