import SwiftUI

/// Layout constants for the instrument.
///
/// Everything here existed already as a literal scattered across the views —
/// nine corner radii, a dozen paddings, four control heights that were all
/// meant to be the same. Collecting them means a control can no longer end up
/// 35pt tall next to one that is 36pt because two files were edited on
/// different days.
///
/// The scale is deliberately tight. This is a dense readout, and the spacing
/// steps are close together so density stays legible instead of becoming
/// cramped.
enum GVMetrics {
    // MARK: - Spacing

    /// Inside a control, between a label and its value.
    static let gapHair: CGFloat = 2
    /// Between related controls on the same row.
    static let gapTight: CGFloat = 4
    /// Between groups within a panel.
    static let gap: CGFloat = 6
    /// Between panels.
    static let gapWide: CGFloat = 10
    /// Panel inset from the display edge.
    static let screenInset: CGFloat = 8
    /// Inset for chrome drawn level with the display's top corner curve.
    static let cornerShoulderInset: CGFloat = 20

    // MARK: - Layout scale

    /// Compact structural steps.
    static let stepMicro: CGFloat = 2
    static let stepInternal: CGFloat = 6
    static let stepRelated: CGFloat = 8
    static let stepStandard: CGFloat = 12
    static let stepSection: CGFloat = 16
    static let stepMajor: CGFloat = 24

    // MARK: - Radii

    /// Radii are small on purpose. Large corners read as a consumer settings
    /// list; instrumentation has tight ones or none.
    static let radiusTight: CGFloat = 4
    static let radius: CGFloat = 7
    /// Containers only. Nothing that holds a single value should use this.
    static let radiusPanel: CGFloat = 14

    // MARK: - Surfaces

    /// The one hairline width in the app. UIKit-thin rules disappear on some
    /// displays and look heavy on others, so this is a fixed point value.
    static let hairline: CGFloat = 1

    // MARK: - Controls

    /// Compact visual control height. Interaction targets remain >= 44pt.
    static let controlHeight: CGFloat = 34
    /// Cards carrying a label, a detail line and a status row.
    static let cardHeight: CGFloat = 48
    /// Minimum tappable dimension. Controls may be drawn smaller than this
    /// as long as their content shape is expanded to meet it.
    static let touchTarget: CGFloat = 44

    // MARK: - Type

    /// The instrument's type scale.
    ///
    /// Four steps, 1.5pt apart. The previous four sat inside a 3.5pt span —
    /// 6 / 7 / 8 / 9.5 — which is not a hierarchy, it is four slightly
    /// different smalls, and almost nothing used them: the workspace carried
    /// twenty-one distinct hardcoded sizes between 5 and 14, several of them
    /// a tenth of a point apart.
    ///
    /// `micro` is the floor. Nothing in the chrome is drawn smaller. 5.2pt
    /// type is decoration that happens to be spelled in words.
    static let textMicro = GVTheme.CompactType.caption.size
    static let textSmall = GVTheme.CompactType.label.size
    static let textBody = GVTheme.CompactType.control.size
    static let textValue = GVTheme.CompactType.value.size
}

extension GVTheme {
    /// The single separator colour. Soft on charcoal, clear enough for structure.
    static var separator: Color {
        Color.white.opacity(0.10)
    }

    /// Border for a control the operator has selected.
    static var separatorActive: Color {
        GVTheme.violet.opacity(0.55)
    }
}
