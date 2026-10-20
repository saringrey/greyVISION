import SwiftUI

/// Stardust button — starfield behind frosted glass, darker than standard.
/// Used for codec selection and the passcode stardust flash.
struct GVStardustButtonStyle: ButtonStyle {
    var active: Bool = false
    var radius: CGFloat = 9
    /// Some dense telemetry rails only need the Stardust surface while a field
    /// is selected; their inactive values remain unboxed for scanability.
    var showsInactivePlate: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeBody(configuration: Configuration) -> some View {
        let isSelected = active || configuration.isPressed
        return configuration.label
            .colorInvertIf(isSelected)
            .background { stardustBackground(isPressed: configuration.isPressed) }
            .overlay { stardustBorder(isPressed: configuration.isPressed) }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
            .animation(GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion), value: configuration.isPressed)
    }

    @ViewBuilder
    private func stardustBackground(isPressed: Bool) -> some View {
        let selected = active || isPressed
        if !showsInactivePlate, !selected {
            Color.clear
        } else {
            let baseTint = selected ? Color.white.opacity(isPressed ? 0.78 : 0.88) : Color.black.opacity(0.58)
            ZStack {
                // Selected controls invert the surface: the starfield remains,
                // but black points on a bright plate make the state readable
                // at a glance instead of relying on a thin border.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(baseTint)
                if !reduceTransparency {
                    DeterministicStarfield()
                        .opacity(selected ? 0.30 : 0.22)
                        .colorInvertIf(selected)
                        .blur(radius: 0.6)
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(selected ? 0.30 : 0.55))
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(selected ? Color.white.opacity(0.12) : Color.black.opacity(0.22))
                }
            }
            .overlay {
                // Subtle inner lift while held.
                if isPressed {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(selected ? Color.white.opacity(0.10) : Color.white.opacity(0.06))
                }
            }
        }
    }

    @ViewBuilder
    private func stardustBorder(isPressed: Bool) -> some View {
        let selected = active || isPressed
        if !showsInactivePlate, !selected {
            Color.clear
        } else {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    selected ? Color.black.opacity(isPressed ? 0.48 : 0.36) : Color.white.opacity(0.10),
                    lineWidth: isPressed ? 1.0 : (selected ? 0.85 : 0.5)
                )
                .modifier(GVLightReactiveBorderOverlay(
                    radius: radius,
                    baseOpacity: isPressed ? 0.22 : 0.10,
                    lightLevel: GVAmbientLight.shared.level,
                    lineWidth: 0.5,
                    color: selected ? .black : .white
                ))
        }
    }
}

private struct GVColorInvertIf: ViewModifier {
    let isInverted: Bool

    func body(content: Content) -> some View {
        if isInverted {
            content.colorInvert()
        } else {
            content
        }
    }
}

extension View {
    func colorInvertIf(_ isInverted: Bool) -> some View {
        modifier(GVColorInvertIf(isInverted: isInverted))
    }

    func gvStardustButton(active _: Bool = false) -> some View {
        // helper not used directly — style is applied via buttonStyle
        self
    }
}
