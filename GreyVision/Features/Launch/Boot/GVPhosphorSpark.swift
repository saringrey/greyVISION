import SwiftUI

/// Dramatic phosphor spark effect: single purple pixel awakens then explodes into bloom
/// Phase 1: Tiny dot (spark phase)
/// Phase 2: Radial CRT-style bloom explosion
struct GVPhosphorSpark: View {
    let isSparkVisible: Bool
    let isBloomActive: Bool
    let start: Date

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: false)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)

            ZStack {
                if isSparkVisible, !isBloomActive {
                    // Phase 1: Single pixel spark
                    sparkPixel
                        .opacity(sparkOpacity(elapsed: elapsed))
                }

                if isBloomActive {
                    // Phase 2: Dramatic bloom explosion
                    bloomExplosion(elapsed: elapsed)
                }
            }
        }
    }

    private var sparkPixel: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        GVTheme.violet,
                        GVTheme.violetDeep.opacity(0.8),
                        .clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 2
                )
            )
            .frame(width: 4, height: 4)
            .blur(radius: 0.5)
            .shadow(color: GVTheme.violet, radius: 8, x: 0, y: 0)
    }

    private func bloomExplosion(elapsed: TimeInterval) -> some View {
        let progress = min(elapsed / GVBootTiming.bloomSeconds, 1.0)
        let easedProgress = easeOutCubic(progress)

        // Dramatic expansion from 0 to full screen
        let maxRadius: CGFloat = 2000
        let currentRadius = maxRadius * easedProgress

        // Intensity peaks early then settles
        let intensity = progress < 0.3
            ? progress / 0.3 // Ramp up fast
            : 1.0 - ((progress - 0.3) / 0.7) * 0.85 // Slow fade

        return ZStack {
            // Core bright bloom
            RadialGradient(
                colors: [
                    GVTheme.violet.opacity(intensity * 0.9),
                    GVTheme.violetDeep.opacity(intensity * 0.6),
                    GVTheme.violetDeep.opacity(intensity * 0.3),
                    .clear
                ],
                center: .center,
                startRadius: 0,
                endRadius: currentRadius * 0.4
            )

            // Extended glow ring
            RadialGradient(
                colors: [
                    .clear,
                    GVTheme.violetDeep.opacity(intensity * 0.2),
                    GVTheme.violetDeep.opacity(intensity * 0.1),
                    .clear
                ],
                center: .center,
                startRadius: currentRadius * 0.4,
                endRadius: currentRadius
            )

            // Subtle phosphor trails (CRT artifact)
            if progress > 0.2 {
                RadialGradient(
                    colors: [
                        .clear,
                        GVTheme.violet.opacity(intensity * 0.05),
                        .clear
                    ],
                    center: .center,
                    startRadius: currentRadius * 0.6,
                    endRadius: currentRadius * 0.8
                )
                .opacity(sin(progress * .pi * 4) * 0.5 + 0.5)
            }
        }
        .blur(radius: max(8 * (1 - progress), 1))
        .compositingGroup()
        .blendMode(.plusLighter)
    }

    private func sparkOpacity(elapsed: TimeInterval) -> Double {
        let progress = min(elapsed / GVBootTiming.sparkSeconds, 1.0)
        // Fade in quickly then hold
        return progress < 0.3 ? progress / 0.3 : 1.0
    }

    private func easeOutCubic(_ t: Double) -> Double {
        let t1 = t - 1
        return t1 * t1 * t1 + 1
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        GVPhosphorSpark(
            isSparkVisible: true,
            isBloomActive: true,
            start: Date()
        )
    }
}
