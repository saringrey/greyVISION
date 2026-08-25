import SwiftUI

/// The three surface tiers, as one modifier.
///
/// The problem this replaces: nearly every panel, card, chip and rail drew its
/// own `RoundedRectangle` with its own fill opacity and its own violet
/// `strokeBorder`. Five effect categories side by side were all outlined at
/// the same weight, so the selected one had no way to announce itself — the
/// accent had become wallpaper.
///
/// Now only `.armed` gets a violet edge. Everything else is dark glass with a
/// boundary at the threshold of visibility, and selection is the one thing on
/// screen that glows.
enum GVSurfaceTier {
    /// Backs anything holding controls. Dark, readable over the camera.
    case primary
    /// Groups without enclosing. Almost invisible by design.
    case secondary
    /// Selected, armed, or actionable right now. Earns the accent.
    case armed
    /// Recording or failed. Earns the only other accent.
    case critical

    var fill: Color {
        switch self {
        case .primary: GVTheme.surfacePrimary
        case .secondary: GVTheme.surfaceSecondary
        case .armed: GVTheme.surfaceArmed
        case .critical: GVTheme.surfaceArmed
        }
    }

    var border: Color {
        switch self {
        case .primary: Color.white.opacity(0.07)
        case .secondary: Color.white.opacity(0.035)
        case .armed: GVTheme.violet.opacity(0.75)
        case .critical: GVTheme.record.opacity(0.75)
        }
    }

    var borderWidth: CGFloat {
        switch self {
        case .primary, .secondary: GVMetrics.hairline
        case .armed, .critical: 1.2
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
    /// Applies a surface tier with a plain rounded rectangle.
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
            .background {
                shape
                    .fill(tier.fill)
                    .overlay {
                        shape
                            .stroke(tier.border, lineWidth: tier.borderWidth)
                    }
                    .modifier(GVSurfaceGlow(color: tier.glow))
            }
            .contentShape(shape)
    }

    /// `AnyShape` rather than a `@ViewBuilder`: the builder yields
    /// `_ConditionalContent`, which is a View and not a Shape, so it cannot be
    /// used for `fill`, `stroke` or `contentShape`.
    private var shape: AnyShape {
        clipped
            ? AnyShape(GVClippedRectangle(cut: radius + 3))
            : AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Separated so the shadow modifiers are only attached when there is something
/// to cast. An always-applied `.shadow(color: .clear)` still costs a layer.
private struct GVSurfaceGlow: ViewModifier {
    let color: Color?

    func body(content: Content) -> some View {
        if let color {
            content
                .shadow(color: color, radius: 6)
                .shadow(color: color.opacity(0.5), radius: 14)
        } else {
            content
        }
    }
}

/// Two opposite corners cut flat. The instrument's shape signature.
struct GVClippedRectangle: Shape {
    var cut: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        let cut = min(self.cut, min(rect.width, rect.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + cut, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cut))
        path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cut))
        path.closeSubpath()
        return path
    }
}
