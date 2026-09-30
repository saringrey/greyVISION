import SwiftUI

/// Screen-resolution dot lettering preserves the GIF's scrolling rows without
/// stretching its low-resolution, heavily swollen frames across the display.
///
/// Every row scrolls on its own heading, at its own pace, from its own offset.
/// The rows used to alternate by parity — even rows one way, odd the other —
/// which meant the field was really two bands sliding past each other, and any
/// two rows with the same parity were locked together forever. A row can now
/// follow the row above it, oppose it, or crawl against a faster neighbour,
/// which is what a terminal failing to hold its own text actually looks like.
struct GVSplashBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion || scenePhase != .active)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSince(start)
            Canvas { context, size in
                let pitch = size.width / 76
                let rowHeight = pitch * 10
                let period = CGFloat(GVSplashLettering.columns) * pitch
                guard pitch > 0 else { return }
                let rowCount = Int(ceil(size.height / rowHeight)) + 1
                var highlights: [(path: Path, opacity: Double)] = []
                for row in 0 ..< rowCount {
                    var dots = Path()
                    var litDots = Path()
                    let highlight = GVSplashLettering.highlight(at: time, row: row)
                    let strength = reduceMotion ? 0 : highlight.strength
                    let flicker = reduceMotion ? 1 : GVSplashLettering.rowBrightness(at: time, row: row, count: rowCount)
                    let motion = GVSplashLettering.motion(for: row)
                    // Normalised into one period: a negative remainder would
                    // still draw correctly through the copies below, but
                    // keeping the offset positive means every row is covered by
                    // the same two copies either side of it.
                    let travel = CGFloat(time) * motion.direction * motion.speed + motion.phase * period
                    let wrapped = travel.truncatingRemainder(dividingBy: period)
                    let offset = wrapped < 0 ? wrapped + period : wrapped
                    let radius = pitch * GVSplashLettering.dotRadius(at: time, row: row)
                    for copy in -2 ... 2 {
                        for point in GVSplashLettering.points {
                            let x = point.x * pitch + offset + CGFloat(copy) * period
                            let y = CGFloat(row) * rowHeight + point.y * pitch + pitch
                            guard x >= -radius, x <= size.width + radius else { continue }
                            let isLit = Int(point.x) / 6 == highlight.character
                            let dotRadius = radius * (1 + (isLit ? 0.12 * strength : 0))
                            let rect = CGRect(x: x - dotRadius, y: y - dotRadius,
                                              width: dotRadius * 2, height: dotRadius * 2)
                            dots.addEllipse(in: rect)
                            if isLit { litDots.addEllipse(in: rect) }
                        }
                    }
                    context.fill(dots, with: .color(.white.opacity(0.70 * flicker)))
                    highlights.append((litDots, strength * flicker))
                    context.fill(litDots, with: .color(.white.opacity(strength * flicker)))
                }
                if !reduceMotion {
                    // One blur pass for the whole field, not a surface per row.
                    context.drawLayer { glow in
                        glow.addFilter(.blur(radius: pitch * 0.65))
                        for highlight in highlights {
                            glow.fill(highlight.path, with: .color(.white.opacity(0.65 * highlight.opacity)))
                        }
                    }
                }
            }
            .background(GVTheme.void)
            .overlay(alignment: .top) {
                HStack {
                    Text("BUILD 0.1.0")
                    Spacer()
                    Text("ARE YOU HAPPY?")
                }
                .gvMono(10, .medium)
                .tracking(1.2)
                .foregroundStyle(GVTheme.bone)
                .padding(.horizontal, GVMetrics.stepMajor)
                .padding(.top, GVMetrics.stepRelated)
                .padding(.bottom, GVMetrics.stepInternal)
                .background(GVTheme.void)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GVTheme.void)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One row's heading, pace and start offset.
///
/// A table rather than a draw: a row that re-rolled its direction on every tick
/// would flicker between headings sixty times a second, which reads as a fault
/// rather than as a scroll.
struct GVSplashRowMotion {
    /// `+1` or `-1`. Rows are free to repeat a neighbour's heading — that is
    /// what makes the field look random rather than striped.
    let direction: CGFloat
    /// Columns travelled per second. Rows disagree so the panel never locks
    /// into the old even/odd mirror.
    let speed: CGFloat
    /// Start position as a fraction of one text period, so two rows heading the
    /// same way do not sit in the same place.
    let phase: CGFloat
}

enum GVSplashLettering {
    // Five-column dot glyphs; no frame decoding or raster enlargement per tick.
    private static let glyphs: [Character: [Int]] = [
        "G": [14, 17, 16, 23, 17, 17, 14], "R": [30, 17, 17, 30, 20, 18, 17],
        "E": [31, 16, 16, 30, 16, 16, 31], "Y": [17, 17, 10, 4, 4, 4, 4],
        "/": [1, 2, 2, 4, 8, 8, 16], "V": [17, 17, 17, 17, 17, 10, 4],
        "I": [14, 4, 4, 4, 4, 4, 14], "S": [15, 16, 16, 14, 1, 1, 30],
        "O": [14, 17, 17, 17, 17, 17, 14], "N": [17, 25, 25, 21, 19, 19, 17]
    ]
    static let text = "GREY // VISION "
    static let columns = text.count * 6
    private static let characters = text.enumerated().compactMap { $0.element == " " ? nil : $0.offset }

    static func highlight(at time: Double, row: Int) -> (character: Int, strength: Double) {
        let clock = max(time, 0) / 2.8 + Double(motion(for: row).phase)
        let cycle = Int(floor(clock))
        let phase = clock - floor(clock)
        // Step five visits every non-space glyph before repeating.
        let index = (cycle * 5 + row * 7) % characters.count
        return (characters[index], pow(sin(.pi * phase), 2))
    }

    static func rowBrightness(at time: Double, row: Int, count: Int) -> Double {
        guard count > 0 else { return 1 }
        let clock = max(time, 0) / 4
        let cycle = Int(floor(clock))
        let phase = clock - floor(clock)
        // A single soft dip, on a different row each window; never a strobe.
        let selected = (cycle + Int(motion(for: cycle / count).phase * Double(count))) % count
        guard row == selected, phase < 0.12 else { return 1 }
        return 1 - 0.28 * sin(.pi * phase / 0.12)
    }

    static let points: [CGPoint] = text.enumerated().flatMap { index, letter in
        (glyphs[letter] ?? []).enumerated().flatMap { row, bits in
            (0 ..< 5).compactMap { column in
                bits & (1 << (4 - column)) != 0
                    ? CGPoint(x: index * 6 + column, y: row) : nil
            }
        }
    }

    /// Per-row heading, pace and offset.
    ///
    /// SplitMix64's finaliser over the row index: cheap, deterministic, and it
    /// decorrelates neighbouring indices, so row 3 and row 4 bear no relation
    /// to each other the way `row % 2` left them. Determinism is the point —
    /// this is called from inside the draw closure on every frame, and a fresh
    /// `Int.random` per tick would re-aim the whole field sixty times a second.
    static func motion(for row: Int) -> GVSplashRowMotion {
        var hash = UInt64(bitPattern: Int64(row)) &+ 0x9E37_79B9_7F4A_7C15
        hash = (hash ^ (hash >> 30)) &* 0xBF58_476D_1CE4_E5B9
        hash = (hash ^ (hash >> 27)) &* 0x94D0_49BB_1331_11EB
        hash ^= hash >> 31

        return GVSplashRowMotion(
            direction: (hash & 1) == 0 ? 1 : -1,
            // 9...30 columns a second. Wide enough that a fast row visibly
            // overtakes a slow one; never so wide that a row strobes.
            speed: 9 + CGFloat((hash >> 8) & 0xFF) / 255 * 21,
            phase: CGFloat((hash >> 24) & 0xFFFF) / 65535
        )
    }

    static func dotRadius(at time: Double, row: Int) -> CGFloat {
        // Radius stays below half the dot pitch: adjacent dots never merge.
        // The swell is phased off the row's own motion rather than off its
        // index, so the size wave does not travel straight down the panel while
        // the rows it passes are scrolling in six different directions.
        let phase = Double(motion(for: row).phase) * 2 * .pi
        return 0.28 + 0.025 * sin(time * 1.4 + phase)
    }
}
