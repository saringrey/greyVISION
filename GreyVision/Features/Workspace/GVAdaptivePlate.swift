import SwiftUI

/// A panel's own plate, only as dark as the frame under it requires.
///
/// The scrims handle the bands at the top and bottom of the screen. Panels
/// sit inside those bands and cannot simply be made opaque: the whole reason
/// to open one is to watch the image change while driving a value. So they get
/// the same treatment the scrims get — measured, not assumed.
///
/// Over a dark subject this is very nearly nothing and the panel reads as type
/// floating on the frame. Over a blown-out sky it is a real plate. The numbers
/// stay readable either way, which is the only thing a panel exists to do.
struct GVAdaptivePlate: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let statsMailbox: CameraRenderStatsMailbox
    /// Which measured band this panel actually sits in. A panel under the
    /// status line is lit by what is at the top of the frame, not by what is
    /// behind the effect deck two thirds of the way down.
    var band: KeyPath<CameraRenderStats, Double> = \.deckChromeLoad
    var cornerRadius: CGFloat = GVMetrics.radiusPanel
    /// Plate opacity over a dark frame and over a bright one.
    var quiet: Double = 0.04
    var loud: Double = 0.74

    func body(content: Content) -> some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 1 : 0.25)) { _ in
            let load = statsMailbox.latest[keyPath: band]
            let opacity = quiet + (loud - quiet) * load

            content
                .background { adaptiveBackground(opacity: opacity) }
                .overlay { adaptiveBorder }
                .animation(.easeInOut(duration: 0.45), value: load)
        }
    }

    private func adaptiveBackground(opacity: Double) -> some View {
        let tint = Color.black.opacity(opacity)

        return ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tint)
        }
    }

    private var adaptiveBorder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(Color.white.opacity(0.035), lineWidth: GVMetrics.hairline)
    }
}

extension View {
    /// Darkens this panel's plate by however much the frame beneath it demands.
    func gvAdaptivePlate(
        _ statsMailbox: CameraRenderStatsMailbox,
        band: KeyPath<CameraRenderStats, Double> = \.deckChromeLoad,
        cornerRadius: CGFloat = GVMetrics.radiusPanel,
        quiet: Double = 0.04,
        loud: Double = 0.74
    ) -> some View {
        modifier(GVAdaptivePlate(
            statsMailbox: statsMailbox,
            band: band,
            cornerRadius: cornerRadius,
            quiet: quiet,
            loud: loud
        ))
    }
}
