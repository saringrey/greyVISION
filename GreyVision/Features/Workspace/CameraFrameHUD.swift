import SwiftUI

/// Subtle focus indicator around the live frame.
///
/// Shows only the last touch point while focusing. Decorative system chatter
/// and edge visualizers were removed to keep the viewfinder clean.
struct CameraFrameHUD: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var cameraRuntime: CameraRuntime
    @EnvironmentObject private var audioRuntime: AudioReactiveRuntime

    /// Normalised coordinate of the most recent touch interaction, if any.
    let touchPoint: CGPoint?

    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 1 : 1 / 6)) { _ in
            ZStack(alignment: .topLeading) {
                if let touchPoint {
                    coordinateReadout(at: touchPoint)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func coordinateReadout(at point: CGPoint) -> some View {
        GeometryReader { geometry in
            label(
                String(format: "%.2f, %.2f", point.x, point.y),
                opacity: 0.45
            )
            .position(
                x: min(max(point.x * geometry.size.width + 34, 40), geometry.size.width - 40),
                y: min(max(point.y * geometry.size.height + 16, 20), geometry.size.height - 20)
            )
        }
    }

    private func label(
        _ text: String,
        opacity: Double,
        color: Color = GVTheme.bone
    ) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(color.opacity(opacity))
            .fixedSize()
    }
}
