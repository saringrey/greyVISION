import SwiftUI

/// The ground the chrome stands on, only as dark as the frame requires.
///
/// The interface is unplated type laid over the live camera. Against a dark
/// subject that reads beautifully and the camera stays the whole screen; against
/// a white wall, a bright sky or a lit stage the dock and the telemetry strip
/// disappear entirely. Plating every control permanently would fix it and undo
/// the thing the design spent its whole diff achieving.
///
/// So the renderer measures the frame's perceptual brightness under the two
/// bands where chrome actually lives, and the scrim darkens only when it has
/// to. Over a night shot this is nearly invisible. Over a snowfield it is a
/// solid gradient. Nothing else in the interface changes.
///
/// A gradient rather than a slab, so the viewport still reads as larger than
/// the controls mounted on it.
struct GVAdaptiveScrim: View {
    enum Edge {
        case top
        case bottom
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let edge: Edge
    var height: CGFloat
    let statsMailbox: CameraRenderStatsMailbox

    var body: some View {
        // 4 Hz. This tracks a lighting condition, not a frame — the renderer
        // already smooths it heavily, and polling faster would only spend
        // battery arriving at the same number.
        TimelineView(.periodic(from: .now, by: reduceMotion ? 1 : 0.25)) { _ in
            let stats = statsMailbox.latest
            let load = edge == .top ? stats.topChromeLoad : stats.bottomChromeLoad

            LinearGradient(
                stops: stops(for: load),
                startPoint: edge == .top ? .bottom : .top,
                endPoint: edge == .top ? .top : .bottom
            )
            .frame(height: height)
            .animation(.easeInOut(duration: 0.45), value: load)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func stops(for strength: Double) -> [Gradient.Stop] {
        // Quiet end and loud end of each stop, interpolated by `strength`.
        //
        // The bottom is weighted toward its middle rather than its edge: that
        // is where the category rail sits, and a gradient that only gets dark
        // at the very bottom leaves the rail exactly where it was.
        let ramp: [(location: Double, quiet: Double, loud: Double)] = edge == .top
            ? [(0.0, 0.00, 0.06), (0.34, 0.10, 0.48), (0.70, 0.24, 0.74), (1.0, 0.38, 0.90)]
            : [(0.0, 0.00, 0.08), (0.34, 0.32, 0.74), (0.62, 0.70, 0.92), (1.0, 0.88, 0.97)]

        return ramp.map { stop in
            let opacity = stop.quiet + (stop.loud - stop.quiet) * strength
            return .init(color: .black.opacity(opacity), location: stop.location)
        }
    }
}
