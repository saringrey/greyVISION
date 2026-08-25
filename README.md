# greyvisionMASTER

The canonical working copy of grey//VISION. Copied from
`/Users/grey/Documents/GreyVisionv3` on 2026-08-25 (including that tree's
uncommitted redesign), then fixed so it actually builds — the source it came
from did not compile.

## Build / run

```sh
cd ~/Documents/greyvisionMASTER

xcodebuild -project GreyVision.xcodeproj -scheme GreyVision \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/gvmaster build        # device build

./scripts/run-simulator.sh                            # build + install + launch in simulator
./scripts/install-iphone.sh                           # signed build onto a paired iPhone
./scripts/verify.sh                                   # generate, format, lint, tests, device build
```

Xcode: open `GreyVision.xcodeproj` directly. Scheme `GreyVision`.
Build products go to `/private/tmp`, never into the project (iCloud xattr issue).

## What was fixed to make it build

All in `GreyVision/Features/Workspace/WorkspaceView.swift` unless noted:

1. **Extraneous `}` at line 1236** — stray closing brace at end of file.
2. **Missing `radialGesture`** — the long-press radial instrument gesture was
   referenced but its implementation had been dropped from the working copy.
   Restored from `HANDOFFVISION`'s WorkspaceView.
3. **Access control** — `toggleTopDeck` / `topControlDeck` take the private
   `WorkspaceTopDeck`, so they must be `private`.
4. **Swift 6.4 frontend crash** ("failed to produce diagnostic") — caused by
   `GVChamferedPlate().strokeBorder(...)` on a shape that wasn't
   `InsettableShape`. Fixed in `DesignSystem/GVPrimitives.swift` by making
   `GVChamferedPlate` conform to `InsettableShape`. The full styled
   `shellChip` (chamfered plate, glyph glow, press animation, a11y id) is intact.

## Notes inherited from HANDOVER.md / docs/

- Access code is `3914` (`GVAccessCode.value`).
- Free-team provisioning profile expires around 2026-08-25; re-run
  `./scripts/install-iphone.sh` with the phone unlocked to renew.
- See `HANDOVER.md` and `docs/CURRENT_STATE.md` for full state and caveats.
