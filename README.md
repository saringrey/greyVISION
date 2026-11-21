# grey//VISION

A live visual-effects camera for iPhone: SwiftUI chrome over a Metal render
graph, with a Mac link that streams the processed picture to a paired Mac.

## Layout

| Path | What it is |
|---|---|
| `GreyVision/` | The iPhone app. `App/` boot and routing, `Engine/` capture, rendering, audio, depth, AR and the Mac link, `Features/` the splash and workspace, `DesignSystem/` shared chrome. |
| `GreyVisionTests/`, `GreyVisionUITests/` | Unit and UI tests. |
| `GreyVisionMacCapture/` | The Mac app that receives the Mac Cam stream. Own `project.yml`. |
| `GreyVisionVirtualCamera/` | The macOS camera extension. On hold until a paid developer account; see its README. |
| `tools/splash-extend/` | Rebuilds the splash film's outpainted stills. |
| `scripts/` | Build, install and verification scripts. |
| `docs/ARCHITECTURE.md` | How the app is put together. |
| `CONTEXT.md`, `PRODUCT.md` | Domain language and product brief. |

## Build and run

The Xcode project is generated, not committed:

```sh
xcodegen generate                 # writes GreyVision.xcodeproj from project.yml
open GreyVision.xcodeproj         # scheme GreyVision

./scripts/run-simulator.sh        # build, install and launch in the simulator
./scripts/install-iphone.sh       # signed build onto a paired iPhone
./scripts/verify.sh               # generate, format, lint, tests, device build
```

Build products go to `/private/tmp`, never into the project: iCloud stamps
Finder metadata on anything under `~/Documents` and codesign then refuses it.

## Notes

- The free-team provisioning profile lasts seven days. Re-run
  `./scripts/install-iphone.sh` with the phone unlocked to renew it.
