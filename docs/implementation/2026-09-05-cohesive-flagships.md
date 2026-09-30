# Cohesive polish and nine flagship effects

Approved scope: iPhone-first, preserve current layout/monochrome identity and all existing uncommitted work. Nine effects: CMYK Press, Spectral Diffraction, Reaction Garden; Vector Codebook, Motion Transplant, Bitplane Latch; Surface Relight, World Grid, Sonar Pulse. Preserve saved raw IDs/slot UUIDs, variant algorithms, preset and broadcast wire formats.

## Implementation ledger

Baseline: unsigned iPhone build and 91 simulator unit tests passed during planning. Snapshot of the original dirty production/test tree: /private/tmp/gv-nextlevel-implementation/baseline.tgz.

Ruling: work on a new codex branch in the current checkout because the approved baseline includes extensive uncommitted code; no unrelated changes will be reverted or committed. Parallel workers have exclusive file ownership.

| Work | Owner / interface | Status |
| --- | --- | --- |
| Camera kernels, simulation, resource requirements, enum registration | Camera worker owns renderer, CameraShaders, WorkspaceEffectParameters; root consumes new cases and requirements | Implemented |
| Depth kernels/runtime/deck/geometry | Depth worker owns Depth files, ARDepthFrameSource, UIShaders; root consumes catalog defaults | Implemented |
| Shared UI material/motion/ambient styling | UI worker owns DesignSystem and AppRootView; root consumes typed ambient API | Implemented |
| Canonical catalog, editor variants, browser/radial/broadcast, preset restoration | Root owns workspace/editor/preset files except depth deck and effect enum | Implemented |
| Integration, GPU/compatibility/unit/UI tests, physical checks where available | Root after workers finish; builds serialized | Implemented |

Ruling: performance claims require measurements; simulator and build evidence do not imply physical LiDAR or thermal verification. Use bounded effect resources and preserve capture dimensions. New simulation and render types stay internal; existing wire structures are unchanged.


## Delivered implementation

- Added CMYK Press (style 140), Spectral Diffraction (141), Reaction Garden (dedicated per-slot Gray–Scott stage), Vector Codebook (temporal 44), Motion Transplant (45), Bitplane Latch (46), Surface Relight (depth 17), World Grid (18), and Sonar Pulse (19). Existing raw IDs and shader modes retain their meaning.
- Reaction Garden has two RG16Float fields, a fixed bounded solver clock, deterministic camera/touch seeding, hold/reset behavior and per-slot ownership. Flow runs once for all motion consumers. Internal detail adapts with hysteresis; recording dimensions and effect selection stay intact.
- Flow, aged taps, timestamped history, shared composition history and slot state now allocate/update only for their declared consumers. Camera identity and source geometry changes reset temporal state. Pure shader and simulation stacks need no temporal image history.
- One catalog supplies canonical shelves, aliases, search, radial groups and broadcast descriptors. Variant changes preserve UUID, order, power, Blend and cached controls; disabled and duplicate family slots stay addressable. Legacy descriptors remain on the existing wire format.
- Shared surfaces, compact type roles and motion tokens retain existing geometry. Opaque Reduce Transparency fallback, Reduce Motion fades, stable borders, typed 4 Hz ambient sampling, narrower preview/chrome observers and paused inactive audio work reduce unnecessary updates.
- Parameter decks use shared descriptors; LiDAR acquisition gates occupy the next page. Preset previews restore the original composition on end, close and interruption. Search moves above the keyboard and dismisses it when choosing an effect.
- Brush input, Prediction Drift hold, Night Vision controls/grain, point-cloud controls, misleading luma labels, temporal preset summaries, Subject Decay attachment/history handling and invalid-depth camera fallback were repaired.
- LiDAR bounds in-flight submissions and skips repeated static frames. Calibrated world geometry drives relighting/grid/sonar without temporal history. Leaving Subject Decay releases its textures and segmentation state. World Grid suppresses degenerate axes on coplanar surfaces.

## Verification and installation

- 111 simulator unit/GPU tests passed on iOS 27, including zero-blend identity, finite/distinct output for all nine additions, invalid-depth/confidence fallback, Gray–Scott hold/evolution/independent slots, bounded simulation clock, adaptive quality hysteresis, family identity/undo, preset restoration/round trips and legacy broadcast descriptors.
- Portrait and both landscape capture controls passed UI checks. A search interaction test exposed keyboard occlusion; this was fixed and the current CMYK search/parameter checks pass. Both targeted UI tests passed after the fix, including CMYK selection/controls, legacy Kaleido6 search, family switching, and collapse/restore. Six fresh screenshot attachments were exported to /private/tmp/gv-nextlevel-implementation/ui/attachments/.
- Signed Debug iPhone build succeeded using the existing development team. Installed on Nick’s iPhone 17 Pro Max (DA48F3DB-C16D-5418-8CD4-428F8BB31168), bundle com.saringrey.greyvision. Automatic launch was refused because the phone was locked; installation itself succeeded.
- Build, install, launch and test logs: /private/tmp/gv-nextlevel-implementation/. Signed app: /private/tmp/gv-nextlevel-implementation/signed/Build/Products/Debug-iphoneos/GreyVision.app.
- Scoped SwiftFormat passed after formatting new modules/tests. SwiftLint reports five style warnings (brace/else placement), no errors in those files. Earlier failing UI runs stalled while collecting Xcode diagnostics and were terminated after their tests completed; later runs disable diagnostic collection.

### Limits of the evidence

Physical camera/LiDAR alignment, moving world anchors, sustained recording/thermal performance, device memory growth and measured before/after frame-rate gains have not been verified. Synthetic Metal fixtures validate rendering math and invariants, not AR tracking accuracy. iOS 18 deployment compatibility is retained but only the available iOS 27 simulator was exercised. Fresh portrait/both-landscape after captures are in the UI test attachments; the complete requested before/after accessibility screenshot matrix is not yet complete. Existing older Bootstrap UI cases use pre-baseline category/parameter identifiers and were not included in the targeted UI run. No claim of measured device speedup is made.
