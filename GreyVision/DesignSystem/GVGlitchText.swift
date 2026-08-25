import SwiftUI

/// Chromatic glitch text.
///
/// Native port of React Bits' `GlitchText`: two offset copies of the string sit
/// behind the fill, one shadowed red and one cyan, each masked by a clip
/// rectangle that jumps to a new band on its own cycle. The web version drives
/// this with two CSS keyframe animations at different durations; here the same
/// two cycles are derived from the clock, which keeps them out of phase without
/// needing a second animation driver.
struct GVGlitchText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String
    var size: CGFloat = 16
    var weight: Font.Weight = .black
    var tracking: CGFloat = 1.2
    var fill = GVTheme.bone
    /// Higher slows the glitch, matching the component's `speed` multiplier.
    var speed: Double = 0.5
    var enableShadows = true

    /// The clip bands the web keyframes step through, as (topInset, bottomInset)
    /// fractions of the line box.
    private static let bands: [(CGFloat, CGFloat)] = [
        (0.20, 0.50), (0.10, 0.60), (0.15, 0.55), (0.25, 0.35),
        (0.30, 0.40), (0.40, 0.20), (0.10, 0.60), (0.15, 0.55),
        (0.25, 0.35), (0.30, 0.40), (0.20, 0.50), (0.10, 0.60),
        (0.15, 0.55), (0.25, 0.35), (0.30, 0.40), (0.40, 0.20),
        (0.20, 0.50), (0.10, 0.60), (0.15, 0.55), (0.25, 0.35)
    ]

    var body: some View {
        if reduceMotion {
            glyphs.foregroundStyle(fill)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 20, paused: false)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                ZStack {
                    layer(time: time, duration: speed * 2, offset: -5, shadow: .cyan)
                    layer(time: time, duration: speed * 3, offset: 5, shadow: .red)
                    glyphs.foregroundStyle(fill)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
        }
    }

    /// One displaced, clipped copy. `alternate-reverse` in the original is what
    /// makes the two copies never line up; stepping the band table forward and
    /// backward on alternating cycles reproduces that.
    private func layer(time: TimeInterval, duration: Double, offset: CGFloat, shadow: Color) -> some View {
        let cycle = time / max(duration, 0.05)
        let step = Int(cycle * Double(Self.bands.count)) % Self.bands.count
        let reversed = Int(cycle) % 2 == 1
        let index = reversed ? Self.bands.count - 1 - step : step
        let band = Self.bands[index]

        return glyphs
            .foregroundStyle(fill)
            .shadow(color: enableShadows ? shadow.opacity(0.9) : .clear, radius: 0, x: offset * 0.4)
            .offset(x: offset)
            .mask(alignment: .top) {
                GeometryReader { geometry in
                    let height = geometry.size.height
                    Rectangle()
                        .frame(height: max(height * (1 - band.0 - band.1), 1))
                        .offset(y: height * band.0)
                }
            }
            .allowsHitTesting(false)
    }

    private var glyphs: some View {
        Text(text)
            .gvTerminal(size, weight)
            .tracking(tracking)
    }
}
