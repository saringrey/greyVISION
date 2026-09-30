import SwiftUI

/// ASCII wave rising from the bottom edge of the access gate.
///
/// Ported from the `ascii-wave` React component in
/// `~/src/components/lightswind`. The original draws to a 2D canvas on a
/// `requestAnimationFrame` loop; this is the same maths in a SwiftUI `Canvas`
/// driven by `TimelineView`.
///
/// Two deliberate departures from the source:
///
/// * **Deterministic dropouts.** The original calls `Math.random()` per glyph
///   per frame, so the holes strobe and every device differs. Everything else
///   on this screen is hashed from position and time; a random field here
///   would be the one layer that flickers differently on every run.
/// * **Bone, not orange.** The source defaults to `#FF4500`. The gate is a
///   monochrome terminal, and the one warm element on it was the traffic
///   lights, which were just blacked out for the same reason.
struct GateASCIIWave: View {
    /// Density ramp, light to dark — the original's ordering.
    private static let ramp = Array(" .:+x*#")
    private static let fontSize: CGFloat = 12
    private static let columnWidth: CGFloat = 10
    /// Scales the whole field's opacity. Brightened from 0.30: the operator
    /// asked for a more present backdrop, and the lock sits far enough above
    /// the crest that the wave can carry more light without competing.
    private static let peakOpacity = 0.44

    var speed: Double = 1
    /// Device tilt — when supplied the wave leans and its amplitude shifts
    /// with the hands, so the gate's backdrop is not a loop but a surface.
    var tilt: CGSize = .zero

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 20, paused: reduceMotion)) { timeline in
            // A fixed instant gives Reduce Motion a still crest rather than a
            // frozen-then-jumping one.
            let t = reduceMotion ? 4_000 : timeline.date.timeIntervalSinceReferenceDate * 1_000
            Canvas { context, size in
                draw(time: t, size: size, into: &context)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(time: Double, size: CGSize, into context: inout GraphicsContext) {
        let columns = Int(ceil(size.width / Self.columnWidth))
        let rows = Int(ceil(size.height / Self.fontSize))
        guard rows > 0, columns > 0 else { return }

        let font = Font.system(size: Self.fontSize, weight: .regular, design: .monospaced)

        for column in 0 ..< columns {
            // Halved again — ~3% lean.
            let tiltLean = Double(tilt.width) * 0.03
            let tiltLift = Double(tilt.height) * 0.015
            let shape = sin(Double(column) * 0.1 + tiltLean) * 0.6 + cos(Double(column) * 0.25 - tiltLean * 0.6) * 0.4
            let breath = sin(time * 0.002 * speed + tiltLean) * (0.10 + tiltLift * 0.01)
            let flicker = sin(time * 0.008 * speed + Double(column) * 100) * 0.05

            let noise = shape + breath + flicker + tiltLift * 0.0075
            let normalisedHeight = max(0.15, (noise + 1) / 2 * 0.6 + 0.15)
            let activeRows = Int(normalisedHeight * Double(rows))
            guard activeRows > 0 else { continue }

            let firstRow = rows - activeRows
            for row in stride(from: rows - 1, through: max(firstRow, 0), by: -1) {
                // Holes in the flame. Hashed on cell and a coarse time bucket
                // so a hole persists for a few frames instead of strobing.
                guard Self.hash(column &* 92_837 &+ row &* 689 &+ Int(time / 90) &* 7) > 0.06 else { continue }

                let flow = time * 0.005 * speed
                let charNoise = sin(Double(row) * 0.2 - flow + Double(column) * 10)
                let index = min(Int((charNoise + 1) / 2 * Double(Self.ramp.count)), Self.ramp.count - 1)
                let glyph = Self.ramp[index]
                guard glyph != " " else { continue }

                // Fade in over the first few rows below the crest, so the top
                // of each column dissolves instead of ending on a hard edge.
                let fade = min(1, Double(row - firstRow) / 6)
                let alpha = fade * Self.peakOpacity
                guard alpha > 0.004 else { continue }

                context.draw(
                    Text(String(glyph)).font(font).foregroundColor(.white.opacity(alpha)),
                    at: CGPoint(
                        x: CGFloat(column) * Self.columnWidth,
                        y: CGFloat(row) * Self.fontSize
                    ),
                    anchor: .topLeading
                )
            }
        }
    }

    /// The gate's shared LCG, so the wave's holes come from the same noise
    /// source as the rain and the square field.
    private nonisolated static func hash(_ value: Int) -> Double {
        var mixed = UInt64(bitPattern: Int64(value)) &* 6_364_136_223_846_793_005
        mixed = mixed &+ 1_442_695_040_888_963_407
        return Double((mixed >> 33) % 100_000) / 100_000
    }
}

/// The yang to `GateASCIIWave`'s yin: the same wave maths, inverted and
/// hanging from the top edge. Where the black wave rises from the bottom of
/// the gate, this one descends from the top, and the two are masked so each
/// fades out exactly where the other takes over — the screen reads as one
/// continuous field split into a light half and a dark half.
///
/// Deliberately fainter than the black wave (0.38 vs 0.44): white ink carries
/// more visual weight on black than black ink on white would, so the matched
/// alpha would make the top half dominate the composition.
struct GateASCIIWaveInverted: View {
    var speed: Double = 1
    var tilt: CGSize = .zero

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 20, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 4_000 : timeline.date.timeIntervalSinceReferenceDate * 1_000
            Canvas { context, size in
                draw(time: t, size: size, into: &context)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(time: Double, size: CGSize, into context: inout GraphicsContext) {
        let columns = Int(ceil(size.width / GateASCIIWaveMirror.columnWidth))
        let rows = Int(ceil(size.height / GateASCIIWaveMirror.fontSize))
        guard rows > 0, columns > 0 else { return }

        let font = Font.system(size: GateASCIIWaveMirror.fontSize, weight: .regular, design: .monospaced)

        for column in 0 ..< columns {
            // Mirrored lean: the tilt moves this wave the *opposite* way to
            // the black one, so tilting the device visibly swaps the halves.
            let tiltLean = -Double(tilt.width) * 0.03
            let tiltLift = -Double(tilt.height) * 0.015
            let shape = sin(Double(column) * 0.1 + tiltLean) * 0.6 + cos(Double(column) * 0.25 - tiltLean * 0.6) * 0.4
            let breath = sin(time * 0.002 * speed + tiltLean) * (0.10 + tiltLift * 0.01)
            let flicker = sin(time * 0.008 * speed + Double(column) * 100) * 0.05

            let noise = shape + breath + flicker + tiltLift * 0.0075
            let normalisedHeight = max(0.15, (noise + 1) / 2 * 0.6 + 0.15)
            let activeRows = Int(normalisedHeight * Double(rows))
            guard activeRows > 0 else { continue }

            for row in 0 ..< activeRows {
                // Same hashed dropouts as the black wave, offset by a prime so
                // the two waves' holes never line up into vertical channels.
                guard GateASCIIWaveMirror.hash(column &* 92_837 &+ row &* 689 &+ Int(time / 90) &* 7 &+ 104_729) > 0.06 else { continue }

                let flow = time * 0.005 * speed
                let charNoise = sin(Double(row) * 0.2 - flow + Double(column) * 10)
                let index = min(Int((charNoise + 1) / 2 * Double(GateASCIIWaveMirror.ramp.count)), GateASCIIWaveMirror.ramp.count - 1)
                let glyph = GateASCIIWaveMirror.ramp[index]
                guard glyph != " " else { continue }

                // Fade in over the first few rows below the crest — here the
                // crest is at the top, so the fade runs the other way.
                let fade = min(1, Double(activeRows - row) / 6)
                // Blend into the black wave: this half is masked away below
                // the screen's midpoint (see the mask in the view body's
                // parent), so the two fields hand over at the centre line.
                let alpha = fade * GateASCIIWaveMirror.peakOpacity * 0.78
                guard alpha > 0.004 else { continue }

                context.draw(
                    Text(String(glyph)).font(font).foregroundColor(.white.opacity(alpha)),
                    at: CGPoint(
                        x: CGFloat(column) * GateASCIIWaveMirror.columnWidth,
                        y: CGFloat(row) * GateASCIIWaveMirror.fontSize
                    ),
                    anchor: .topLeading
                )
            }
        }
    }
}

/// Namespace mirror of the constants `GateASCIIWave` owns privately, so the
/// inverted wave shares the exact grid, ramp and noise source — the two halves
/// must be the same field, not two similar ones.
enum GateASCIIWaveMirror {
    static let ramp = Array(" .:+x*#")
    static let fontSize: CGFloat = 12
    static let columnWidth: CGFloat = 10
    static let peakOpacity = 0.38

    static func hash(_ value: Int) -> Double {
        var mixed = UInt64(bitPattern: Int64(value)) &* 6_364_136_223_846_793_005
        mixed = mixed &+ 1_442_695_040_888_963_407
        return Double((mixed >> 33) % 100_000) / 100_000
    }
}
