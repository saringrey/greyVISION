import SwiftUI

/// CRT glass over the creator mark.
///
/// The rest of the instrument is seen through scanlines and a slight chromatic
/// break, so an untreated photograph in the middle of it reads as an asset
/// pasted in from somewhere else. This puts the mark behind the same tube.
///
/// One `Canvas` inside one `TimelineView`: the drift is derived from the
/// timestamp rather than stored, so nothing publishes per frame.
struct GVCreatorScreenEffect: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 24, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                guard size.width > 0, size.height > 0 else { return }

                // Scanlines, drifting slowly downward.
                let spacing: CGFloat = 3
                let drift = reduceMotion ? 0 : CGFloat(time.truncatingRemainder(dividingBy: 1)) * spacing
                var y = -drift
                while y < size.height {
                    context.fill(
                        Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                        with: .color(.black.opacity(0.22))
                    )
                    y += spacing
                }

                // Two bright bands sweeping at different rates. A single band
                // reads as a scanning animation; two at odds with each other
                // read as an unstable signal.
                for index in 0 ..< 2 {
                    let rate = index == 0 ? 0.13 : 0.31
                    let phase = reduceMotion
                        ? 0.5
                        : (time * rate).truncatingRemainder(dividingBy: 1)
                    let bandY = size.height * CGFloat(phase)
                    let height = size.height * (index == 0 ? 0.06 : 0.015)
                    context.fill(
                        Path(CGRect(x: 0, y: bandY, width: size.width, height: height)),
                        with: .color(.white.opacity(index == 0 ? 0.045 : 0.075))
                    )
                }

                // Violet bloom pooling at the edges, matching the panel glow.
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .radialGradient(
                        Gradient(colors: [
                            .clear,
                            GVTheme.violetDeep.opacity(0.10),
                            GVTheme.violetDeep.opacity(0.26)
                        ]),
                        center: CGPoint(x: size.width / 2, y: size.height / 2),
                        startRadius: size.width * 0.25,
                        endRadius: size.width * 0.78
                    )
                )
            }
            .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
