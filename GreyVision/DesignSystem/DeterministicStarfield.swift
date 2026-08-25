import SwiftUI

struct DeterministicStarfield: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset = CGSize.zero

    private let stars = Star.seeded(count: 268, seed: 0x47_5649_5349_4F4E)

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 24, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                for star in stars {
                    let pulse = reduceMotion ? 0.72 : 0.52 + sin(time * star.speed + star.phase) * 0.28
                    let x = star.x * size.width + dragOffset.width * star.depth
                    let y = star.y * size.height + dragOffset.height * star.depth
                    let rect = CGRect(x: x, y: y, width: star.size, height: star.size)
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color((star.isViolet ? GVTheme.violet : .white).opacity(pulse))
                    )
                }
                if !reduceMotion {
                    drawShootingStar(context: context, size: size, time: time)
                }
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    guard !reduceMotion else { return }
                    dragOffset = CGSize(
                        width: value.translation.width * 0.025,
                        height: value.translation.height * 0.025
                    )
                }
                .onEnded { _ in
                    withAnimation(.smooth(duration: 0.7)) {
                        dragOffset = .zero
                    }
                }
        )
        .allowsHitTesting(!reduceMotion)
        .accessibilityHidden(true)
    }

    /// One streak at a time, derived from the clock rather than stored.
    ///
    /// Time is cut into fixed windows; each window's index seeds the entry
    /// point and heading, and roughly a third of windows are skipped so the
    /// streaks do not arrive on a beat. Deriving instead of storing means no
    /// per-frame state has to cross the main actor.
    private func drawShootingStar(context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let window = 6.5
        let flight = 1.15
        let local = time.truncatingRemainder(dividingBy: window)
        guard local < flight else { return }

        let index = UInt64(bitPattern: Int64(time / window))
        var seed = index &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        // Skip about a third of the windows outright.
        guard seed % 100 >= 34 else { return }

        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        let startX = (Double(seed % 1000) / 1000) * size.width * 1.2 - size.width * 0.1
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        let startY = (Double(seed % 1000) / 1000) * size.height * 0.42
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        // Heading down and mostly sideways, direction chosen per streak.
        let sway = Double(seed % 1000) / 1000
        let dirX: Double = sway > 0.5 ? -1 : 1
        let span = size.width * (0.42 + sway * 0.34)

        let progress = local / flight
        // Eased travel, then a fade that only starts in the last third.
        let travel = 1 - pow(1 - progress, 2.2)
        let fade = progress < 0.62 ? min(progress / 0.14, 1) : max(1 - (progress - 0.62) / 0.38, 0)

        let headX = startX + dirX * span * travel
        let headY = startY + span * 0.52 * travel

        // Tail drawn as segments of falling width and opacity: a single
        // stroke with a gradient would need a shading per frame, and this
        // reads the same at a third of the cost.
        let segments = 7
        let tailX = -dirX * size.width * 0.075
        let tailY = -size.height * 0.026
        for segment in 0 ..< segments {
            let near = Double(segment) / Double(segments)
            let far = Double(segment + 1) / Double(segments)
            var path = Path()
            path.move(to: CGPoint(x: headX + tailX * near, y: headY + tailY * near))
            path.addLine(to: CGPoint(x: headX + tailX * far, y: headY + tailY * far))
            context.stroke(
                path,
                with: .color(.white.opacity((1 - near) * 0.75 * fade)),
                style: StrokeStyle(lineWidth: 1.7 * (1 - near * 0.75), lineCap: .round)
            )
        }

        context.fill(
            Path(ellipseIn: CGRect(x: headX - 1.5, y: headY - 1.5, width: 3, height: 3)),
            with: .color(.white.opacity(0.95 * fade))
        )
        context.fill(
            Path(ellipseIn: CGRect(x: headX - 4, y: headY - 4, width: 8, height: 8)),
            with: .radialGradient(
                Gradient(colors: [GVTheme.violet.opacity(0.6 * fade), .clear]),
                center: CGPoint(x: headX, y: headY),
                startRadius: 0,
                endRadius: 4
            )
        )
    }
}

private struct Star: Sendable {
    let x: Double
    let y: Double
    let size: Double
    let phase: Double
    let speed: Double
    let depth: Double
    let isViolet: Bool

    static func seeded(count: Int, seed: UInt64) -> [Star] {
        var generator = SeededGenerator(state: seed)
        return (0 ..< count).map { _ in
            Star(
                x: generator.nextUnit(),
                y: generator.nextUnit(),
                size: 0.4 + pow(generator.nextUnit(), 2.1) * 2.1,
                phase: generator.nextUnit() * .pi * 2,
                speed: 0.3 + generator.nextUnit() * 1.4,
                depth: 0.3 + generator.nextUnit() * 0.9,
                isViolet: generator.nextUnit() > 0.76
            )
        }
    }
}

private struct SeededGenerator: Sendable {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
