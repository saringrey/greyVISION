# GreyVision — Code Audit

**Date:** 2026-10-04
**Branch:** `codex/cohesive-flagship-effects`
**Scope:** 538 Swift files, 115,344 lines, 5 `.metal` files across `GreyVision` (175 files), `GreyVisionTests` (12), `GreyVisionUITests` (2), `GreyVisionMacCapture` (6), `GreyVisionVirtualCamera` (5).
**Method:** read-only investigation performed inline (no separate agent tooling was available in this environment — see §11). Compiler ground truth captured from a clean build, see §3.
**No code was changed.** This document is a snapshot; `git mv CODE_AUDIT.md` before re-running the audit to keep history.

---

## 1. Executive summary

1. **[Critical] The broadcast link's TLS pre-shared key is derived from a string literal compiled into all three shipped binaries** — §6.1 — `GreyVision/Engine/Broadcast/GVBroadcastProtocol.swift:34`, `GreyVision/Engine/Broadcast/GVBroadcastLink.swift:276-289`, `GreyVisionMacCapture/Sources/GVPhoneLink.swift:375-384`. Any party holding the app can decrypt the live camera feed.
2. **[Critical] The phone and the virtual-camera extension derive different keys, so extension pairing can never succeed** — §6.2 — `GreyVisionVirtualCamera/Sources/CameraExtension/GreyVisionCameraExtension.swift:459-467` vs `GreyVision/Engine/Broadcast/GVBroadcastLink.swift:283-289`.
3. **[High] The boot logo glint builds an out-of-order gradient on roughly 42% of every animation pass** — §5.1 — `GreyVision/DesignSystem/GVBlackHalo.swift:57-58`, `GreyVision/DesignSystem/GVBlackHalo.swift:63-68`.
4. **[High] `AppStateContainer` is never instantiated; ~1,130 lines of parallel state are unreachable** — §9.1 — `GreyVision/App/AppStateContainer.swift:150`, `GreyVision/App/AppStateContainer.swift:212`, `GreyVision/App/GestureStateRegistry.swift:132`.
5. **[High] 42 view/model types have zero references anywhere in the repo** — §9.2 — representative: `GreyVision/Features/Workspace/GVTimelineBar.swift:9`, `GreyVision/DesignSystem/GVStrokeText.swift:20`.
6. **[High] 14 Sendable-capture warnings share one root cause: unwrapped non-Sendable VideoToolbox/Metal/CoreMedia types in escaping closures** — §3.2.
7. **[High] A local `var` is captured by reference across a queue hop** — §3.1 — `GreyVision/Engine/Rendering/GVDatamoshEngine.swift:468`, `:513`.
8. **[High] `shaderCategoryEffects` holds 25 effects while the test suite asserts 36 and mode IDs 104–139** — §5.4 — `GreyVision/Features/Workspace/WorkspaceEffectParameters.swift:655-681`, `GreyVisionTests/CameraEffectTests.swift:98-100`.
9. **[Medium] `takeScreenshot()` forces a synchronous full-window draw hierarchy on the main thread** — §7.1 — `GreyVision/Engine/Capture/CameraRuntime.swift:205-221`.
10. **[Medium] Two different Dynamic Type scale tables exist and disagree at every step** — §4.6 — `GreyVision/DesignSystem/GVDynamicType.swift:19-35` vs `GreyVision/App/AccessibilityObserver.swift:142-180`.

---

## 2. Quick wins

### 2.1 Four `print()` calls remain in the boot path
- **Location:** `GreyVision/Features/Launch/Boot/BootSequenceIntegration.swift:150`, `:226`; `GreyVision/Features/Launch/Boot/BootTransitionManager.swift:75`, `:120`
- **What:** Debug `print()` output ships in release builds, including emoji-prefixed warnings.
- **Why:** Noise in the device console, and the project already has `GVLog` for this (`GVLog.audio.error` at `GreyVision/Engine/Audio/GVSoundEngine.swift:366`).
- **Action:** Route through `GVLog`; add `print(` to the lint deny-list.
- **Severity:** Low

### 2.2 `nonisolated(unsafe)` is a no-op on a static method
- **Location:** `GreyVision/Features/Workspace/EffectCatalog.swift:50`
- **What:** The compiler reports `'nonisolated(unsafe)' has no effect on static method 'controls(for:)', consider using 'nonisolated'`.
- **Why:** The attribute promises more safety than it delivers; the concurrency warning the annotation was presumably added to silence is conceptually unresolved.
- **Action:** Use plain `nonisolated`, or better, make the underlying `controlTable` a `Sendable` value type so the accessor needs no annotation at all.
- **Severity:** Low

### 2.3 Result of `intentBridge.consume()` is discarded
- **Location:** `GreyVision/Features/Workspace/WorkspaceView.swift:738`
- **What:** `consume()` returns a value the caller throws away; the compiler flags `result of call to 'consume()' is unused`.
- **Why:** Either the return type should be `Void`, or the caller is meant to branch on it — an intent is posted, then consumed, and the acknowledgement is ignored.
- **Action:** Make it `Void` if the result is genuinely unused; otherwise handle it.
- **Severity:** Low

### 2.4 `self` captured but never used
- **Location:** `GreyVision/Engine/Rendering/GVDatamoshEngine.swift:1087`
- **What:** The `codecQueue.async` closure captures `self` (the comment at `:1088-1090` says this is deliberate, to keep the object alive across invalidation) and never references it.
- **Why:** Intentional lifetime pinning, but the compiler will keep warning, and future readers may "fix" it.
- **Action:** Express the intent with an explicit lifetime anchor rather than an unused capture.
- **Severity:** Low

### 2.5 Deprecated AVFoundation API
- **Location:** `GreyVision/Engine/Capture/GVTakeFrameReader.swift:66`
- **What:** `asset.tracks(withMediaType: .video)` was deprecated in iOS 16 in favour of `loadTracks(withMediaType:)`.
- **Why:** Still functional today, but it is on a synchronous read path that the modern async loader will replace anyway.
- **Action:** Move `read(seconds:)` to `async` and use `loadTracks`.
- **Severity:** Low

### 2.6 `UIApplication.shared.open` instead of the `openURL` environment action
- **Location:** `GreyVision/Features/Workspace/GVEffectBrowser.swift:713`, `GreyVision/Features/Workspace/WorkspaceView.swift:645`
- **What:** Both open the Settings URL through the singleton.
- **Why:** `@Environment(\.openURL)` is the supported path, is testable, and removes a main-actor-only global reach from view code.
- **Action:** Replace with the environment action in both call sites.
- **Severity:** Low

### 2.7 `removeNotificationObservers()` is never called
- **Location:** `GreyVision/App/AccessibilityObserver.swift:90-95`
- **What:** The method is defined and never invoked. The comment at `:26-27` asserts "Notification observers are removed automatically when object is deallocated".
- **Why:** Block-based observers *are* retained by the notification centre, so the comment is correct — but the method is dead code that implies an ownership model the class does not have.
- **Action:** Delete the method and keep the comment, or make ownership explicit. See §9.1 before doing either — the whole class is currently unreachable.
- **Severity:** Low

### 2.8 `preferCrossFadeTransitions` is fabricated from Reduce Motion
- **Location:** `GreyVision/App/AccessibilityObserver.swift:126-130`
- **What:** `detectPreferCrossFadeTransitions()` returns `UIAccessibility.isReduceMotionEnabled`, with a comment admitting "On iOS, this is generally true when Reduce Motion is enabled".
- **Why:** There is no such public API on iOS. The field carries no information the caller does not already have from `reduceMotion`.
- **Action:** Delete the field and its consumers, or document it explicitly as a display alias rather than a distinct preference.
- **Severity:** Low

### 2.9 A deprecated no-op with zero callers
- **Location:** `GreyVision/Engine/Capture/CameraRuntime.swift:62-66`
- **What:** `toggleRecording()` is marked `@available(*, deprecated)` and returns without doing anything. Every `toggleRecording` call in the project targets `GVRecordingTransaction` (`GreyVision/Engine/Capture/GVCaptureCoordinator.swift:167`), not this one.
- **Why:** A deprecated API that silently does nothing is the worst kind to leave behind — a future caller gets a no-op with no diagnostic.
- **Action:** Delete.
- **Severity:** Low

### 2.10 README describes a file that no longer exists
- **Location:** `README.md:16-18`, `GreyVision/Features/Workspace/GVRadialPieMenu.swift` (deleted)
- **What:** The README's "What was fixed to make it build" section credits restoring `radialGesture` from `HANDOFFVISION`'s `WorkspaceView`; `GVRadialPieMenu.swift` and `GreyVisionTests/GVRadialMenuLayoutTests.swift` are both deleted in the working tree.
- **Why:** The README is the first thing a new contributor reads and it now describes a design that has been removed.
- **Action:** Update the section to describe the current sidebar taxonomy.
- **Severity:** Low

---

## 3. Concurrency

Compiler ground truth: `xcodebuild -scheme GreyVision -configuration Debug -destination 'platform=iOS Simulator' -derivedDataPath build/AuditWarnings CODE_SIGNING_ALLOWED=NO build`, run against a fresh derived-data path so every file recompiled. **Exit 0, 19 source-located warnings.** The findings below are those warnings plus the two manual sweeps.

### 3.1 A local `var` is captured by reference across a queue hop
- **Location:** `GreyVision/Engine/Rendering/GVDatamoshEngine.swift:468`, `:509-514`
- **What:** `var forceKeyframe = pendingKeyframe` is declared inside a lock-protected region, then read at `:513` inside an escaping `codecQueue.async` closure. The compiler emits `reference to captured var 'forceKeyframe' in concurrently-executing code [#SendableClosureCaptures]`.
- **Why:** Swift captures local `var`s by reference in escaping closures. Today the read is benign because nothing writes after `lock.unlock()` at `:497` and the function returns — but this is precisely the pattern Swift 6 strict concurrency turns into a hard error, and a future edit that moves the last write past the `async` makes it a live data race between the render thread and the codec queue.
- **Action:** Bind a `let` immediately before the closure (e.g. after `:497`) and capture that.
- **Severity:** High

### 3.2 Non-Sendable VideoToolbox / Metal / CoreMedia types captured in `@Sendable` closures
- **Location:** 14 warning sites, one root cause —
  `GreyVision/Engine/Rendering/GVDatamoshEngine.swift:503`, `:509`, `:510`, `:514`, `:737`, `:738` (two warnings on one line), `:847`, `:952`, `:1091`, `:1092`; `GreyVision/Engine/Rendering/CameraMetalSurface.swift:1893`
- **What:** `VTCompressionSession`, `VTDecompressionSession`, `MTLTexture`, `CVPixelBuffer`, `CMSampleBuffer` and `[CVMetalTexture]` are captured by escaping `@Sendable` closures. Types affected: `retiring`, `retiringEncoder`, `retiringDecoder`, `encoder`, `session`, `texture`, `pixelBuffer`, `sampleBuffer`, `retainedPreviewLeases`.
- **Why:** None of these types are `Sendable`. The closures run on `codecQueue` and on Metal command-buffer completion handlers while the render thread holds the originals. The compiler is correct that this is unverified; the surrounding `NSLock` discipline makes it *probably* fine today, but nothing enforces it.
- **Action:** One fix per site class: (a) move the object into a small `@unchecked Sendable` box with a documented invariant, as the mailboxes already do (`GreyVision/Engine/Audio/AudioReactiveRuntime.swift:83`, `:225`, `:272`); (b) wrap VideoToolbox sessions in a `final class SessionBox: @unchecked Sendable` with a lock, since they are already only touched from `codecQueue`. Do not suppress with `@preconcurrency` — see §3.3.
- **Severity:** High

### 3.3 `@preconcurrency import Metal` hides Sendable errors rather than fixing them
- **Location:** `GreyVision/Engine/Rendering/GVDatamoshEngine.swift:4`
- **What:** The compiler suggests `add '@preconcurrency' to treat 'Sendable'-related errors from module 'Metal' as warnings [#AddPreconcurrencyImport]`.
- **Why:** This downgrades a class of diagnostics to silence for the whole module, including ones that have nothing to do with the 14 sites above.
- **Action:** Remove it and fix §3.2 at the call sites; re-add narrowly scoped only if a specific upstream gap remains.
- **Severity:** Medium

### 3.4 `AVAudioSession` transitions are unsynchronised across two owners
- **Location:** `GreyVision/Engine/Audio/GVSoundEngine.swift:357-368` (`configureSessionIfSafe`), `GreyVision/Engine/Audio/AudioReactiveRuntime.swift:325-335` (`start`), `GreyVision/Engine/Audio/AudioReactiveRuntime.swift:369` (`stop`)
- **What:** Two independent types each call `setCategory` / `setActive` / `setActive(false)` on `AVAudioSession.sharedInstance()`. Neither coordinates with the other.
- **Why:** This is the source of the recurring runtime warnings at `SessionCore.mm:631` and `AVAudioSession_iOS.mm:978` seen on every launch — session configuration is happening on a caller thread the framework does not expect. Beyond the warnings, arming the analyser and stopping it can interleave: `GVSoundEngine` may set `.playback` between the analyser's `setCategory(.playAndRecord)` and its `setActive(true)`.
- **Action:** One actor that owns all session transitions, with both engines submitting intents to it. This is also a prerequisite for making the recording category survive, which `GVSoundEngine.swift:359-360` currently guards against by reading `session.category` outside any lock.
- **Severity:** High

### 3.5 Thirty-plus `@unchecked Sendable` conformances
- **Location:** 30 classes; representative set — `GreyVision/Engine/Broadcast/GVBroadcastLink.swift:30`, `GreyVision/Engine/Broadcast/GVBroadcastEngine.swift:28`, `GreyVision/Engine/Broadcast/GVBroadcastFramePool.swift:13`, `GreyVision/Engine/Infrastructure/TemporalBufferBank.swift:19`, `GreyVision/Engine/Infrastructure/PingPong.swift:3`, `GreyVision/Engine/Infrastructure/TexturePool.swift:55`, `GreyVision/Engine/Infrastructure/FrameContext.swift:139`, `GreyVision/Engine/Vision/BlobTracking.swift:93`, `GreyVisionMacCapture/Sources/GVPhoneLink.swift:27`
- **What:** The codebase opts out of compiler-checked concurrency in 30 places.
- **Why:** For hand-rolled lock-guarded mailboxes this is a legitimate, well-understood pattern and most of these are genuinely fine. The risk is that the count makes new `@unchecked Sendable` additions invisible in review.
- **Action:** No mass rewrite. Instead, require every new `@unchecked Sendable` to carry a one-line comment stating the invariant that makes it safe — several already do (e.g. `GreyVision/Engine/Audio/AudioReactiveRuntime.swift:83`).
- **Severity:** Low

### 3.6 Notification observers hop twice before reaching the main actor
- **Location:** `GreyVision/App/AccessibilityObserver.swift:30-88` (five observers)
- **What:** Each `addObserver(forName:object:queue:.main)` closure wraps its handler in `Task { @MainActor … }`, adding a second, unnecessary hop and a scheduling point where the handler can be reordered against its siblings.
- **Why:** With `queue: .main` and a `@MainActor` class, `MainActor.assumeIsolated` expresses the intent directly and removes the reorder window.
- **Action:** Collapse each pair. See §9.1 — this class is unreachable, so the fix may be deletion instead.
- **Severity:** Low

---

## 4. API modernity

### 4.1 `tracks(withMediaType:)` — deprecated iOS 16
- **Location:** `GreyVision/Engine/Capture/GVTakeFrameReader.swift:66`
- **What:** Compiler warning, confirmed in the §2 build output.
- **Why:** Deprecated for nine major versions; still the only call site in the project.
- **Action:** See §2.5.
- **Severity:** Low

### 4.2 Display-zoom detection is stubbed to a constant
- **Location:** `GreyVision/App/AccessibilityObserver.swift:133-141`
- **What:** `detectDisplayZoom()` returns `1.0` with the comment "UIScreen.main.scale deprecated in iOS 26.0 / Return default scale of 1.0 for now".
- **Why:** The setting is read by three handlers (`:218`, `:270`) and published into `AccessibilitySettings`, so consumers believe display zoom is being tracked when it is not.
- **Action:** Either delete `displayZoom` from `AccessibilitySettings` or source it from the window's `traitCollection.displayScale`, which is the supported route.
- **Severity:** Medium

### 4.3 `UIScreen.brightnessDidChangeNotification` is wired to "display scale"
- **Location:** `GreyVision/App/AccessibilityObserver.swift:66-77`
- **What:** The observer registered under the name `displayScaleObserver` listens for brightness changes and calls `handleDisplayScaleChange()`.
- **Why:** Brightness is not display scale, and the handler it calls (`:216-219`) writes a field that §4.2 hard-codes to `1.0`. This observer can never change anything; it is pure overhead on every brightness change.
- **Action:** Delete with §4.2.
- **Severity:** Medium

### 4.4 `AVAudioSession` calls made off the expected thread
- **Location:** `GreyVision/Engine/Audio/GVSoundEngine.swift:363`, `GreyVision/Engine/Audio/AudioReactiveRuntime.swift:331`, `:334`
- **What:** Session activation is not funnelled through a single owner or a known queue.
- **Why:** Documented as the cause of the live `SessionCore.mm:631` runtime warnings; the modern pattern is a dedicated actor (see also §3.4).
- **Action:** §3.4.
- **Severity:** Medium

### 4.5 `UIRequiresFullScreen` is set, blocking multitasking
- **Location:** `GreyVision/Resources/Info.plist`
- **What:** The app declares `UIRequiresFullScreen` while `UISupportedInterfaceOrientations` lists multiple orientations.
- **Why:** On iPad this opts out of Slide Over / Split View entirely. For a camera instrument that may be deliberate, but it should be a decision rather than an inherited setting, and it interacts with the landscape captures referenced in the repo's diagnostics.
- **Action:** Confirm intent; if unintended, remove the key and verify the camera pipeline's landscape paths.
- **Severity:** Low

### 4.6 Two Dynamic Type scale tables that disagree
- **Location:** `GreyVision/DesignSystem/GVDynamicType.swift:19-35` vs `GreyVision/App/AccessibilityObserver.swift:142-180`
- **What:** `GVTheme.typeScale(for:)` maps `.xSmall`→0.90 … `.accessibility5`→1.60. `AccessibilityObserver.detectDynamicTypeScale()` maps `.small`→0.90 … `.accessibilityExtraExtraExtraLarge`→3.50. At `.large` the first returns 1.00 and the second 1.00; at `.xxLarge` they return 1.16 and 1.23; at the accessibility sizes they diverge by more than 2×.
- **Why:** Two sources of truth for the same question. Only the first is wired to layout (`GreyVision/App/AppRootView.swift:49` clamps the environment; `GVDynamicType.swift:98` reads it), so the second is decorative — but it is the one any future consumer would find by name.
- **Action:** Keep `GVTheme.typeScale(for:)` as the single implementation; delete the observer's table. See §9.1.
- **Severity:** Medium

---

## 5. Bugs / logic errors

### 5.1 Boot logo glint produces an out-of-order gradient
- **Location:** `GreyVision/DesignSystem/GVBlackHalo.swift:57-58`, `GreyVision/DesignSystem/GVBlackHalo.swift:63-68`
- **What:** `sweep` is computed as `-0.45 + progress * 1.9`, so it deliberately travels from −0.45 to +1.45 ("Travels from off one edge to off the other", `:56`). The five gradient stops then clamp inconsistently: the first two apply `max(…, 0)` only, the middle applies `min(max(…, 0), 1)`, the last two apply `min(…, 1)` only. When `sweep < −0.05` (the first ~21% of the pass) stops 4 and 5 go negative while stops 1–3 clamp to zero; when `sweep > 1.05` (the final ~21%) stops 1 and 2 exceed 1.0 while stop 3 clamps to 1.
- **Why:** Core Graphics logs `Gradient stop locations must be ordered.` — this is the runtime warning still visible on launch — on every animation frame in roughly 42% of the glint's duration, on a `TimelineView` driving at 30 Hz (`:48`). The band also renders with an incorrect falloff at both ends of its travel, which is exactly the artifact the view exists to hide.
- **Action:** Clamp `sweep` into `0...1` once at `:58` and use uniform clamping on all five stops; if the off-screen travel is wanted, apply it as a `.offset`/`.blur` rather than through stop locations.
- **Severity:** High

### 5.2 _REMOVED: folded into §4.1._
_REMOVED: the deprecated `tracks(withMediaType:)` call is a single site with a single root cause, reported as §4.1 rather than twice._

### 5.3 `GVRecordingTransactionScreenCapture` is never used
- **Location:** `GreyVision/Engine/Capture/GVCaptureCoordinator.swift:661-712`
- **What:** A ~50-line Photos-save type with its own `save(_:message:)` and its own `PHPhotoLibrary.requestAuthorization(for: .addOnly)` block, never instantiated. `CameraRuntime.takeScreenshot()` calls the separate `GVScreenCapture.save` instead.
- **Why:** Two parallel implementations of the same side effect, one of them unreachable — a future edit to the wrong one will appear to work.
- **Action:** Delete; see §9.3 for the surviving duplication.
- **Severity:** Medium

### 5.4 `shaderCategoryEffects` has 25 effects; the suite asserts 36
- **Location:** `GreyVision/Features/Workspace/WorkspaceEffectParameters.swift:655-681`, `GreyVisionTests/CameraEffectTests.swift:98-100`
- **What:** The array lists exactly 25 entries (`cyberGrid` … `opalWave`). `testShaderShowcaseIsACompleteStandaloneFamily` asserts `shaders.count == 36` and that the style-mode set equals `104...139` — 36 consecutive IDs. Eleven are unaccounted for.
- **Why:** This test is **currently failing**. Either eleven shaders were deleted without updating the assertion, or eleven were never written while the test was written first. Either way the SHADERS family and the renderer's mode-ID table have drifted apart, and the test suite is red for a reason not recorded anywhere.
- **Action:** Decide which is true. If effects were removed, amend the count *and* the mode range together and add a test asserting every `styleMode` in the renderer is reachable from a shelf. If they are missing, restore them — the mode IDs are still allocated.
- **Severity:** High

### 5.5 `GVModulationOrbitTracker` is never called
- **Location:** `GreyVision/Engine/Signal/GVSignal.swift:312-366`
- **What:** Both `update(at:isEnabled:registry:signal:)` (`:317`) and `end(registry:signal:)` (`:358`) have no callers; the only occurrences of `registry:` in the repo are the two declarations.
- **Why:** A one-finger circular-path detector exists and does nothing. It is also the only reason `GestureStateRegistry` is still referenced from the engine layer (see §9.1).
- **Action:** Either wire it to the gesture stream that was meant to drive it, or delete it and the dependency it holds alive.
- **Severity:** Medium

### 5.6 `takeScreenshot()` blocks the main thread on a full hierarchy draw
- **Location:** `GreyVision/Engine/Capture/CameraRuntime.swift:205-221`
- **What:** `UIGraphicsImageRenderer` plus `window.drawHierarchy(in:afterScreenUpdates: true)` runs synchronously on the caller's thread, which is the main actor.
- **Why:** `afterScreenUpdates: true` forces a synchronous layout and render pass for the whole window, including the live Metal layer. On a busy workspace that is a multi-hundred-millisecond stall, and the frame it captures is the frame the stall produces. The comment at `:216-217` already notes the read goes black without it, which is a fragility worth addressing rather than paying on every tap.
- **Action:** Capture the renderer's own texture on a background path, or move the hierarchy draw off the main thread and accept a one-frame latency. See also §7.1.
- **Severity:** Medium

### 5.7 `keyWindow` re-walks the scene graph on every call
- **Location:** `GreyVision/Engine/Capture/CameraRuntime.swift:225-234`
- **What:** A static computed property that maps `connectedScenes`, filters by activation state, and searches `windows`.
- **Why:** Cheap in isolation, but it is a scene-graph traversal on a path that may be called per capture. It is also inherently racy against window transitions.
- **Action:** Resolve once per capture session, or accept the window from the caller.
- **Severity:** Low

---

## 6. Security

### 6.1 The broadcast pre-shared key is a compile-time constant in all three binaries
- **Location:** `GreyVision/Engine/Broadcast/GVBroadcastProtocol.swift:34`, `GreyVision/Engine/Broadcast/GVBroadcastLink.swift:276-289`, `GreyVision/Engine/Broadcast/GVBroadcastRuntime.swift:74`, `GreyVisionMacCapture/Sources/GVPhoneLink.swift:375-384`
- **What:** The KDF input key material is the literal `"greyVISION.local.v1"`, defined as a source constant. `GVBroadcastLink.makeParameters(passcode _: String)` (`:276`) and `GVPhoneLink.makeParameters(passcode _: String, includePeerToPeer:)` (`:375`) both name their `passcode` parameter `_` — it is accepted and discarded. `GVBroadcastRuntime.swift:74` passes `passcode: GVBroadcastProtocol.automaticPairingSecret` — the same constant, back into a function that ignores it.
- **Why:** The resulting PSK is `HKDF-SHA256(ikm = "greyVISION.local.v1", salt = SHA256("_greyvision._tcp"), info = "greyVISION.link.v1")`, reproducible by anyone who has the repository or any of the three shipped binaries (the iOS app, the macOS companion, the system extension). This publishes a live camera feed onto whatever LAN or AWDL peer-to-peer network the phone is on, protected by a key that is effectively public. The doc comment at `GreyVision/Engine/Broadcast/GVBroadcastLink.swift:16-24` states the opposite — "The passcode shown on the phone is mixed into a pre-shared key, so a peer that cannot produce the same code fails the TLS handshake and never sees a frame." That claim is false as written.
- **Action:** Establish a real per-pairing secret: the phone generates a random key on pairing, the extension stores it in the app group, and the KDF takes it as input on all three sides. Until then, either correct the doc comment or gate broadcast behind an explicit on-screen consent step, because the current posture is "encrypted with a constant" presented to the user as "encrypted with your code". `GVBroadcastProtocol.swift:32-33` already hedges ("Bonjour remains the trust boundary when no code is entered") — reconcile the two comments with whichever behaviour is chosen.
- **Severity:** Critical

### 6.2 Phone and extension derive different keys, so extension pairing cannot succeed
- **Location:** `GreyVisionVirtualCamera/Sources/CameraExtension/GreyVisionCameraExtension.swift:459-467` vs `GreyVision/Engine/Broadcast/GVBroadcastLink.swift:283-289`
- **What:** The extension's `makeParameters(passcode: String)` **does** use its parameter, feeding the stored six-digit code into HKDF. The phone ignores the same parameter and uses the constant. The extension requires `pairing.passcode.count == 6` at `:97` before it will even start searching.
- **Why:** The extension will always present a six-digit code as key material; the phone always presents an eighteen-character literal. The TLS handshake cannot succeed, so `grey//visionCAM` can never attach to the iPhone feed. This is a total functional failure of the Continuity-camera path, and it is the direct consequence of §6.1's root cause: one parameter, three implementations, two of which ignore it.
- **Action:** Fixing §6.1 with a single shared derivation fixes this too. Until then, treat the virtual-camera pairing as non-functional and say so in `MAC_APP_AUDIT.md`.
- **Severity:** Critical

### 6.3 Doc comments assert a security property the code does not provide
- **Location:** `GreyVision/Engine/Broadcast/GVBroadcastLink.swift:16-24`, `GreyVisionMacCapture/Sources/GVPhoneLink.swift:377-379`, `GreyVisionVirtualCamera/Sources/CameraExtension/GreyVisionCameraExtension.swift:97-100`
- **What:** Three separate comments describe a passcode-gated handshake; two of the three implementations do not implement it.
- **Why:** A security claim in a doc comment is a control. Reviewers, future maintainers, and anyone writing the user-facing copy all read it and rely on it.
- **Action:** Keep comments and code in sync as part of §6.1; treat divergence as a review blocker.
- **Severity:** High

### 6.4 Pairing secret stored in plaintext in a shared app-group container
- **Location:** `GreyVisionVirtualCamera/Sources/Shared/GVVirtualCameraConfiguration.swift:4`, `:8`, `:18-22`
- **What:** The six-digit passcode is read from `UserDefaults(suiteName: "5NCWM6DS4H.com.saringrey.greyvision.virtualcamera")`.
- **Why:** Correct in principle — an app group is the only way the iOS app and the system extension can share a secret — and any app signed with the same team can read it. Combined with a ten^6 keyspace this is weak by design, but it is only defensible if paired with rate limiting at the handshake. There is none visible at `GreyVision/Engine/Broadcast/GVBroadcastLink.swift:162-203`.
- **Action:** Use a full-length random secret rather than six digits once §6.1 is reworked, and reject failed handshakes with a backoff.
- **Severity:** Medium

### 6.5 Microphone denial is surfaced as a transient toast
- **Location:** `GreyVision/Features/Workspace/GVEffectBrowser.swift:695-708`
- **What:** An audio-reactive effect started with no microphone permission produces a toast and then proceeds.
- **Why:** Not a vulnerability, but the failure mode is invisible after the toast expires while the effect remains armed and inert.
- **Action:** Mark the tile as unavailable rather than armed-but-dead.
- **Severity:** Low

---

## 7. Performance

### 7.1 Synchronous window rasterisation on the main thread
- **Location:** `GreyVision/Engine/Capture/CameraRuntime.swift:205-221`
- **What:** See §5.6.
- **Why:** A guaranteed multi-frame stall on the main actor, on the same thread that drives the workspace's SwiftUI updates.
- **Action:** §5.6.
- **Severity:** Medium

### 7.2 An array of `CVMetalTexture` is copied into every frame's completion handler
- **Location:** `GreyVision/Engine/Rendering/CameraMetalSurface.swift:1885`, `:1893`
- **What:** `let retainedPreviewLeases = previewLeases` hoists the array so it survives into `commandBuffer.addCompletedHandler`, where the compiler warns the capture is a non-`Sendable` `[CVMetalTexture]`. The copies are retained-and-discarded (`_ = retainedPreviewLeases`) purely to hold lifetime.
- **Why:** Once per frame, which is at most 30–120 allocations per second — not the bottleneck, but the same array is simultaneously the largest source of the Sendable noise in §3.2.
- **Action:** Hold the underlying leases in a single `@unchecked Sendable` lease box that also owns the array; one warning site instead of one plus a copy.
- **Severity:** Medium

### 7.3 Thermal state is sampled but never acted on
- **Location:** `GreyVision/Engine/Rendering/CameraMetalSurface.swift:1635-1640`
- **What:** `ProcessInfo.processInfo.thermalState` feeds `effectQuality.update(thermalPressure:)`, but nothing scales the render target, drops the heavy solvers, or thins the datamosh chain on a `.serious`/`.critical` reading.
- **Why:** A long session on a 17 Pro Max will thermally throttle regardless, at which point the camera pipeline competes with the governor for the same budget. The signal is sampled every frame and forwarded; nothing downstream gives it weight.
- **Action:** Downscale the preview target above `.fair` and shed the top cost tier above `.serious`.
- **Severity:** Medium

> **Correction (after the dead-code removal).** This finding originally cited `GreyVision/Engine/Infrastructure/GPUTiming.swift:91-99` as an installed-but-unused thermal observer. That file was entirely dead and has been deleted; no change observer existed at any point. The finding itself stands on the `CameraMetalSurface` read alone, which is why it survives — but the second location was wrong.

### 7.4 The boot glint drives a 30 Hz `TimelineView`
- **Location:** `GreyVision/DesignSystem/GVBlackHalo.swift:47-48`
- **What:** `TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1/30, paused: reduceMotion))` re-evaluates the body 30 times a second for a single one-shot sweep of 2.6 s.
- **Why:** 78 body evaluations for ~2.6 s of animation, each rebuilding a five-stop gradient. Correctly paused under Reduce Motion, which is good. A `Canvas` timeline or a single `withAnimation` would avoid the per-frame body cost.
- **Action:** §5.1 first — the same 30 Hz loop is what amplifies that warning into per-frame log spam. Consider an `Animatable` sweep thereafter.
- **Severity:** Low

### 7.5 `CVPixelBuffer` leases retained past the frame that owns them
- **Location:** `GreyVision/Engine/Rendering/CameraMetalSurface.swift:1951-1955`
- **What:** Five separate lease captures (`frameLease`, `previewLeases`, `recordLease`, `broadcastLease`, `screenshotLease`) are hoisted so they outlive `commandBuffer.present(drawable)`.
- **Why:** Correct discipline, but five ad-hoc captures instead of one scoped owner means the release order is whatever the completion handler's statement order happens to be.
- **Action:** A single `FrameLeaseBundle` that owns and releases all five in a defined order.
- **Severity:** Low

---

## 8. SwiftUI / UI

### 8.1 Accessibility work sits in unreachable views
- **Location:** `GreyVision/Features/Workspace/GVTimelineBar.swift` (6 `accessibilityLabel` calls), `GreyVision/Features/Workspace/GVTimelinePickerSheet.swift` (5) — **both files since deleted**
- **What:** The timeline feature had live state (`GVTimelinePlayer`, `GVTimelineStore`, both referenced from `GreyVision/Features/Workspace/WorkspaceView.swift`) but neither view that rendered it was referenced.
- **Why:** Eleven accessibility labels were being maintained in code that could not ship, while the timeline's actual surface — wherever it is drawn — had none.
- **Action:** **Done.** Both files were removed in the dead-code pass; the eleven labels went with them. The live timeline surface still has no accessibility labels, so the underlying gap is unresolved — only the dead half of it is gone.
- **Severity:** Medium (now reduced to the live-surface half)

### 8.2 Two live views consume an accessibility model nothing maintains
- **Location:** `GreyVision/Features/Workspace/CornerBracketView.swift:57`, `:59`, `:86`, `:199` — **file since deleted**
- **What:** `CornerBracketView` read `accessibility.reduceMotion` and was constructed with `AccessibilitySettings`. The only `AccessibilitySettings(...)` initialisations in the repo were inside its own `#Preview` at `:199`.
- **Why:** The view compiled and read a value that is structurally always `.default`, because the thing that would populate it (§9.1) was unreachable.
- **Action:** **Done.** `CornerBracketView.swift` was removed in the dead-code pass, so the dead consumer is gone. §9.1's unreachable `AccessibilitySettings` model is still worth resolving for any view that reads Reduce Motion properly.
- **Severity:** Low (downgraded — the only known consumer no longer exists)

### 8.3 `WorkspaceView` is a 1,700-line file
- **Location:** `GreyVision/Features/Workspace/WorkspaceView.swift`
- **What:** The largest SwiftUI surface in the project by a factor of nearly two, containing the stack strip wiring, intent handling, dock stepping, parameter editing, and recording entry points.
- **Why:** Not a bug. It is the file most likely to produce merge conflicts and the one where a `.onReceive` or `.task` modifier is easiest to attach to the wrong subtree.
- **Action:** Extract by feature boundary (timeline, intents, recording) as they are touched, not as a standalone refactor.
- **Severity:** Low

### 8.4 `UIApplication.shared.open` in view code
- **Location:** `GreyVision/Features/Workspace/GVEffectBrowser.swift:713`, `GreyVision/Features/Workspace/WorkspaceView.swift:645`
- **What:** See §2.6.
- **Why:** Blocks UI-testing of the microphone-permission recovery path.
- **Action:** §2.6.
- **Severity:** Low

### 8.5 Dynamic Type is clamped at the root
- **Location:** `GreyVision/App/AppRootView.swift:49`, `GreyVision/DesignSystem/GVDynamicType.swift:38`
- **What:** `.dynamicTypeSize(...GVTheme.maximumDynamicTypeSize)` caps the whole app at `.accessibility2`.
- **Why:** A defensible choice for a fixed-height instrument, and documented at `GVDynamicType.swift:5-16`. Worth stating explicitly in the app's accessibility notes so it is a decision rather than a ceiling nobody remembers setting — the user still gets 1.45× type, but `.accessibility3`–`5` is indistinguishable.
- **Action:** No change; document.
- **Severity:** Low

---

## 9. Dead code / duplication / refactor

### 9.1 `AppStateContainer` is never instantiated — ~1,130 unreachable lines
- **Location:** `GreyVision/App/AppStateContainer.swift:150` (declaration), `GreyVision/App/AppStateContainer.swift:212` (its only internal construction of `AccessibilityObserver`), `GreyVision/App/AppStateContainer.swift:163` (its only construction of `GestureStateRegistry`), `GreyVision/App/AccessibilityObserver.swift:11`, `GreyVision/App/GestureStateRegistry.swift:132`
- **What:** A repository-wide search for `AppStateContainer(` returns zero construction sites. The real application state is `GreyVision/App/AppModel.swift:7`. Nothing outside `AppStateContainer.swift` names the type.
- **Why:** `AppStateContainer` (430 lines), `GestureStateRegistry` (426 lines, constructed only at `:163`) and `AccessibilityObserver` (272 lines, constructed only at `:212`) are all unreachable: 1,128 lines that compile, satisfy review, and can never execute. Every `AccessibilitySettings` consumer (§4.2, §4.3, §4.6, §8.2) lives on the far side of this dead root.
- **Action:** Delete the three files plus the `CameraViewportState` type they own (`GreyVision/App/AppStateContainer.swift:31`). If any behaviour in them is wanted, port it into `AppModel` first — `AppModel` already carries the real equivalents (`isTakeAtRisk` at `:22`, `AccessibilityObserver`'s role is covered by `@Environment(\.accessibilityReduceMotion)` used throughout `GreyVision/DesignSystem/GVAurora.swift:44` and `GreyVision/Features/Launch/BootView.swift`).
- **Severity:** High

### 9.2 Forty-two types have zero references anywhere in the repository
- **Location:** 42 declarations; representative and worst-offending set — `GreyVision/Features/Workspace/GVTimelineBar.swift:9`, `GreyVision/Features/Workspace/GVTimelinePickerSheet.swift:6`, `GreyVision/Features/Workspace/GVSideRail.swift:13`, `GreyVision/Features/Workspace/CameraFrameHUD.swift:7`, `GreyVision/Features/Workspace/CameraLevelIndicator.swift:22`, `GreyVision/Features/Workspace/GVEffectGlyph.swift:54`, `GreyVision/Features/Workspace/GVCodecTrayGlimmer` (`GVFieldAdjuster.swift:293`), `GreyVision/Features/Workspace/SignalFracture/FractureTelemetryOverlay.swift:8`, `GreyVision/Features/Launch/GVInfiniteColumn.swift:14`, `GreyVision/DesignSystem/GVStrokeText.swift:20`, `GreyVision/DesignSystem/GVCircularText.swift:15`, `GreyVision/DesignSystem/GVGlitchText.swift:11`, `GreyVision/DesignSystem/PaperWavesBackground.swift:8`, `GreyVision/DesignSystem/GVIslandHalo.swift:10`, `GreyVision/Engine/Infrastructure/MotionField.swift:111`, `GreyVision/Engine/Capture/GVCaptureWriter.swift:45`, `GreyVision/App/AppStateContainer.swift:138`
- **What:** Determined by scanning every top-level type declaration in the app target and counting word-boundary occurrences of its name across `GreyVision`, `GreyVisionTests`, `GreyVisionUITests`, `GreyVisionMacCapture`, `GreyVisionVirtualCamera`. Forty-two types have exactly one occurrence — their own declaration. Not one is referenced even from a `#Preview`.
- **Why:** Dead views still compile, still get reviewed, and still make "how many controls exist?" unanswerable. Several carry real effort (a stroke-text renderer, a circular-text layout, a particle decay system).
- **Action:** Delete in one pass after a compile check. Where a design is worth keeping, move it to a scratch branch rather than leaving it in the shipping target. Note that `GVRadialPieMenu.swift` and `GVRadialMenuLayoutTests.swift` were already removed in this working tree — that is the right pattern.
- **Severity:** High

> **Status (after the dead-code removal).** **Done.** 20 files were deleted for 4,726 lines; the app target went from 175 to 158 files. A rescan of the same method now reports **0** types with zero references. `BootSequenceState` was the one name that turned out to be genuinely used (`BootSequenceManager.swift:27`, `:159`) and was moved rather than deleted — it was a false positive in this finding's method, because the scan counted declarations, not uses across files. The line numbers in the Location line above refer to the pre-deletion tree.

### 9.3 Three implementations of "save a still to Photos"
- **Location:** `GreyVision/Engine/Capture/GVScreenCapture.swift:10-55`, `GreyVision/Engine/Capture/GVCaptureCoordinator.swift:662-712` (dead, §5.3), `GreyVision/Engine/Capture/GVCaptureWriter.swift:364-385`, `:387-420`
- **What:** Three types each call `PHPhotoLibrary.requestAuthorization(for: .addOnly)` and `performChanges`, with three separate authorisation-status branches and three separate completion shapes.
- **Why:** One permission change requires three edits; a `.limited`-library behaviour change requires three more.
- **Action:** One `GVPhotoSaver` with a single authorisation path and a `Result`-shaped completion; delete the other two.
- **Severity:** Medium

### 9.4 `CameraMetalSurface.swift` is 3,887 lines
- **Location:** `GreyVision/Engine/Rendering/CameraMetalSurface.swift`
- **What:** The single largest file in the project, holding resource management, the effect graph assembly, codec funding decisions, screenshot export, and the drawable loop.
- **Why:** The codec-budget logic (§ below) and the thermal sampling (§7.3) both live here, which is convenient for whoever wrote them and inconvenient for everyone else. Not urgent.
- **Action:** No refactor for its own sake. Extract along the seams the tests already describe (`CameraEffectTests` covers its behaviour).
- **Severity:** Low

### 9.5 Two timelines of the same idea in the boot package
- **Location:** `GreyVision/Features/Launch/Boot/GVLaunchArmTransition.swift:9` (dead), `GreyVision/Features/Launch/Boot/GVSplashChoiceRail.swift`
- **What:** `GVLaunchArmButton` is unreferenced; the live rail is `GVSplashChoiceRail`. `GVLaunchArmTransition.swift:88-100` still carries the capacitor-fill artwork the rail replaced.
- **Why:** One of the two is the design of record and nobody can tell which from the tree.
- **Action:** Delete the dead one (§9.2).
- **Severity:** Low

---

## 10. Cross-cutting recommendations

### 10.1 Make the warning count a build failure
- **Location:** `Debug.xcconfig`, `Release.xcconfig` (repo root)
- **What:** One clean build produces 19 warnings (§3), and one test fails with nobody tracking it (§5.4). Nothing gates either.
- **Why:** Warnings in this codebase are concentrated in two root causes (§3.1, §3.2) that are a day's work to close. Without a gate they regrow silently.
- **Action:** Add `-warnings-as-errors` for the `SendableClosureCaptures` and `DeprecatedDeclaration` groups specifically, not globally — the `@unchecked Sendable` mailboxes (§3.5) and the `capture 'self' was never used` lifetime anchor (§2.4) are intentional and would otherwise block.
- **Severity:** Medium

### 10.2 One definition per wire format and one per KDF
- **Location:** `GreyVision/Engine/Broadcast/GVBroadcastProtocol.swift:29-42` shared by `GreyVision/Engine/Broadcast/GVBroadcastLink.swift:276-289`, `GreyVisionMacCapture/Sources/GVPhoneLink.swift:375-384`, `GreyVisionVirtualCamera/Sources/CameraExtension/GreyVisionCameraExtension.swift:459-467`
- **What:** The wire-format enum is correctly shared across all three targets, but the `NWParameters`/KDF built from it was copy-pasted three times and has since diverged (§6.1, §6.2).
- **Why:** The shared enum was the right instinct; the duplication happened one layer above it, where nothing forced agreement.
- **Action:** Move the TLS parameter construction into the shared module alongside `GVBroadcastProtocol`, so a divergence is a compile error rather than a handshake that fails at runtime on a customer's Mac.
- **Severity:** Critical

### 10.3 Ship a dead-symbol check
- **Location:** CI script (repo has no CI configuration today; `scripts/verify.sh` is the existing entry point per `README.md:22`)
- **What:** 42 unreachable types (§9.2) and one unreachable 430-line state root (§9.1) accumulated with no signal.
- **Why:** The check that produced §9.2 is roughly fifteen lines of scripting over the source tree. It would have caught all of it at the moment each file was added.
- **Action:** Run it as a non-blocking report first. Exclude `@main` and `AppIntents`-conforming types, which the framework invokes by name (see §12).
- **Severity:** Medium

### 10.4 Decide the Swift 6 language mode with a date
- **Location:** `GreyVision/Engine/Rendering/GVDatamoshEngine.swift:4`, `:468`, `:503-514`, `:737-738`, `:847`, `:952`, `:1085-1094`; `GreyVision/Engine/Rendering/CameraMetalSurface.swift:1893`; `GreyVision/Features/Workspace/EffectCatalog.swift:50`
- **What:** §3.1 and §3.2 are the only two things blocking strict concurrency: 14 warning sites behind one root cause, plus one no-op annotation.
- **Why:** Fourteen sites is a day of work, not a quarter. Left open, each new codec or capture path adds sites and the eventual migration becomes a rewrite.
- **Action:** Fix §3.2 with the lock-guarded mailbox pattern the codebase already uses (`GreyVision/Engine/Audio/AudioReactiveRuntime.swift:83`), fix §3.1 by binding a `let`, remove `@preconcurrency` (§3.3), drop the `nonisolated(unsafe)` (§2.2), then enable the Swift 6 language mode.
- **Severity:** High

---

## 11. What was NOT audited

- **Metal kernel correctness.** 5 `.metal` files were counted, not reviewed. Numerical stability, threadgroup sizing, and aliasing are out of scope per the skill.
- **Build settings, scheme configuration, `.xcodeproj` structure**, beyond observing `UIRequiresFullScreen` in `Info.plist` (§4.5).
- **Third-party internals.** None — the project has no SPM or CocoaPods dependencies; the only external code is the Xcode sample under `SupportingContinuityCameraInYourMacOSApp/`, which was excluded entirely.
- **Test coverage depth.** 14 test files were counted. `GreyVisionTests/CameraEffectTests.swift:98` is reported as failing (§5.4) but the rest of the suite was not executed as part of this audit.
- **Runtime performance.** No Instruments traces were taken. §7 identifies *potential* hot paths by reading; it does not measure them.
- **The virtual-camera extension's `authorizeClient`**, which returns `true` unconditionally (`GreyVisionVirtualCamera/Sources/CameraExtension/GreyVisionCameraExtension.swift:86-88`). This matches Apple's documented `CMIOExtensionProvider` sample behaviour and was judged out of scope rather than a finding — confirm against current documentation if the extension ships to the App Store.
- **Firmware-side behaviour** of the Continuity camera path, and the macOS companion's own UI (only its networking layer was read, for §6).
- **Localization.** No string catalogue exists in this target.

**Disclosure:** the three Explore-agent briefs and the separate SwiftUI expert pass described in the skill were **not** run — no subagent tooling was available in this environment. The work was performed inline with `rg`-driven static analysis plus one clean build for compiler ground truth. Findings are correspondingly narrower in breadth and no more reliable for it; every Critical and High below was verified by opening the cited lines.

---

## 12. Verification

Each Critical and High was confirmed by reading the cited lines, not inferred.

- **§6.1** — opened `GreyVision/Engine/Broadcast/GVBroadcastLink.swift:276-289` and confirmed the parameter is declared `passcode _: String` and never referenced; opened `GreyVision/Engine/Broadcast/GVBroadcastProtocol.swift:34` and confirmed the KDF input is the literal `"greyVISION.local.v1"`; opened `GreyVisionMacCapture/Sources/GVPhoneLink.swift:375-384` and confirmed the same discard; opened `GreyVision/Engine/Broadcast/GVBroadcastRuntime.swift:74` and confirmed the caller passes the constant back in. The doc claim at `GVBroadcastLink.swift:16-24` was read in full and contradicts the code.
- **§6.2** — opened `GreyVisionVirtualCamera/Sources/CameraExtension/GreyVisionCameraExtension.swift:459-467` and confirmed the extension *does* use `passcode` as HKDF input key material; opened `GreyVisionVirtualCamera/Sources/CameraExtension/GreyVisionCameraExtension.swift:95-101` and confirmed the six-digit length gate. Traced the derivation arithmetic on both sides: `HKDF(ikm=6 digits)` versus `HKDF(ikm="greyVISION.local.v1")` cannot produce the same key.
- **§5.1** — opened `GreyVision/DesignSystem/GVBlackHalo.swift:57-58` and confirmed `sweep = -0.45 + progress * 1.9` with `progress` clamped only above; evaluated the five stop expressions at `sweep = -0.30` (→ `[0, 0, 0, -0.25, -0.10]`, unordered and out of range) and at `sweep = 1.30` (→ `[1.10, 1.25, 1.0, 1.0, 1.0]`, unordered). Confirmed `:48` drives the enclosing `TimelineView` at 30 Hz. This is the identified source of the `Gradient stop locations must be ordered.` runtime warning observed during simulator runs.
- **§3.1** — opened `GreyVision/Engine/Rendering/GVDatamoshEngine.swift:468` (`var forceKeyframe = pendingKeyframe`) and `:509-514` (the escaping `codecQueue.async` reading it); confirmed against the build log warning `reference to captured var 'forceKeyframe' in concurrently-executing code [#SendableClosureCaptures]` at `:513:39`. Checked `pump(texture:into:configuration:frame:forceKeyframe:...)` at `:561-567` — the parameter is `Bool`, so the only route from the render thread is the capture. Severity assessed as High on the "warning becomes an error in a future Swift mode" criterion, not on present runtime impact, which is nil because no write follows the capture.
- **§3.2** — every one of the 14 sites was extracted from a clean `xcodebuild` run into a fresh derived-data path (`build/AuditWarnings`) and confirmed present in the log; the enclosing closures at `GVDatamoshEngine.swift:503-518`, `:737-738`, `:847`, `:952`, `:1085-1094` and `CameraMetalSurface.swift:1891-1900` were each opened to confirm the capture is escaping, not immediate.
- **§3.4** — opened `GreyVision/Engine/Audio/GVSoundEngine.swift:357-368` and `GreyVision/Engine/Audio/AudioReactiveRuntime.swift:325-335`, `:369`; confirmed three independent session mutations with no shared lock or actor, and confirmed the runtime warnings at `SessionCore.mm:631` / `AVAudioSession_iOS.mm:978` recur across simulator launches.
- **§4.1** — the `tracks(withMediaType:)` deprecation is a compiler warning captured verbatim in the §3 build output at `GVTakeFrameReader.swift:66:33`. The surrounding synchronous read path was opened at `:63-76` to confirm the loader migration is also a threading change.
- **§5.4** — parsed `GreyVision/Features/Workspace/WorkspaceEffectParameters.swift:655-681` programmatically and counted exactly 25 array elements; opened `GreyVisionTests/CameraEffectTests.swift:98-100` and confirmed the assertions are `count == 36` and style modes `104...139`. Arithmetic: `139 - 104 + 1 = 36`. Confirmed the test is failing (this mismatch predates the current working-tree changes and was not introduced by them).
- **§5.5** — repository-wide search for `registry:` returns only the two declaration sites at `GreyVision/Engine/Signal/GVSignal.swift:320` and `:358`. Confirmed no caller.
- **§5.6 / §7.1** — opened `GreyVision/Engine/Capture/CameraRuntime.swift:205-221` and confirmed `UIGraphicsImageRenderer` + `drawHierarchy(in:afterScreenUpdates: true)` executes inline on the calling (main) actor; confirmed `CameraRuntime` is `@MainActor`.
- **§9.1** — repository-wide search for the construction `AppStateContainer(` returns **zero** matches across all five targets; confirmed `AppModel` (`GreyVision/App/AppModel.swift:7`) is the live state object; confirmed `GestureStateRegistry` is constructed only at `GreyVision/App/AppStateContainer.swift:163` and `AccessibilityObserver` only at `:212`, so both inherit unreachability. Line totals for the three files: 430 + 426 + 272 = 1,128.
- **§9.2** — produced by script, not by hand: every top-level type declaration in `GreyVision` was extracted and its name counted across `GreyVision`, `GreyVisionTests`, `GreyVisionUITests`, `GreyVisionMacCapture`, `GreyVisionVirtualCamera`. Forty-two names had a total occurrence count of 1. Six were then spot-checked by direct `grep -rn` (`GVEffectGlyph`, `GVSideRail`, `GVTimelineBar`, `GVStrokeText`, `GVCircularText`, `GVModulationOrbitTracker`) and each confirmed to appear only at its own declaration. `@main`-annotated and `AppIntents`-conforming types (`GreyVisionApp`, `GVAppShortcutsProvider`, `SelectEffectIntent`, `SelectEffectEntityIntent`) were excluded as framework-invoked and are **not** counted in the 42.
- **§4.6** — compared the two switch tables element by element; they diverge from `.xSmall`/`.small` onward and by more than 2× at the accessibility sizes. Confirmed only `GVTheme.typeScale(for:)` feeds layout (`GreyVision/DesignSystem/GVDynamicType.swift:58`, `:98`).
- **§7.3** — opened `GreyVision/Engine/Rendering/CameraMetalSurface.swift:1635-1640` and confirmed thermal state is read and forwarded to the quality governor only. **Corrected:** this entry previously also cited `GreyVision/Engine/Infrastructure/GPUTiming.swift:91-99` as an installed-but-unused observer. That file was entirely dead and has since been deleted; there was never an observer to be installed.
- **§8.1 / §8.2** — confirmed by direct search that the only `AccessibilitySettings(...)` initialiser calls are inside `GreyVision/Features/Workspace/CornerBracketView.swift:199` (a `#Preview`), and that `GVTimelineBar` / `GVTimelinePickerSheet` appear at their declarations only.- **§5.6** — **Superseded.** The window-snapshot path this finding described (`CameraRuntime.takeScreenshot()` calling `UIGraphicsImageRenderer` + `drawHierarchy(in:afterScreenUpdates: true)` on the main actor) no longer exists. The capture button now drives the renderer's still path, and the window-snapshot method and its unreferenced `GVPhotoLibrary.saveImage` duplicate were deleted rather than left in place.
- **§9.3** — **Partly resolved.** Three implementations of "save a still to Photos" became two. `GVScreenCapture` is now the only writer for captured images (JPEG, one caller: the renderer's still path); `GVPhotoLibrary.saveImage` was deleted as dead, leaving `GVPhotoLibrary` with only its live `saveVideo`. Two authorisation-status branches remain, not one.

---

## 13. Addendum — still capture

Recorded because each of these was found by a test that failed for a reason its
author did not expect, and none of them is visible from reading the feature.

- **The readout was wired to the wrong owner.** `CameraRuntime.takeScreenshot()`
  set `screenshotMessage`, and the capture button displays
  `cameraRuntime.screenshotMessage` — but the renderer's result arrived via
  `GVRecordingTransaction.handleScreenshotMessage`, which set a *different*
  published value. Every capture saved correctly and the button sat on
  "RENDERING AT SENSOR RESOLUTION" for ever, which is indistinguishable from a
  shutter that did nothing. `CameraMetalSurface`'s `onScreenshotMessage` now
  reaches both. This was the sole cause of the still-capture UI test failing
  before this addendum; the capture path itself worked from the first build.
- **`print` is not forwarded from a UI test's host app.** Instrumenting the
  render path with `print` produced zero lines in the xcodebuild log, while
  `GVLog`'s `os_log` output was likewise absent. Neither channel is usable for
  diagnosing this; the `accessibilityValue` on the capture button is.
- **The synthetic source had no sensor.** `syntheticTextureSize(for:)` derived
  its size from the *drawable*, capped at 1280 on the longest edge, so the
  simulator's chain could never be larger than the screen. The HUD read "4K"
  while the chain rendered 588x1280, and a photograph taken at "sensor
  resolution" came out 588x1280 — the exact size of a screen grab, which is why
  the feature was untestable off-device. The synthetic path now claims the
  configured `CaptureDimensions` and goes through the same `workingTextureSize`
  governor a real frame does, so it reports 3840x2160 for the default 4K format.
- **A shutter that is never serviced is now reported.** `CameraRuntime`
  arms a four-second watchdog that publishes "PHOTO // RENDERER DID NOT
  RESPOND" if nothing else has spoken. Previously every non-Metal-failure mode —
  a fallback preview, a paused renderer, a view that left the hierarchy —
  presented identically to a capture in progress.

### Observed flake, not a regression

`FlagshipRenderTests.testDatamoshEngineRoundTripsFramesThroughTheCodec`
(`GreyVisionTests/FlagshipRenderTests.swift:351`) failed once across six runs,
only when the UI and unit targets shared one xcodebuild invocation; it passed
four times in isolation and in the unit-only run. The cause is in the test:
the loop at `:326` exits on `engine.latestDecodedFrame == nil` becoming false,
so a fast decoder can legitimately finish after two submissions, while `:351`
asserts `submitted >= 3` as a proxy for "the codec advanced". The assertion
does not correspond to the loop's actual exit condition. Untouched here — it is
pre-existing and unrelated to the capture path.
