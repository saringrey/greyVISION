import SwiftUI

/// The instrument's palette and type.
///
/// Taken from the splash film: a surreal still life of porcelain backdrops,
/// chrome and steel, cobalt lattices, a vermilion sphere, terminal-green
/// growth and olive wood. Porcelain is the type, cool steel-ink the ground,
/// cobalt the selection, green the armed state and vermilion the record.
///
/// Six colours carry meaning and nothing else does. The previous palette had
/// eleven, and the two violets in particular were used interchangeably, which
/// is how every control ended up outlined in the same accent: if the accent is
/// everywhere it has stopped being information.
///
/// The rule now: `bone` and `ash` carry all normal reading, `violet` means the
/// operator selected this, `acid` means the system is armed and ready, and
/// `record` means recording or failure. A view that reaches for an accent to
/// look interesting is reaching for the wrong thing.
enum GVTheme {
    // MARK: - Core palette

    /// Near-black canvas. Everything sits on this. Neutral, not blue: the
    /// only colour in the chrome is the live accent.
    static var void: Color {
        Color(red: 0.008, green: 0.008, blue: 0.010)
    }

    /// Warm off-white. Primary type and anything the operator reads to work.
    ///
    /// Deliberately not pure white: against a black field, 1.0 white haloes on
    /// OLED and reads as a light source rather than as printed type.
    static var bone: Color {
        Color(red: 0.925, green: 0.922, blue: 0.898)
    }

    /// Secondary telemetry and inactive labels. Present, not competing.
    static var ash: Color {
        Color(red: 0.52, green: 0.52, blue: 0.54)
    }

    /// Selected, active, operator-chosen. The only accent on an idle screen,
    /// and on an idle screen there should be at most one or two of them.
    ///
    /// Live: this is `GVAccent`, which follows the camera's dominant colour.
    /// The name is historical; every call site that meant "the accent" reads
    /// through here, so they all change together and immediately.
    static var violet: Color {
        GVAccent.shared.color
    }

    /// Same as `violet`; the name new code should use.
    static var accent: Color {
        GVAccent.shared.color
    }

    /// The deep end of the violet ramp. Gradients, glows and edges fade toward
    /// this; it is never a standalone state colour.
    static var violetDeep: Color {
        GVAccent.shared.deep
    }

    /// Armed, ready, succeeded. Never decoration.
    static var acid: Color {
        Color(red: 0.38, green: 0.88, blue: 0.54)
    }

    /// Recording, destructive, critical. Never decoration.
    static var record: Color {
        Color(red: 0.93, green: 0.26, blue: 0.17)
    }

    /// Linear RGB passed to interaction shaders. Keeping this beside the
    /// visible palette prevents press treatments from inventing a separate
    /// accent that does not exist anywhere else in the instrument.
    static var interactionPulseRGB: SIMD3<Float> {
        GVAccent.shared.floatRGB
    }

    /// Warning that is genuinely a warning — thermal pressure, dropped frames.
    /// Muted on purpose so it cannot be mistaken for `record`.
    static var warn: Color {
        Color(red: 0.80, green: 0.66, blue: 0.32)
    }

    // MARK: - Semantic state

    /// State to colour. Views should reach for these rather than picking a
    /// palette entry directly, so a control cannot drift out of step with the
    /// rest of the instrument.
    enum State {
        case inactive
        case normal
        case selected
        case armed
        case recording
        case error
        case warning
    }

    /// The dimmest mark the instrument draws: unlit tick marks, an inactive
    /// toggle, a control that is present but has nothing to say.
    static var faint: Color {
        Color(red: 0.22, green: 0.22, blue: 0.24)
    }

    static func color(_ state: State) -> Color {
        switch state {
        case .inactive: ash
        case .normal: bone
        case .selected: violet
        case .armed: acid
        case .recording, .error: record
        case .warning: warn
        }
    }

    // MARK: - Surfaces

    /// Three tiers, distilled. Charcoal plates separate groups without heavy
    /// outlines; only the armed tier carries a clear state edge.
    static var surfacePrimary: Color {
        Color(red: 0.030, green: 0.030, blue: 0.034).opacity(0.74)
    }

    static var surfaceSecondary: Color {
        Color(red: 0.024, green: 0.024, blue: 0.028).opacity(0.54)
    }

    static var surfaceArmed: Color {
        Color(red: 0.045, green: 0.045, blue: 0.050).opacity(0.80)
    }

    /// Shared elevation tint so panels feel lit by the same source.
    static var elevationShadow: Color {
        Color.black.opacity(0.22)
    }

    /// Compact camera chrome keeps its existing dimensions while sharing text roles.
    enum CompactType {
        case caption, label, control, value

        var size: CGFloat {
            switch self {
            case .caption: 7.2
            case .label: 8.6
            case .control: 10.1
            case .value: 11.5
            }
        }
    }

    // MARK: - Type

    /// Four levels, and only four.
    ///
    /// Tracking is the hierarchy signal as much as size: real values are set
    /// tight so they read as data, and only decorative system text gets the
    /// wide letterspacing that used to be applied to everything.
    enum TypeLevel {
        /// The mark. Used sparingly.
        case branding
        /// Controls the operator drives.
        case control
        /// Live values — ISO, frame rate, timecode.
        case telemetry
        /// Diagnostic chatter at the edges.
        case diagnostic

        var size: CGFloat {
            switch self {
            case .branding: 25
            case .control: 16
            // Legible at arm's length while remaining secondary to capture.
            case .telemetry: 14
            case .diagnostic: 8.5
            }
        }

        var weight: Font.Weight {
            switch self {
            case .branding: .black
            case .control: .bold
            case .telemetry: .medium
            case .diagnostic: .bold
            }
        }

        /// Tight for data, wide for decoration.
        var tracking: CGFloat {
            switch self {
            case .branding: 1.6
            case .control: 0.4
            case .telemetry: 0.2
            case .diagnostic: 1.3
            }
        }
    }

    static func font(_ level: TypeLevel, scale: CGFloat = 1) -> Font {
        .system(size: level.size * scale, weight: level.weight, design: .monospaced)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Narrow terminal face. Condensed rather than monospaced, so it reads as
    /// machine type without the wide, evenly-spaced feel of the diagnostics.
    static func terminal(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
            .width(.condensed)
    }
}
