# greyVISION v3 Reference Index

This is a clean-room provenance ledger. References guide behavior and visual intent; they are not source dependencies.

## Inherited product inputs

| Input | Role | Import policy |
|---|---|---|
| `/Users/grey/Documents/FULLUIGREYVISIONIOS.swift` | Visual hierarchy, interaction vocabulary, copy, effect categories, presets, and social links | Read as specification only. Reimplemented modularly; no source copied into the target. |
| `/Users/grey/Desktop/greyvector.png` | Official splash/logo pixels | Copied byte-for-byte into the asset catalog. Never redrawn or replaced. |
| `/Users/grey/Downloads/GREYVISION -- CODEX GODMODE REBUILD.md` | Build constraints, performance contract, validation gates, and clean-room rules | Read as implementation brief only. |
| `/Users/grey/Downloads/bottomUIcollapsed.jpg` | Collapsed workspace dock hierarchy, pill proportions, category/effect rail relationship, and violet edge treatment | Visual reference only. Reimplemented with native SwiftUI geometry, live controls, and explicit capability gates; the JPEG is not shipped in the app. |
| `/Users/grey/Downloads/IMG_1560.jpg` | Dynamic-Island-engulfing top-shell geometry, stacked brand placement, floating status pill, and transparent violet-edged control treatment | Visual reference only. Reimplemented with native SwiftUI safe-area geometry and live controls; the JPEG is not shipped in the app. |
| `/Users/grey/Downloads/IMG_1570.jpg` | Corrected top-shell proportion: `grey` / `VISION` centered in the left hardware-free zone, Dynamic Island reserve preserved, and compact top-right icon controls | Visual reference only. Reimplemented with native SwiftUI geometry and live controls; the JPEG is not shipped in the app. |

The derived app icon composites the supplied transparent logo over an original black/violet background generated for this project. The background generation prompt requested an empty, opaque, terminal-decay plate with a quiet center, violet radial energy, scanline fragments, and no text, creature, or logo. Source generation output: `/Users/grey/.codex/generated_images/019fe50b-a033-7970-a1f5-f9bc162b2349/exec-143c6550-3680-467e-b71d-d62f0617cfb9.png`; project-bound copy: `GreyVision/Resources/Generated/AppIconBackground.png`.

## Platform references

| Framework | Use |
|---|---|
| AVFoundation | Camera discovery/configuration, sample-buffer capture, audio capture, raw recording, and writer lifecycle. |
| CoreVideo | Bi-planar pixel buffers and `CVMetalTextureCache` plane mapping. |
| Metal / MetalKit | YUV conversion, ordered effects, temporal storage, compute particles, point cloud, and preview. |
| Accelerate | Preallocated vDSP FFT, band energy, and RMS analysis. |
| Vision | Person segmentation, tracking metadata, and bounded optical-flow requests. |
| ARKit | Exclusive scene-depth source, confidence, intrinsics, transforms, and timestamps. |
| CoreMotion | Gyroscope-driven modulation. |
| Photos | Explicit user-initiated still/video library saves. |

## Apple implementation references

| Reference | Applied contract |
|---|---|
| [AVCaptureSession 4K preset](https://developer.apple.com/documentation/avfoundation/avcapturesession/preset/hd4k3840x2160) | Establishes 3840×2160 as the platform 4K capture size. The app uses input-priority format selection while enforcing the same minimum dimensions. |
| [AVCaptureDevice format frame-rate ranges](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/videosupportedframerateranges) | Resolves the requested cadence only within a range advertised by the selected 4K format. |
| [Creating a fog effect using scene depth](https://developer.apple.com/documentation/arkit/creating-a-fog-effect-using-scene-depth) | Uses real `sceneDepth` / `smoothedSceneDepth` data and confidence rather than inferred or synthetic depth. |
| [Displaying a point cloud using scene depth](https://developer.apple.com/documentation/arkit/displaying-a-point-cloud-using-scene-depth) | Reconstructs camera-space XYZ from metric depth and camera intrinsics. |

## Vault policy

Reference vault repositories may be consulted only for isolated subsystem concepts after the corresponding gate begins. They are never linked, copied wholesale, or treated as product source. Any later consultation is recorded below with the exact file and the concept learned.

No vault subsystem files have been imported or consulted for implementation.

## Brand constants

- Display name: `grey//VISION`
- Product and scheme: `GreyVision`
- Bundle identifier: `com.saringrey.greyvision`
- Instagram: `https://instagram.com/bigbabygrey`
- GitHub: `https://github.com/saringrey`
- Visual character: black instrument surface, white rules/type, violet energy, camera-interface overlays, restrained digital decay.

## Capability truthfulness

Factory presets, effects, codecs, depth modes, and readiness labels are exposed only with an implemented backing seam. Future effect cards carry their exact gate/unavailable reason instead of pretending to alter pixels. Simulator sources are labelled and never assert hardware codec support. Live temporal datamosh is not described as codec-level/offline bitstream datamosh.
