import Foundation
import simd

/// A quiet breathing signal under the audio-reactive effects.
///
/// Those effects are driven entirely by the analyser, so in a quiet room — or
/// with the microphone off — they rendered the camera untouched and looked
/// broken. Each channel now floors at a slow, low-level breath: real sound
/// always wins (the input is the larger of the two), and silence shows the
/// effect's character at rest instead of nothing. The measurement scopes are
/// excluded on purpose — an instrument has to report silence as silence.
enum GVAudioIdle {
    struct Signal {
        var bands: SIMD4<Float>
        var dynamics: SIMD4<Float>
        var spectrum: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    }

    /// The floor at `time` (seconds on the effect clock): a 0.4 Hz breath,
    /// with a soft accent every 1.2 s — a slow pulse — so onset-driven
    /// effects still fire.
    static func floor(at time: Float) -> Signal {
        let breath = 0.5 + 0.5 * sin(time * 2.5)
        let phase = time.truncatingRemainder(dividingBy: 1.2) / 1.2
        let accent = exp(-phase * 10)
        var bins = [Float](repeating: 0, count: 16)
        for index in 0 ..< 16 {
            let tilt = 1 - Float(index) / 20
            bins[index] = (0.10 + 0.12 * breath * tilt + (index < 3 ? 0.25 * accent : 0)) * tilt
        }
        return Signal(
            bands: SIMD4(0.14 + 0.10 * breath + 0.2 * accent, 0.16 + 0.12 * breath + 0.35 * accent,
                         0.12 + 0.08 * breath, 0.10 + 0.06 * breath),
            dynamics: SIMD4(0.2 + 0.3 * accent, accent > 0.5 ? accent * 0.7 : 0, 0.3 * breath, 0),
            spectrum: (SIMD4(bins[0], bins[1], bins[2], bins[3]), SIMD4(bins[4], bins[5], bins[6], bins[7]),
                       SIMD4(bins[8], bins[9], bins[10], bins[11]), SIMD4(bins[12], bins[13], bins[14], bins[15]))
        )
    }

    /// The audio an effect should see: live audio, floored for effects that
    /// opt in.
    static func resolve(effect: WorkspaceAdjustableEffect, live: Signal, time: Float) -> Signal {
        guard effect.idlesOnAudioFloor else { return live }
        let idle = floor(at: time)
        return Signal(
            bands: simd_max(live.bands, idle.bands),
            dynamics: simd_max(live.dynamics, idle.dynamics),
            spectrum: (simd_max(live.spectrum.0, idle.spectrum.0), simd_max(live.spectrum.1, idle.spectrum.1),
                       simd_max(live.spectrum.2, idle.spectrum.2), simd_max(live.spectrum.3, idle.spectrum.3))
        )
    }
}

extension WorkspaceAdjustableEffect {
    /// Audio-driven looks that render nothing in silence. Scopes are left out.
    var idlesOnAudioFloor: Bool {
        WorkspaceAdjustableEffect.audioFamily.contains(self) && !isSpectrumOverlay
    }
}
