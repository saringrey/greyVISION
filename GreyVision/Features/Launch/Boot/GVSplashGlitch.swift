import SwiftUI

/// Random, transient interface corruption.
///
/// Each element carries its own seed, so glitches fire at uncorrelated moments
/// rather than as a synchronised screen-wide stutter. Windows are short
/// (~120–260 ms) and rare, and the shader is bypassed entirely between them, so
/// the cost outside a glitch is a single `isEnabled: false` layer effect.
struct GVSplashGlitch: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Gates the ambient clock: a decoration that is not on screen should
    /// not be scheduling frames.
    @Environment(\.scenePhase) private var scenePhase

    /// Distinguishes elements so they do not corrupt in lockstep.
    let seed: Int
    /// Peak displacement, 0...1.
    var intensity = 1.0
    /// Average seconds between glitch windows.
    var period = 5.2
    var isEnabled = true

    func body(content: Content) -> some View {
        if reduceMotion || !isEnabled {
            content
        } else {
            TimelineView(GVAmbientClock.ambient(hertz: 30, scenePhase: scenePhase, isActive: isEnabled)) { timeline in
                let amount = GVSplashGlitch.amount(
                    at: timeline.date.timeIntervalSinceReferenceDate,
                    seed: seed,
                    period: period
                ) * intensity
                let time = Float(
                    timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 600)
                )

                // `visualEffect` exposes the geometry without a GeometryReader.
                // A GeometryReader here would claim all offered space and shove
                // every sibling out of position.
                content.visualEffect { view, proxy in
                    view.layerEffect(
                        ShaderLibrary.uiGlitch(
                            .float2(proxy.size),
                            .float(Float(amount)),
                            .float(Float(seed)),
                            .float(time)
                        ),
                        maxSampleOffset: CGSize(width: 48, height: 2),
                        isEnabled: amount > 0.004
                    )
                }
            }
        }
    }

    /// Envelope for the current moment. Zero for most of the cycle.
    static func amount(at time: TimeInterval, seed: Int, period: Double) -> Double {
        // Each element gets a phase offset and a slightly different period so
        // the whole screen never corrupts at once.
        let jitter = Double((seed &* 2_654_435_761) % 1000) / 1000
        let localPeriod = period * (0.7 + jitter * 0.9)
        let phase = (time + jitter * localPeriod).truncatingRemainder(dividingBy: localPeriod)

        // Cycles are skipped at random so the rhythm never becomes predictable.
        let cycle = floor((time + jitter * localPeriod) / localPeriod)
        let roll = GVSplashGlitch.hash(UInt64(bitPattern: Int64(cycle)) &+ UInt64(abs(seed)))
        guard roll > 0.42 else { return 0 }

        let window = 0.12 + roll * 0.14
        guard phase < window else { return 0 }

        // Sharp attack, ragged decay.
        let normalized = phase / window
        let envelope = normalized < 0.18
            ? normalized / 0.18
            : pow(1 - (normalized - 0.18) / 0.82, 1.7)
        let stutter = GVSplashGlitch.hash(UInt64(phase * 240) &+ UInt64(abs(seed))) > 0.25 ? 1.0 : 0.35
        return min(max(envelope * stutter, 0), 1)
    }

    private static func hash(_ value: UInt64) -> Double {
        let mixed = (value &* 6_364_136_223_846_793_005) &+ 1_442_695_040_888_963_407
        return Double((mixed >> 33) % 100_000) / 100_000
    }
}

extension View {
    /// Randomly corrupts this element with brief slice displacement and chroma
    /// separation. Use distinct seeds for neighbouring elements.
    func gvGlitch(
        seed: Int,
        intensity: Double = 1.0,
        period: Double = 5.2,
        isEnabled: Bool = true
    ) -> some View {
        modifier(
            GVSplashGlitch(
                seed: seed,
                intensity: intensity,
                period: period,
                isEnabled: isEnabled
            )
        )
    }
}
