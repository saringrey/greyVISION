# greyVISION Current State

Last updated: 2026-08-19.

Rewritten from the tree. The previous revision was dated 2026-08-13 and had
drifted badly: it reported 29 camera effects against a registry of 133, and
described Record and Screenshot as printing a Gate 5 notice when
`GVCaptureWriter`, `GVScreenCapture` and `GVRealtimeRecordingSession` were all
implemented and wired. A document that is confidently wrong costs more than no
document, so treat this one as a claim to re-check rather than a fact.

## Evidence levels

- `BUILD` — compiler and linker succeeded.
- `TEST` — automated unit or UI tests succeeded.
- `SIM` — launched and inspected against the deterministic simulator source.
- `DEVICE` — exercised with physical camera, audio or depth hardware.
- `TRACE` — Instruments or MetricKit evidence captured.

Evidence is never promoted across levels. A simulator pass does not satisfy a
device gate.

## Where this actually stands

**Almost nothing here has been exercised on hardware.** The suite is green and
every commit builds and installs, but "installed" means "it built". No camera,
recording, gesture or boot path has been driven by hand on a device since the
instrument overhaul. That is the single largest gap in this project and no
amount of green simulator output closes it.

### Verified 2026-08-19

- 25 unit tests and 5 UI tests pass on iPhone 17 Pro Max / iOS 26.5 simulator.
  That suite was 21 tests with 10 failures at the start of the day.
- Generic `iphoneos` Debug build passes.
- `swiftformat --lint .` passes for whitespace, indent and import order.
  `.swiftformat` now pins `--swiftversion 6.0` and disables the rules this
  codebase violates on purpose. There was no config before, so both formatters
  ran on defaults and a default run rewrote 67 of 115 files.

### Fixed 2026-08-19

- **Temporal render order.** `insertInPipelineOrder` ranked new slots against
  `metalRenderOrder` alone. All 39 temporal effects are absent from that list,
  so each took the same fallback rank, tied, and fell back to tap order — TRAILS
  then ECHO rendered differently from ECHO then TRAILS. `temporalRenderOrder`
  had no remaining references anywhere in the tree. Slots now rank against
  `defaultPlacementOrder`, and a structural test asserts every effect with a
  `styleMode` or `temporalMode` has exactly one placement rank.
- **The frame governor shed the wrong effects.** Within the style pass costs are
  only 1.0 or 1.4, so `dropCheapest` removed the cheap nodes: full visible cost,
  almost no milliseconds recovered, and only an `os_log` line to explain it. It
  now sheds the most expensive, always leaves one effect standing, and publishes
  the count so the telemetry strip prints `SHED n`.
- **Dynamic Type.** 69 call sites moved onto `.gvFont` / `.gvMono` /
  `.gvTerminal`, which scale against `\.dynamicTypeSize` on a compressed curve
  topping out at 1.6, clamped once at the root to `.accessibility2`. Before
  this the smallest label was a fixed 5.2pt.
- **`GVTerminalParameterRow` is a slider to VoiceOver.** It reports through
  `accessibilityRepresentation`, with adjustments routed through the same
  `commit` path a finger scrub uses.
- **Effect discoverability.** A search field over name and description, and a
  `RECENTS` shelf holding the last ten effects used.
- **2,445 dead lines removed**, four files of which were excluded from the
  target rather than deleted. Recoverable at tag `pre-fixall-20260819`.
- **`scripts/` restored** — `verify.sh`, `run-simulator.sh`,
  `stop-simulator.sh`, `install-iphone.sh`. `docs/GOD_MODE.md` had documented
  these all along without them existing in the tree.
- **`docs/GOD_MODE.md` deleted.** It described a scene conductor with an atom
  control in the workspace header, six deterministic scene banks and an
  `APEX / BALANCED / SURVIVAL` governor. Grep finds no God Mode source anywhere
  in this tree. The document described a feature that does not exist, which is
  worse than describing none. Recoverable at tag `pre-fixall-20260819`.

## Implementation ledger

| Gate | State | Evidence |
|---|---|---|
| 0 — Bootstrap | Verified | XcodeGen generation; whitespace lint clean; simulator unit + UI suite green; generic `iphoneos` build passes. |
| 1 — UI | Verified (`BUILD`, `TEST`, `SIM`) | Gate → Boot → Workspace state machine; splash sequence; Dynamic-Island-aware top shell; collapsed Camera/Settings decks; dock with nineteen families plus favourites, recents and search; typed parameter decks; Reduce Motion honoured throughout. |
| 2 — Camera | Implemented; `DEVICE` pending | Serial session owner; permission on start; native bi-planar YUV; 4K-or-higher format filter; capability-resolved 30/60/120; focus/zoom/exposure/WB/torch/position/lens; interruption and media-reset recovery; scene cleanup. Physical colour, orientation and lifecycle proof outstanding. |
| 3 — Metal | Implemented; device identity comparison pending | Capacity-one mailbox; texture-cache plane mapping; metadata-driven conversion to `rgba16Float`; retained `CVMetalTexture` leases; reusable ping-pong surfaces; raw fallback. |
| 4 — Graph/FX | Broad implementation; gate pending | 133 renderer nodes with clamped parameters, enable/bypass/reset and stable ordering. Slot model supports reorder and duplicate as data operations; **no UI drives it yet**. |
| 5 — Capture | Implemented; `DEVICE` pending | `GVVideoRecorder`, `GVScreenCapture`, `GVRealtimeRecordingSession`, `GVPhotoLibrary`. Recorded-pixel parity and playback validation are unproven. |
| 6 — Temporal | Partial | One bounded history ring drives Feedback, Trails, Echo, Freeze and live motion-gated Datamosh. Long-duration memory evidence outstanding. |
| 7 — Audio/Modulation | Partial | `AudioReactiveRuntime`, `GVSignal`, `GVSoundEngine` present and wired to audio-reactive effects. Not gate-verified. |
| 8 — Vision | Partial | `VisionPersonMaskAnalyzer`, `BlobTracking` present. Not gate-verified. |
| 9 — Depth | Broad implementation; verification deferred | Exclusive AVFoundation→ARKit switch; real scene depth and confidence; 17 modes; XYZ reconstruction with invalid-sample rejection. Physical LiDAR pixels not yet observed. |
| 10 — Particles | Pending | — |
| 11 — Harden | Pending | — |

## Known limits

- **The provisioning profile expires 2026-08-25 16:32 UTC.** A signed build was
  made and installed on the Gate 2 iPhone on 2026-08-19; the launch was denied
  because the phone was locked. Xcode reused the existing profile rather than
  issuing a new one, so **the expiry did not move** — rebuilding early does not
  buy another seven days. `scripts/install-iphone.sh` has to be run on or after
  the expiry date, with the phone unlocked, to get a fresh profile.
- No physical-device observation of camera colour, orientation, crop, front/rear
  switching, interruption or lifecycle since the overhaul.
- Recorded-pixel parity, 4K recording and playback are unverified.
- Microphone, Photos, Vision, physical LiDAR output, HDR, thermal and sustained
  performance are all future device gates.
- `swiftlint lint` reports ~250 findings, concentrated in `CameraMetalSurface`,
  `ARObjectMetalSurface`, `CameraFluidSolver` and `WorkspaceDockView` — size and
  complexity debt, recorded rather than fixed. It is not a gate.
- Six files still carry `swiftlint:disable file_length`. `CameraMetalSurface` is
  ~2,330 lines and `CameraShaders.metal` is ~3,200.
- 43 `@unchecked Sendable` types under `SWIFT_STRICT_CONCURRENCY: complete`. The
  pattern is uniform and reviewable, but the compiler is not checking what the
  setting claims.
- 72 `TimelineView`s in the tree. Nobody has measured them.
- Running the whole UI suite back to back on one simulator can SIGTERM the fifth
  app launch. Re-run the individual test before treating it as a product bug.

## Commands

```bash
./scripts/verify.sh          # generate, format, lint, simulator tests, device build
./scripts/run-simulator.sh   # build, install, launch with console attached
./scripts/stop-simulator.sh
./scripts/install-iphone.sh  # signed build, install and launch on a paired iPhone
```

Build products go to `/private/tmp`, never into the project — DerivedData under
`~/Documents` gets `com.apple.FinderInfo` stamped by iCloud sync and codesign
then fails. `xattr -cr` does not hold; sync re-applies it.
