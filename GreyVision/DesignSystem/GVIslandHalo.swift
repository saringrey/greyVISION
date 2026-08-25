import SwiftUI

/// A violet outline hugging the Dynamic Island.
///
/// Two concentric rounded capsules sit just outside the cutout, so the island
/// reads as a machined port in the instrument rather than a hole the interface
/// ignores. Purely decorative and never hit-testable — the island already
/// swallows touches in that band, and adding another target there is what made
/// a phantom button appear behind it.
struct GVIslandHalo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Cutout metrics for the current device family. The island is a fixed
    /// size across the Pro models; anything without one reports a short inset
    /// and the halo is suppressed.
    var topInset: CGFloat
    var tint = GVTheme.violet

    /// Measured cutout. Apple does not vend these, so they are constants.
    private let islandWidth: CGFloat = 126
    private let islandHeight: CGFloat = 37
    private let islandTop: CGFloat = 11

    /// Devices without a Dynamic Island report a materially smaller inset.
    private var hasIsland: Bool {
        topInset >= 51
    }

    var body: some View {
        if hasIsland {
            ZStack {
                ring(inset: -3, width: 1.4, opacity: 0.85)
                ring(inset: -8, width: 1.0, opacity: 0.40)
                ring(inset: -14, width: 0.8, opacity: 0.18)
            }
            .frame(width: islandWidth, height: islandHeight)
            .position(x: UIScreen.main.bounds.width / 2, y: islandTop + islandHeight / 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .ignoresSafeArea()
        }
    }

    private func ring(inset: CGFloat, width: CGFloat, opacity: Double) -> some View {
        Group {
            if reduceMotion {
                capsule(inset: inset)
                    .stroke(tint.opacity(opacity), lineWidth: width)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 20, paused: false)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    // A slow breath so the port reads as powered, not printed.
                    let breath = 0.82 + sin(time * 1.6 + inset * 0.2) * 0.18
                    capsule(inset: inset)
                        .stroke(tint.opacity(opacity * breath), lineWidth: width)
                        .shadow(color: tint.opacity(opacity * 0.5 * breath), radius: 6)
                }
            }
        }
    }

    private func capsule(inset: CGFloat) -> some Shape {
        RoundedRectangle(cornerRadius: (islandHeight - inset * 2) / 2, style: .continuous)
            .inset(by: inset)
    }
}
