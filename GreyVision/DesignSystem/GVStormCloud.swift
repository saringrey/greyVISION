import SwiftUI

/// A small storm behind the workspace wordmark.
///
/// Three soft cloud lobes with violet lightning striking on an irregular
/// schedule. Sized to sit behind the title only — it is punctuation for the
/// mark, not a background layer, so it never competes with the camera.
///
/// The whole thing is one `Canvas` inside a single `TimelineView`, and the
/// bolt geometry is derived from the strike index rather than stored, so no
/// per-frame state crosses the main actor.
struct GVStormCloud: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 24, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                drawCloud(context: context, size: size, time: time)
                if !reduceMotion {
                    drawLightning(context: context, size: size, time: time)
                }
            }
            // The lobes are deliberately wider than the canvas, so without
            // this the gradient is cut mid-falloff and the frame shows as a
            // hard horizontal seam across the screen. Feathering the layer
            // itself is the only fix that survives the lobes moving.
            .mask {
                LinearGradient(
                    stops: Self.feather,
                    startPoint: .top,
                    endPoint: .bottom
                )
                .mask {
                    LinearGradient(
                        stops: Self.feather,
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static let feather: [Gradient.Stop] = [
        .init(color: .clear, location: 0.00),
        .init(color: .white.opacity(0.5), location: 0.09),
        .init(color: .white, location: 0.22),
        .init(color: .white, location: 0.78),
        .init(color: .white.opacity(0.5), location: 0.91),
        .init(color: .clear, location: 1.00)
    ]

    /// Lobe rest positions, each with its own drift phase and period so the
    /// mass churns instead of sliding sideways as one rigid shape.
    private static let lobes: [(x: CGFloat, y: CGFloat, r: CGFloat, o: Double, phase: Double, rate: Double)] = [
        (0.30, 0.52, 0.30, 0.30, 0.0, 0.17),
        (0.52, 0.40, 0.36, 0.26, 2.1, 0.23),
        (0.72, 0.55, 0.28, 0.22, 4.3, 0.13),
        (0.42, 0.62, 0.24, 0.18, 1.2, 0.29),
        (0.62, 0.34, 0.22, 0.16, 3.4, 0.19)
    ]

    private func drawCloud(context: GraphicsContext, size: CGSize, time: TimeInterval) {
        // Bulk drift, then per-lobe churn on top of it: each lobe wanders on
        // its own ellipse and breathes on a different period, which is what
        // separates smoke from a static blob that happens to slide.
        let drift = reduceMotion ? 0 : sin(time * 0.21) * size.width * 0.03

        for lobe in Self.lobes {
            let wander = reduceMotion ? 0 : sin(time * lobe.rate + lobe.phase)
            let rise = reduceMotion ? 0 : cos(time * lobe.rate * 0.73 + lobe.phase)
            // Breathing radius. The lobes fall in and out of step, so the
            // silhouette of the mass keeps changing rather than pulsing.
            let breath = reduceMotion ? 1 : 1 + sin(time * lobe.rate * 1.31 + lobe.phase) * 0.16
            let radius = size.width * lobe.r * breath
            let opacity = reduceMotion
                ? lobe.o
                : lobe.o * (0.78 + (sin(time * lobe.rate * 0.61 + lobe.phase * 1.7) + 1) * 0.16)
            let centerX = size.width * lobe.x + drift + wander * size.width * 0.05
            let centerY = size.height * lobe.y + rise * size.height * 0.07
            let rect = CGRect(
                x: centerX - radius,
                y: centerY - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(
                Ellipse().path(in: rect),
                with: .radialGradient(
                    Gradient(colors: [
                        GVTheme.violetDeep.opacity(opacity),
                        GVTheme.violetDeep.opacity(opacity * 0.4),
                        .clear
                    ]),
                    center: CGPoint(x: rect.midX, y: rect.midY),
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }
    }

    private func drawLightning(context: GraphicsContext, size: CGSize, time: TimeInterval) {
        // Strikes on a ~2.4s cycle, each lasting ~180ms. The strike index seeds
        // the bolt so a given flash is stable for its whole duration instead of
        // redrawing a new path every frame.
        // Longer flash, slower cycle: the storm should read as weather, not a strobe.
        let cycle = 3.4
        let phase = time.truncatingRemainder(dividingBy: cycle)
        guard phase < 0.34 else { return }

        let strike = Int(time / cycle)
        let seed = UInt64(bitPattern: Int64(strike)) &* 2_654_435_761
        // Two-stage flash: bright leader, brief decay.
        let intensity = phase < 0.09 ? 1.0 : 1.0 - (phase - 0.09) / 0.25

        let originX = size.width * (0.30 + Double(seed % 40) / 100)
        var path = Path()
        path.move(to: CGPoint(x: originX, y: size.height * 0.42))

        var x = originX
        var y = size.height * 0.42
        var step = seed
        // Four jagged segments down to just below the cloud base.
        for index in 1 ... 4 {
            step = step &* 6_364_136_223_846_793_005 &+ 1
            let jitter = (Double(step % 100) / 100 - 0.5) * size.width * 0.18
            x += jitter
            y += size.height * 0.16
            path.addLine(to: CGPoint(x: x, y: y))
            if index == 2 {
                // A short fork, which is most of what sells a bolt as a bolt.
                var fork = Path()
                fork.move(to: CGPoint(x: x, y: y))
                fork.addLine(to: CGPoint(x: x + jitter * 1.4, y: y + size.height * 0.14))
                context.stroke(
                    fork,
                    with: .color(GVTheme.violet.opacity(0.55 * intensity)),
                    lineWidth: 0.8
                )
            }
        }

        context.stroke(path, with: .color(.white.opacity(0.9 * intensity)), lineWidth: 1.1)
        context.stroke(path, with: .color(GVTheme.violet.opacity(0.7 * intensity)), lineWidth: 2.6)
        context.stroke(path, with: .color(GVTheme.violetDeep.opacity(0.34 * intensity)), lineWidth: 6)
    }
}
