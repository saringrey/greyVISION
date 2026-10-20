import SwiftUI

/// Splits the departing splash into horizontal slices that displace by a few
/// pixels, revealing the live camera surface behind them.
struct GVRasterTear: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isActive: Bool
    let start: Date

    func body(content: Content) -> some View {
        if reduceMotion {
            content.opacity(isActive ? 0 : 1)
        } else if !isActive {
            content
        } else {
            GeometryReader { geometry in
                TimelineView(.animation(minimumInterval: 1 / 60, paused: false)) { timeline in
                    let progress = min(
                        max(timeline.date.timeIntervalSince(start) / GVBootTiming.departSeconds, 0),
                        1
                    )
                    content
                        .layerEffect(
                            ShaderLibrary.bootRasterTear(
                                .float2(geometry.size),
                                .float(Float(progress))
                            ),
                            maxSampleOffset: CGSize(width: geometry.size.width * 0.07, height: 2)
                        )
                }
            }
        }
    }
}

extension View {
    func gvRasterTear(isActive: Bool, start: Date) -> some View {
        modifier(GVRasterTear(isActive: isActive, start: start))
    }
}

/// The corruption that settles over the workspace as the signal path opens.
///
/// Runs for roughly 380 ms after entry and then removes itself entirely, so no
/// continuous work survives into the live camera session.
struct GVSignalPathSettle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let start: Date
    let onFinished: () -> Void

    private let duration = 0.4

    var body: some View {
        Group {
            if reduceMotion {
                Color.clear
            } else {
                TimelineView(.animation(minimumInterval: 1 / 60, paused: false)) { timeline in
                    let progress = min(max(timeline.date.timeIntervalSince(start) / duration, 0), 1)
                    let energy = 1 - progress

                    ZStack {
                        GVScanlines(opacity: 0.10 * energy, frequency: 60, speed: 1.4)

                        ForEach(0 ..< 5, id: \.self) { index in
                            Rectangle()
                                .fill(.white.opacity(0.035 * energy))
                                .frame(height: 2 + CGFloat(index) * 1.4)
                                .offset(
                                    x: CGFloat(index.isMultiple(of: 2) ? 1 : -1) * energy * 14,
                                    y: CGFloat(index - 2) * 62
                                )
                        }

                        Rectangle()
                            .fill(GVTheme.violet.opacity(0.14 * energy))
                            .blendMode(.screen)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .accessibilityHidden(true)
        .task {
            try? await Task.sleep(for: .milliseconds(420))
            onFinished()
        }
    }
}
