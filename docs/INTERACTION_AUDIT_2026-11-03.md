# Interaction audit — 2026-11-03

## Confirmed defects fixed

1. Active effects containing duplicate stack slots generated repeated effect IDs in the discovery grid. `GVEffectIndexSection` now keeps the first item for each effect identity in order, without removing any render slots.
2. Clear became disabled when every retained stack slot was powered off. The dock now enables Clear for any retained slot, enabled RGB Split, or LiDAR. This preserves the original Clear handler and undo behavior.

## Evidence

- The production section model, compiled in an isolated host harness with only the effect enum dependency substituted, returned `[vhs, vhs]` before the identity fix (exit 1), and `[vhs]` after it (exit 0).
- Live iPhone 17 Pro / iOS 27 simulator taps opened RGB Split, switched to Time, and selected Echo without app exit. Powering off Echo reproduced the disabled Clear control before its fix.
- A debug-only invocation of the actual selection handler opened VHS. The temporary hook was removed after investigation.
- After rebuilding/installing the fixes, a live Datamosh selection opened its parameter controls without app exit.
- Complete builds included Metal shaders. Edited files parse and the source diff passes whitespace checks.
- Added a unit regression for duplicate slot identities and a UI regression for repeated selection, powered-off Clear, Undo, Bypass, and settings.

## Limitations and unresolved report

The reported every-selection crash was not reproduced, and no GreyVision crash report was available locally. Hardware camera paths were not verified. The targeted XCTest runs built but did not execute tests: the installed Xcode beta repeatedly failed to connect to `instruments.deviceservice.lockdown` / bless its service hub. The working simulator tap connection later closed during final verification, so the corrected Clear flow could not be verified end-to-end through taps. No passing XCTest run is claimed.

To trace the reported crash further, obtain the exact effect/control, device/OS, and the corresponding device crash report or Xcode crash backtrace.
