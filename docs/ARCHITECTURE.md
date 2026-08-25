# greyVISION Architecture

Rewritten 2026-08-19 from the source tree. The previous revision described
`MetalRenderer`, `RecordingController`, `EffectInstance`, `PresetDocument` and
`ModulationBinding` — none of which exist here — and put the effect count at
29 when the registry holds 133. Where this document and the code disagree, the
code is right and this file is a bug.

## Product boundary

iPhone-only, local-first realtime camera instrument. iOS 18+, Swift 6 with
`SWIFT_STRICT_CONCURRENCY: complete`, no third-party runtime dependencies.
112 Swift files / ~29,800 lines, plus ~4,000 lines of Metal across
`CameraShaders.metal` and `UIShaders.metal`.

## Routes

`AppModel` (`@MainActor`) owns the only route:

```
.gate  →  .boot  →  .workspace
```

`.gate` is a four-digit access ceremony (`GVAccessCode.value`, a compile-time
constant — it keeps a curious hand out, it is not a secret store). Launch
arguments: `--uitesting` starts at `.boot`; `--uitesting-workspace` and
`--skip-boot` start at `.workspace`.

## Capture sources

Three, mutually exclusive, all owned by `AppModel`:

| Mode | Owner | Backing |
|---|---|---|
| `.camera` | `CameraRuntime` → `CameraController` | AVFoundation |
| `.lidar` | `DepthRuntime` → `ARDepthFrameSource` | ARKit scene depth |
| `.objects` | `ARObjectRuntime` → `ARObjectSource` | ARKit world tracking |

Switching is transactional: the outgoing source is fully stopped before the
incoming one starts, and a failure restores the AVFoundation configuration that
was live before. The two ARKit sources and AVFoundation never contend for the
camera.

## Frame path

```
CameraController (serial session queue)
    → LatestCapturedFrameMailbox (capacity one, drops stale)
    → CameraMetalRenderer.draw()
        → YUV or synthetic → linear rgba16Float
        → RGB split pass          (own kernel)
        → style pass              (one mode-specialised kernel, A/B ping-pong)
        → fluid stage             (multi-pass, own velocity/dye/pressure grids)
        → temporal pass           (history-ring kernel)
        → signal fracture
        → sRGB preview + GVVideoRecorder
```

`CameraFrameTextureLease` retains the `CVPixelBuffer` and each `CVMetalTexture`
until the command buffer's completion handler fires. Two transient
`rgba16Float` textures ping-pong; one bounded history ring backs the temporal
nodes. Nothing in the loop allocates per frame.

### Concurrency

Every thread boundary in the app is the same shape: a small final class holding
an `NSLock` and one value, named `*Mailbox`. Capture never waits on rendering,
rendering never waits on SwiftUI, and analysers publish immutable timestamped
snapshots at bounded rates. There are 43 of these, all `@unchecked Sendable`.

That is a deliberate trade: strict concurrency is enabled project-wide and then
opted out of at each boundary, because the compiler cannot express "this is
mutated only on the render thread and read only under this lock". The pattern
is identical everywhere, which is what makes it reviewable. Adding a boundary
means adding another mailbox, not another mechanism.

### The frame governor

`adaptiveEffectDropCount()` watches a rolling GPU-time average. After six
consecutive frames over 16.6 ms it sheds one style effect, up to three, and
restores one after thirty consecutive frames under 12 ms — recovery is slower
than degradation on purpose, so the stack does not oscillate.

It sheds the **most expensive** effects and always leaves one standing, and the
count is published in `CameraRenderStats.shedEffects` so the telemetry strip
can print `SHED n`. Before 2026-08-19 it shed the cheapest and said nothing:
the operator paid the full visible cost of the drop, recovered almost no time,
and had no way to tell a shed from a broken effect.

## Effect model

`WorkspaceAdjustableEffect` — 136 cases:

- **92** with a `styleMode`: one mode-specialised compute kernel, ordered by
  `metalRenderOrder`.
- **39** with a `temporalMode`: history-aware kernel, ordered by
  `temporalRenderOrder`.
- **1** with its own kernel: `rgbSplit` (in `metalRenderOrder`, no `styleMode`).
- **1** multi-pass: `fluid`, a full Eulerian solve with persistent grids.
- **3** SwiftUI-only HUD overlays: `grid`, `scanlines`, `brackets`. These are
  composition objects, deliberately not camera pixels.

`CameraEffectStackParameters` is an ordered `[Slot]`, each slot carrying its own
`UUID`, so a second instance of an effect with different parameters is
representable and reorder/duplicate are data operations:

```swift
var orderedSlots: [Slot]
mutating func move(fromOffsets:toOffset:)
mutating func duplicate(_ id: Slot.ID) -> Slot.ID?
mutating func remove(_ id: Slot.ID)
mutating func setEnabled(_ enabled: Bool, slot id: Slot.ID)
```

**None of that API has a UI yet.** The subscript still reads and writes the
first slot for an effect, which is what every existing call site uses.

New slots are placed by `defaultPlacementOrder`, which is
`metalRenderOrder + temporalRenderOrder`. The two lists are disjoint and every
effect with a `styleMode` or `temporalMode` appears in exactly one of them;
`testEveryRenderableEffectHasExactlyOnePlacementRank` enforces both. This is
load-bearing — ranking against `metalRenderOrder` alone gave all 39 temporal
nodes the same fallback rank, which silently made their render order depend on
which one the operator tapped first.

Shader mode indices must be unique and contiguous from zero: the value indexes
a `switch` inside the Metal kernel, so a gap routes an effect to whatever the
default arm draws.

## Depth

`DepthCapability` checks `ARWorldTrackingConfiguration.isSupported` and
`supportsFrameSemantics` before the UI can offer depth; it prefers
`.smoothedSceneDepth` and falls back to `.sceneDepth`. The simulator reports an
explicit unsupported reason and never fabricates depth.

`DepthEffectMode` has 17 modes. Point Cloud reconstructs XYZ from metric depth
and scaled camera intrinsics, rejecting non-finite, non-positive and
low-confidence samples. Every composite mode shares metric near/far, confidence
and intensity controls; intensity zero returns the aligned camera image.

## Recording and capture

- `GVVideoRecorder` — `AVAssetWriter` over processed frames, adaptor-backed
  pixel buffer pool, original capture presentation timestamps.
- `GVScreenCapture` / `GVUIScreenRecorder` — captures including interface
  chrome, controlled by `GVPreferences.captureIncludesChrome`.
- `GVRealtimeRecordingSession` — the AR-object path.
- `GVPhotoLibrary` — Photos permission is requested only at save.

Record and Screenshot are live controls. Documentation describing them as
printing a "Gate 5 notice" is out of date.

## Design system

- `GVTheme` — six meaning-carrying colours and a `State → Color` map. One
  accent: `violet` means the operator selected this. `acid` means armed,
  `record` means recording or destructive, `warn` means genuinely degraded.
  A view reaching for an accent to look interesting is reaching for the wrong
  thing.
- `GVMotion` — the whole animation vocabulary, plus `resolved(_:reduceMotion:)`.
  Hardware does not bounce: springs are reserved for direct manipulation.
- `GVMetrics` — spacing scale, radii, control heights, the one hairline width.
- `GVDynamicType` — `.gvFont` / `.gvMono` / `.gvTerminal` resolve their size
  against `\.dynamicTypeSize` on a compressed scale topping out at 1.6.
  `AppRootView` clamps the environment at `.accessibility2`, once, because the
  top shell has a fixed hardware-free zone and the rails are sized to the frame.
- `GVTerminalControls` — the real instrument widgets: segmented and bipolar
  meters, angle scales, tick tracks, precision scrubbing, direct numeric entry.
  `GVTerminalParameterRow` reports itself to VoiceOver as the slider it behaves
  like via `accessibilityRepresentation`, with adjustments routed through the
  same `commit` path a scrub uses.

## Dock

Nineteen category families plus two shelves — `FAVOURITES` (starred, canonical
order) and `RECENTS` (last ten used, most recent first) — and a search field
matching effect names and descriptions. Search and the category rail are
mutually exclusive: a live query outranks the selected family. Experimental
families stay hidden behind the `EXPERIMENTAL` preference, and search honours
that rather than becoming a side door around it.

## Testing

- Unit: registries, parameter clamping, stack ordering and slot operations,
  depth geometry, horizon maths, codec mapping, capability filtering.
- Metal: deterministic textures, kernel presence, RGB displacement, style-pixel
  mutation, temporal history dependence, point-cloud geometry.
- UI: boot format dock, workspace layout in both landscapes, effect selection
  and live parameter scrubbing, LiDAR truthfulness on the simulator.

Custom scrub rows are driven in UI tests with a real horizontal drag
(`XCUIElement.scrub(by:)`), not `adjust(toNormalizedSliderPosition:)` — the
accessibility representation reports as a slider but carries no scrubber
geometry for XCUITest to synthesise against.

Back-to-back UI tests on one simulator can SIGTERM the fifth app launch. That
is simulator resource pressure, not a product failure; re-run the individual
test to confirm before chasing it.

## Capability policy

Baseline correctness is classic Metal and SDR. LiDAR depth, HDR/10-bit, ProRes,
ProRes RAW and MetalFX are runtime-gated, and diagnostics report what was
requested, what the active output advertises, and why anything is unavailable.
A missing advanced capability never makes the core instrument unusable, and no
effect, codec or readiness label is exposed without an implemented backing seam.
