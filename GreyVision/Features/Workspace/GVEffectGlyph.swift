import SwiftUI

/// Per-family procedural glyphs.
///
/// Each effect family draws its own miniature diagram rather than an icon, so
/// the browser reads as a rack of signal processors. Animation is continuous
/// but extremely low amplitude, and the whole glyph is a single `Canvas` pass.
enum GVEffectGlyphKind {
    case feedback
    case trails
    case echo
    case datamosh
    case pixelSort
    case flow
    case depth
    case block
    case glitch
    case audio
    case frame

    // swiftlint:disable cyclomatic_complexity
    // Maps the effect registry onto a glyph family.
    static func kind(for effect: WorkspaceAdjustableEffect) -> GVEffectGlyphKind {
        switch effect {
        case .feedback, .feedbackTunnel, .depthFeedback:
            .feedback
        case .trails, .motionBloom, .prismStreak:
            .trails
        case .echo, .frameHoldSmear, .rollingTime, .slitScan:
            .echo
        case .datamosh, .liquidMosh, .heavyMosh, .dataBend, .pixelShift, .signalTear:
            .datamosh
        case .sort, .depthSort, .objectSort, .radialSort, .temporalPixelSort, .sortBrush:
            .pixelSort
        case .opticalFlowLiquid, .vectorWarp, .ripple, .wave, .pixelGravity:
            .flow
        case .pointCloudSmear, .lumaExtrusion, .freezeBrush, .freeze:
            .depth
        case .pixelate, .posterize, .dither, .halftone, .threshold, .edge, .emboss, .sharpen:
            .block
        case .rgbSplit, .vhs, .crt, .grain, .thermal, .solarize, .hueShift, .invert, .monochrome:
            .glitch
        case .audioSpectral, .audioScanBend, .audioChromaPulse, .audioWaveform,
             .audioBandSlice, .audioBloom, .audioKick:
            .audio
        default:
            .frame
        }
    }
    // swiftlint:enable cyclomatic_complexity
}

/// A small animated diagram for one effect family.
struct GVEffectGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let kind: GVEffectGlyphKind
    /// Raised while the effect is running.
    var activity: Double = 0
    var size: CGFloat = 16

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 15, paused: reduceMotion)) { timeline in
            Canvas(rendersAsynchronously: false) { context, canvasSize in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                draw(&context, canvasSize, time)
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var stroke: Color {
        GVTheme.bone.opacity(0.34 + activity * 0.5)
    }

    private var accent: Color {
        GVTheme.violet.opacity(0.45 + activity * 0.45)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func draw(_ context: inout GraphicsContext, _ canvas: CGSize, _ time: TimeInterval) {
        let width = canvas.width
        let height = canvas.height
        let pulse = 0.5 + sin(time * (1.1 + activity * 1.4)) * 0.5

        switch kind {
        case .feedback:
            // Recursive squares marching inward.
            for index in 0 ..< 4 {
                let inset = CGFloat(index) * width * 0.11 + CGFloat(pulse) * width * 0.03
                let rect = CGRect(
                    x: inset,
                    y: inset,
                    width: max(width - inset * 2, 0.5),
                    height: max(height - inset * 2, 0.5)
                )
                context.stroke(
                    Path(rect),
                    with: .color(index == 0 ? accent : stroke.opacity(0.7 - Double(index) * 0.15)),
                    lineWidth: 0.7
                )
            }

        case .trails:
            // A fading trajectory.
            var path = Path()
            path.move(to: CGPoint(x: 1, y: height * 0.74))
            for step in 1 ... 12 {
                let fraction = CGFloat(step) / 12
                let x = fraction * (width - 2) + 1
                let y = height * 0.74 - sin(Double(fraction) * 3.0 + time) * height * 0.28 * fraction
                path.addLine(to: CGPoint(x: x, y: y))
            }
            context.stroke(path, with: .color(accent), lineWidth: 0.8)
            for step in 0 ..< 3 {
                let fade = 0.28 - Double(step) * 0.08
                context.stroke(
                    path.offsetBy(dx: CGFloat(-step) * 1.6, dy: 0),
                    with: .color(stroke.opacity(fade)),
                    lineWidth: 0.6
                )
            }

        case .echo:
            // Offset frames.
            for index in 0 ..< 3 {
                let offset = CGFloat(index) * width * 0.13
                let rect = CGRect(
                    x: offset,
                    y: offset * 0.6,
                    width: width * 0.6,
                    height: height * 0.6
                )
                context.stroke(
                    Path(rect),
                    with: .color(index == 0 ? accent : stroke.opacity(0.62 - Double(index) * 0.18)),
                    lineWidth: 0.7
                )
            }

        case .datamosh:
            // Broken macroblocks.
            let cells = 4
            for row in 0 ..< cells {
                for column in 0 ..< cells {
                    let seed = Double(row &* 7 &+ column &* 13)
                    let noise = (sin(seed * 12.9898 + floor(time * 3)) * 0.5 + 0.5)
                    guard noise > 0.42 else { continue }
                    let jitter = CGFloat(noise - 0.5) * width * 0.16 * CGFloat(0.4 + activity)
                    let cell = CGRect(
                        x: CGFloat(column) * width / CGFloat(cells) + jitter,
                        y: CGFloat(row) * height / CGFloat(cells),
                        width: width / CGFloat(cells) - 1,
                        height: height / CGFloat(cells) - 1
                    )
                    context.fill(
                        Path(cell),
                        with: .color(noise > 0.8 ? accent : stroke.opacity(0.34))
                    )
                }
            }

        case .pixelSort:
            // A stretched histogram.
            let bars = 6
            for index in 0 ..< bars {
                let fraction = Double(index) / Double(bars)
                let magnitude = 0.25 + abs(sin(fraction * 4 + time * 0.8)) * 0.72
                let barHeight = height * CGFloat(magnitude)
                let rect = CGRect(
                    x: CGFloat(index) * width / CGFloat(bars),
                    y: height - barHeight,
                    width: width / CGFloat(bars) - 1,
                    height: barHeight
                )
                context.fill(Path(rect), with: .color(index == bars - 1 ? accent : stroke.opacity(0.5)))
            }

        case .flow:
            // A vector field.
            for row in 0 ..< 3 {
                for column in 0 ..< 3 {
                    let x = (CGFloat(column) + 0.5) * width / 3
                    let y = (CGFloat(row) + 0.5) * height / 3
                    let angle = sin(Double(row) * 1.3 + Double(column) * 0.9 + time * 0.9) * 2.2
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: y))
                    path.addLine(
                        to: CGPoint(x: x + cos(angle) * width * 0.16, y: y + sin(angle) * height * 0.16)
                    )
                    context.stroke(
                        path,
                        with: .color(row == 1 && column == 1 ? accent : stroke.opacity(0.55)),
                        lineWidth: 0.7
                    )
                }
            }

        case .depth:
            // Contour mesh.
            for index in 0 ..< 4 {
                var path = Path()
                let offset = CGFloat(index) * height * 0.2 + CGFloat(pulse) * 1.5
                path.move(to: CGPoint(x: 0, y: height - offset))
                for step in 0 ... 8 {
                    let fraction = CGFloat(step) / 8
                    let y = height - offset - sin(Double(fraction) * 3.14 + Double(index)) * height * 0.12
                    path.addLine(to: CGPoint(x: fraction * width, y: y))
                }
                context.stroke(
                    path,
                    with: .color(index == 0 ? accent : stroke.opacity(0.5 - Double(index) * 0.1)),
                    lineWidth: 0.7
                )
            }

        case .block:
            // Quantisation lattice.
            let cells = 3
            for row in 0 ..< cells {
                for column in 0 ..< cells {
                    let filled = (row + column).isMultiple(of: 2)
                    let rect = CGRect(
                        x: CGFloat(column) * width / CGFloat(cells),
                        y: CGFloat(row) * height / CGFloat(cells),
                        width: width / CGFloat(cells) - 1,
                        height: height / CGFloat(cells) - 1
                    )
                    context.fill(
                        Path(rect),
                        with: .color(filled ? stroke.opacity(0.5) : accent.opacity(0.3 + pulse * 0.2))
                    )
                }
            }

        case .glitch:
            // Displaced scan bands.
            for index in 0 ..< 5 {
                let y = CGFloat(index) * height / 5
                let seed = Double(index) + floor(time * 4)
                let shift = CGFloat(sin(seed * 8.3) * 0.5) * width * 0.3
                let rect = CGRect(x: shift, y: y, width: width * 0.85, height: height / 5 - 1)
                context.fill(
                    Path(rect),
                    with: .color(index == 2 ? accent : stroke.opacity(0.34))
                )
            }

        case .audio:
            // Level meter.
            let bars = 5
            for index in 0 ..< bars {
                let fraction = Double(index) / Double(bars)
                let magnitude = 0.2 + abs(sin(time * 3.4 + fraction * 5)) * (0.4 + activity * 0.5)
                let barHeight = height * CGFloat(magnitude)
                let rect = CGRect(
                    x: CGFloat(index) * width / CGFloat(bars) + 0.5,
                    y: height - barHeight,
                    width: width / CGFloat(bars) - 1.4,
                    height: barHeight
                )
                context.fill(
                    Path(rect),
                    with: .color(magnitude > 0.7 ? accent : stroke.opacity(0.55))
                )
            }

        case .frame:
            // Corner brackets.
            let length = width * 0.3
            var path = Path()
            path.move(to: CGPoint(x: 0, y: length))
            path.addLine(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: length, y: 0))
            path.move(to: CGPoint(x: width - length, y: height))
            path.addLine(to: CGPoint(x: width, y: height))
            path.addLine(to: CGPoint(x: width, y: height - length))
            context.stroke(path, with: .color(accent), lineWidth: 0.9)
            context.stroke(
                Path(CGRect(x: width * 0.3, y: height * 0.3, width: width * 0.4, height: height * 0.4)),
                with: .color(stroke.opacity(0.4)),
                lineWidth: 0.6
            )
        }
    }
}
