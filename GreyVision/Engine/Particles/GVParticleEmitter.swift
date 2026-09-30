import Foundation

/// The four particle emitters that ship as first-class slot effects.
///
/// Each emitter is a GPU-rendered, CPU-simulated particle system that lives
/// in the processed-frame path (so realtime recording captures it) and is
/// driven by the workspace's existing slot parameters plus the app's live
/// signals (audio analyser, motion field, LiDAR depth).
///
/// The emitter deliberately carries no runtime state: it is metadata. All
/// simulation state lives in ``GVParticleEngine``, which is owned by
/// ``GVParticleOverlayEffect`` on the render thread.
enum GVParticleEmitterKind: String, CaseIterable, Identifiable, Codable, Sendable {
    /// TV snow / signal static. Constant respawn, 1-3 frame lifetimes.
    case staticNoise
    /// Rising sparks. Spawn along the bottom edge, accelerate upward.
    case ember
    /// Slow drifting motes. Long lifetimes, toroidal wrap, subtle motion.
    case dust
    /// Pixel scatter shards. Quiet baseline, hard-square bursts on transients
    /// and camera motion. Pairs with datamosh / temporal effects.
    case glitch

    var id: String { rawValue }

    /// Workspace slot label. Matches the all-caps deck convention.
    var displayName: String {
        switch self {
        case .staticNoise: "STATIC"
        case .ember: "EMBER"
        case .dust: "DUST"
        case .glitch: "GLITCH"
        }
    }

    /// Workspace slot detail line.
    var detail: String {
        switch self {
        case .staticNoise: "SIGNAL SNOW"
        case .ember: "RISING SPARKS"
        case .dust: "DRIFTING MOTES"
        case .glitch: "PIXEL SCATTER"
        }
    }

    /// Documents which live signals drive this emitter. Kept next to the
    /// kind so the wiring (and any future parameter deck) can show what
    /// "audio-reactive" actually means per emitter without digging into
    /// ``GVParticleEngine``.
    var signalRouting: String {
        switch self {
        case .staticNoise:
            "Audio amplitude flickers brightness; transients pop the field."
        case .ember:
            "Bass energy boosts spawn rate and rise speed."
        case .dust:
            "Camera motion stirs the drift. Calm by design, no mic needed."
        case .glitch:
            "Transients and motion bursts fire hard-square shards."
        }
    }

    /// Whether the emitter needs the microphone armed to behave as designed.
    /// Mirrors `WorkspaceAdjustableEffect.requiresAudioAnalysis`; the
    /// registry wiring should return `true` for the cases that return `true`
    /// here so the audio analyser arms when one of those slots is active.
    var requiresAudioAnalysis: Bool {
        switch self {
        case .staticNoise, .ember, .glitch:
            true
        case .dust:
            false
        }
    }

    /// Registry anchor: the `WorkspaceAdjustableEffect` case this emitter
    /// maps to once the wiring lands. Kept as a string on purpose so this
    /// file compiles before the enum cases exist.
    var workspaceEffectName: String {
        switch self {
        case .staticNoise: "particleStatic"
        case .ember: "particleEmber"
        case .dust: "particleDust"
        case .glitch: "particleGlitch"
        }
    }
}
