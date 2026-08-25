import SwiftUI

/// One animation language for the whole instrument.
///
/// Every button, card, panel and readout derives its timing from these four
/// tokens rather than inventing its own duration. Keeping the vocabulary this
/// small is what makes unrelated surfaces feel like one machine.
enum GVMotion {
    /// 120ms — value readouts, tick marks, press-in states. Below the
    /// threshold where the user reads it as "animation" rather than "response".
    static let micro: Animation = .easeOut(duration: 0.12)

    /// 220ms — selection changes, card slides, category movement.
    static let normal: Animation = .easeInOut(duration: 0.22)

    /// 320ms — panels arriving and leaving. Spring because panels carry weight.
    static let panel: Animation = .spring(response: 0.32, dampingFraction: 0.82)

    /// 450ms — deliberate, once-per-interaction moments. Used sparingly.
    static let cinematic: Animation = .spring(response: 0.45, dampingFraction: 0.78)

    /// Release spring for press states — small overshoot, settles fast.
    static let press: Animation = .spring(response: 0.26, dampingFraction: 0.62)

    /// Reduce Motion substitute. Same perceived state change, no travel.
    static let reduced: Animation = .easeInOut(duration: 0.12)

    // MARK: - Instrument motion

    /// Hardware does not bounce. These four are the instrument's real
    /// vocabulary: things snap into position, scan across, tear open or
    /// collapse shut. Springs stay reserved for direct manipulation, where
    /// overshoot corresponds to something the finger actually did.

    /// 90ms — a control taking a new value. Reads as a mechanism, not a fade.
    static let snap: Animation = .easeOut(duration: 0.09)

    /// 180ms — a rail or strip moving along its own axis.
    static let scan: Animation = .timingCurve(0.2, 0, 0, 1, duration: 0.18)

    /// 200ms — a panel opening. Fast in, no settle.
    static let tear: Animation = .timingCurve(0.16, 1, 0.3, 1, duration: 0.20)

    /// 160ms — a panel closing. Quicker than it opened; leaving should not be
    /// something the operator waits through.
    static let collapse: Animation = .easeIn(duration: 0.16)

    /// 240ms — a major deck changing state.
    static let deck: Animation = .timingCurve(0.2, 0, 0, 1, duration: 0.24)

    /// 120ms — corruption arriving and clearing.
    static let decay: Animation = .easeOut(duration: 0.12)

    /// Resolves a token against the user's Reduce Motion preference.
    static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reduced : animation
    }
}

/// Press treatment shared by every interactive chrome element.
///
/// Compresses slightly, brightens its border, pulls its glow inward, then
/// releases on a short spring. Deliberately subtle — the point is that the
/// control feels physically connected to the finger, not that it performs.
struct GVPressStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    var tint: Color = GVTheme.violetDeep

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? scale : 1))
            .brightness(configuration.isPressed ? 0.06 : 0)
            .shadow(
                color: tint.opacity(configuration.isPressed ? 0.42 : 0),
                radius: configuration.isPressed ? 3 : 0
            )
            .animation(
                GVMotion.resolved(
                    configuration.isPressed ? GVMotion.micro : GVMotion.press,
                    reduceMotion: reduceMotion
                ),
                value: configuration.isPressed
            )
    }
}

extension View {
    /// Fades the leading/trailing edges of a horizontal scroller so clipped
    /// content reads as "more over here" instead of "layout overflow".
    func gvHorizontalEdgeFade(_: CGFloat = 18) -> some View {
        mask(
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
        )
    }
}
