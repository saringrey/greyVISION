import SwiftUI

/// Text laid around a circle, rotating slowly.
///
/// This is the React Bits `CircularText` behaviour rebuilt natively. The
/// original positions each character with a CSS `rotateZ` plus a translate and
/// spins the container with a Motion tween. The layout maths is the same here;
/// only the transform and the clock change:
///
///   `rotateZ(i * 360/n) translate3d(...)`  →  `.rotationEffect` + `.offset`
///   Motion linear repeat tween             →  `TimelineView` over a start date
///
/// Driven from a timestamp rather than published state, so the ring costs one
/// timer and never pushes a frame through the view graph.
struct GVCircularText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String
    /// Radius of the character ring, in points.
    var radius: CGFloat = 150
    /// Seconds for one full revolution.
    var spinDuration: Double = 20
    var fontSize: CGFloat = 11
    var color: Color = GVTheme.bone
    var opacity: Double = 0.28
    /// Reverses the direction of travel.
    var counterClockwise = false

    private var characters: [Character] { Array(text) }

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30, paused: reduceMotion)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let turns = elapsed / max(spinDuration, 0.1)
            let spin = (counterClockwise ? -turns : turns) * 360

            ZStack {
                ForEach(Array(characters.enumerated()), id: \.offset) { index, character in
                    let step = 360.0 / Double(max(characters.count, 1))
                    let angle = step * Double(index)
                    Text(String(character))
                        .gvMono(fontSize, .bold)
                        .kerning(0.5)
                        .foregroundStyle(color)
                        // Offset first, rotate second. Pushing the glyph up by
                        // the radius and then turning the whole thing about
                        // the centre places it on the ring and tilts it
                        // tangentially in one operation. Rotating before the
                        // offset instead leaves every letter upright, which
                        // reads as a scattered ring rather than curved text.
                        .offset(y: -radius)
                        .rotationEffect(.degrees(angle))
                }
            }
            .frame(width: radius * 2, height: radius * 2)
            .rotationEffect(.degrees(spin))
        }
        .opacity(opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
