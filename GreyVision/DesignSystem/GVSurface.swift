import SwiftUI

/// The three surface tiers, as one modifier.
///
/// The problem this replaces: nearly every panel, card, chip and rail drew its
/// own `RoundedRectangle` with its own fill opacity and its own violet
/// `strokeBorder`. Five effect categories side by side were all outlined at
/// the same weight, so the selected one had no way to announce itself — the
/// accent had become wallpaper.
///
/// Now only `.armed` gets a violet edge. Everything else is dark frosted glass
/// with a boundary at the threshold of visibility, and selection is the one
/// thing on screen that glows.
enum GVSurfaceTier {
    /// Backs anything holding controls. Dark, readable over the camera.
    case primary
    /// Groups without enclosing. Almost invisible by design.
    case secondary
    /// Selected, armed, or actionable right now. Earns the accent.
    case armed
    /// Recording or failed. Earns the only other accent.
    case critical

    var materialRole: GVMaterialRole {
        switch self {
        case .primary, .armed: .deck
        case .secondary: .rail
        case .critical: .notice
        }
    }

    var materialState: GVMaterialState {
        switch self {
        case .primary, .secondary: .inactive
        case .armed: .selected(GVTheme.color(.selected))
        case .critical: .critical(GVTheme.color(.recording))
        }
    }

    /// Only lit tiers cast light. A primary surface that glows is a primary
    /// surface pretending to be selected.
    var glow: Color? {
        switch self {
        case .primary, .secondary: nil
        case .armed: GVTheme.violet.opacity(0.34)
        case .critical: GVTheme.record.opacity(0.34)
        }
    }
}

extension View {
    /// Applies a surface tier with a plain rounded rectangle, using the unified
    /// frosted glass system.
    func gvSurface(
        _ tier: GVSurfaceTier,
        radius: CGFloat = GVMetrics.radius
    ) -> some View {
        modifier(GVSurfaceModifier(tier: tier, radius: radius, clipped: false))
    }

    /// Applies a surface tier with the instrument's clipped-corner geometry.
    ///
    /// Reserved for selected, armed, experimental or high-priority elements.
    /// Giving every rectangle cut corners is what made the old interface read
    /// as decoration rather than as hierarchy.
    func gvClippedSurface(
        _ tier: GVSurfaceTier,
        radius: CGFloat = GVMetrics.radius
    ) -> some View {
        modifier(GVSurfaceModifier(tier: tier, radius: radius, clipped: true))
    }
}

private struct GVSurfaceModifier: ViewModifier {
    let tier: GVSurfaceTier
    let radius: CGFloat
    let clipped: Bool

    func body(content: Content) -> some View {
        content
            .gvMaterial(
                tier.materialRole,
                shape: .rounded(radius: radius, clipped: clipped),
                state: tier.materialState
            )
            .modifier(GVSurfaceGlow(color: tier.glow))
    }
}

/// Separated so the shadow modifiers are only attached when there is something
/// to cast. An always-applied `.shadow(color: .clear)` still costs a layer.
private struct GVSurfaceGlow: ViewModifier {
    let color: Color?

    func body(content: Content) -> some View {
        if let color {
            content
                .shadow(color: color, radius: 8, y: 2)
        } else {
            content
        }
    }
}
