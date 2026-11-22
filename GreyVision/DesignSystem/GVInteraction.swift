import SwiftUI
import UIKit

/// Shared press behaviour for every control in the instrument.
///
/// Compresses slightly on touch-down, brightens, then releases with a small
/// spring. The glow contracts inward while held rather than expanding, so
/// pressing reads as mechanical travel instead of a highlight.
/// Enhanced with cybercore press pulse shader.
struct GVPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Compression at full press.
    var scale = 0.96
    /// Fires a restrained haptic on touch-down. Reserve for meaningful actions.
    var haptic = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? scale : 1))
            .brightness(configuration.isPressed ? 0.08 : 0)
            .colorEffect(
                ShaderLibrary.pressPulse(
                    .float(Float(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))),
                    .float2(44, 44),
                    .float(configuration.isPressed && !reduceMotion ? 1.0 : 0.0),
                    .float3(
                        GVTheme.interactionPulseRGB.x,
                        GVTheme.interactionPulseRGB.y,
                        GVTheme.interactionPulseRGB.z
                    )
                )
            )
            .animation(
                reduceMotion ? nil : GVMotion.softPress(configuration.isPressed),
                value: configuration.isPressed
            )
            .onChange(of: configuration.isPressed) { _, pressed in
                guard haptic, pressed else { return }
                GVInteractionHaptics.press()
            }
    }
}

extension ButtonStyle where Self == GVPressButtonStyle {
    static var gvPress: GVPressButtonStyle {
        GVPressButtonStyle()
    }

    static var gvPressPrimary: GVPressButtonStyle {
        GVPressButtonStyle(scale: 0.96, haptic: true)
    }
}

/// Restrained interaction feedback. Deliberately light and never repeated at
/// animation rates.
@MainActor
enum GVInteractionHaptics {
    private static var lastFire: TimeInterval = 0

    static func press() {
        fire(style: .light, intensity: 0.45)
    }

    static func select() {
        fire(style: .soft, intensity: 0.6)
    }

    static func commit() {
        fire(style: .rigid, intensity: 0.7)
    }

    private static func fire(style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat) {
        // Rate limit so rapid scrubbing cannot produce a buzz.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFire > 0.045 else { return }
        lastFire = now
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred(intensity: intensity)
    }
}

/// Emission levels. Purple glow is a signal, not decoration: most surfaces sit
/// at `.line`, and only genuine state earns bloom.
enum GVEmission {
    /// Default: a thin, unlit purple rule.
    case line
    /// Selected: modest, static glow.
    case selected
    /// Working: animated glow.
    case processing
    /// Problem: pulsing.
    case warning

    var borderOpacity: Double {
        switch self {
        case .line: 0.34
        case .selected: 0.95
        case .processing: 0.8
        case .warning: 0.9
        }
    }

    var glowRadius: CGFloat {
        switch self {
        case .line: 0
        case .selected: 6
        case .processing: 9
        case .warning: 8
        }
    }

    var glowOpacity: Double {
        switch self {
        case .line: 0
        case .selected: 0.28
        case .processing: 0.34
        case .warning: 0.42
        }
    }

    var tint: Color {
        switch self {
        case .warning: GVTheme.record
        default: GVTheme.violet
        }
    }
}

/// Fades the leading and trailing edges of a horizontal scroller so clipped
/// content reads as "more over here" rather than as a layout overflow.
struct GVEdgeFade: ViewModifier {
    var width: CGFloat = 22

    func body(content: Content) -> some View {
        content.mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.035),
                    .init(color: .black, location: 0.965),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
}

extension View {
    func gvEdgeFade(width: CGFloat = 22) -> some View {
        modifier(GVEdgeFade(width: width))
    }

    /// Applies the emission level as a border and matching glow.
    func gvEmission(_ level: GVEmission, shape: some InsettableShape, lineWidth: CGFloat = 1) -> some View {
        overlay {
            shape.strokeBorder(level.tint.opacity(level.borderOpacity), lineWidth: lineWidth)
        }
        .shadow(color: level.tint.opacity(level.glowOpacity), radius: level.glowRadius)
    }
}
