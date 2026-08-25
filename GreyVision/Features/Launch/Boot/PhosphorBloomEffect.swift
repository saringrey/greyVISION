import Metal
import SwiftUI

/// Phosphor bloom effect for boot sequence Phase 1.
///
/// Implements a radial gradient shader that expands from the center of the screen
/// with a CRT-style purple glow aesthetic. The effect uses ease-out timing over
/// 1200ms to create a smooth, organic expansion.
///
/// **Visual Characteristics:**
/// - Radial gradient expanding from screen center
/// - Purple/violet color palette matching grey//VISION theme
/// - Soft bloom effect with multiple gradient stops
/// - Ease-out animation curve for natural feel
///
/// **Requirements:** 3.4 (Phosphor bloom visual effect)
struct PhosphorBloomEffect: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Progress through the bloom animation [0, 1]
    let progress: CGFloat

    /// Whether the effect is active
    let isActive: Bool

    var body: some View {
        if reduceMotion {
            // Static glow for reduced motion
            staticBloom
        } else {
            // Animated bloom with TimelineView
            animatedBloom
        }
    }

    // MARK: - Static Bloom (Reduced Motion)

    private var staticBloom: some View {
        RadialGradient(
            colors: bloomColors(intensity: isActive ? 1.0 : 0.0),
            center: .center,
            startRadius: 0,
            endRadius: 400
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Animated Bloom

    private var animatedBloom: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let maxRadius = sqrt(pow(size.width / 2, 2) + pow(size.height / 2, 2))

            // Ease-out curve for smooth expansion (Requirement 3.4)
            let easedProgress = easeOut(progress)

            // Calculate expanding radius
            let currentRadius = maxRadius * easedProgress
            let startRadius = max(currentRadius * 0.1, 0)

            // Intensity fade
            let intensity = isActive ? min(1.0, progress * 1.5) : 0.0

            RadialGradient(
                colors: bloomColors(intensity: intensity),
                center: .center,
                startRadius: startRadius,
                endRadius: currentRadius
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .blendMode(.screen) // Additive-like blending for glow effect

            // Secondary glow layer for depth
            RadialGradient(
                colors: secondaryBloomColors(intensity: intensity * 0.6),
                center: .center,
                startRadius: startRadius * 0.5,
                endRadius: currentRadius * 0.7
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .blendMode(.screen)
        }
    }

    // MARK: - Color Configuration

    /// Primary bloom colors with CRT-style purple glow
    private func bloomColors(intensity: CGFloat) -> [Color] {
        [
            // Hot center
            GVTheme.violet.opacity(0.35 * intensity),
            // Mid glow
            GVTheme.violetDeep.opacity(0.25 * intensity),
            // Outer glow
            GVTheme.violetDeep.opacity(0.15 * intensity),
            // Fade to black
            Color.black.opacity(0.1 * intensity),
            .clear
        ]
    }

    /// Secondary bloom layer for depth and richness
    private func secondaryBloomColors(intensity: CGFloat) -> [Color] {
        [
            // Brighter hot center
            Color.white.opacity(0.12 * intensity),
            // Purple core
            GVTheme.violet.opacity(0.20 * intensity),
            // Outer fade
            GVTheme.violetDeep.opacity(0.08 * intensity),
            .clear
        ]
    }

    // MARK: - Animation Curves

    /// Ease-out curve for smooth expansion (Requirement 3.4: 1200ms ease-out)
    /// Uses cubic ease-out: t * t * (3 - 2 * t)
    private func easeOut(_ t: CGFloat) -> CGFloat {
        let clamped = max(0, min(1, t))
        return clamped * clamped * (3 - 2 * clamped)
    }
}

// MARK: - Preview

#Preview("Phosphor Bloom Animation") {
    ZStack {
        Color.black.ignoresSafeArea()

        TimelineView(.animation) { timeline in
            let seconds = timeline.date.timeIntervalSinceReferenceDate
            let progress = CGFloat((seconds.truncatingRemainder(dividingBy: 2.0)) / 2.0)

            PhosphorBloomEffect(
                progress: progress,
                isActive: true
            )
        }
    }
}

#Preview("Phosphor Bloom Static") {
    ZStack {
        Color.black.ignoresSafeArea()

        PhosphorBloomEffect(
            progress: 1.0,
            isActive: true
        )
    }
}
