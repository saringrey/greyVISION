import SwiftUI

/// Expanding rings of light leaving the mark.
///
/// Two colours on one ring rather than two separate rings: a white leading
/// edge with violet trailing behind it reads as a single wavefront with
/// chromatic separation, the way a real discharge does. Two independent rings
/// would read as two effects that happen to be near each other.
///
/// Rings are derived from elapsed time inside one `TimelineView`, so the whole
/// system costs one timer and never publishes per-frame state.
struct GVPulseWave: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// When the sequence began.
    let start: Date
    /// Seconds between emissions.
    var interval: Double = 2.4
    /// Seconds a ring takes to travel from the mark to full radius.
    var travel: Double = 2.0
    /// Rings alive at once.
    var count: Int = 3
    /// Radius at full expansion, in points.
    var maximumRadius: CGFloat = 320

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 40, paused: reduceMotion)) { timeline in
            let elapsed = max(timeline.date.timeIntervalSince(start), 0)

            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                for index in 0 ..< count {
                    // Each ring is the same wave offset in time, so they stay
                    // evenly spaced however long the view has been alive.
                    let offset = Double(index) * (interval / Double(count))
                    let age = (elapsed - offset).truncatingRemainder(dividingBy: interval)
                    guard age >= 0 else { continue }
                    let progress = min(age / travel, 1)
                    guard progress < 1 else { continue }

                    // Eased so the wave leaves fast and settles, which reads as
                    // energy dissipating rather than a circle being scaled.
                    let eased = 1 - pow(1 - progress, 2.2)
                    let radius = maximumRadius * eased
                    // Fades out over the back half only, so the leading edge
                    // stays crisp while it is still travelling.
                    let presence = 1 - max((progress - 0.45) / 0.55, 0)
                    guard presence > 0.01 else { continue }

                    let rect = CGRect(
                        x: centre.x - radius,
                        y: centre.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )

                    // Violet trails a couple of points behind the white edge.
                    context.stroke(
                        Ellipse().path(in: rect.insetBy(dx: 2.5, dy: 2.5)),
                        with: .color(GVTheme.violet.opacity(0.55 * presence)),
                        lineWidth: 3.0
                    )
                    context.stroke(
                        Ellipse().path(in: rect),
                        with: .color(.white.opacity(0.42 * presence)),
                        lineWidth: 1.1
                    )
                    // Wide, faint violet bloom carrying the ring's weight.
                    context.stroke(
                        Ellipse().path(in: rect.insetBy(dx: 6, dy: 6)),
                        with: .color(GVTheme.violetDeep.opacity(0.16 * presence)),
                        lineWidth: 9
                    )
                }
            }
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
