import SwiftUI

/// Seamless splash backdrop.
///
/// The previous composition layered a radial gradient that terminated at
/// `0.76 * max(width, height)` over a grid field masked by a fixed 420 pt
/// circle. Both terminations landed inside the visible frame on most devices,
/// producing a hard ring that read as two images butted together.
///
/// This version derives every radius from the actual geometry, extends past the
/// corner diagonal, and uses multi-stop ramps so there is no discontinuity
/// anywhere in the frame.
struct GVSplashBackdrop: View {
    /// 0 = void, 1 = fully surfaced. Drives the whole backdrop's presence.
    let presence: Double
    /// Extra bloom, typically driven by a live signal.
    var energy: Double = 0

    var body: some View {
        GeometryReader { geometry in
            // Corner-to-corner distance from centre: past this, nothing is
            // visible, so every ramp must complete beyond it.
            let diagonal = hypot(geometry.size.width, geometry.size.height) * 0.5
            let reach = max(diagonal * 1.35, 1)

            // Eased presence. The bloom *grows* out of the centre rather than
            // cross-fading in at full size: fading a full-screen violet disc up
            // from black reads as a slab arriving, which is exactly what this
            // avoids. Radius leads, amplitude follows.
            let eased = presence * presence * (3 - 2 * presence)
            let radius = reach * (0.06 + eased * 0.94)
            let amplitude = pow(eased, 1.8)

            ZStack {
                GVTheme.void

                // Core violet bloom. Many small steps so the falloff never
                // bands or rings, and a low peak so it never reads as a shape.
                RadialGradient(
                    stops: [
                        .init(color: GVTheme.violetDeep.opacity((0.20 + energy * 0.08) * amplitude), location: 0.00),
                        .init(color: GVTheme.violetDeep.opacity((0.150 + energy * 0.06) * amplitude), location: 0.14),
                        .init(color: GVTheme.violetDeep.opacity(0.092 * amplitude), location: 0.28),
                        .init(color: GVTheme.violetDeep.opacity(0.052 * amplitude), location: 0.42),
                        .init(color: GVTheme.violetDeep.opacity(0.027 * amplitude), location: 0.56),
                        .init(color: GVTheme.violetDeep.opacity(0.012 * amplitude), location: 0.70),
                        .init(color: GVTheme.violetDeep.opacity(0.004 * amplitude), location: 0.84),
                        .init(color: .clear, location: 1.00)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: radius
                )

                // A second, wider and weaker wash on a different scale. Two
                // overlapping ramps hide any residual step in either one.
                RadialGradient(
                    stops: [
                        .init(color: GVTheme.violet.opacity(0.042 * amplitude), location: 0.00),
                        .init(color: GVTheme.violet.opacity(0.020 * amplitude), location: 0.38),
                        .init(color: GVTheme.violet.opacity(0.006 * amplitude), location: 0.68),
                        .init(color: .clear, location: 1.00)
                    ],
                    center: UnitPoint(x: 0.5, y: 0.42),
                    startRadius: 0,
                    endRadius: radius * 1.7
                )
                .blendMode(.screen)

                // Vertical settling across the full height. The previous version
                // held clear between 0.34 and 0.66, and those two stops were
                // visible as horizontal bands across the violet.
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.34 * amplitude), location: 0.00),
                        .init(color: .black.opacity(0.14 * amplitude), location: 0.22),
                        .init(color: .black.opacity(0.03 * amplitude), location: 0.44),
                        .init(color: .black.opacity(0.03 * amplitude), location: 0.58),
                        .init(color: .black.opacity(0.18 * amplitude), location: 0.80),
                        .init(color: .black.opacity(0.44 * amplitude), location: 1.00)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Fine dither breaks up any remaining gradient banding.
                GVBackdropDither()
                    .opacity(0.055 * amplitude)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Static ordered dither. Gradients over near-black band badly on OLED; a
/// fixed, non-animating noise field removes it without adding motion.
private struct GVBackdropDither: View {
    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            var state: UInt64 = 0x4756_4449_5448_4552
            let step: CGFloat = 3
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    state = (state &* 6_364_136_223_846_793_005) &+ 1_442_695_040_888_963_407
                    let value = Double((state >> 33) % 1000) / 1000
                    if value > 0.86 {
                        context.fill(
                            Path(CGRect(x: x, y: y, width: 1, height: 1)),
                            with: .color(.white.opacity(value * 0.5))
                        )
                    }
                    x += step
                }
                y += step
            }
        }
        .blendMode(.overlay)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
