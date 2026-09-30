import SwiftUI

/// CRT synchronisation pass.
///
/// A thin purple-white calibration beam travels down the frame. Everything it
/// crosses briefly gains contrast, and a single-frame chromatic separation
/// follows immediately behind it before the frame locks.
struct GVSyncSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Gates the ambient clock: a decoration that is not on screen should
    /// not be scheduling frames.
    @Environment(\.scenePhase) private var scenePhase

    let isActive: Bool
    let start: Date

    var body: some View {
        if reduceMotion || !isActive {
            Color.clear
        } else {
            GeometryReader { geometry in
                TimelineView(GVAmbientClock.ambient(hertz: 60, scenePhase: scenePhase, isActive: isActive)) { timeline in
                    let progress = GVSyncSweep.progress(from: start, now: timeline.date)
                    let height = geometry.size.height
                    let beamY = height * progress

                    ZStack(alignment: .top) {
                        // Leading edge: contrast lift just ahead of the beam.
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.05), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 96)
                        .offset(y: max(beamY - 78, -96))

                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        .clear,
                                        BootPalette.glow.opacity(0.85),
                                        .white,
                                        BootPalette.glow.opacity(0.85),
                                        .clear
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(height: 1.4)
                            .shadow(color: BootPalette.glow.opacity(0.5), radius: 4)
                            .offset(y: beamY)
                            .opacity(progress >= 1 ? 0 : 1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .blendMode(.screen)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    static func progress(from start: Date, now: Date) -> Double {
        min(max(now.timeIntervalSince(start) / GVBootTiming.sweepSeconds, 0), 1)
    }

    /// Chromatic separation amount for the frame immediately after the sweep.
    static func chromaticAmount(from start: Date, now: Date, isActive: Bool) -> Double {
        guard isActive else { return 0 }
        let elapsed = now.timeIntervalSince(start)
        let window = GVBootTiming.sweepSeconds
        guard elapsed >= window, elapsed < window + 0.07 else { return 0 }
        return 1 - (elapsed - window) / 0.07
    }
}

/// Applies the single-frame RGB separation produced by `GVSyncSweep`.
struct GVChromaticLock: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Gates the ambient clock: a decoration that is not on screen should
    /// not be scheduling frames.
    @Environment(\.scenePhase) private var scenePhase

    let isActive: Bool
    let start: Date

    func body(content: Content) -> some View {
        if reduceMotion || !isActive {
            content
        } else {
            TimelineView(GVAmbientClock.ambient(hertz: 60, scenePhase: scenePhase, isActive: isActive)) { timeline in
                let amount = GVSyncSweep.chromaticAmount(
                    from: start,
                    now: timeline.date,
                    isActive: isActive
                )
                content
                    .layerEffect(
                        ShaderLibrary.bootChromaShift(.float(Float(amount))),
                        maxSampleOffset: CGSize(width: 5, height: 0),
                        isEnabled: amount > 0.001
                    )
            }
        }
    }
}

extension View {
    func gvChromaticLock(isActive: Bool, start: Date) -> some View {
        modifier(GVChromaticLock(isActive: isActive, start: start))
    }
}
