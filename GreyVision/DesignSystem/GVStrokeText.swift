import CoreText
import SwiftUI

/// Wordmark that draws itself as an outline, then floods with fill.
///
/// This is the React Bits `StrokeText` behaviour rebuilt natively. The original
/// is a GSAP timeline animating `strokeDashoffset` on SVG `<text>` with a
/// clip-path wipe over the fill. None of that transfers to a SwiftUI app, so
/// the mechanism is rebuilt from the equivalent primitives:
///
///   strokeDasharray / strokeDashoffset  →  `Shape.trim(from:to:)`
///   per-character `<tspan>` stagger     →  one path per glyph, offset start
///   clip-path wipe over the fill        →  a mask rectangle growing on X
///   GSAP timeline                       →  `TimelineView` over a start date
///
/// Glyph outlines come from Core Text rather than from a font-rendered `Text`,
/// because `trim` needs a real path — there is no way to partially draw a
/// `Text` view. That also means the stroke follows the true letterform instead
/// of an approximation.
struct GVStrokeText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String
    var fontSize: CGFloat = 40
    var weight: Font.Weight = .black
    var tracking: CGFloat = 6.8
    var strokeColor: Color = GVTheme.violet
    var fillColor: Color = GVTheme.bone
    var strokeWidth: CGFloat = 1.4
    /// Seconds each glyph outline spends drawing on.
    var drawDuration: Double = 1.6
    /// Seconds after the outline completes before the fill begins.
    var fillDelay: Double = 0.2
    /// Seconds between one glyph starting and the next.
    var stagger: Double = 0.05
    /// When the timeline began.
    let start: Date

    private var glyphs: [GVGlyphPath] {
        GVGlyphPath.paths(for: text, fontSize: fontSize, weight: weight, tracking: tracking)
    }

    var body: some View {
        let shapes = glyphs
        let bounds = shapes.reduce(CGRect.null) { $0.union($1.path.boundingRect) }
        guard !shapes.isEmpty, !bounds.isNull, bounds.width > 0 else {
            return AnyView(EmptyView())
        }

        // Total run: the last glyph starts at (count - 1) * stagger.
        let lastStart = Double(shapes.count - 1) * stagger
        let drawEnd = lastStart + drawDuration
        let fillDuration = max(0.4, drawDuration * 0.5)

        return AnyView(
            TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 60, paused: reduceMotion)) { timeline in
                // Reduce Motion lands on the finished state rather than
                // animating, which is what the source component does too.
                let elapsed = reduceMotion
                    ? drawEnd + fillDelay + fillDuration
                    : max(timeline.date.timeIntervalSince(start), 0)
                let fillProgress = min(max((elapsed - drawEnd - fillDelay) / fillDuration, 0), 1)

                ZStack {
                    ForEach(Array(shapes.enumerated()), id: \.offset) { index, glyph in
                        let began = elapsed - Double(index) * stagger
                        let drawn = min(max(began / drawDuration, 0), 1)
                        GVGlyphShape(path: glyph.path, bounds: bounds)
                            .trim(from: 0, to: drawn)
                            .stroke(strokeColor, lineWidth: strokeWidth)
                    }

                    // Fill wipes in left to right behind the outline, clipped
                    // by a rectangle whose width is animated. Fading the fill
                    // in instead would lose the sense of the letters being
                    // poured rather than switched on.
                    ForEach(Array(shapes.enumerated()), id: \.offset) { _, glyph in
                        GVGlyphShape(path: glyph.path, bounds: bounds)
                            .fill(fillColor)
                    }
                    .mask(
                        GeometryReader { proxy in
                            Rectangle()
                                .frame(width: proxy.size.width * fillProgress)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    )
                }
                .aspectRatio(bounds.width / bounds.height, contentMode: .fit)
            }
            .frame(height: fontSize * 1.05)
            .accessibilityElement()
            .accessibilityLabel(text)
        )
    }
}

/// One glyph outline plus where it sits on the baseline.
struct GVGlyphPath {
    let path: Path

    /// Extracts per-character outlines with tracking applied.
    ///
    /// Per character rather than one path for the whole string, because the
    /// stagger needs each letter to be trimmable on its own clock.
    static func paths(
        for text: String,
        fontSize: CGFloat,
        weight: Font.Weight,
        tracking: CGFloat
    ) -> [GVGlyphPath] {
        let uiWeight: UIFont.Weight = switch weight {
        case .black: .black
        case .heavy: .heavy
        case .bold: .bold
        case .semibold: .semibold
        default: .regular
        }
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: uiWeight)
        let ctFont = CTFontCreateWithName(font.fontName as CFString, fontSize, nil)

        var results: [GVGlyphPath] = []
        var penX: CGFloat = 0

        for character in text {
            let scalars = Array(String(character).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: scalars.count)
            let mapped = CTFontGetGlyphsForCharacters(ctFont, scalars, &glyphs, scalars.count)
            guard mapped, let glyph = glyphs.first else { continue }

            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyphs, &advance, 1)

            if let cgPath = CTFontCreatePathForGlyph(ctFont, glyph, nil) {
                // Core Text draws with Y up from the baseline; SwiftUI draws
                // with Y down from the top. Flipping here rather than at the
                // view keeps the bounding box arithmetic in one space.
                var transform = CGAffineTransform(translationX: penX, y: 0)
                    .scaledBy(x: 1, y: -1)
                if let flipped = cgPath.copy(using: &transform) {
                    results.append(GVGlyphPath(path: Path(flipped)))
                }
            }
            penX += advance.width + tracking
        }
        return results
    }
}

/// Draws a pre-built glyph path scaled into the view's bounds.
struct GVGlyphShape: Shape {
    let path: Path
    /// Union bounds of every glyph, so all of them share one coordinate space
    /// and the letters do not each stretch to fill the frame.
    let bounds: CGRect

    func path(in rect: CGRect) -> Path {
        guard bounds.width > 0, bounds.height > 0 else { return Path() }
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let offsetX = (rect.width - bounds.width * scale) / 2 - bounds.minX * scale
        let offsetY = (rect.height - bounds.height * scale) / 2 - bounds.minY * scale
        return path.applying(
            CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
        )
    }
}
