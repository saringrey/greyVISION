import SwiftUI

/// A soft black field behind bright content.
///
/// The splash lays the wordmark and the signature directly over the mark's
/// violet field, and where the artwork's own falloff ended against that text
/// the two met on a visible line. Darkening the plate underneath removes the
/// meeting point: the violet fades into black before the type starts, so
/// there is no edge left to see.
///
/// Built from stacked shadows rather than a shape, so it takes the silhouette
/// of whatever it is applied to and never introduces a rectangle of its own —
/// which is the mistake that produced the seam in the first place.
struct GVBlackHalo: ViewModifier {
    let radius: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(opacity), radius: radius * 0.30)
            .shadow(color: .black.opacity(opacity * 0.8), radius: radius * 0.62)
            .shadow(color: .black.opacity(opacity * 0.55), radius: radius)
    }
}

extension View {
    /// Sinks bright content into a dark pocket.
    ///
    /// - Parameters:
    ///   - radius: Reach of the outermost falloff, in points.
    ///   - opacity: Darkness of the innermost pass.
    func gvBlackHalo(radius: CGFloat, opacity: Double = 0.65) -> some View {
        modifier(GVBlackHalo(radius: radius, opacity: opacity))
    }
}

/// A slow specular sweep across the mark while the system boots.
///
/// Reads as light travelling over a physical object rather than as a glow
/// switched on, which is the difference between the mark looking lit and the
/// mark looking like an image with a filter on it.
struct GVLogoGlint: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// When the sweep began.
    let start: Date
    /// Seconds for one pass, edge to edge.
    var duration: Double = 2.6

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30, paused: reduceMotion)) { timeline in
            let elapsed = max(timeline.date.timeIntervalSince(start), 0)
            // Runs once and stops. A looping glint turns the mark into a
            // banner ad.
            let progress = min(elapsed / duration, 1)
            // Travels from off one edge to off the other, so the band is never
            // parked in view at either end.
            let sweep = -0.45 + progress * 1.9
            // Fades out over the last third rather than cutting.
            let presence = 1 - max((progress - 0.66) / 0.34, 0)

            GeometryReader { proxy in
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: max(sweep - 0.20, 0)),
                        .init(color: .white.opacity(0.16 * presence), location: max(sweep - 0.05, 0)),
                        .init(color: GVTheme.violet.opacity(0.42 * presence), location: min(max(sweep, 0), 1)),
                        .init(color: .white.opacity(0.16 * presence), location: min(sweep + 0.05, 1)),
                        .init(color: .clear, location: min(sweep + 0.20, 1))
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .blendMode(.plusLighter)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
