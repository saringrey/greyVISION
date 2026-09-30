# grey//VISION iOS Code Audit

**Scope:** Current working tree, excluding `.git`, `Dead/`, Pods, and build outputs. The tree contains 509 Swift files / 103,925 reported lines and five Metal files; this count includes a nested `.claude/worktrees` checkout. The active application sources were audited, with emphasis on the workspace, capture, AR, broadcast, persistence, and accessibility paths.

**Build ground truth:** A clean Debug iPhoneOS build was run on 2026-08-29. It fails because `WorkspaceView` references four absent timeline/radial-menu types. The compiler also reports the concurrency and cleanup warnings cited below. Metal-kernel algorithmic correctness, profiling, build configuration, third-party internals, test coverage, and localization were not audited.

## 1. Executive summary

1. **[High] The current workspace cannot compile because timeline and radial-menu types are absent** — §5.1 — `GreyVision/Features/Workspace/WorkspaceView.swift:63-67, 422-430, 1339-1342`
2. **[High] Notification callbacks violate the main-actor boundary** — §3.1 — `GreyVision/App/AccessibilityObserver.swift:30-76`
3. **[High] AR audio recording captures non-Sendable AVFoundation objects in a queue closure** — §3.2 — `GreyVision/Engine/AR/ARRecordingSession.swift:253-258`
4. **[High] Broadcast encoding captures a pixel buffer in a queue closure** — §3.3 — `GreyVision/Engine/Broadcast/GVBroadcastEngine.swift:140-174`
5. **[Medium] The Burn HUD setting cannot affect a recording** — §5.2 — `GreyVision/Engine/Capture/GVCaptureCoordinator.swift:270-295`
6. **[Medium] Denied screenshot saves retain temporary image files and repeated saves can collide** — §5.3 — `GreyVision/Engine/Capture/GVScreenCapture.swift:15-40`
7. **[Medium] Broadcast uses a source-visible, fixed automatic-pairing secret** — §6.1 — `GreyVision/Engine/Broadcast/GVBroadcastProtocol.swift:28-35`, `GreyVision/Engine/Broadcast/GVBroadcastLink.swift:267-286`
8. **[Medium] Recipe persistence and export failures are silently discarded** — §9.1 — `GreyVision/Features/Workspace/GVPresetStore.swift:138-167`

## 2. Quick wins

### 2.1 Remove the unused successful-recording URL binding
- **Location:** `GreyVision/Engine/Capture/GVCaptureCoordinator.swift:305-315`
- **What:** The clean build warns that the successful-recording URL is bound but never read.
- **Why:** It adds compiler-noise to the warning baseline.
- **Action:** Match the success case without binding the URL, or use it in a diagnostic.
- **Severity:** Low

### 2.2 Remove redundant `await` markers in the boot sequence
- **Location:** `GreyVision/Features/Launch/Boot/BootSequenceManager.swift:128-131`
- **What:** The compiler reports that an `await` is applied where no asynchronous work occurs.
- **Why:** It obscures the actual isolation and scheduling behavior.
- **Action:** Remove the unnecessary effect marker after confirming the called methods' isolation.
- **Severity:** Low

### 2.3 Keep icon-only controls explicitly named
- **Location:** `GreyVision/DesignSystem/GVCompactDeckKit.swift:266-318`, `GreyVision/DesignSystem/GVCompactDeckKit.swift:342-379`
- **What:** The shared chip and pager now contain accessibility labels, but future icon-only additions can fall back to the generic label `Control`.
- **Why:** Generic labels make an otherwise dense operator interface difficult to use with VoiceOver.
- **Action:** Require an action-specific accessibility label for every icon-only control at review time.
- **Severity:** Low

## 3. Concurrency

### 3.1 Notification callbacks call main-actor methods from nonisolated closures
- **Location:** `GreyVision/App/AccessibilityObserver.swift:30-76`, `GreyVision/App/AccessibilityObserver.swift:173-229`
- **What:** Five `NotificationCenter` block observers synchronously call methods on a `@MainActor` object; the clean build reports actor-isolation warnings for each call.
- **Why:** This is already a Swift 6 warning and risks becoming a build error under stricter concurrency checking.
- **Action:** Explicitly hop to the main actor from each observer callback, or adopt an actor-isolated observation API.
- **Severity:** High

### 3.2 AR audio recording crosses a Sendable boundary with media objects
- **Location:** `GreyVision/Engine/AR/ARRecordingSession.swift:249-258`
- **What:** `AVAssetWriterInput` and `CMSampleBuffer` are captured by `writerQueue.async`; both are reported non-Sendable by the compiler.
- **Why:** Ownership and lifetime of the input and sample buffer are not encoded at the asynchronous handoff.
- **Action:** Give one serial owner responsibility for writer input and samples, with an explicit, audited media-object handoff.
- **Severity:** High

### 3.3 Broadcast frame submission crosses a Sendable boundary with a pixel buffer
- **Location:** `GreyVision/Engine/Broadcast/GVBroadcastEngine.swift:140-174`
- **What:** `CVPixelBuffer` is captured in `encodeQueue.async`; the clean build reports the non-Sendable capture.
- **Why:** The renderer and encoder can access the same Core Video object without compiler-checked ownership.
- **Action:** Establish a serial encoder owner or an audited retained-frame handoff before queueing work.
- **Severity:** High

### 3.4 Capture completion also crosses a non-Sendable AVFoundation boundary
- **Location:** `GreyVision/Engine/Capture/GVCaptureWriter.swift:233-266`
- **What:** The clean build reports that the `finishWriting` completion captures `AVAssetWriter` in a Sendable closure.
- **Why:** This expands the project's undefined media-ownership pattern beyond AR and broadcast paths.
- **Action:** Apply the same explicit media-object ownership rule to writer completion.
- **Severity:** Medium

## 4. API modernity

### 4.1 Display-zoom support is advertised but permanently reports the default
- **Location:** `GreyVision/App/AccessibilityObserver.swift:59-67`, `GreyVision/App/AccessibilityObserver.swift:121-129`, `GreyVision/App/AccessibilityObserver.swift:204-212`
- **What:** Brightness changes are used to trigger display-scale handling while `detectDisplayZoom()` always returns `1.0`.
- **Why:** Consumers receive a display-zoom value that never reflects the device setting, and brightness changes create unnecessary work.
- **Action:** Source the value from an appropriate window/view environment, or remove the unsupported field and observer.
- **Severity:** Medium

## 5. Bugs / logic errors

### 5.1 Workspace references unavailable timeline and radial-menu implementations
- **Location:** `GreyVision/Features/Workspace/WorkspaceView.swift:61-70`, `GreyVision/Features/Workspace/WorkspaceView.swift:418-430`, `GreyVision/Features/Workspace/WorkspaceView.swift:1339-1342`
- **What:** `GVTimelineStore`, `GVTimelinePlayer`, `GVBeatDetector`, and `GVRadialPieMenu` are referenced but are not available to the target; the clean build fails at these sites.
- **Why:** The application cannot be built, installed, or shipped from the current tree.
- **Action:** Restore and include the implementations in the GreyVision target, or remove the incomplete feature references as one coherent change.
- **Severity:** High

### 5.2 The Burn HUD preference is ignored by recording configuration
- **Location:** `GreyVision/Features/Workspace/WorkspaceView.swift:998-1006`, `GreyVision/Engine/Capture/GVCaptureCoordinator.swift:270-295`
- **What:** The settings UI toggles `watermarkEnabled`, but recording preparation hard-codes `burnHUD` to `false`, making the watermark expression unreachable.
- **Why:** Operators can enable a capture setting that has no effect on the produced recording.
- **Action:** Pass the preference through the recording transaction or remove the exposed setting until its ownership is implemented.
- **Severity:** Medium

### 5.3 Screenshot temporary files leak on authorization denial and can collide
- **Location:** `GreyVision/Engine/Capture/GVScreenCapture.swift:15-40`
- **What:** A PNG is written before Photos authorization; the denial branch returns without deletion, and filenames use whole-second timestamps.
- **Why:** Denied captures retain potentially sensitive imagery in temporary storage, while two saves within a second target the same path.
- **Action:** Use unique temporary URLs and delete the file on every terminal branch.
- **Severity:** Medium

### 5.4 Recipe export uses the display name directly as a filename
- **Location:** `GreyVision/Features/Workspace/GVPresetStore.swift:138-142`
- **What:** A user-controlled recipe name is interpolated into the export path without filename sanitization.
- **Why:** Path separators or invalid filename characters can make export fail or create unintended paths below the recipe directory.
- **Action:** Generate a filesystem-safe export filename independent of the display name.
- **Severity:** Low

## 6. Security

### 6.1 Broadcast pairing uses a fixed shared secret
- **Location:** `GreyVision/Engine/Broadcast/GVBroadcastProtocol.swift:28-35`, `GreyVision/Engine/Broadcast/GVBroadcastLink.swift:267-286`
- **What:** The TLS PSK is deterministically derived from a source-visible constant shared by all installations.
- **Why:** Anyone who has the app or source can derive the credential for an automatically discovered broadcast endpoint.
- **Action:** Use a per-session, user-confirmed pairing secret and expire it after pairing.
- **Severity:** Medium

### 6.2 Incoming broadcast commands execute while the link lock is held
- **Location:** `GreyVision/Engine/Broadcast/GVBroadcastLink.swift:242-255`
- **What:** The command callback is retrieved and invoked inside `lock.withLock`.
- **Why:** A future callback that re-enters link state or transmission can deadlock the network path.
- **Action:** Copy the callback under lock and invoke it after releasing the lock.
- **Severity:** Medium

## 7. Performance

### 7.1 The workspace retains a broad invalidation surface
- **Location:** `GreyVision/Features/Workspace/WorkspaceView.swift:4-84`, `GreyVision/Features/Workspace/WorkspaceView.swift:490-579`
- **What:** The root workspace observes source, capture, effects, audio, broadcast, HUD, timeline, toast, and overlay state while constructing the full workspace hierarchy.
- **Why:** Frequent runtime updates can recompute unrelated chrome and viewfinder structure.
- **Action:** Split stable viewport, top chrome, capture controls, dock, and optional timeline surfaces into narrowly observed subviews.
- **Severity:** Medium

### 7.2 Timeline processing schedules a 60 Hz SwiftUI update path
- **Location:** `GreyVision/Features/Workspace/WorkspaceView.swift:574-579`
- **What:** A `TimelineView` is mounted to feed the beat detector on every animation-frame interval.
- **Why:** Once the feature compiles, it can enlarge the root workspace's invalidation load even when the operator is not editing a timeline.
- **Action:** Scope the cadence to the active feature and keep display-link work out of broad view-body dependencies.
- **Severity:** Medium

## 8. SwiftUI / UI

### 8.1 Parameter-pager actions are now individually exposed, but their compact layout remains below the standard target height
- **Location:** `GreyVision/DesignSystem/GVCompactDeckKit.swift:342-379`
- **What:** The previous/next controls are explicit VoiceOver elements, but their visible row is fixed at 24 points.
- **Why:** Dense, image-only navigation is harder to acquire reliably when visual and hit-target sizing are not clearly separated.
- **Action:** Retain the compact appearance while giving each pager control an explicit minimum touch target.
- **Severity:** Low

### 8.2 Capture format and aspect controls only cycle forward
- **Location:** `GreyVision/Features/Workspace/CameraControlsView.swift:189-246`
- **What:** Resolution and aspect buttons advance through fixed lists with no direct selection, reverse direction, or next-value hint.
- **Why:** Reaching a previous setting requires repeated taps and the result is not predictable from the control's accessibility output.
- **Action:** Provide an explicit selector or expose the next value and a reverse/direct-selection path.
- **Severity:** Low

## 9. Dead code / duplication / refactor

### 9.1 Recipe persistence and export failures are silent
- **Location:** `GreyVision/Features/Workspace/GVPresetStore.swift:138-167`
- **What:** Export, encoding, disk write, disk read, and decode failures are handled with `try?` or `nil` without diagnostics.
- **Why:** A failed save or unreadable recipe is indistinguishable from lost user work.
- **Action:** Preserve the prior valid data, record structured errors, and route save/import/export failures through the existing toast channel.
- **Severity:** Medium

### 9.2 Photo authorization and save behavior are duplicated across capture paths
- **Location:** `GreyVision/Engine/Capture/GVScreenCapture.swift:23-55`, `GreyVision/Engine/Capture/GVCaptureWriter.swift:259-265`, `GreyVision/Engine/AR/ARRecordingSession.swift:291-327`
- **What:** Still, processed-video, and AR-video paths each implement their own PhotoKit authorization and cleanup contract.
- **Why:** The screenshot denial leak demonstrates how behavior can drift between copies.
- **Action:** Consolidate authorization, save, and temporary-file cleanup behind one typed photo-library boundary.
- **Severity:** Medium

### 9.3 Large workspace files couple unrelated UI concerns
- **Location:** `GreyVision/Features/Workspace/WorkspaceView.swift:4-1493`, `GreyVision/Features/Workspace/WorkspaceEffectParameters.swift:1-1880`, `GreyVision/Engine/Rendering/CameraMetalSurface.swift:1-2578`
- **What:** Primary UI composition, effect schemas, and rendering orchestration are each maintained in multi-thousand-line files.
- **Why:** This increases merge conflict risk and makes state, performance, and interaction regressions difficult to isolate.
- **Action:** Split along stable boundaries: workspace chrome, source/viewfinder, decks, effect schemas, and renderer passes.
- **Severity:** Medium

## 10. Cross-cutting recommendations

### 10.1 Establish one media-object ownership model
- **Location:** `GreyVision/Engine/AR/ARRecordingSession.swift:253-258`, `GreyVision/Engine/Broadcast/GVBroadcastEngine.swift:151-174`, `GreyVision/Engine/Capture/GVCaptureWriter.swift:249-266`
- **What:** Core Media, Core Video, and AVFoundation objects cross asynchronous closures using different ad-hoc patterns.
- **Why:** The three compiler warnings have the same root cause and will continue to spread under Swift 6.
- **Action:** Adopt a documented serial-owner or audited handoff pattern for all media objects.
- **Severity:** High

### 10.2 Make operator-visible settings transactional
- **Location:** `GreyVision/Features/Workspace/WorkspaceView.swift:998-1006`, `GreyVision/Engine/Capture/GVCaptureCoordinator.swift:270-295`, `GreyVision/Features/Workspace/GVPresetStore.swift:138-167`
- **What:** Settings can be toggled, saved, exported, and recorded through disconnected state paths with silent failures.
- **Why:** The interface can report an enabled choice that the capture transaction does not honor.
- **Action:** Define one source of truth and explicit success/failure feedback for each persisted or capture-affecting setting.
- **Severity:** Medium

## 11. What was NOT audited

_No findings._

- Deep mathematical or visual correctness of Metal kernels.
- Instruments-based CPU, GPU, memory, battery, or network profiling.
- Xcode project/build-setting correctness beyond the Debug build attempt.
- Third-party and system-framework internals.
- Comprehensive test coverage, localization wording, and VoiceOver runtime testing on hardware.
- The nested `.claude/worktrees` checkout was not treated as active application source.

## 12. Verification

- **§3.1** — The clean build reports actor-isolation warnings at `AccessibilityObserver.swift:35, 45, 55, 65, 75`; each invocation is visible at `30-76`.
- **§3.2** — The clean build reports non-Sendable captures at `ARRecordingSession.swift:255-256`; the queue closure is visible at `253-258`.
- **§3.3** — The clean build reports the non-Sendable pixel-buffer capture at `GVBroadcastEngine.swift:156`; the asynchronous handoff is visible at `140-174`.
- **§5.1** — The clean build fails at `WorkspaceView.swift:63-65` and `1341`; the unavailable types and their UI call site are visible at `61-70`, `418-430`, and `1339-1342`.
- **§10.1** — The three compiler warnings above establish the shared asynchronous media-ownership issue at the cited AR, broadcast, and capture-writer locations.
