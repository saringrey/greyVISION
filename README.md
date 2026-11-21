# grey//VISION

A live visual-effects camera for iPhone: SwiftUI chrome over a Metal render
graph, with a Mac link that streams the processed picture to a paired Mac.

## Layout

| Path | What it is |
|---|---|
| `GreyVision/` | The iPhone app. `App/` boot and routing, `Engine/` capture, rendering, audio, depth, AR and the Mac link, `Features/` the splash and workspace, `DesignSystem/` shared chrome, `Resources/` assets, shaders and fonts. |
| `Tests/` | `Unit/` and `UI/` test targets for the iPhone app. |
| `Mac/` | `Capture/` is the Mac app that receives the Mac Cam stream. `VirtualCamera/` is the macOS camera extension, on hold until a paid developer account. Each has its own `project.yml`. |
| `docs/` | Architecture, product brief, domain language and the on-device test pass. |
| `scripts/` | Build, install and verification scripts, plus `splash-extend/` for the splash film's outpainted stills. |

## Build and run

The Xcode project is generated, not committed:

```sh
xcodegen generate                 # writes GreyVision.xcodeproj from project.yml
open GreyVision.xcodeproj         # scheme GreyVision

./scripts/run-simulator.sh        # build, install and launch in the simulator
./scripts/install-iphone.sh       # signed build onto a paired iPhone
GV_DEVICE_UDID="Nick's iPhone" ./scripts/install-iphone.sh   # pick a phone by name or UDID
./scripts/verify.sh               # generate, format, lint, tests, device build
```

Build products go to `/private/tmp`, never into the project: iCloud stamps
Finder metadata on anything under `~/Documents` and codesign then refuses it.

## Notes

- The free-team provisioning profile lasts seven days. Re-run
  `./scripts/install-iphone.sh` with the phone unlocked to renew it.
