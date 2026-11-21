# Title-screen audit — October 27, 2026

Scope: GreyVision's launch screen, ASCII identity, waterfall/nebula, capture-format dock and choice rail. This is a source audit and iPhone 16 simulator review, not hardware certification.

## Result

The checked portrait screen preserves the centered `grey` / larger `VISION` identity. An 11-second recording shows one letter scrambling and resolving at a time across both lines. The nebula has a finer ordered-dither texture and quiet downward glyph trails. No portrait clipping or overlap was observed at default or accessibility-extra-extra-large text size.

The signed iPhone build succeeded and passed `codesign --verify --deep --strict`. Its provisioning profile includes Nick's device and expires October 30, 2026 at 21:21:35 UTC. After the phone became available, CoreDevice pairing was restored, the finished app was installed, and launch succeeded. An independent device process query confirmed GreyVision running as PID 2856 from the new installation container. Physical-screen appearance and hardware frame timing remain unverified.

## Changes made

- `SplashShaders.metal`: finer 1.5-point Bayer cells and three tonal levels make the nebula visibly dithered. The existing continuous waterfall and 60 Hz schedule remain intact.
- `GVSplashBackdrop.swift`: shared, static `GVSplashPlate` gives format controls the same cyan/violet ordered texture without adding another animation clock.
- `BootView.swift`: format buttons show opening/closing chevrons, a responding accent rule, and a value transition. VoiceOver receives expanded/collapsed state and an escape action to dismiss the chooser.
- `GVSplashChoiceRail.swift`: radio-style circle/checkmark indicators replace the ambiguous plus; selected options expose the selected accessibility trait and use the shared dithered plate.

## Audit health

These scores are provisional within the checked source/portrait scope.

| Dimension | Score | Evidence / limit |
| --- | --- | --- |
| Accessibility | 3/4 | Labels, selection/expanded state, 44-point minimum targets, and large text reviewed. VoiceOver traversal and escape gesture need actual input. |
| Performance | 3/4 | Rasterized-once title; ambient schedules pause offscreen; control texture has no animation clock. Hardware frame timing was not measured. |
| Appearance | 4/4 | Shared nebula palette, border treatment, ordered texture, and readable portrait hierarchy. |
| Platform conformance | 3/4 | Native SwiftUI buttons, SF Symbols, safe-area layout; touch behavior could not be independently confirmed. |
| Adaptivity | 2/4 | Default and large-text portrait checked. Landscape remains unverified. |
| Total | 15/20 | Good within the reviewed scope; interaction/device verification remains open. |

No confirmed P0/P1 title-screen code defects were found in the checked states. The remaining gates are verification blockers, not established app defects:

1. CODEC (twice), FPS, RES, and the title link all remained unchanged after runtime elementRef taps reported delivery. Each returned a snapshot-settle warning. This shared failure prevents certifying codec selection, selected-card appearance, value updates, or automatic chooser collapse. Direct CUA fallback reported that the Mac was locked.
2. Resolved: Nick's iPhone was initially unavailable, then required pairing again. Pairing, installation, launch, and an independent running-process check subsequently succeeded. Unlocking the Mac is still required for direct GUI interaction checks.

## Evidence

- [Default portrait](portrait-title.jpg)
- [Large text](large-text.jpg)
- [One-letter decryption recording](title-decryption-11s.mp4)
- [Runtime verification log](audit.log)
- [Runtime snapshots](runtime-snapshots.json)

Fresh focused checks against the current `GVGlyphMask` / `GVLetterDecryption` production source passed for both words: all letter boundaries, 22 decrypt frames per letter, stable inactive cells/geometry, settled dwell, cycle wrap, and invalid inputs. Full XCTest, real touch, landscape, and physical-device FPS were not verified.

## Device handoff

Signed app: `/private/tmp/gv-title-device-20261027/Build/Products/Debug-iphoneos/GreyVision.app`.

Initial build/install attempt log: `/tmp/gv-title-install-20261027.log`. Successful device launch evidence: `/tmp/gv-title-device-launch-20261027.json`; independent process evidence: `/tmp/gv-title-device-processes-20261027.json`.

To rebuild, install, and launch on Nick's explicitly selected iPhone once available:

```zsh
GV_DEVICE_UDID='DA48F3DB-C16D-5418-8CD4-428F8BB31168' GV_DERIVED_DATA_PATH='/private/tmp/gv-title-device-20261027' zsh '/Users/grey/Documents/greyvisionMASTER/scripts/install-iphone.sh'
```
