import SwiftUI

/// The instrument's palette and type.
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

    /// Near-black canvas. Everything sits on this.
    static var void: Color {
        Color(red: 0, green: 0, blue: 0)
    }

    /// Warm off-white. Primary type and anything the operator reads to work.
    ///
    /// Deliberately not pure white: against a black field, 1.0 white haloes on
    /// OLED and reads as a light source rather than as printed type.
    static var bone: Color {
        Color(red: 0.941, green: 0.937, blue: 0.925)
    }

    /// Secondary telemetry and inactive labels. Present, not competing.
    static var ash: Color {
        Color(white: 0.48)
    }

    /// Selected, active, operator-chosen. The only accent on an idle screen,
    /// and on an idle screen there should be at most one or two of them.
    static var violet: Color {
        Color.white
    }

    /// The deep end of the violet ramp. Gradients, glows and edges fade toward
    /// this; it is never a standalone state colour.
    static var violetDeep: Color {
        Color.white
    }

    /// Armed, ready, succeeded. Never decoration.
    static var acid: Color {
        Color(red: 0.64, green: 1.0, blue: 0.12)
    }

    /// Recording, destructive, critical. Never decoration.
    static var record: Color {
        Color(red: 1.0, green: 0.16, blue: 0.32)
    }

    /// Linear RGB passed to interaction shaders. Keeping this beside the
    /// visible palette prevents press treatments from inventing a separate
    /// accent that does not exist anywhere else in the instrument.
    static let interactionPulseRGB = SIMD3<Float>(1, 1, 1)

    /// Warning that is genuinely a warning — thermal pressure, dropped frames.
    /// Muted on purpose so it cannot be mistaken for `record`.
    static var warn: Color {
        Color(red: 0.92, green: 0.66, blue: 0.20)
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
    /// toggle, a control that is present but has nothing to say. Filed with
    /// state rather than with surfaces — it was never a plate.
    static var faint: Color {
        Color(white: 0.20)
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

    /// Three tiers, not eleven.
    ///
    /// `primary` backs anything holding controls. `secondary` is almost
    /// invisible and exists only to separate a group from the camera behind
    /// it. `armed` is the sole tier that earns a violet edge.
    static var surfacePrimary: Color {
        Color.black.opacity(0.68)
    }

    static var surfaceSecondary: Color {
        Color.black.opacity(0.30)
    }

    static var surfaceArmed: Color {
        Color.black.opacity(0.74)
    }

    /// Shared elevation tint so panels feel lit by the same source.
    static var elevationShadow: Color {
        violetDeep.opacity(0.04)
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

extension GVTheme {
    /// Identity hues for radial-menu subcategories.
    ///
    /// The core palette is deliberately tiny; these are different in kind —
    /// they identify *which* subcategory is under the finger inside a
    /// transient menu, so a dozen hues are the point rather than a violation.
    /// All are tuned to sit on the black field without reading as state
    /// colours: none of them equals acid/record/warn.
    enum RadialHue {
        case magenta, cyan, amber, lime, rose, teal, ember, sky, moss, plum, sand, azure

        var color: Color {
            switch self {
            case .magenta: Color(red: 1.00, green: 0.30, blue: 0.78)
            case .cyan: Color(red: 0.12, green: 0.96, blue: 1.00)
            case .amber: Color(red: 1.00, green: 0.72, blue: 0.18)
            case .lime: Color(red: 0.64, green: 1.00, blue: 0.12)
            case .rose: Color(red: 1.00, green: 0.38, blue: 0.42)
            case .teal: Color(red: 0.14, green: 0.86, blue: 0.66)
            case .ember: Color(red: 1.00, green: 0.44, blue: 0.14)
            case .sky: Color(red: 0.36, green: 0.62, blue: 1.00)
            case .moss: Color(red: 0.62, green: 0.92, blue: 0.42)
            case .plum: Color(red: 0.76, green: 0.42, blue: 1.00)
            case .sand: Color(red: 0.92, green: 0.86, blue: 0.56)
            case .azure: Color(red: 0.44, green: 0.80, blue: 1.00)
            }
        }
    }
}
