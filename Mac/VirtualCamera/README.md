# GreyVision on macOS: Virtual Camera First

## Decision

**A real macOS virtual camera is possible and remains the correct implementation.** `GreyVisionVirtualCamera` uses a Core Media I/O Camera Extension, which macOS publishes as **GreyVision Virtual Camera**. Apple documents Camera Extensions as selectable camera devices in **Photo Booth**, FaceTime, and any app that captures through AVFoundation.[1]

> This is the route that lets a Mac app receive the *processed GreyVision iPhone feed*, rather than only the iPhone’s native camera image.

| Desired destination | Expected path | Current status |
|---|---|---|
| **Photo Booth** | Select **GreyVision Virtual Camera** from the camera menu. | Supported by the Camera Extension API; requires signed installation and one on-Mac runtime test. |
| FaceTime, QuickTime, Safari, Zoom, OBS, and standard AVFoundation clients | Select **GreyVision Virtual Camera** in the app’s camera/input selector. | Supported by the Camera Extension API; requires signed installation and one on-Mac runtime test. |
| Blackmagic camera software | Select **GreyVision Virtual Camera** if the product exposes macOS AVFoundation camera devices. | Requires a product-specific runtime check; no compatibility claim is made until tested. |

## What the New Supporting Folder Changes

`SupportingContinuityCameraInYourMacOSApp` is Apple’s **Continuity Camera capture-app** sample. It teaches a Mac app to discover an iPhone’s native camera as `AVCaptureDevice.DeviceType.externalUnknown`, respect the system-preferred camera, and use Apple’s Continuity Camera effects.[2]

It does **not** publish a virtual camera and cannot turn GreyVision’s processed iPhone frame into an input for Photo Booth. It is therefore a useful reference and a fallback capture-app baseline, but not a replacement for the Camera Extension.

| Option | Result | Recommendation |
|---|---|---|
| **Core Media I/O Camera Extension** | GreyVision’s processed feed becomes a system camera device. | **Use this.** It addresses Photo Booth and other camera clients. |
| Small macOS capture app based on the supplied sample | A compact Mac app captures the iPhone’s native Continuity Camera feed. It is not a system-wide source and does not carry GreyVision effects. | Use only if system-extension signing or a target app’s input policy blocks virtual cameras. |

## Implemented Files

| Path | Purpose |
|---|---|
| `GreyVision/Features/Workspace/WorkspaceView.swift` | Adds **Mac Cam** beside Clear FX and Audio. Starting it displays the one-time pairing code. |
| `GreyVision/Engine/Broadcast/` | Existing iPhone-side Bonjour, TLS-PSK, low-latency HEVC/H.264 transport. |
| `Mac/VirtualCamera/` | New macOS host app plus the embedded `GreyVisionCameraExtension`. |
| `Mac/VirtualCamera/Sources/CameraExtension/GreyVisionCameraExtension.swift` | Browses, authenticates, decodes, and publishes the iPhone feed as the virtual camera. |

Both targets compile: the iOS app builds for Simulator, and the macOS host app plus Camera Extension build unsigned.

## Live Activation Gate

The only remaining installation blocker is **macOS code signing**. This Mac does not currently have a `Mac Development` certificate with its private key for team `HXS2WF46R2`. A Camera Extension must be signed, embedded in its host app, launched from `/Applications`, and explicitly approved in System Settings before it appears to camera clients.[1]

After a Mac signing certificate is available, use this sequence:

1. Build `GreyVisionVirtualCamera.xcodeproj` with the `GreyVisionVirtualCamera` scheme.
2. Copy **GreyVision Virtual Camera.app** to `/Applications` and launch that copy.
3. On iPhone, tap **Mac Cam** and read the six-digit code.
4. In the Mac app, enter the code, enable the feed, and choose **Install Camera Extension**.
5. Approve the extension in **System Settings → Privacy & Security**.
6. Open **Photo Booth**, select **GreyVision Virtual Camera**, and confirm the processed feed. Then repeat with the required Blackmagic app.

## Fallback if a Required App Rejects Virtual Cameras

Do **not** abandon the virtual-camera architecture preemptively. First test Photo Booth after signed activation, because that is the direct Apple-supported integration path.[1] If a specific Blackmagic product does not list the extension, build a small macOS capture/recording app from the supplied `ContinuityCam` sample. That fallback would be intentionally narrow: automatic iPhone discovery, live preview, a device chooser, and recording. It would solve desktop capture, but it would not make GreyVision available system-wide or preserve its processed iPhone pipeline.

## References

[1]: https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o "Creating a Camera Extension with Core Media I/O — Apple Developer"
[2]: https://developer.apple.com/wwdc22/10018 "Bring Continuity Camera to your macOS app — WWDC22"
