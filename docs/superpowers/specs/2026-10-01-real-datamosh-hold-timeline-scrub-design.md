# Real Datamosh Expansion, Hold-While-Moshing, and Timeline Scrub Preview

Date: 2026-10-01
Status: approved design, pre-implementation
Branch: codex/cohesive-flagship-effects

## Goal

GreyVision's on-screen "mosh" is mostly a shader that computes a codec artefact. Five
codec-driven techniques already exist as real VideoToolbox behaviour, but only three
effects use them, the engine cannot stack, and the frame hold kills the mosh instead of
freezing the camera and letting the codec eat itself. This design makes the real thing the
headline feature, adds the Glitche interaction (hold the frame, the mosh keeps running),
and fixes timeline scrubbing.

## Current state (verified in code, not assumed)

- `GVDatamoshEngine` (Engine/Rendering/GVDatamoshEngine.swift) is a genuine live H.264
  encode→decode round trip: sync-sample suppression, access units withheld from the
  decoder while the encoder keeps predicting from them, and optional recursive re-encode.
- It is wired into the render loop by `encodeDatamoshPass`
  (CameraMetalSurface.swift:3047) and driven by `datamoshConfiguration` (:2986) for
  exactly three effects: `datamosh` (mode 4), `liquidMosh` (39), `heavyMosh` (40).
  `isCodecMoshMode` (:2974) gates it.
- The other mosh-named effects — `moshBrush` 41, `predictionDrift` 43, `vectorCodebook`
  44, `motionTransplant` 45, `bitplaneLatch` 46 — are shader block-transport
  simulations (`isMoshMode`, :2964).
- Frame freeze exists: when `temporalHoldActive`, the linear texture is reused and effects
  keep running (CameraMetalSurface.swift:1310). `holdStyle(for:)` (:1978) passes hold
  behaviour bits to the mosh shader.
- Recording audio already works: `CameraRuntime.swift:193` forwards mic sample buffers to
  `recordingMailbox.appendAudio`. The "microphone … not wired up" comment at
  GVCaptureWriter.swift:87 describes the legacy `GVVideoRecorder` and is stale.
- Timeline scrub is a stub: `storedTimelineForScrub()` returns `nil`
  (GVTimelinePlayer.swift:71), so scrubbing only works after a timeline has already been
  played. No offline re-renderer exists; `PerformanceRecorder` writes a sidecar that
  nothing reads.
- Nothing in the app uses `AVAssetReader`.

## Non-goals

- Offline re-render from the `PerformanceRecorder` sidecar. Deferred to its own design.
- Replacing the shader mosh modes. They stay and keep their look; they are not claimed to
  be codec-driven.
- Multi-peer or hardened transport changes.

## Design

### 1. One codec engine per effect slot

Today the renderer owns a single `GVDatamoshEngine` (CameraMetalSurface.swift:955,
created :1142). Two codec modes in the stack would share one encoder, one decoder, and one
staging ring, and `datamoshStalledSince` (:958) is renderer-global, so slot A's stall
timer forces slot B to emit a keyframe — stacking two codec modes today corrupts both.

- Move the engine onto the Slot node (`CameraRenderGraphNode`,
  CameraMetalSurface.swift:806-902 — already the owner of `moshStateA/B`, `moshStateReadsA`
  and `moshHistory`, with `reset`/`releaseResources` teardown paths to hang the engine on).
  Create it lazily when a codec mode occupies the slot; release it in those two methods.
- `datamoshEngine` is still a single `private let` on the renderer (:955, built :1142) and
  `setCodecActive` (:1444) is a one-boolean hardware-holding switch driven by "is any codec
  mode on screen". Both have to become per-slot; the single-boolean version cannot express
  "two slots want a codec, one of them cannot have it".
- Move the stall watchdog (`datamoshStalledSince`, :958) onto the slot with it.
- Cap live codec instances at two per renderer. Precedence is stack order: the two codec
  slots nearest the front of the effect stack keep the hardware. Deterministic beats
  "whichever slot allocated first this frame".
- **Correction made while implementing Task 1.** This section said a refused slot "falls back
  to the shader transport". That is not true of the three instruments that exist: all of them
  compose the decoder's reconstruction and nothing else (`CameraShaders.metal:3192`, `:3843`,
  `:3901`, each gated on `uniforms.mode.w == 1u`), and their block-state textures were
  deliberately removed from `isMoshMode` when they moved onto the codec. A refused slot
  renders the frame **whole**. Accepted rather than papered over: the refusal is counted in
  render stats so the operator can see that a stacked mosh mode is not running. Giving refused
  codec slots a genuine shader-mosh fallback is a separate, open decision — it means
  re-introducing block state for modes that no longer have it.
- Surface the fallback as a new `CameraRenderStats.codecMoshSlots` counter (live codec
  slots) beside the existing `shedEffects` field (:51), and show it in `GVTelemetryStrip`.
  An effect that quietly stops being codec-driven is exactly the kind of thing the operator
  should not have to infer from the picture.

### 2. Zero-copy staging — already implemented, verify only

Superseded during writing. `GVDatamoshEngine` now has `sharedStagingTexture(for:…)`
(GVDatamoshEngine.swift:1004) with a `#if targetEnvironment(simulator)` branch (:1008) that
returns nil and falls through to the CPU row copy, so the device path already hands the
encoder and Metal the same IOSurface, and the simulator crash described in the earlier
comment is already avoided.

What remains is verification, not construction: a test that asserts the device branch is
taken on a real device, and a measurement that two live instances stay inside frame budget.
If they do not, the instance cap from §1 is the lever, not a rewrite of staging.

Two related additions landed since the first read, and both change how new modes should be
built:

- `Configuration.codec` (`Codec` enum, :72-96) selects H.264 Baseline 3.1 (16×16 macroblocks,
  CAVLC, no B-frames — the instrument datamoshing was invented on) or HEVC Main (8×8 CTUs,
  stronger loop filter). Codec family is therefore already a real, exposed axis and a new
  effect may choose it rather than inherit H.264.
- Slider→codec intent moved onto the engine as
  `GVDatamoshEngine.configuration(variant:primary:secondary:tertiary:maximumEncodeEdge:)`
  (:110), with `enum Variant` (:98) listing the three instruments. New techniques are added
  by extending `Variant` and that function, which is testable with no camera, no view
  hierarchy, and no renderer — and `FlagshipRenderTests` already exercises it.

### 3. Five new codec techniques

Each is an encoder or decoder behaviour, not a computed artefact. Every new effect gets its
own mode number — no effect may share a mode, per the invariant recorded at
WorkspaceEffectParameters.swift:1285, where three effects once shared mode 4 and turned two
thirds of the rail into a relabelling.

| Effect | Technique | Real mechanism |
| --- | --- | --- |
| `chromaMosh` | Colour from the codec, detail from the camera | Decode to a 4:2:0 target and composite the decoder's chroma plane over clean camera luma. 4:2:0 chroma is what smears across whole macroblocks, so the bleeding is produced by quantisation, not by a filter. |
| `generationMosh` | Mosh of a mosh | Two chained round trips per frame: stage two encodes stage one's reconstruction, each with its own bitrate. The recursive re-encode that gives a mosh its melting tail. |
| `timeLoopMosh` | Drag across a time gap | The encoder predicts from a delayed frame taken from `CircularFrameHistory.frame(framesAgo:)` instead of the previous one, so motion vectors are applied against a reference from a real moment ago. |
| `beatGOP` | Corruption on the beat | `keyframeIntervalFrames` driven by `GVBeatDetector`: transients force sync samples, so the picture is repeatedly built up and released. Rate control is the thing being modulated. |
| `pFrameSplice` | The original datamosh edit | Parse the access unit, splice one frame's macroblock layer onto another frame's sync sample at NAL level, then decode. Highest authenticity, highest risk: it depends on how tolerant the hardware decoder is of hand-edited slices, and it must degrade to unmodified delivery rather than to a black frame. |

Numbering: these are **temporal** mode numbers, and the temporal table currently tops out at
46, so the five take 47-51. The style table independently uses 47-59 already
(`.halation: 47` at WorkspaceEffectParameters.swift:1166), so every new number has to be
checked against both tables — a collision between two switches that each start from their
own `default:` is silent, and the effect graph would run one kernel for two effects.
All eight codec-driven effects (three existing, five new) are added to
`isCodecMoshMode`, `temporalMode`, `freezesHistoryOnHold`, the parameter-label table,
`EffectCatalog` shelves, cost weighting, and the catalogues the Mac broadcast controller
reads.

### 4. Hold that keeps moshing

This is the Glitche interaction and the actual bug. Today the three codec modes are absent
from `freezesHistoryOnHold` (WorkspaceEffectParameters.swift:1803), so `freezeForEffect`
never becomes true for them. Worse: with the camera frame frozen and `recycle = 0`, the
encoder re-encodes the same clean still — no motion, no reference divergence — so the
codec converges and the mosh stalls. Only HEAVY MOSH with RECYCLE pushed to maximum
self-feeds, and only by accident of that slider.

- Add all eight codec effects to `freezesHistoryOnHold`.
- While held, the encoder's input is `latestDecodedFrame`, not the frozen camera frame: the
  codec eats its own reconstruction, so corruption compounds while the picture is frozen.
- Reference drops and rate starvation continue while held — the drag still runs.
- Beat-forced sync samples are suppressed while held. `beatGOP` would otherwise punch a key
  frame in on every transient and repair the very image the hold exists to consume; on a
  hold, the beat drives bitrate starvation instead of sync placement.
- The 0.4 s stall watchdog must not fire during a hold, or the hold repairs the image
  instead of consuming it.
- Releasing the hold forces a sync sample so the operator gets the live picture back
  immediately rather than waiting for a reference chain to expire.
- `chromaMosh` holds differently: its luma comes from the camera, so holding must freeze the
  luma source too, otherwise the colour keeps drifting over a live picture and the effect
  reads as broken rather than held.

### 5. Contextual hold gesture

The press-and-hold on the preview was deliberately deleted and replaced by an explicit
freeze toggle, "This replaces the undiscoverable hold gesture" (CameraRuntime.swift:382).
Restoring it must not re-create that problem.

- Long-press on the preview arms the hold only when at least one effect with
  `freezesHistoryOnHold` is in the stack — the case where holding means something. Tap to
  focus, pan, and the existing recognisers are untouched otherwise.
- A visible HOLD badge with elapsed seconds, driven by the `holdSeconds` the renderer
  already computes (:1351).
- `toggleFrameFreeze` stays as the discoverable route.

### 6. Timeline scrub that works, and shows a frame

- **Prerequisite zero — there is no scrub UI.** `GVTimelinePlayer.scrub(to:)`
  (GVTimelinePlayer.swift:63) has **zero call sites** in the app or the tests, and
  `GVTimelineBar.swift` contains no `DragGesture`, `onTapGesture`, or `gesture(` of any kind —
  its track (`:46-55`) is a decorative rounded rectangle, and the bar is play / mode / pick /
  save only. So "fix scrub" means building the interaction, not repairing it. A draggable
  playhead across the existing track, with tap-to-seek, and a VoiceOver adjustable action.
- **Prerequisite one — there is no media to read.** `GVTimeline` (GVTimelineStore.swift:76-88)
  stores a name, factory flag, capture format, base composition and keyframes, but no
  reference to any recorded file, and the finished take's URL is thrown away on the way
  through: `GVCaptureWriter.swift:293` nils `outputURL` before the completion handler fires,
  so `GVCaptureCoordinator.swift:530` reads nil and `handleResult` (:360) discards the path
  it did get. A scrub preview has nothing to open until that is fixed. So: stop niling the
  URL early, and surface the last completed take as an observable
  `lastCompletedTake: URL?` that the timeline bar can read.
- `storedTimelineForScrub()` returns the stored timeline instead of `nil`
  (GVTimelinePlayer.swift:70-72), so dragging the playhead applies keyframe state without
  requiring a prior play.
- Scrub preview: pull the single frame at the playhead out of that take with `AVAssetReader`
  (new `Engine/Capture/GVTakeFrameReader.swift`) and **substitute it as the render loop's source
  for that tick**, so the same single graph pass runs on recorded content. Deliberately not a
  second concurrent pass: every temporal node advances its own state once per pass
  (`moshStateReadsA.toggle()`, the `moshHistory` copy-back at `CameraMetalSurface.swift:1959-1969`),
  so a second pass would corrupt the live effect at double rate while the operator was merely
  inspecting a frame. The ingest branch at `:1310-1314` already substitutes a retained texture for
  a new camera sample, which is the precedent this follows. Nothing in the app reads media today —
  `AVAssetReader` has zero occurrences in sources.
- Consequence for the UI: while scrubbing the viewfinder shows recorded content, so it must say
  so — a SCRUB badge in the same slot and treatment as the hold badge, camera back the moment the
  playhead settles.
- A frame read costs real time (open the reader, walk from a sync sample), so requests are
  quantised, coalesced to the newest requested playhead, and abandoned in flight, never one read
  per drag event.
- The preview is a frame under the playhead, not a second timeline: no offline re-render.

### 7. Cleanup

Correct the stale "microphone … is not wired up" comment at GVCaptureWriter.swift:87 so it
says plainly that `GVVideoRecorder` is the legacy video-only path and the live recorder is
`GVRealtimeRecordingSession`.

## Error handling

- Every new codec path fails open to the un-moshed frame, never to black, and never throws
  a slot out of the graph. `pFrameSplice` in particular treats a splice the decoder
  rejects as "deliver the original access unit".
- Engine construction failure (`init?` already returns nil) disables that slot's codec
  mode for the session — the slot renders whole, once, without per-frame retries.
- Instance-cap fallback is reported through render stats, not silently absorbed.

## Testing

- `GVDatamoshEngine` takes an `MTLDevice` and has no renderer dependency, so
  encode-size quantisation, staging-ring reuse, hold→self-feed state transitions, and
  per-slot instance lifecycle plus the instance cap are real unit tests in GreyVisionTests.
- `pFrameSplice` gets a bitstream test that asserts a spliced unit still decodes to a
  non-black frame, and that a malformed splice falls back rather than killing the chain.
- `storedTimelineForScrub` and keyframe interpolation at a scrub time are tested against a
  stored timeline fixture.
- Visual truth cannot be established from a simulator: the IOSurface branch, real encoder
  behaviour, and hold-while-moshing need a physical iPhone, and "does it read as a real
  codec" is the operator's judgement, not a test assertion.

## Delivery phases

This is too much to land as one change, and three of the phases are independently
verifiable on your iPhone. Order is set by what unblocks what: the hold cannot work until
the engine is per-slot, and the two-instance budget cannot be trusted until staging is
zero-copy.

1. **Foundation** — engine per slot, per-slot stall watchdog, instance cap plus telemetry,
   IOSurface staging on device with the simulator copy as fallback. Ships the existing
   three modes stacking correctly, which they do not do today.
2. **Hold** — `freezesHistoryOnHold` for the codec modes, self-feeding encoder input while
   held, watchdog suppression, sync sample on release, contextual long-press with the HOLD
   badge. This is the Glitche interaction, and it is the reason the feature exists.
3. **New techniques** — `chromaMosh`, `generationMosh`, `timeLoopMosh`, `beatGOP`, each with
   its own sliders, labels, shelf placement, and Mac catalogue entry.
4. **Scrub** — `storedTimelineForScrub` fix and the `AVAssetReader` frame preview.
   Independent of phases 1-3 and can run in parallel.
5. **P-FRAME SPLICE** — last, deliberately. It is the most authentic and the only one whose
   success depends on undocumented decoder tolerance; it needs a real device in hand before
   it is worth any code, and the other four techniques do not.

## Files touched

- Engine/Rendering/GVDatamoshEngine.swift — per-instance lifecycle, IOSurface staging, new
  configuration intents, hold self-feed, NAL splice.
- Engine/Rendering/CameraMetalSurface.swift — engine moved onto the slot, instance cap,
  `isCodecMoshMode`, `datamoshConfiguration`, hold gating, stall watchdog per slot.
- Resources/Shaders/CameraShaders.metal — chroma composite, delayed-reference read,
  staging kernel for the new intents.
- Features/Workspace/WorkspaceEffectParameters.swift — five new cases, `temporalMode`,
  `freezesHistoryOnHold`, labels, cost weighting.
- Features/Workspace/EffectCatalog.swift — shelves, variants, defaults.
- Engine/Capture/CameraRuntime.swift + preview gesture host — contextual hold.
- Features/Workspace/GVTimelinePlayer.swift, GVTimelineStore.swift, GVTimelineBar.swift —
  scrub fix plus frame preview.
- New: Engine/Capture/GVTakeFrameReader.swift — `AVAssetReader` single-frame read.
- GreyVisionTests — engine and timeline tests.

## Appendix: registering one codec-backed effect

Written because the repo has already shipped an effect that existed in one table and not another
(two effects sharing temporal mode 4, and modes 37/38 that were listed with no shader arm and so
rendered as passthroughs). Every point below has to move together or the effect becomes a silent
half-effect, which is invisible from Swift alone.

Symbol names rather than line numbers: the line numbers in the original plan had already drifted by
the time the first technique was built.

| # | Where | What goes in |
| --- | --- | --- |
| 1 | `WorkspaceAdjustableEffect` | the `case` |
| 2 | `temporalRenderOrder` | position in the temporal chain. Must appear in `temporalRenderOrder` **or** `metalRenderOrder`, never both — `defaultPlacementOrder` adds both lists and an effect in both silently loses rank |
| 3 | `temporalMode` | next contiguous number from the top of the temporal table. **The style table is separate and already owns 47-59**, so a collision is silent: one kernel would serve two effects |
| 4 | `datamoshCategoryEffects` | shelf membership; feeds `timeCategoryEffects` |
| 5 | `curatedFamily`, `curatedCategoryEffectGroups` | family card; `repeatedCuratedCategoryEffects` fails on duplicate membership |
| 6 | `computedLabel`, `detail` | rail label and the one-line technical truth (e.g. `"H.264 REFERENCE DRAG"`) |
| 7 | `computedParameterLabels` | exactly three, or the registry test fails |
| 8 | `defaultCameraParameters` | defaults; `isEnabled` must stay false |
| 9 | `estimatedCost` | honest budget weight — `liquidMosh` is 2.4, the codec group 1.5, a two-stage cascade more |
| 10 | `freezesHistoryOnHold` | yes for every codec instrument, or the hold converges instead of compounding |
| 11 | `requiresAudioAnalysis` | only for a beat-driven instrument; a beat effect that never got audio is the failure mode to avoid |
| 12 | `curatedRadialSubcategories(for:)` `"TIME"` | shelf/rail membership list |
| 13 | `isCodecMoshMode` in `CameraMetalSurface.swift` | the new mode number, or the Slot never gets a round trip |
| 14 | `holdStyle(for:)` | the hold bits for the new mode |
| 15 | `GVDatamoshEngine.Variant` + `configuration(variant:…)` + `Variant(_ effect:)` | the slider→codec intent, and the effect→variant mapping |
| 16 | `gvCameraTemporalEffect`'s mode switch in `CameraShaders.metal` | a real arm, using the switch's own locals (`current`, `result`, `controls.x/y/z`, `uv`, gate `uniforms.mode.w == 1u`) |
| 17 | `CameraEffectResourceRequirements` | `.videoCodec`, plus `.slotHistory, .moshState` where a shader fallback still needs them |
| 18 | `GVEffectGlyph.kind(for:)` | glyph family |
| 19 | `EffectCatalog.variantGroups` | only if it is a variant of an existing card |

**Ordering constraint, learned the hard way:** `CameraEffectShaderCoverageTests` is **bidirectional**
— an arm with no Swift case fails it exactly as a Swift case with no arm does. So the Metal arm and
points 1-19 must land in one commit; an "engine and shader first, register later" split can only
carry the intent half (points 15's `Configuration` fields, `Variant` cases and slider mapping, which
are pure functions and testable with no camera, device or view).

**Nothing needs adding on the Mac:** `GVBroadcastControlCatalog` builds the desktop catalogue from
`WorkspaceAdjustableEffect.allCases` and `GVBroadcastControlBridge` resolves by `rawValue`, so a new
effect reaches the desktop automatically.
