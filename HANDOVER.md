# greyVISION — session handover

Date: 2026-08-19
Branch: `fix/all-20260819`
Backup tag: `pre-fixall-20260819`

---

## Read this first

The suite is green — 24 unit tests and 6 UI tests, from 21 tests with 10
failures at the start of the session — and both the simulator and generic
`iphoneos` builds pass. **None of it has been driven by hand on a device.**
"Green" here means the machine agrees with itself. Treat every device-facing
claim below as unproven until you hold the phone.

The single highest-value thing anyone can do next is run the app.

---

## Deadline

**The provisioning profile expires 2026-08-25 16:32 UTC.** Free personal team,
seven-day profile.

A signed build was made and installed on nick's iPhone
(`DA48F3DB-C16D-5418-8CD4-428F8BB31168`) on 2026-08-19. Launch was denied
because the phone was locked, and — this is the part worth knowing — **Xcode
reused the existing profile rather than issuing a fresh one, so the expiry did
not move.** Rebuilding today does not buy another seven days. Apple reissues a
free-team profile only once the current one is at or near expiry, so:

```sh
./scripts/install-iphone.sh
```

needs running on or after 2026-08-25, with the phone unlocked, to get a new
profile. Verify with:

```sh
security cms -D -i /private/tmp/gvdevice/Build/Products/Debug-iphoneos/GreyVision.app/embedded.mobileprovision \
  | plutil -extract ExpirationDate raw -o - -
```

---

## What changed

### Two real bugs

**Temporal render order.** `insertInPipelineOrder` ranked new slots against
`metalRenderOrder` alone. All 39 temporal effects are absent from that list, so
each one took the same fallback rank, tied, and fell back to whichever the
operator tapped first — TRAILS then ECHO rendered differently from ECHO then
TRAILS, and nothing on screen said why. `temporalRenderOrder`, the constant that
used to decide this, had no remaining references in the tree. The guard test
that shipped with the slot model filtered to `styleMode != nil`, so it only ever
covered the half that still worked.

Slots now rank against `defaultPlacementOrder`
(`metalRenderOrder + temporalRenderOrder`), and
`testEveryRenderableEffectHasExactlyOnePlacementRank` asserts the two lists are
disjoint and that every effect with a shader mode appears in exactly one. Adding
an enum case without adding it to the matching list now fails a test instead of
quietly reordering the pipeline.

**The frame governor shed the wrong effects.** `adaptiveEffectDropCount` fires
after six consecutive frames over 16.6 ms and called `dropCheapest`. Inside the
style pass the only costs are 1.0 and 1.4 — the entire 1.5 bucket is temporal
and never reaches that call — so under load it removed the cheap nodes: the
operator paid the full visible cost of the drop and got almost none of the
milliseconds back. It also only logged, so a shed was indistinguishable from a
broken effect, and the 30-frame recovery hysteresis meant it stayed gone.

It now sheds the most expensive, always leaves one effect standing, and
publishes the count. The telemetry strip prints `SHED n` in `warn` while it is
happening.

### Accessibility

- 69 call sites moved onto `.gvFont` / `.gvMono` / `.gvTerminal`, which resolve
  against `\.dynamicTypeSize` on a compressed curve topping out at 1.6.
  `AppRootView` clamps the environment once at `.accessibility2`. Before this
  the smallest label in the app was a fixed 5.2pt and the setting did nothing.
  **This is the change most likely to have moved layout. Look at it on device
  at a large text size before trusting it.**
- `GVTerminalParameterRow` reports to VoiceOver as the slider it behaves like,
  through `accessibilityRepresentation`, with adjustments routed through the
  same `commit` path a finger scrub uses.

### Discoverability

133 effects sat in a flat rail behind nineteen category pills. Added a search
field at the head of the dock matching name and description, and a `RECENTS`
shelf holding the last ten effects used. Search honours the `EXPERIMENTAL`
switch rather than being a side door around it.

### Cleanup

- 2,445 dead lines removed. Four of those files were excluded from the target in
  `project.yml` rather than deleted; the rest had zero references. All
  recoverable at `pre-fixall-20260819`.
- `scripts/` restored — `verify.sh`, `run-simulator.sh`, `stop-simulator.sh`,
  `install-iphone.sh`. `docs/GOD_MODE.md` documented these for weeks without
  them existing.
- `docs/GOD_MODE.md` deleted: it described a scene conductor that has no source
  anywhere in this tree.
- `docs/ARCHITECTURE.md` and `docs/CURRENT_STATE.md` rewritten from the code.
  The old ones named five types that do not exist and reported 29 effects
  against a registry of 133.
- `.swiftformat` added. There was no config, so both formatters ran on defaults
  and the docs claimed `swiftformat --lint .` passed — a default run rewrites 67
  of 115 files, including turning `44_100` into `44100`. The rules this codebase
  violates on purpose are now disabled explicitly, so a lint failure means drift.

### Test repairs

The suite was red for four separate reasons, none of them regressions:

- The route test predated the access gate and asserted `.boot` on cold launch.
- The registry test hardcoded 31/30 effect counts. It now asserts the invariant
  the Metal kernel actually needs: modes unique and contiguous from zero.
- `--uitesting` did not bypass the gate despite the previous handover saying it
  did, so the boot-dock suite sat on the keypad until it timed out.
- Record drives the writer now rather than printing a Gate 5 notice, and the
  camera deck is scrub rows rather than +/- buttons.

---

## Next steps, in order

1. **Run the app.** Priority checks: boot sequence, long-press radial
   (ZOOM/EXP/LIGHT/WB), recording, telemetry taps driving ISO/shutter/WB, lens
   switch and rotation, screenshot/video with UI in frame. Then repeat the pass
   with Larger Text turned up.
2. **Rebuild before 2026-08-25.**
3. **Effect stack UI.** `orderedSlots`, `move`, `duplicate`, `remove` and
   `setEnabled(_:slot:)` all exist and nothing calls them. Note that
   `GVActiveEffectPanel`, which was most of the display half, was removed in
   this pass as dead code — recover it from `pre-fixall-20260819` if it helps.
4. **Measure something.** 72 `TimelineView`s and a 2,300-line renderer, and the
   only performance number anyone has quoted came off a screenshot.
5. **Wire `resumeAutoExposure()`.** Touching ISO or shutter drops the camera
   into custom exposure and it stays there. The setter exists; no gesture calls
   it. A long press on the telemetry strip is the obvious home.

---

## Still true, still not fixed

- 43 `@unchecked Sendable` types under `SWIFT_STRICT_CONCURRENCY: complete`. The
  mailbox pattern is uniform and reviewable, but the compiler is not checking
  what the setting claims.
- `swiftlint lint` reports ~250 size and complexity findings, concentrated in
  `CameraMetalSurface`, `ARObjectMetalSurface`, `CameraFluidSolver` and
  `WorkspaceDockView`. Recorded, not gated.
- `GVTheme` still ships nine surface constants under a comment reading "Three
  tiers, not eleven" — the old ladder survived the palette cut as "retained
  fills". Either migrate the call sites or delete the retained set.
- A second greyVISION app may still be on the phone from an earlier agent, under
  a different bundle ID. This one reads **greyVISION v5**.
- Running the whole UI suite back to back on one simulator can SIGTERM the fifth
  app launch. Re-run the individual test before chasing it as a product bug.

---

## Build

```sh
./scripts/verify.sh          # generate, format, lint, simulator tests, device build
./scripts/run-simulator.sh   # build, install, launch with console attached
./scripts/install-iphone.sh  # signed build, install, launch on a paired iPhone
```

Build products go to `/private/tmp`, never into the project. DerivedData under
`~/Documents` gets `com.apple.FinderInfo` stamped by iCloud sync and codesign
fails with "resource fork, Finder information, or similar detritus not allowed".
`xattr -cr` does not hold; sync re-applies it.

The access code is **3914**, in `GVAccessCode.value`. It is a compile-time
constant and readable by anyone with the source. It is a ceremony, not a lock.
