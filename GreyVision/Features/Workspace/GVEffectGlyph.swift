import SwiftUI

/// Per-family procedural glyphs.
///
/// Each effect family draws its own miniature diagram rather than an icon, so
/// the browser reads as a rack of signal processors. Animation is continuous
/// but extremely low amplitude, and the whole glyph is a single `Canvas` pass.
enum GVEffectGlyphKind {
    case feedback
    case trails
    case echo
    case datamosh
    case pixelSort
    case flow
    case depth
    case block
    case glitch
    case audio
    case frame

    // swiftlint:disable cyclomatic_complexity
    // Maps the effect registry onto a glyph family.
    static func kind(for effect: WorkspaceAdjustableEffect) -> GVEffectGlyphKind {
        switch effect {
        case .feedback, .feedbackTunnel:
            .feedback
        case .trails:
            .trails
        case .echo, .frameHoldSmear, .slitScan:
            .echo
        case .datamosh, .liquidMosh, .heavyMosh, .predictionDrift, .dataBend, .pixelShift:
            .datamosh
        case .sort, .radialSort:
            .pixelSort
        case .pointCloudSmear:
            .depth
        case .pixelate, .posterize, .dither, .threshold, .edge:
            .block
        case .rgbSplit, .vhs, .crt, .grain, .thermal, .invert, .monochrome:
            .glitch
        case .audioScanBend,
             .audioBandSlice, .audioKick:
            .audio
        default:
            .frame
        }
    }
    // swiftlint:enable cyclomatic_complexity
}
