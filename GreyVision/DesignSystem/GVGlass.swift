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
        case .control: Color(red: 0.020, green: 0.020, blue: 0.024).opacity(0.58)
        case .rail: Color(red: 0.018, green: 0.018, blue: 0.022).opacity(0.60)
        case .deck: Color(red: 0.016, green: 0.016, blue: 0.020).opacity(0.64)
        case .notice: Color(red: 0.022, green: 0.022, blue: 0.026).opacity(0.70)
        }
    }

    /// Reduce Transparency must remove transparency, rather than merely omit
    /// blur while keeping a translucent fill.
    var opaqueFallback: Color {
        switch self {
        case .control: Color(red: 0.030, green: 0.030, blue: 0.034)
        case .rail: Color(red: 0.024, green: 0.024, blue: 0.028)
        case .deck: Color(red: 0.020, green: 0.020, blue: 0.024)
        case .notice: Color(red: 0.028, green: 0.028, blue: 0.032)
        }
    }

    var inactiveBorderOpacity: Double {
        switch self {
        case .control: 0.06
        case .rail: 0.04
        case .deck: 0.055
        case .notice: 0.08
        }
    }

    var shadow: (color: Color, radius: CGFloat, y: CGFloat)? {
        switch self {
        case .control, .rail: nil
        case .deck: (Color.black.opacity(0.28), 10, 5)
        case .notice: (Color.black.opacity(0.36), 12, 6)
        }
    }

    var nativeVeilOpacity: Double {
        switch self {
        case .control: 0.32
        case .rail: 0.36
        case .deck: 0.40
        case .notice: 0.46
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
                // Slightly see-through, over a blur, so the plate reads as
                // smoked glass rather than a solid black slab.
                content.background {
                    ZStack {
                        if reduceTransparency {
                            shape.erased.fill(role.opaqueFallback)
                        } else {
                            shape.erased.fill(.ultraThinMaterial)
                            shape.erased.fill(role.opaqueFallback.opacity(0.74))
                        }
                    }
                    .overlay { ambientWash }
                }
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
                .overlay { ambientWash }
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
                ambientWash
            }
            .clipShape(shape.erased)
        }
    }

    /// A trace of the accent at the foot of each panel. Kept faint: the
    /// plates are near-black and the accent lives on edges and selections.
    private var ambientWash: some View {
        shape.erased
            .fill(LinearGradient(
                colors: [GVTheme.accent.opacity(0.0), GVTheme.accent.opacity(0.07)],
                startPoint: .top, endPoint: .bottom
            ))
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
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
        let color = state.accent?.opacity(state.borderOpacity) ?? GVTheme.accent.opacity(min(inactiveOpacity * 2.2, 0.42))

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
        tint: Color = Color(red: 0.103, green: 0.121, blue: 0.167).opacity(0.50)
    ) -> some View {
        gvMaterial(.deck, shape: .rounded(radius: radius), tint: tint)
    }

    func gvGlassRail(
        radius: CGFloat = 14,
        tint: Color = Color(red: 0.099, green: 0.116, blue: 0.161).opacity(0.46)
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

// MARK: - Chrome plate

extension View {
    /// The workspace's chrome surface: the splash tracker plate — x-ray black,
    /// a hairline, lime corner brackets — shared by the capture row, the
    /// camera deck, every parameter deck and the effect dock, so the whole
    /// interface reads as one family with the splash it opened from.
    ///
    /// `tag` hangs a splash-style label off the top-left corner;
    /// `bracketInset` pulls the brackets in, as the splash does when a box
    /// locks on.
    func gvChromePlate(_ shape: some InsettableShape, tag: String? = nil, bracketInset: CGFloat = 0) -> some View {
        modifier(GVSplashDockPlate(shape: shape, tag: tag, bracketInset: bracketInset))
    }
}
