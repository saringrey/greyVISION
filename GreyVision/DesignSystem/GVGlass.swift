import SwiftUI

/// The material vocabulary for workspace chrome.
///
/// Geometry remains owned by each component. This role only decides how much
/// live imagery shows through, how strong its boundary is, and whether the
/// surface carries elevation.
enum GVMaterialRole {
    case control
    case rail
    case deck
    case notice

    var tint: Color {
        switch self {
        case .control: Color.black.opacity(0.28)
        case .rail: Color.black.opacity(0.32)
        case .deck: Color.black.opacity(0.38)
        case .notice: Color.black.opacity(0.46)
        }
    }

    /// Reduce Transparency must remove transparency, rather than merely omit
    /// blur while keeping a translucent black fill.
    var opaqueFallback: Color {
        switch self {
        case .control: Color(white: 0.10)
        case .rail: Color(white: 0.075)
        case .deck: Color(white: 0.065)
        case .notice: Color(white: 0.085)
        }
    }

    var inactiveBorderOpacity: Double {
        switch self {
        case .control: 0.07
        case .rail: 0.045
        case .deck: 0.065
        case .notice: 0.10
        }
    }

    var shadow: (color: Color, radius: CGFloat, y: CGFloat)? {
        switch self {
        case .control, .rail: nil
        case .deck: (Color.black.opacity(0.34), 8, 4)
        case .notice: (Color.black.opacity(0.52), 10, 5)
        }
    }

    var nativeVeilOpacity: Double {
        switch self {
        case .control: 0.12
        case .rail: 0.14
        case .deck: 0.18
        case .notice: 0.22
        }
    }
}

enum GVMaterialState {
    case inactive
    case selected(Color)
    case critical(Color)

    var accent: Color? {
        switch self {
        case .inactive: nil
        case let .selected(color), let .critical(color): color
        }
    }

    var borderOpacity: Double {
        switch self {
        case .inactive: 0
        case .selected: 0.46
        case .critical: 0.68
        }
    }

    var borderWidth: CGFloat {
        switch self {
        case .inactive: GVMetrics.hairline
        case .selected, .critical: 1
        }
    }
}

enum GVMaterialShape {
    case rounded(radius: CGFloat, clipped: Bool = false)
    case capsule

    var erased: AnyShape {
        switch self {
        case let .rounded(radius, true):
            AnyShape(GVClippedRectangle(cut: radius + 3))
        case let .rounded(radius, false):
            AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        case .capsule:
            AnyShape(Capsule(style: .continuous))
        }
    }
}

extension View {
    /// Shared material renderer used by all compatibility wrappers below.
    func gvMaterial(
        _ role: GVMaterialRole,
        shape: GVMaterialShape,
        state: GVMaterialState = .inactive,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(GVMaterialModifier(
            role: role,
            shape: shape,
            state: state,
            tintOverride: tint,
            interactive: interactive
        ))
    }

    func gvNoticeCapsule(
        tint: Color? = nil,
        critical: Bool = false
    ) -> some View {
        gvMaterial(
            .notice,
            shape: .capsule,
            state: critical ? .critical(GVTheme.record) : .inactive,
            tint: tint
        )
    }
}

private struct GVMaterialModifier: ViewModifier {
    let role: GVMaterialRole
    let shape: GVMaterialShape
    let state: GVMaterialState
    let tintOverride: Color?
    let interactive: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ObservedObject private var ambient = GVAmbientLight.shared

    private var tint: Color { tintOverride ?? role.tint }

    func body(content: Content) -> some View {
        Group {
            if role == .control {
                // Keep control labels above an opaque plate; nested native
                // glass containers can composite their dark tint over text.
                content.background { shape.erased.fill(role.opaqueFallback) }
            } else if #available(iOS 26.0, *), !reduceTransparency {
                nativeMaterial(content: content)
            } else {
                content.background { fallbackMaterial }
            }
        }
        .overlay { border }
        .modifier(GVMaterialShadow(shadow: role.shadow))
        .contentShape(shape.erased)
    }

    @available(iOS 26.0, *)
    @ViewBuilder
    private func nativeMaterial(content: Content) -> some View {
        content.background {
            shape.erased.fill(.clear)
                .glassEffect(.regular.tint(tint).interactive(interactive), in: shape.erased)
                .overlay { nativeVeil }
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var fallbackMaterial: some View {
        if reduceTransparency {
            shape.erased.fill(role.opaqueFallback)
        } else {
            ZStack {
                shape.erased.fill(.ultraThinMaterial)
                shape.erased.fill(tint)
            }
            .clipShape(shape.erased)
        }
    }

    private var nativeVeil: some View {
        shape.erased
            .fill(Color.black.opacity(role.nativeVeilOpacity))
            .allowsHitTesting(false)
    }

    private var border: some View {
        let highContrastScale = contrast == .increased ? 1.5 : 1
        let ambientScale = 0.76 + ambient.level * 0.48
        let inactiveOpacity = min(role.inactiveBorderOpacity * ambientScale * highContrastScale, 0.22)
        let color = state.accent?.opacity(state.borderOpacity) ?? Color.white.opacity(inactiveOpacity)

        return shape.erased
            .stroke(color, lineWidth: state.borderWidth)
            .allowsHitTesting(false)
    }
}

private struct GVMaterialShadow: ViewModifier {
    let shadow: (color: Color, radius: CGFloat, y: CGFloat)?

    func body(content: Content) -> some View {
        if let shadow {
            content.shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
        } else {
            content
        }
    }
}

/// Compatibility names retained so existing call sites keep their exact
/// dimensions while sharing the semantic material renderer.
enum GVGlassTier {
    case primary
    case secondary
    case elevated

    var materialRole: GVMaterialRole {
        switch self {
        case .primary: .deck
        case .secondary: .rail
        case .elevated: .notice
        }
    }
}

extension View {
    func gvGlass(
        _ tier: GVGlassTier = .primary,
        radius: CGFloat = GVMetrics.radiusPanel,
        clipped: Bool = false
    ) -> some View {
        gvMaterial(tier.materialRole, shape: .rounded(radius: radius, clipped: clipped))
    }

    func gvGlassButton(
        radius: CGFloat = GVMetrics.radius,
        active: Bool = false
    ) -> some View {
        gvMaterial(
            .control,
            shape: .rounded(radius: radius),
            state: active ? .selected(GVTheme.color(.selected)) : .inactive,
            interactive: true
        )
    }

    func gvGlassChip(
        radius: CGFloat = 5,
        active: Bool = false,
        tint: Color = .white
    ) -> some View {
        gvMaterial(
            .control,
            shape: .rounded(radius: radius),
            state: active ? .selected(tint) : .inactive,
            interactive: true
        )
    }

    func gvGlassPanel(
        radius: CGFloat = GVMetrics.radiusPanel,
        tint: Color = Color.black.opacity(0.34)
    ) -> some View {
        gvMaterial(.deck, shape: .rounded(radius: radius), tint: tint)
    }

    func gvGlassRail(
        radius: CGFloat = 14,
        tint: Color = Color.black.opacity(0.32)
    ) -> some View {
        gvMaterial(.rail, shape: .rounded(radius: radius), tint: tint)
    }

    func gvGlassField(radius: CGFloat = 10) -> some View {
        gvMaterial(.notice, shape: .rounded(radius: radius))
    }
}

/// Two opposite corners cut flat — the instrument's shape signature.
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

/// Type-erased shape for modifiers that need a single Shape type.
struct AnyShape: Shape {
    private let pathBuilder: @Sendable (CGRect) -> Path

    init(_ shape: some Shape) {
        pathBuilder = { rect in shape.path(in: rect) }
    }

    func path(in rect: CGRect) -> Path {
        pathBuilder(rect)
    }
}

/// Kept for focused callers that need only a dark veil above native glass.
struct GVBlackGlassVeil: View {
    let radius: CGFloat
    var opacity: Double = 0.12

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.black.opacity(opacity))
            .allowsHitTesting(false)
    }
}
