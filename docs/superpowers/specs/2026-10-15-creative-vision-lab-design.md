# Creative Vision Lab Design

**Date:** 2026-10-15
**Status:** Approved in conversation; awaiting written-spec review
**Quality bar:** Flagship

## Goal

Add a first-class **Vision** effect shelf to grey//VISION and turn the existing blob analyzer into stable, production-quality tracking. The first release ships four creative, recordable looks driven by real computer-vision analysis while keeping detection boxes, labels, and landmarks out of saved output.

## Product decisions

- The feature is a creative Vision lab, not a utility scanner.
- The first shelf contains exactly four effects: Field Warp, Subject Echo, Face Prism, and Attention Bloom.
- Detection diagnostics remain an optional preview HUD and are never baked into photos, recordings, or broadcasts.
- Effects automatically request the analysis they need; creators do not have to start a detector first.
- No OCR, barcode scanning, custom Core ML model, or general object classifier is part of this release.
- The existing camera, effect stack, saved effect identity, capture, and broadcast behavior remain intact.

## User experience

### Vision shelf

Add `WorkspaceDockCategory.vision` and a corresponding `EffectCatalog` shelf labeled `VISION`. Place it with the other effect families in the browser; keep `objects`, `blobs`, and `lidar` as capture modes outside the browser.

The shelf contains:

| Effect | Analysis | Visual behavior | Parameters |
|---|---|---|---|
| **Field Warp** | Stable color-blob tracks | Bends and ripples the frame around tracked color fields | Hue, Selectivity, Force |
| **Subject Echo** | Person segmentation | Leaves masked temporal silhouettes while the background stays live | Trail, Offset, Decay |
| **Face Prism** | Face landmarks | Anchors refractive RGB fractures to detected faces | Refraction, Spread, Response |
| **Attention Bloom** | Attention saliency | Blooms and melts visually dominant image regions | Focus, Glow, Drift |

Every effect retains the existing fourth Blend control supplied by the shared parameter deck.

### States

The parameter deck presents one quiet analysis state:

- **Searching** — analysis is running but no usable target is present.
- **Tracking** — at least one current target is driving the effect.
- **Limited** — the request failed or the current device/runtime cannot provide a usable result.

These states must not produce repeated alerts. With no target, each effect becomes a clean pass-through at its current Blend rather than holding stale geometry or imagery.

### Tracking HUD

The existing Tracking capture mode remains available as a diagnostic overlay. It may draw boxes and procedural labels over the preview, but the overlay stays outside the Metal output and therefore outside photos, recordings, and broadcasts.

When Field Warp is active, its Hue and Selectivity values are the blob analyzer's active color profile. The tracking deck continues to own the advanced Cell Size and Min Area controls. Both surfaces update the same tracker; they do not create competing analyzer instances.

### Thumbnails

`GVEffectThumbnailStore` supplies deterministic sample analysis data:

- stable blob centers for Field Warp,
- a generated person mask for Subject Echo,
- fixed face bounds and landmarks for Face Prism,
- a generated grayscale saliency mask for Attention Bloom.

The thumbnails must show the actual effect kernels rather than generic placeholders and must not depend on a live camera or Vision request.

## Architecture

### UI-facing runtime

Introduce `@MainActor @Observable final class VisionRuntime` as the UI-facing owner of computer-vision state. It exposes:

- current demand,
- published blob tracks for the optional HUD,
- per-analysis state (`idle`, `searching`, `tracking`, `limited`),
- blob tuning parameters,
- start/stop/reset lifecycle operations.

`AppModel` owns one `VisionRuntime` for the workspace lifetime. The runtime replaces `BlobTrackingRuntime` rather than adding a second camera-frame consumer.

### Demand model

Define a `VisionDemand` option set with independent requirements:

- `blobs`
- `personMask`
- `faceLandmarks`
- `saliency`
- `trackingHUD`

Each Vision effect has one explicit requirement mapping. The active effect stack and HUD toggle resolve into a single demand value. An analyzer starts only while its bit is present and stops promptly when demand disappears.

### Analysis coordinator

A non-UI `VisionAnalysisCoordinator` is the sole consumer of camera analysis frames. The camera callback performs only a synchronous latest-frame publish. Long-running analysis happens on dedicated workers and never on the capture callback or main actor.

Each analyzer has:

- a latest-frame mailbox,
- at most one in-flight request,
- a minimum cadence,
- no catch-up behavior,
- a latest-result mailbox.

If a request takes longer than its interval, the next request starts from the newest available frame after completion. Frames are dropped by design; no analysis backlog is allowed.

### Snapshot boundary

The coordinator publishes an immutable `VisionSnapshot` containing:

- stable blob tracks,
- up to two ranked face observations with bounds and required landmark points,
- latest person mask plus sequence number,
- latest saliency mask plus sequence number,
- monotonic timestamps and per-result age,
- request latency and status.

Pixel-buffer observations use a narrowly scoped unchecked-Sendable wrapper, matching the existing capture and mask boundaries. The wrapper only transfers immutable ownership of the latest buffer; mutation remains prohibited.

SwiftUI reads published summaries through `VisionRuntime`. Metal reads the lock-backed snapshot mailbox directly, so rendering never waits on a main-actor update.

## Vision requests

The deployment target is iOS 18, so new camera analysis uses Swift-native Vision requests with async/await:

- `GeneratePersonSegmentationRequest` with `.balanced` quality,
- `DetectFaceLandmarksRequest`,
- `GenerateAttentionBasedSaliencyImageRequest`.

The existing legacy person analyzer used by the separate LiDAR renderer is outside this change unless sharing the new implementation proves behavior-preserving during implementation.

Captured-frame orientation and mirroring must be carried into every request. Results are converted into the delivered, interface-oriented camera coordinate space before publication.

## Blob detection and tracking

The current tracker identifies a blob by hashing its current rectangle, so ordinary movement changes identity and labels. Replace that behavior with a detector/tracker split whose core is independent of camera APIs and unit-testable.

### Detection

For each accepted frame:

1. Sample the bi-planar YUV buffer on the configured grid.
2. Convert samples using the buffer's declared color range and the appropriate YCbCr conversion coefficients.
3. Classify cells with circular hue distance, saturation gating, and the active selectivity value.
4. Remove isolated one-cell noise and close one-cell gaps.
5. Build components with an eight-neighbor flood fill.
6. Reject components below Min Area and rank the remainder by area and confidence.

The detector emits raw observations containing bounds, centroid, mean color, area, and confidence. It does not assign persistent IDs.

### Temporal association

The tracker maintains at most 12 tracks. For every update it predicts each track's next center from velocity, then scores observation/track pairs using:

- predicted center distance: 45%,
- inverse rectangle overlap: 30%,
- circular hue/color distance: 15%,
- logarithmic area change: 10%.

Pairs outside the distance/color gate are discarded. Remaining pairs are assigned deterministically from lowest cost upward. Matched geometry uses exponential smoothing (`0.42` for center/size, `0.30` for color); velocity is updated from the unsmoothed observation delta.

A new observation must be present for two consecutive updates before publication. A matched track gains confidence; a missed track loses confidence and is removed after four missed updates. During that grace period its published strength fades, allowing a brief occlusion without a label jump. On merges the best-cost existing track keeps its ID; on splits unmatched branches become new tracks after the two-hit confirmation.

IDs are monotonic for the runtime session. Procedural labels derive from the stable track ID, so a moving field keeps its designation.

### Cadence

- Blob detection/tracking: up to 12 Hz.
- Face landmarks: up to 10 Hz.
- Person segmentation: up to 10 Hz.
- Attention saliency: up to 4 Hz.

Cadence is a ceiling, not a timer that creates queued work.

## Renderer integration

Extend the existing render settings with:

- up to four stable blob fields including strength,
- packed face bounds/landmark data for up to two faces,
- a person-mask texture and readiness flag,
- a saliency-mask texture and readiness flag.

Mask pixel buffers become Metal textures through the renderer's existing texture cache on the render queue. The renderer retains only the latest texture for each mask sequence.

- Field Warp is a style pass using blob uniforms.
- Subject Echo is a temporal pass using the frame-history ring and person mask.
- Face Prism is a style pass using face uniforms.
- Attention Bloom is a style pass using the saliency texture.

Allocate new render modes through the existing registration checklist. The style and temporal mode spaces are independent and must remain contiguous and collision-free under tests.

Results older than their analyzer-specific freshness window fade to zero. A camera switch, interruption, workspace exit, or background transition clears all snapshots and temporal Vision state.

## Performance and telemetry

Vision analysis is completely decoupled from the full-rate Metal loop. The renderer always uses the newest available snapshot and never waits for analysis.

Add telemetry for:

- active Vision demand,
- latency per analyzer,
- age of each consumed result,
- number of published blob and face tracks,
- dropped analysis submissions,
- limited/error state.

When all four effects are stacked, each analyzer still allows only one request in flight. Thermal or slow-request pressure reduces analysis freshness rather than camera or recording frame rate.

The feature is acceptable only if real-device use shows stable preview and recording behavior. Simulator success is not evidence of Vision quality or performance.

## Failure behavior

- No target: pass through and report Searching.
- Brief target loss: fade confidence during the four-update grace period.
- Sustained target loss: remove the target and stop applying its contribution.
- Request error: log the concrete error once per state transition, clear stale output, and report Limited.
- Camera interruption or source change: cancel/stop workers, clear mailboxes, and restart only when camera demand resumes.
- Unsupported input format: report Limited for the dependent analyzer without disabling unrelated effects.

No Vision failure may stop capture, recording, broadcasting, or an unrelated effect.

## Testing

### Unit tests

- YUV cell classification across hue wrap-around, saturation floor, and selectivity limits.
- Noise removal and one-cell gap closing.
- Eight-neighbor component extraction and area filtering.
- Stable ID during translation, scale change, and color drift.
- Short occlusion retention and sustained-loss removal.
- Merge/split identity behavior.
- Deterministic maximum-track ranking.
- Demand resolution from effect stacks and HUD state.
- Result freshness and stale fade.
- Vision effect parameter labels/defaults and category membership.
- Unique, contiguous render modes and Swift/Metal coverage.

### Integration tests

- Real test pixel buffers exercise person, face, and saliency adapters where Vision is available; otherwise tests skip with an explicit capability reason.
- Snapshot publication never blocks frame submission.
- Starting/stopping demand resets state and does not leave workers active.
- Deterministic thumbnail fixtures render every Vision effect.

### UI and accessibility tests

- Vision appears in the effect browser and exposes exactly four effects.
- Selecting each effect opens the parameter deck and auto-arms its analysis.
- Searching, Tracking, and Limited states are accessible without relying on color.
- The optional tracking HUD remains preview-only.
- Touch targets, Dynamic Type, VoiceOver labels, and Reduce Motion behavior remain valid.

### Real-device verification

On Nick's iPhone 17 Pro Max:

1. Exercise all four effects with front and rear cameras.
2. Verify target acquisition, motion, occlusion, camera switching, and background recovery.
3. Stack all four effects and inspect analysis latency, result age, render cadence, and thermal behavior.
4. Record and play back video with each effect and the full stack.
5. Capture stills and verify no diagnostic HUD is baked into output.
6. Install the verified signed build.

## Delivery constraints

At design time:

- The current working tree passes an unsigned iPhoneOS build.
- Signed build fails because Xcode-beta has no active account/profile for `com.saringrey.greyvision`.
- Nick's iPhone is currently reported unavailable.

Before the installation step, connect and unlock Nick's iPhone and sign `glassxxhouse@gmail.com` into Xcode-beta. Keep `DEVELOPMENT_TEAM` set to `L8V6HKA9MZ`; do not substitute the certificate common-name identifier.

## Out of scope

- OCR and document recognition.
- Barcode scanning.
- General object detection/classification.
- Custom Core ML models.
- Baked diagnostic overlays.
- LiDAR-person analyzer migration unless it is demonstrably behavior-preserving.
- Unrelated effect-browser redesign or renderer refactoring.
