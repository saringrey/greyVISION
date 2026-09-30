import Foundation

/// Stable parameter ids for the particle family. These ids are the contract
/// between ``GVParticleOverlayEffect``, its ``EffectParameterState``, and any
/// future parameter deck or automation: read them by id, never by position.
enum GVParticleParameterID {
    static let density = "density"
    static let size = "size"
    static let speed = "speed"
    static let turbulence = "turbulence"
    static let glow = "glow"
}

/// The five user-tunable particle parameters, fully clamped through
/// ``ParameterDefinition`` so every entry point (deck sliders, automation,
/// presets) gets the same bounds. All values are 0...1 normalized; the
/// engine maps them to physical ranges per emitter.
///
/// The workspace deck exposes three sliders plus blend per slot. The
/// ``GVParticleOverlayEffect/sync(from:)`` bridge maps the deck's
/// primary/secondary/tertiary onto density/size/speed; turbulence and glow
/// keep their tuned defaults until the deck (or automation) addresses them
/// directly. Nothing about that mapping changes these definitions.
enum GVParticleParameters {
    static let definitions: [ParameterDefinition] = [
        ParameterDefinition(
            id: GVParticleParameterID.density,
            displayName: "DENSITY",
            defaultValue: 0.55,
            minimum: 0,
            maximum: 1,
            unit: .normalized,
            importance: .primary,
            category: .primary
        ),
        ParameterDefinition(
            id: GVParticleParameterID.size,
            displayName: "SIZE",
            defaultValue: 0.35,
            minimum: 0,
            maximum: 1,
            unit: .normalized,
            importance: .standard,
            category: .primary
        ),
        ParameterDefinition(
            id: GVParticleParameterID.speed,
            displayName: "SPEED",
            defaultValue: 0.5,
            minimum: 0,
            maximum: 1,
            unit: .normalized,
            importance: .standard,
            category: .temporal
        ),
        ParameterDefinition(
            id: GVParticleParameterID.turbulence,
            displayName: "TURBULENCE",
            defaultValue: 0.4,
            minimum: 0,
            maximum: 1,
            unit: .normalized,
            importance: .advanced,
            category: .motion
        ),
        ParameterDefinition(
            id: GVParticleParameterID.glow,
            displayName: "GLOW",
            defaultValue: 0.7,
            minimum: 0,
            maximum: 1,
            unit: .normalized,
            importance: .standard,
            category: .color
        ),
    ]

    static func definition(id: String) -> ParameterDefinition? {
        definitions.first { $0.id == id }
    }
}

/// The engine's per-frame view of the user parameters. Resolved once per
/// frame from an ``EffectParameterState`` so the simulation never reads raw
/// slider values.
struct GVParticleConfiguration: Equatable, Sendable {
    /// 0...1. Fraction of the device-scaled particle budget that is alive.
    var density: Float = 0.55
    /// 0...1. Scales each emitter's base particle diameter.
    var size: Float = 0.35
    /// 0...1. Scales velocities and lifetimes.
    var speed: Float = 0.5
    /// 0...1. Scales curl / sway / teleport-jitter amplitude.
    var turbulence: Float = 0.4
    /// 0...1. Scales particle alpha (premultiplied in the vertex color).
    var glow: Float = 0.7
    /// 0...1. Global slot mix, applied in the vertex shader on top of glow.
    var mix: Float = 1

    /// Resolves every field through its ``ParameterDefinition`` clamp. Any
    /// parameter missing from `state` falls back to the definition default,
    /// so partial states (for example the deck's three-slider bridge) stay
    /// well-defined.
    static func resolve(state: EffectParameterState, mix: Float) -> GVParticleConfiguration {
        func value(_ id: String) -> Float {
            guard let definition = GVParticleParameters.definition(id: id) else { return 0 }
            return state.effectiveValue(for: definition)
        }
        let mixValue = mix.isFinite ? mix : 1
        return GVParticleConfiguration(
            density: value(GVParticleParameterID.density),
            size: value(GVParticleParameterID.size),
            speed: value(GVParticleParameterID.speed),
            turbulence: value(GVParticleParameterID.turbulence),
            glow: value(GVParticleParameterID.glow),
            mix: min(max(mixValue, 0), 1)
        )
    }
}
