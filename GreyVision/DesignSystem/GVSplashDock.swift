import SwiftUI

/// The splash's tracker language, carried into the workspace chrome.
///
/// On the splash the film plays as an x-ray, and the "tracked objects" that
/// wander over it are lime corner brackets with a small mono tag hanging off
/// the top-left corner. The docks wear the same thing: an x-ray black plate,
/// a hairline, four lime brackets on its corners and, where a dock names a
/// thing, a lime tag. One language from the first frame to the last control.
enum GVSplashDock {
    /// The splash tracker's lime. Framing only — never a state colour, so it
    /// cannot be mistaken for `GVTheme.acid` (armed) on a key.
    static let lime = Color(red: 0.89, green: 0.96, blue: 0.36)
    /// Tracker boxes are nearly square; the docks keep a whisper of rounding
    /// so they still sit well against the rounded display.
    static let radius: CGFloat = 7
    /// The longest a bracket arm gets, matching the splash's object boxes.
    static let arm: CGFloat = 12
}

/// Four L-shaped corners. `inset` pulls them toward the centre, which is how
/// the splash shows a box "locking on".
struct GVTrackerBrackets: Shape {
    var inset: CGFloat = 0
    var arm: CGFloat = GVSplashDock.arm

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(inset, arm) }
        set { inset = newValue.first; arm = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: inset)
        let length = min(arm, box.width / 4, box.height / 4)
        var path = Path()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: box.minX, y: box.minY), 1, 1), (CGPoint(x: box.maxX, y: box.minY), -1, 1),
            (CGPoint(x: box.minX, y: box.maxY), 1, -1), (CGPoint(x: box.maxX, y: box.maxY), -1, -1)
        ]
        for (corner, dx, dy) in corners {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * length))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * length, y: corner.y))
        }
        return path
    }
}

/// The lime tag the splash hangs off a tracked box: black mono capitals on a
/// lime chip, sitting just above the top-left corner.
struct GVTrackerTag: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(0.6)
            .foregroundStyle(Color.black)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 4)
            .frame(height: 13)
            .background(GVSplashDock.lime)
            .accessibilityHidden(true)
    }
}

/// Static x-ray scanlines: one hairline every three points. Drawn once per
/// size, never animated, so a dock costs nothing extra per frame.
private struct GVXrayScanlines: View {
    var body: some View {
        Canvas { context, size in
            var lines = Path()
            for y in stride(from: CGFloat(0.5), through: size.height, by: 3) {
                lines.move(to: CGPoint(x: 0, y: y))
                lines.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(lines, with: .color(.white.opacity(0.03)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The dock surface. See `GVSplashDock`.
struct GVSplashDockPlate<S: InsettableShape>: ViewModifier {
    let shape: S
    var tag: String?
    var bracketInset: CGFloat = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    shape.fill(Color(red: 0.02, green: 0.025, blue: 0.035))
                } else {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        // The x-ray: near-black with the film's cool cast.
                        shape.fill(Color(red: 0.012, green: 0.018, blue: 0.03).opacity(0.80))
                        GVXrayScanlines().clipShape(shape)
                    }
                }
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(contrast == .increased ? 0.3 : 0.08), lineWidth: 0.6)
                    .allowsHitTesting(false)
            }
            .overlay {
                GVTrackerBrackets(inset: bracketInset)
                    .stroke(GVSplashDock.lime.opacity(0.9),
                            style: StrokeStyle(lineWidth: contrast == .increased ? 1.5 : 1, lineCap: .square))
                    .padding(-1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .topLeading) {
                if let tag {
                    GVTrackerTag(text: tag)
                        .offset(x: -1, y: -14)
                        .allowsHitTesting(false)
                }
            }
            .animation(.spring(response: 0.18, dampingFraction: 0.72), value: bracketInset)
            .shadow(color: .black.opacity(0.45), radius: 12, y: 5)
    }
}
