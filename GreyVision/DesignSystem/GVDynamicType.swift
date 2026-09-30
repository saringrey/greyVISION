import SwiftUI

/// Dynamic Type for the instrument.
///
/// Every label used to be a fixed point size — 5.2pt at the smallest — which
/// meant the app ignored the one accessibility setting most people actually
/// change. It also cannot simply adopt the system text styles: this is a dense
/// readout laid out against a fixed hardware-free zone and fixed rail heights,
/// and `.caption` at accessibility5 is roughly triple the size the top shell
/// has room for.
///
/// The compromise is a compressed scale. Type tracks the user's preference
/// across the whole range, but at a reduced slope, and `AppRootView` clamps
/// the environment so the instrument never has to lay out beyond
/// `.accessibility2`. What the operator gets is type that grows by half again
/// rather than type that ignores them.
extension GVTheme {
    /// Multiplier applied to every instrument size. Tops out at 1.6.
    static func typeScale(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: 0.90
        case .small: 0.95
        case .medium, .large: 1.00
        case .xLarge: 1.08
        case .xxLarge: 1.16
        case .xxxLarge: 1.25
        case .accessibility1: 1.35
        case .accessibility2: 1.45
        case .accessibility3: 1.52
        case .accessibility4: 1.56
        case .accessibility5: 1.60
        @unknown default: 1.00
        }
    }

    /// The largest size the layout is designed to survive. Applied once, at
    /// the root, rather than per screen.
    static let maximumDynamicTypeSize = DynamicTypeSize.accessibility2
}

/// Resolves an instrument face against the live Dynamic Type setting.
private struct GVScaledFont: ViewModifier {
    enum Face {
        case level(GVTheme.TypeLevel)
        case mono(CGFloat, Font.Weight)
        case terminal(CGFloat, Font.Weight)
    }

    let face: Face

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.font(resolved)
    }

    private var resolved: Font {
        let scale = GVTheme.typeScale(for: dynamicTypeSize)
        switch face {
        case let .level(level):
            return GVTheme.font(level, scale: scale)
        case let .mono(size, weight):
            return GVTheme.mono(size * scale, weight)
        case let .terminal(size, weight):
            return GVTheme.terminal(size * scale, weight)
        }
    }
}

extension View {
    /// Scaling replacement for `.gvFont(_:)`.
    func gvFont(_ level: GVTheme.TypeLevel) -> some View {
        modifier(GVScaledFont(face: .level(level)))
    }

    /// Scaling replacement for `.gvMono(_:_:)`.
    func gvMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> some View {
        modifier(GVScaledFont(face: .mono(size, weight)))
    }

    /// Scaling replacement for `.gvTerminal(_:_:)`.
    func gvTerminal(_ size: CGFloat, _ weight: Font.Weight = .bold) -> some View {
        modifier(GVScaledFont(face: .terminal(size, weight)))
    }

    /// Scales GVTerminalText sizes to respect Dynamic Type.
    func gvTerminalScaled() -> some View {
        modifier(GVTerminalTextScaler())
    }
}

/// Internal modifier that applies Dynamic Type scaling to GVTerminalText.
private struct GVTerminalTextScaler: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content
            .environment(\.gvTerminalTextScale, GVTheme.typeScale(for: dynamicTypeSize))
    }
}

private struct GVTerminalTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var gvTerminalTextScale: CGFloat {
        get { self[GVTerminalTextScaleKey.self] }
        set { self[GVTerminalTextScaleKey.self] = newValue }
    }
}
