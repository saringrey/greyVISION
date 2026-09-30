# Particle system — implementation notes

GPU particle family for the workspace: STATIC, EMBER, DUST, GLITCH.
Implemented 2026-09-21 as new files only; registry and render-loop wiring
is deferred (another agent owns those files right now).

## Files added

- `GreyVision/Engine/Particles/GVParticleEmitter.swift` —
  `GVParticleEmitterKind`: display names, details, per-emitter
  signal-routing docs, `requiresAudioAnalysis`, registry case-name anchors.
- `GreyVision/Engine/Particles/GVParticleParameters.swift` —
  `GVParticleParameterID`, the five clamped `ParameterDefinition`s,
  `GVParticleConfiguration.resolve(state:mix:)`.
- `GreyVision/Engine/Particles/GVParticleEngine.swift` —
  `GVParticleSignals` + `GVParticleSignalMailbox`, `GVParticle` /
  `GVParticleVertexData`, seeded `GVParticleRNG`, the CPU simulation.
- `GreyVision/Engine/Particles/GVParticleOverlayEffect.swift` —
  `RenderEffect` host: pipeline setup, `sync(from:)` deck bridge,
  per-frame `process`, fail-closed bypass.
- `GreyVision/Resources/Shaders/ParticleShaders.metal` —
  `gvParticleVertex` / `gvParticleFragment`: point sprites, additive
  blend, soft discs + hard squares.

No existing file was modified. `project.yml` includes `GreyVision`
recursively, so the new sources are picked up without project edits.

## The four emitters

- STATIC — TV snow / signal static. Particles live 1-3 frames and respawn
  constantly. Audio amplitude flickers brightness; transients pop the field.
- EMBER — rising sparks. Spawn along the bottom edge, accelerate upward
  with buoyancy, sway with turbulence. Bass energy boosts spawn rate and
  rise speed. LiDAR depth (where present) scales size: near embers larger.
- DUST — slow drifting motes. 8-16 s lifetimes, toroidal wrap, cool palette.
  Camera motion stirs the drift. No mic needed.
- GLITCH — pixel scatter. Near-silent baseline of hard squares; transients
  and camera motion fire bursts of 6-36 shards with teleport jitter. Built
  to pair with datamosh / temporal effects.

## Controls

Five normalized parameters, all clamped through `ParameterDefinition`
(0...1, so deck sliders, automation, and presets share the same bounds):

- `density` (DENSITY) — fraction of the device-scaled particle budget alive
- `size` (SIZE) — scales each emitter's base particle diameter
- `speed` (SPEED) — scales velocities and lifetimes
- `turbulence` (TURBULENCE) — sway / curl / teleport-jitter amplitude
- `glow` (GLOW) — particle alpha, premultiplied into the vertex color

Plus the slot's existing blend as global mix (vertex shader, on top of glow).

The deck exposes three sliders + blend per slot, so
`GVParticleOverlayEffect.sync(from:)` bridges primary -> density,
secondary -> size, tertiary -> speed. Turbulence and glow keep their tuned
defaults until the deck (or automation) addresses them directly — both are
modulatable through `parameterState`, so no deck change is needed on day one.

## Signals

Per frame the render loop publishes one `GVParticleSignals` into the
effect's `signalMailbox`:

```swift
particleNode.signalMailbox.publish(
    GVParticleSignals.from(
        audio: audioSnapshot,      // AudioReactiveSnapshot: rms/bass/transient
        motion: motionMagnitude,   // 0...1, from the motion field
        depth: normalizedDepth,    // 0 = near, 1 = far
        depthPresent: depthAvailable
    )
)
```

`process` additionally enriches `signals.motion` from
`request.frame.motionField.aggregateVector`, so dust stirs and glitch
bursts even if the wiring only publishes audio. Every signal field is
clamped 0...1 and NaN-proofed; `depthPresent == false` skips the depth
term entirely.

## Cost and count scaling

- Device capability: `GVParticleEngine.capacity(for:)` returns 4096
  particles on Apple7-family GPUs and newer, 2048 below. Density takes a
  fraction of that budget, so low-end devices degrade gracefully.
- Governor input: `qualityScale` (1 = full, 0.5 = reduced) halves the
  population target. Set from the render thread.
- Telemetry: `estimatedCostMilliseconds` is a rolling average of the
  simulation cost for the frame governor's adaptive budget. Static
  registry costs are listed under wiring section 1. `SHED n` telemetry
  already reads `CameraRenderStats.shedEffects` — no changes needed.
- Simulation is O(alive) with a tiny constant; vertex upload uses one
  shared buffer, no per-frame allocation.

## Deferred wiring (apply once the in-flight files are quiet)

Everything below touches files another agent is actively editing
(`WorkspaceEffectParameters.swift`, `EffectCatalog.swift`,
`CameraMetalSurface.swift`, tests). Do not apply early.

### 1. WorkspaceEffectParameters.swift — registry cases

Add four cases to `WorkspaceAdjustableEffect` (after `.reactionGarden`):

```swift
case particleStatic
case particleEmber
case particleDust
case particleGlitch
```

Then extend the computed properties (all additive case additions):

```swift
// label
case .particleStatic: "STATIC"
case .particleEmber: "EMBER"
case .particleDust: "DUST"
case .particleGlitch: "GLITCH"

// detail
case .particleStatic: "SIGNAL SNOW"
case .particleEmber: "RISING SPARKS"
case .particleDust: "DRIFTING MOTES"
case .particleGlitch: "PIXEL SCATTER"

// parameterLabels — fits the deck's three sliders
case .particleStatic, .particleEmber, .particleDust, .particleGlitch:
    ["DENSITY", "SIZE", "SPEED"]

// defaultCameraParameters — (primary, secondary, tertiary)
case .particleStatic: (0.55, 0.35, 0.5)
case .particleEmber: (0.5, 0.4, 0.55)
case .particleDust: (0.45, 0.3, 0.4)
case .particleGlitch: (0.5, 0.5, 0.5)

// requiresAudioAnalysis — dust is calm by design, no mic
case .particleStatic, .particleEmber, .particleGlitch: true

// estimatedCost — relative render cost for the governor
case .particleStatic: 1.1
case .particleEmber, .particleDust: 1.2
case .particleGlitch: 1.0
```

Placement — append to `defaultPlacementOrder` after `[.fluid, .reactionGarden]`:

```swift
public static let defaultPlacementOrder: [WorkspaceAdjustableEffect] =
    metalRenderOrder + temporalRenderOrder + [.fluid, .reactionGarden]
        + [.particleStatic, .particleEmber, .particleDust, .particleGlitch]
```

Particles render last: they are a composite overlay, like scopes. Keep the
disjointness invariant — the particle cases must appear in exactly one
placement list.

### 2. WorkspaceEffectParameters.swift — emitter mapping + active filter

On `WorkspaceAdjustableEffect`, next to `styleMode` / `temporalMode`:

```swift
var particleEmitter: GVParticleEmitterKind? {
    switch self {
    case .particleStatic: .staticNoise
    case .particleEmber: .ember
    case .particleDust: .dust
    case .particleGlitch: .glitch
    default: nil
    }
}
```

On `CameraEffectStackParameters`, next to `activeTemporalEffects`:

```swift
var activeParticleEffects: [(slot: CameraEffectSlot, effect: WorkspaceAdjustableEffect)] {
    slots.compactMap { slot in
        guard slot.effect.particleEmitter != nil, slot.effect.isEnabled else { return nil }
        return (slot, slot.effect)
    }
}
```

### 3. CameraEffectResourceRequirements.swift — resource flags

Add `.simulation` for the four cases (they hold simulation state, like
`.fluid` and `.reactionGarden`):

```swift
case .particleStatic, .particleEmber, .particleDust, .particleGlitch:
    requirements.insert(.simulation)
```

This file is not in flight, but the edit references enum cases that do not
exist yet — land it in the same commit as section 1.

### 4. EffectCatalog.swift — dock/shelf placement

Add a category array and a radial subcategory under the DECAY family
(thematic fit: digital decay):

```swift
public static let particleCategoryEffects: [WorkspaceAdjustableEffect] =
    [.particleStatic, .particleEmber, .particleDust, .particleGlitch]
```

- Append `particleCategoryEffects` to `decayCategoryEffects` (additive;
  keeps the `Set(displayed) == Set(effects)` test invariant intact).
- Add a "PARTICLES" entry to the DECAY branch of
  `curatedRadialSubcategories` so the pie menu shows all four.
- Optional: add an 11th dock shelf via `EffectCatalog.shelves`.

### 5. CameraMetalSurface.swift — render-loop branch

Cache one `GVParticleOverlayEffect` per slot UUID, mirroring however
temporal/style nodes are cached. Per active particle slot, once per frame
on the render thread:

```swift
let node = particleNode(for: slot.id, emitter: effect.particleEmitter!) // cached
node.sync(from: slot.parameters)          // deck sliders -> density/size/speed
node.qualityScale = adaptiveQualityScale  // 1 or 0.5 from the governor
node.signalMailbox.publish(GVParticleSignals.from(
    audio: audioSnapshot, motion: motionMagnitude,
    depth: normalizedDepth, depthPresent: depthAvailable))
try node.process(EffectRenderRequest(
    frame: frame, input: inputTexture, output: outputTexture,
    mix: slot.parameters.blend, mask: .none,
    parameters: node.parameterState))
```

Render particles after all other passes (overlay), inside the
processed-frame path so `GVVideoRecorder` captures them. On slot removal
call `node.reset(reason: .explicit)` then `releaseResources()`.
`node.estimatedCostMilliseconds` and `node.activeParticleCount` are
available for HUD/telemetry.

## Verify checklist

- `./scripts/verify.sh` passes (includes .swiftformat conformance).
- New .metal file compiles: `gvParticleVertex` / `gvParticleFragment`
  resolve from the library (fail-closed path covered if not).
- All four emitters visible in the dock/pie menu after wiring 1-4.
- Deck shows DENSITY / SIZE / SPEED sliders; blend drives global mix.
- Bypass (slot disabled or mix 0) forwards the frame unmodified.
- `reset(reason:)` clears particles on slot removal / source change.
- Audio-reactive: static flickers with music, ember follows bass, glitch
  bursts on transients.
- Recorded output (`GVVideoRecorder`) contains the particles.
- `SHED n` telemetry still reports; governor sheds particle slots under
  pressure per `estimatedCost`.
- Swift 6 strict concurrency: no new warnings from the particle files.

## Self-review (2026-09-21, no-compile)

- Every referenced symbol re-verified against the real sources:
  RenderEffect / RenderEffectKind.composite / EffectRenderFormat.pixelFormat /
  RenderPreparationContext / EffectRenderRequest / RenderEffectError
  (RenderEffect.swift); FrameContext.commandBuffer / safeDeltaTime /
  motionField (FrameContext.swift); MotionFieldSnapshot.aggregateVector
  (MotionField.swift); AudioReactiveSnapshot.rms / bass / transient
  (AudioReactiveRuntime.swift); ParameterDefinition init labels /
  EffectParameterState.setBaseValue / effectiveValue / subscript
  (ParameterDefinitions.swift).
- Swift entry-point names match the Metal functions exactly:
  gvParticleVertex, gvParticleFragment.
- Struct layouts match byte-for-byte: GVParticleVertexData (32 bytes) and
  GVParticleUniforms (16 bytes) mirror the Metal structs.
- No force unwraps on any runtime path; prepare throws RenderEffectError
  instead of trapping; process degrades to a pass-through blit when
  unprepared, disabled, or mis-sized.
- No existing files modified; no shared-file edits were safe to make
  (registry, catalog, renderer, and tests all in flight).
- Could not compile: no Xcode/xcodebuild on this path (device-only file
  access). The checklist above is the compile gate.
