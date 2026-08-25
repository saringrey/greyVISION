# Gate 2 Physical-Device Verification

This gate is intentionally not marked complete until the connected iPhone proves the raw AVFoundation path. Simulator color bars prove only app/UI/source-state behavior.

## Signing

Use Xcode 27.0 at `/Applications/Xcode-beta.app` with the already-configured developer account for development team `5NCWM6DS4H`. Keep automatic signing enabled for `com.saringrey.greyvision`; Xcode may create or refresh its development certificate and provisioning profile during the signed build. Treat the signed app's `TeamIdentifier` and the embedded profile's `TeamIdentifier` as authoritative; a parenthetical identifier in a certificate display name is not the project team setting.

Signed build, installation, process launch, and live-process presence passed on the Gate 2 iPhone on 2026-08-09. The visual and lifecycle observations below remain required before Gate 2 is complete.

The alternate Xcode 26.6 installation has a separate unaccepted license and is not needed if Xcode 27 signing is restored.

## Build, install, launch

```bash
./scripts/install-iphone.sh
```

Signed build, install and launch on the first paired physical device. Override
with `GV_DEVICE_UDID`. The script builds into `/private/tmp` — DerivedData under
`~/Documents` gets `com.apple.FinderInfo` stamped by iCloud sync and codesign
then fails with "resource fork, Finder information, or similar detritus not
allowed". `xattr -cr` does not hold; sync re-applies it.

"Device is not able to fulfill the requested usage assertion" means the phone is
locked.

## Required observations

- Camera permission appears only after `START ENGINE // LAUNCH`.
- Rear preview has correct color, no green cast, no synthetic grain, no filter, and no geometry stretch.
- Portrait, landscape left, and landscape right preserve aspect-fill crop and horizon orientation.
- Tap-to-focus reticle maps to the touched subject; exposure follows the same point.
- Zoom, exposure bias, white-balance lock, and torch change the physical camera and recover after restart.
- Front/rear switch and available rear-lens cycling resolve a real supported format and update diagnostics.
- Background/foreground stops and restores camera ownership without a frozen preview.
- An interruption by another camera client reports the concrete reason and resumes afterward.
- Closing the workspace releases the camera indicator; no camera or microphone process remains active.

Record the device/OS, selected lens, resolved format/FPS, orientations tested, and failures in `docs/CURRENT_STATE.md`. Only then advance Gate 2 to `DEVICE` and begin Gate 3.
