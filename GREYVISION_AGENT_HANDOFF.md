# GreyVision Agent Handoff

**Last updated:** 2026-08-28 CDT  
**Project:** `greyvisionMASTER`  
**Primary developer:** Grey / Nicholas Prehn  
**Current handoff author:** Manus AI

> This document is the operational handoff for the next agent working on GreyVision. Read it before modifying the repository. The working tree is intentionally dirty because several rounds of UI, camera, capture, broadcast, signing, and reliability work happened concurrently. Preserve existing work unless a change is directly required for the active task.

## 1. Product and current stopping point

GreyVision is a native SwiftUI iOS camera and effects application. It captures live camera frames, processes them through a Metal effects pipeline, and presents a charcoal/black experimental camera interface with animated white, violet, and acid accents. The application includes camera controls, effect families, stacked effects, audio-reactive effects, temporal effects, AR/depth work, recording, still capture, and a Mac Cam workflow.

The Mac workflow sends the **processed output** from the iPhone to a Mac over a local-network Bonjour service and an authenticated TLS-PSK TCP connection. The active, working product is a standalone single-window macOS application called `GreyVisionMacCapture.app`, installed at `/Applications/GreyVisionMacCapture.app`. It receives, decodes, and previews the processed iPhone feed.

The user explicitly confirmed that the feed works. Landscape rotation was subsequently corrected and the user confirmed that the rotation issue was fixed. The system-wide virtual-camera experiment remains a separate future path and is **not** the active product because the user only has a personal Apple development team.

The most recent UI request before this handoff was to remove the iPhone **Take Photo**, **Record Video**, and **FX collapse caret** controls from the middle of the screen. The current implementation has a `detachedCaptureControls` row in `WorkspaceView.swift`, positioned above the bottom effect dock. The user still reported that these controls appeared in the middle, so the next agent should verify the actual rendered geometry on the iPhone and move the controls into a clearly edge-anchored camera-chrome region, preferably a bottom safe-area inset or a fixed lower control rail. Do not assume that a SwiftUI `Spacer` makes the controls visually bottom-anchored when the surrounding `ZStack`, dock height, safe-area handling, and landscape constraints are involved.

## 2. Non-negotiable operating rules

Do not reset, clean, revert, or regenerate the entire repository. The working tree contains unrelated but important changes from multiple agents. Avoid `git reset --hard`, broad checkout operations, whole-project formatting, or destructive XcodeGen changes. Make narrow edits to the relevant files only.

Do not attempt to activate the Core Media I/O virtual camera under the personal team again. Xcode explicitly reported that personal development teams, including **Nicholas Prehn**, do not support the System Extension capability. The virtual-camera project is retained for later use with a paid Apple Developer Program team, but it is not a valid deployment path with team `5NCWM6DS4H`.

The standalone Mac app must remain one window and must be installed and launched from `/Applications`. The Mac pairing code must remain visible as ordinary text. Do not replace it with a `SecureField` or otherwise mask it.

Use narrow searches and file ranges. The largest relevant files are `CameraMetalSurface.swift` and `CameraShaders.metal`; do not read them in full unless necessary. Build products should be placed in `/tmp`, not inside the iCloud-synchronized project directory.

## 3. Repository and target map

| Area | Important path | Responsibility |
|---|---|---|
| iOS app | `GreyVision/` | Main SwiftUI camera/effects application |
| Workspace UI | `GreyVision/Features/Workspace/WorkspaceView.swift` | Camera chrome, top decks, capture controls, Mac Cam control, effect dock |
| Camera lifecycle | `GreyVision/Engine/Capture/CameraRuntime.swift` | Camera state, orientation, permissions, capture configuration |
| Capture types | `GreyVision/Engine/Capture/CaptureTypes.swift` | Captured frame and orientation data types |
| Metal renderer | `GreyVision/Engine/Rendering/CameraMetalSurface.swift` | Processed frame rendering, recording/stills, broadcast pixel-buffer copy |
| Broadcast protocol | `GreyVision/Engine/Broadcast/GVBroadcastProtocol.swift` | Shared framed wire contract |
| iPhone link | `GreyVision/Engine/Broadcast/GVBroadcastLink.swift` | Bonjour listener, TLS-PSK link, outbound frames, inbound commands |
| Broadcast engine | `GreyVision/Engine/Broadcast/GVBroadcastEngine.swift` | Frame queue, VideoToolbox encoder, telemetry, command handling |
| Broadcast encoder | `GreyVision/Engine/Broadcast/GVBroadcastEncoder.swift` | HEVC-first/H.264 fallback compression session |
| Broadcast runtime | `GreyVision/Engine/Broadcast/GVBroadcastRuntime.swift` | Main-actor lifecycle, pairing code, state and status for SwiftUI |
| Mac app | `GreyVisionMacCapture/` | Standalone receiver and preview window |
| Mac UI/receiver | `GreyVisionMacCapture/Sources/GreyVisionMacCaptureApp.swift` | SwiftUI capture screen, Bonjour browser, decoder, command controls |
| Mac protocol copy | `GreyVisionMacCapture/Sources/GVBroadcastProtocol.swift` | Must stay compatible with the iPhone protocol |
| Virtual camera | `GreyVisionVirtualCamera/` | Future Core Media I/O Camera Extension path; currently blocked by signing |
| Existing docs | `docs/ARCHITECTURE.md`, `docs/CURRENT_STATE.md` | Broader architecture and older state notes; verify dates before relying on them |

## 4. iPhone application architecture

The iPhone camera path is AVFoundation → Metal → SwiftUI. `CameraController` configures the active capture device and publishes `CapturedFrame` values. `CameraRuntime` owns lifecycle and device state. `CameraMetalSurface` receives the latest frame, performs the effect graph, renders the processed image, and optionally copies the finished Metal texture into a pooled IOSurface-backed BGRA pixel buffer for broadcasting or recording.

The local preview can run at substantially higher resolution and frame rate than the Mac stream. The stream must not duplicate an unrestricted 4K/60 workload because early tests showed the phone could freeze when encoding work was initiated directly from Metal completion handlers. The current mitigation is intentionally bounded:

| Safeguard | Current behavior |
|---|---|
| Encode queue | Dedicated serial `encodeQueue` in `GVBroadcastEngine` |
| Backpressure | At most two queued encodes; excess frames are dropped |
| Metal completion | Only schedules bounded encode work; does not perform blocking VideoToolbox work directly |
| Broadcast frame size | Full HD cap, 1920 pixels on the long edge, even dimensions |
| Encoder | HEVC (`hvc1`) first, H.264 (`avc1`) fallback |
| Encoder frame rate | 30 FPS target |
| Default bitrate | 12,000,000 bits/s in the iPhone engine; Mac can request a higher live bitrate through the existing command channel |
| Mac preview publication | Coalesced/throttled to approximately 24 FPS and 1920-pixel maximum dimension |

The Full HD cap was raised from 1280 after the Mac quality was judged lower than the iPhone preview. This is a practical quality/performance compromise, not true pixel parity with a 4K local preview. If the next agent raises the cap further, test phone responsiveness continuously for at least 15 seconds and watch for encoder queue growth, dropped frames, thermal load, and UI stalls.

### Orientation

`CameraRuntime.swift` contains the current AVCapture rotation mapping. The final working correction is:

```swift
case .portrait:
    (90, .portrait)
case .portraitUpsideDown:
    (270, .portraitUpsideDown)
case .landscapeLeft:
    (180, .landscapeLeft)
case .landscapeRight:
    (0, .landscapeRight)
```

The landscape cases were previously reversed. The user confirmed that the rotation issue is fixed. Do not change this mapping without testing both physical landscape directions. The broadcast protocol currently carries raw encoded frames and does not include orientation metadata; the current solution relies on the processed image being rendered with the corrected AVCapture connection rotation before it is copied into the broadcast buffer.

## 5. iPhone-to-Mac wire protocol

The protocol is a custom framed stream over TLS-PSK TCP. Bonjour service type is `_greyvision._tcp`. Each message has a 20-byte big-endian header:

| Offset | Size | Field |
|---:|---:|---|
| 0 | 4 | Magic `GVX1` (`0x47565831`) |
| 4 | 1 | Message kind |
| 5 | 1 | Keyframe flag |
| 6 | 2 | Reserved |
| 8 | 4 | Payload length |
| 12 | 8 | Timestamp in nanoseconds |

Current message kinds are `hello`, `videoFormat`, `videoFrame`, `command`, and `keepalive`. The version is `1`. Payloads are JSON for handshake and control messages, VideoToolbox parameter-set data for `videoFormat`, and length-prefixed NAL access units for `videoFrame`.

`GVBroadcastHello` contains protocol version, device name, width, height, and codec. `GVBroadcastVideoFormat` contains codec, VPS/SPS/PPS or SPS/PPS parameter sets, NAL header length, width, and height. `GVBroadcastCommand` currently has only:

```swift
enum GVBroadcastCommand: Codable, Equatable, Sendable {
    case requestKeyframe
    case setBitrate(Int)
}
```

The iPhone derives a TLS-PSK using HKDF-SHA256 from the visible six-digit pairing code. The Mac uses the same service-type-derived salt, `greyVISION.link.v1` info string, and `greyVISION` PSK identity. Any protocol change must update both:

* `GreyVision/Engine/Broadcast/GVBroadcastProtocol.swift`
* `GreyVisionMacCapture/Sources/GVBroadcastProtocol.swift`

If the virtual-camera target is kept synchronized, update its shared protocol copy as well. Do not bump the framing version for additive JSON fields that preserve decoding compatibility.

## 6. Mac capture application

The Mac app is not a virtual camera device. It is a standalone receiver and preview application. It browses for the iPhone’s Bonjour service, connects using the six-digit code, reconstructs the VideoToolbox format description, decodes HEVC/H.264 to BGRA, converts through Core Image, and publishes an `NSImage` to SwiftUI.

The app is currently designed as a black, minimal GreyVision surface with white animated accents. The recent redesign includes:

* a black full-window background;
* a restrained animated white signal line;
* `GREY//VISION` and `MAC CAPTURE` header treatment;
* live/offline state indicator;
* rounded black preview frame with a thin white border;
* visible iPhone/service and pairing-code fields;
* Connect/Disconnect control;
* `BAL` and `STUDIO` quality presets;
* a keyframe refresh button while connected;
* stream dimensions and codec in the header;
* status text and bitrate detail in the lower rail.

The Mac quality controls use the already-supported `setBitrate` command. They do not change the iPhone’s source resolution; the source resolution is chosen by the iPhone renderer’s Full HD broadcast cap. The Mac `STUDIO` preset requests 20 Mbps and `BAL` requests 12 Mbps. This is a bitrate-quality control, not a promise of the same image resolution or effect state as the local iPhone preview.

The Mac app’s current receiver flow is:

1. User arms Mac Cam on the iPhone.
2. iPhone generates and visibly displays a six-digit code.
3. User enters the code in the Mac app.
4. Mac browses for `greyVISION` on `_greyvision._tcp`.
5. Mac authenticates with TLS-PSK.
6. iPhone sends hello and video format packets.
7. Mac builds the HEVC/H.264 format description.
8. Mac waits for a keyframe, decodes frames, and presents the preview.

A prior HEVC failure was fixed by retaining parameter-set `NSData` objects while calling `CMVideoFormatDescriptionCreateFromHEVCParameterSets`; pointers from a short-lived `Data.withUnsafeBytes` closure were not valid afterward.

## 7. iPhone UI state and the remaining layout issue

The Mac Cam button is in `captureSettingsDeck` in `WorkspaceView.swift`. Its current label is intended to show the code inside the same control after the link is armed:

```swift
label: broadcastRuntime.isArmed
    ? "MAC CAM // \(broadcastRuntime.passcode)"
    : "MAC CAM"
```

The prior separate full-width pairing-code card was removed. The top deck is intended to close automatically after `broadcastRuntime.isConnected` becomes true:

```swift
.onChange(of: broadcastRuntime.isConnected) { _, connected in
    guard connected else { return }
    withAnimation(GVMotion.deck) { activeTopDeck = nil }
}
```

The photo, FX, and record row is `detachedCaptureControls`. It currently contains the photo button, `chromeToggle`, and record button. The user’s latest complaint is that these are still visually in the middle of the screen. The next agent should:

1. Confirm whether the row is being measured in the middle because the surrounding `VStack` has an expanding `Spacer`, because the bottom dock retains layout height while hidden, or because the device is in landscape.
2. Anchor the row explicitly to the bottom safe area rather than relying on stack distribution.
3. Keep the FX control discoverable and accessible. Its accessibility labels are already `Show effects` and `Hide effects`.
4. Keep the record button available while recording even if the rest of the chrome is hidden.
5. Preserve the existing single-tap restore behavior when `isChromeHidden` is true.
6. Test portrait, both landscape directions, Dynamic Type, Reduce Motion, and a live recording.

A likely robust structure is an outer `ZStack(alignment: .bottom)` for the viewport and a bottom chrome group containing the capture controls plus the dock, with explicit bottom-safe-area padding. Do not put the row in a visually centered overlay. If the controls need to sit above the effect dock, use a bottom-aligned `VStack` with explicit spacing and a fixed dock relationship rather than a free `Spacer`.

## 8. Virtual camera experiment and signing constraint

`GreyVisionVirtualCamera/` contains an XcodeGen-generated macOS host and Core Media I/O Camera Extension. The design follows Apple’s Camera Extension architecture: host app, System Extension, App Group communication, and a Core Media I/O provider/device/output stream. This is the correct architecture for a camera selectable by Photo Booth, FaceTime, Blackmagic Camera, and other AVFoundation clients.[1] [2]

The project was built unsigned and its structure was validated. It was also signed under the user’s personal team `Nicholas Prehn`, team ID `5NCWM6DS4H`, and copied to `/Applications/GreyVisionVirtualCamera.app`. Provisioning then failed because personal development teams do not support the System Extension capability. The error was explicit: personal development teams do not support the System Extension capability / required entitlement. The user does not currently have a paid organization team available.

Therefore:

* Do not claim the virtual camera is active.
* Do not claim Photo Booth, FaceTime, or Blackmagic can consume the standalone fallback.
* The standalone Mac capture app is only a receiver/preview window.
* A paid Apple Developer Program team and appropriate System Extension provisioning are required before the virtual-camera path can be resumed.
* Keep the virtual-camera project and README for future paid-team work.

## 9. Build, install, and launch commands

### iPhone physical-device build

The known Nick’s iPhone identifier is:

```text
DA48F3DB-C16D-5418-8CD4-428F8BB31168
```

Build to `/tmp`:

```bash
cd /Users/grey/Documents/greyvisionMASTER
xcodebuild \
  -project GreyVision.xcodeproj \
  -scheme GreyVision \
  -configuration Debug \
  -destination 'id=DA48F3DB-C16D-5418-8CD4-428F8BB31168' \
  -derivedDataPath /tmp/GreyVisionDeviceBuild \
  build
```

Install and launch:

```bash
xcrun devicectl device install app \
  --device DA48F3DB-C16D-5418-8CD4-428F8BB31168 \
  /tmp/GreyVisionDeviceBuild/Build/Products/Debug-iphoneos/GreyVision.app

xcrun devicectl device process launch \
  --device DA48F3DB-C16D-5418-8CD4-428F8BB31168 \
  --terminate-existing \
  com.saringrey.greyvision
```

The phone must be unlocked for `devicectl` to launch the application. Installation may succeed while launch fails with `RequestDenied` and `Locked`.

### Mac capture build and deployment

```bash
cd /Users/grey/Documents/greyvisionMASTER/GreyVisionMacCapture
xcodegen generate
xcodebuild \
  -project GreyVisionMacCapture.xcodeproj \
  -scheme GreyVisionMacCapture \
  -configuration Debug \
  -allowProvisioningUpdates \
  build
```

The generated app is normally under Xcode’s DerivedData path. Deploy it from the built product to Applications without destructive wildcard removal:

```bash
source_app="$(find /Users/grey/Library/Developer/Xcode/DerivedData/GreyVisionMacCapture-*/Build/Products/Debug/GreyVisionMacCapture.app -maxdepth 0 -print -quit)"
if [ -e /Applications/GreyVisionMacCapture.app ]; then
  mv /Applications/GreyVisionMacCapture.app /tmp/GreyVisionMacCapture.previous.app
fi
ditto "$source_app" /Applications/GreyVisionMacCapture.app
codesign --verify --deep --strict /Applications/GreyVisionMacCapture.app
open -na /Applications/GreyVisionMacCapture.app
```

### Device discovery

```bash
xcrun devicectl list devices

dns-sd -B _greyvision._tcp local.
```

The iPhone must be in the GreyVision app with **Mac Cam armed** before the Mac browser can find the service. Use a fresh code after restarting the iPhone broadcaster or Mac receiver.

### Existing project scripts

Inspect before using because the repository is dirty and scripts may have changed:

```bash
./scripts/verify.sh
./scripts/run-simulator.sh
./scripts/stop-simulator.sh
./scripts/install-iphone.sh
```

`docs/CURRENT_STATE.md` notes that build products should stay outside the project because iCloud/Finder metadata can cause codesign failures. `/tmp` is the preferred DerivedData location for ad-hoc validation.

## 10. Verification checklist

### iPhone UI

| Test | Expected result |
|---|---|
| Tap MAC CAM while idle | Button arms and displays the six-digit code in the same control; no separate code box appears |
| Open top settings deck and connect Mac | Deck automatically closes once `isConnected` becomes true |
| Portrait preview | Photo, FX, and record controls are on the lower camera chrome, not the center of the image |
| Landscape left/right | Controls remain edge-anchored and do not drift into the middle |
| Start recording | Record control remains available and changes to stop state |
| Hide chrome | A tap restores the interface; recording can still be stopped |
| Reduce Motion | Animated accents and transitions degrade appropriately |
| VoiceOver | Photo, effects, record, and restore controls have meaningful labels |

### Stream and performance

| Test | Expected result |
|---|---|
| Portrait stream | Mac receives and decodes processed frames |
| Landscape left | Image is upright and not mirrored |
| Landscape right | Image is upright and not mirrored |
| 15-second continuous run | iPhone remains responsive; Mac remains responsive |
| Quality BAL | Link remains stable at approximately 12 Mbps target |
| Quality STUDIO | Mac requests 20 Mbps; image detail improves without freezing the phone |
| Keyframe button | Mac requests a fresh keyframe and recovers from a late join/drop |
| Disconnect/reconnect | Encoder and receiver recover without stale connection state |
| App restart | Fresh code is generated and Bonjour service reappears |

### Build evidence

A prior stable sequence reached: Mac connected, first video frame received, HVC1 format accepted, and preview displayed. The Full HD polish build compiled successfully for Mac and was deployed to `/Applications`. The iPhone polish build also compiled and installed; automatic launch was denied when the phone was locked. Unlock before retesting.

## 11. Known repository risks

The repository contains many unrelated modifications and deletions. At the last inspection, changes existed across app model, root routing, design system, camera, AR, depth, rendering, capture coordination, workspace UI, shaders, tests, project configuration, scripts, and the two Mac projects. There were also untracked directories for `GreyVisionMacCapture`, `GreyVisionVirtualCamera`, diagnostics, shared continuity-camera material, and additional design-system files.

`docs/CURRENT_STATE.md` is useful but dated and explicitly warns that it is a claim-to-recheck document. It reports broad implementation gates, but many physical-device gates remain pending. In particular, color, recording parity, sustained thermal behavior, microphone, Vision, LiDAR, HDR, and long-duration memory behavior have not all been physically verified.

The most important code-size debt is `CameraMetalSurface.swift`, which is approximately 2,600 lines in the current working tree, and `CameraShaders.metal`, which is several thousand lines. Avoid broad refactors during a focused UI task. `GVCaptureCoordinator.swift` and `GVCaptureWriter.swift` were repaired narrowly during prior concurrent work and should receive a dedicated audit rather than casual cleanup.

## 12. Recommended next work, in priority order

First, fix the iPhone capture-control geometry. Inspect `WorkspaceView.body`, `detachedCaptureControls`, the `WorkspaceDockView` call, and all `.frame`, `.padding`, `.opacity`, `.allowsHitTesting`, `.ignoresSafeArea`, and animation modifiers around the bottom stack. Use an explicit bottom-aligned container and verify on a physical device.

Second, build and install the corrected iPhone UI while preserving the Full HD broadcast changes. Unlock Nick’s iPhone before launching with `devicectl`.

Third, validate the end-to-end stream in portrait and both landscape directions. Confirm the user-visible result rather than relying only on compilation. Measure responsiveness for at least 15 seconds.

Fourth, decide whether Mac controls should remain limited to connection, bitrate preset, and keyframe recovery. The iPhone has the full creative effect-control surface. The wire protocol currently does not contain commands for driving the entire effect stack. Adding remote effect controls should be a deliberate protocol and product-design task, not an ad-hoc set of commands.

Fifth, only after a paid Apple Developer team is available, resume the Core Media I/O Camera Extension activation work. Keep that work isolated from the standalone capture app and do not regress the working fallback.

## 13. External references

[1]: https://developer.apple.com/documentation/coremediaio/creating_a_camera_extension_with_core_media_io "Apple Developer — Creating a Camera Extension with Core Media I/O"

[2]: https://developer.apple.com/documentation/coremediaio "Apple Developer — Core Media I/O documentation"

[3]: https://developer.apple.com/documentation/avfoundation "Apple Developer — AVFoundation documentation"

[4]: https://developer.apple.com/documentation/videotoolbox "Apple Developer — VideoToolbox documentation"

## 14. Final handoff summary

GreyVision’s processed iPhone feed is working in the standalone Mac receiver. The Mac app is one window, installed in `/Applications`, signed with the personal Mac team, and styled as a minimal black-and-white GreyVision surface. The phone stream uses a bounded Full HD export and a dedicated encode queue to avoid the earlier freezing behavior. HEVC decoding and parameter-set lifetime issues were fixed. Landscape rotation is fixed and user-confirmed.

The system-wide selectable virtual camera is not deployable under the current personal Apple team. The next practical engineering task is the iPhone camera-chrome layout: move Take Photo, Record Video, and the FX collapse caret to an explicit bottom edge position, keep them accessible, and verify that the layout is stable in portrait and landscape. Preserve all existing unrelated work while making that narrow fix.
