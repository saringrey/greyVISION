import SwiftUI

/// A very slow aurora behind the splash.
///
/// Three ribbons, each a closed path whose edges are the sum of two sines
/// running at rates that are not whole multiples of each other, so the
/// silhouette keeps reforming instead of settling into a visible loop.
///
/// The motion is deliberately near-subliminal — the fastest term takes about
/// ten minutes to come round. Anything quicker reads as a screensaver and
/// competes with the boot sequence for attention.
///
/// One `Canvas` in one `TimelineView` at 20 Hz with a single blur pass over
/// the layer. At this speed the low frame rate is invisible, and it keeps the
/// cost off the boot's critical path.
struct GVAurora: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Vertical band the aurora occupies, in unit coordinates.
    var band: ClosedRange<Double> = 0.04 ... 0.62
    var intensity: Double = 1

    private static let ribbons: [Ribbon] = [
        Ribbon(offset: 0.16, thickness: 0.20, rate: 0.0083, phase: 0.0, tint: 0, alpha: 0.30),
        Ribbon(offset: 0.42, thickness: 0.26, rate: 0.0061, phase: 2.4, tint: 1, alpha: 0.24),
        Ribbon(offset: 0.68, thickness: 0.17, rate: 0.0104, phase: 4.1, tint: 2, alpha: 0.18)
    ]

    private static let tints: [Color] = [
        GVTheme.violet,
        GVTheme.violetDeep,
        Color(red: 0.35, green: 0.85, blue: 0.78)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 2 : 1 / 24, paused: false)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                for ribbon in Self.ribbons {
                    draw(ribbon, context: context, size: size, time: time)
                }
            }
        }
        // One blur for the whole layer rather than per ribbon. The paths are
        // built coarse — 18 samples — on the assumption this softens them.
        .blur(radius: 34)
        .blendMode(.plusLighter)
        .opacity(intensity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(_ ribbon: Ribbon, context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let top = band.lowerBound * size.height
        let height = (band.upperBound - band.lowerBound) * size.height
        let samples = 18
        let phase = reduceMotion ? ribbon.phase : time * ribbon.rate + ribbon.phase

        // Upper edge left to right, then the lower edge back, so both are
        // sampled from the same warp and the band keeps a roughly constant
        // weight instead of pinching where the sines cross.
        var path = Path()
        for index in 0 ... samples {
            let unit = Double(index) / Double(samples)
            let point = CGPoint(
                x: unit * size.width,
                y: top + (ribbon.offset + warp(unit, phase: phase)) * height
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        for index in stride(from: samples, through: 0, by: -1) {
            let unit = Double(index) / Double(samples)
            let swell = 0.7 + (sin(unit * 4.1 + phase * 1.7) + 1) * 0.3
            let point = CGPoint(
                x: unit * size.width,
                y: top + (ribbon.offset + warp(unit, phase: phase) + ribbon.thickness * swell) * height
            )
            path.addLine(to: point)
        }
        path.closeSubpath()

        let tint = Self.tints[ribbon.tint]
        context.fill(
            path,
            with: .linearGradient(
                Gradient(colors: [
                    tint.opacity(ribbon.alpha * 0.15),
                    tint.opacity(ribbon.alpha),
                    tint.opacity(ribbon.alpha * 0.25)
                ]),
                startPoint: .zero,
                endPoint: CGPoint(x: size.width, y: 0)
            )
        )
    }

    /// Two sines an octave and a bit apart. The ratio is not a whole number,
    /// which is what stops the curve settling into a repeating shape.
    private func warp(_ unit: Double, phase: Double) -> Double {
        sin(unit * 2.7 + phase) * 0.09 + sin(unit * 5.3 - phase * 1.31) * 0.05
    }

    private struct Ribbon: Sendable {
        let offset: Double
        let thickness: Double
        let rate: Double
        let phase: Double
        let tint: Int
        let alpha: Double
    }
}
