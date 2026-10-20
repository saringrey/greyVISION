import CoreText
import SwiftUI

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
