import Foundation
import SwiftUI

// MARK: - Element decay

/// Momentary signal decay applied to a single splash element.
///
/// Deliberately cheap — an offset, a chromatic smear and a brightness dip.
/// Anything heavier would cost more than the effect is worth on a screen that
/// only exists for a few seconds.
struct GVElementDecay: ViewModifier {
    let isActive: Bool
    var seed: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            let displacement = isActive ? CGFloat(sin(seed * 12.9898) * 4.5) : 0
            content
                .offset(x: displacement)
                .overlay {
                    if isActive {
                        content
                            .foregroundStyle(GVTheme.violet)
                            .offset(x: -displacement * 0.7)
                            .blendMode(.screen)
                            .opacity(0.55)
                            .allowsHitTesting(false)
                    }
                }
                .brightness(isActive ? -0.18 : 0)
                .animation(.linear(duration: 0.06), value: isActive)
        }
    }
}

extension View {
    /// Applies transient decay when this element is the one currently glitching.
    func gvDecay(_ isActive: Bool, seed: Double = 0) -> some View {
        modifier(GVElementDecay(isActive: isActive, seed: seed))
    }
}
