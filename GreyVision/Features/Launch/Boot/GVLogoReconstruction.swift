import SwiftUI

/// Reconstructs the existing grey//VISION mark instead of fading it in.
///
/// The stages are produced by the `bootReconstruct` Metal layer effect so the
/// mark is assembled with the same vocabulary the camera engine uses:
/// point cloud, wireframe, broken raster blocks, datamosh displacement and a
/// short pixel-sort streak before the clean logo resolves.
struct GVLogoReconstruction<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Set once the materialisation phase has begun.
    let isActive: Bool
    /// Start of the materialisation phase.
    let start: Date
    @ViewBuilder let content: Content

    var body: some View {
        if reduceMotion || !isActive {
            content.opacity(isActive ? 1 : 0)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 60, paused: false)) { timeline in
                let progress = GVLogoReconstruction.progress(from: start, now: timeline.date)
                let time = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 60)

                content
                    .layerEffect(
                        ShaderLibrary.bootReconstruct(
                            .float2(size),
                            .float(Float(progress)),
                            .float(Float(time))
                        ),
                        maxSampleOffset: CGSize(width: 38, height: 22)
                    )
                    .opacity(min(0.25 + progress * 1.4, 1))
                    .scaleEffect(1 + (1 - progress) * 0.012)
            }
        }
    }

    /// Reconstruction progress. Eased so the final lock-in feels mechanical.
    static func progress(from start: Date, now: Date) -> Double {
        let raw = min(max(now.timeIntervalSince(start) / GVBootTiming.reconstructionSeconds, 0), 1)
        return raw * raw * (3 - 2 * raw)
    }

    /// The layer effect needs the view size in points; the mark is laid out by
    /// `BootView` so a fixed reference size keeps the shader stable across
    /// device classes without an extra `GeometryReader` pass.
    private var size: CGSize {
        CGSize(width: 512, height: 360)
    }
}
