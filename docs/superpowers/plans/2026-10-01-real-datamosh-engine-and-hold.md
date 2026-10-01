# Real Datamosh Engine, Hold-While-Moshing, and New Codec Techniques Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the VideoToolbox datamosh stackable as real per-slot hardware, make a frame hold keep moshing instead of stalling, and add four more genuinely codec-driven techniques plus a bitstream-splice instrument.

**Architecture:** `GVDatamoshEngine` is a live H.264/HEVC encode→decode round trip with deliberately broken reference chains; the renderer feeds it one staged frame per pass and displays the decoder's reconstruction. Engine instances move from the renderer onto the render-graph node, so each effect slot owns its own codec and its own stall watchdog. New techniques are added as `Variant` cases — slider→codec intent is a pure static function, so every technique is unit-testable with no camera, no view, and no Metal pass.

**Tech Stack:** Swift 6, VideoToolbox, CoreVideo/CVMetalTextureCache, Metal (MSL compute), SwiftUI + UIKit gestures, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-01-real-datamosh-hold-timeline-scrub-design.md`

## Global Constraints

- `SWIFT_VERSION: 6.0` with `SWIFT_STRICT_CONCURRENCY: complete` — no `@preconcurrency` escape hatches, no unchecked Sendable widening without a lock justifying it in a comment.
- `IPHONEOS_DEPLOYMENT_TARGET: 18.0`, `TARGETED_DEVICE_FAMILY: 1` (iPhone only).
- `GreyVision.xcodeproj` is XcodeGen-generated. Never hand-edit it; run `xcodegen generate` after adding any file. New `.swift`/`.metal` under `GreyVision/` are picked up automatically by the source glob (`project.yml:53-72`).
- Tests are **XCTest**, not Swift Testing. Every one is `@testable import GreyVision`, and any Metal-dependent test guards on `MTLCreateSystemDefaultDevice()` with `throw XCTSkip("Metal unavailable on this destination")`.
- Temporal mode numbers must stay **unique and contiguous from zero** — enforced by `CameraEffectTests.testEffectRegistryHasUniqueImplementedModesAndLiveParameters`. The temporal table tops out at 46 today, so new modes take 47-51. The style table uses 47-59 independently (`WorkspaceEffectParameters.swift:1166`); check both.
- Every effect needs **exactly three** parameter labels and `isEnabled == false` in its defaults, or the registry test goes red.
- Swift↔Metal arm parity is enforced by `GreyVisionTests/CameraEffectShaderCoverageTests.swift`. A registered mode without a kernel arm fails the suite.
- Format and lint before committing: `swiftformat --lint .` and `swiftlint lint` (deliberately **not** `--strict`; `function_body_length`, `file_length`, `type_body_length`, `cyclomatic_complexity`, `line_length` and `large_tuple` are disabled in `.swiftlint.yml`, so long functions will not fail the gate but must still be justified).
- Full gate: `./scripts/verify.sh` (runs xcodegen, swiftformat, swiftlint, simulator tests, then a device build). Destination is computed, never hardcoded; override with `GV_SIMULATOR_DESTINATION`.
- **Codec truth cannot be judged in the Simulator.** Tasks 1-5 are verifiable by tests; Tasks 6-10 additionally need a physical iPhone to confirm the artefact reads as a real codec. That judgement is the operator's, not a test assertion.
- Baseline for this plan is commit `38204e4` ("Preserve the untracked real-datamosh engine and in-progress render work"), which is where the `GVDatamoshEngine.swift` that had been sitting untracked finally entered history. That commit builds clean on the simulator. `./scripts/verify.sh` currently exits non-zero at the `swiftformat --lint .` step for reasons that predate it (depth files, generated asset symbols, and pre-existing violations in `GVDatamoshEngine.swift`'s simulator-only block) — do not "fix" unrelated formatting to make the gate green; report it instead.

---

### Task 1: Per-slot codec engine with an instance budget

Today `datamoshEngine` is one `private let` on the renderer (`CameraMetalSurface.swift:955`, built `:1142`) and `setCodecActive(_:)` (`:1444`) is a single boolean meaning "any codec mode is on screen". Two codec slots therefore share one encoder, one decoder and one staging ring, and `datamoshStalledSince` (`:958`) is renderer-global, so slot A's gap forces slot B to emit a sync sample — stacking two codec modes today corrupts both.

**Files:**
- Modify: `GreyVision/Engine/Rendering/CameraMetalSurface.swift` (`:806-902` node class, `:955` engine property, `:958` watchdog, `:1142` construction, `:1444` `setCodecActive`, `:1929` pass trigger, `:3029` `encodeDatamoshPass`)
- Modify: `GreyVision/Engine/Rendering/GVDatamoshEngine.swift` (add an `isActive` gate replacing the external `setCodecActive` boolean)
- Test: `GreyVisionTests/FlagshipRenderTests.swift`

**Interfaces:**
- Consumes: `CameraRenderGraphNode` (`:806`), which already owns `moshStateA/B`, `moshStateReadsA`, `moshHistory` and clears them in `reset(reason:)` (`:879`) and `releaseResources()` (`:890`).
- Produces: `CameraRenderGraphNode.codecEngine: GVDatamoshEngine?` — the per-slot round trip; `CameraRenderGraphNode.datamoshStalledSince: TimeInterval?` — the per-slot watchdog; `CameraRenderStats.codecSlots: Int`; and `GVDatamoshEngine.Budget` — a pure value type holding the funding rule, so the decision is testable without a renderer. `CameraRenderGraphNode` is `private` to `CameraMetalSurface.swift`, so **no test can reach it**; the budget rule therefore has to live somewhere public or the task is untestable as written.

- [ ] **Step 1: Write the failing test — the budget rule, as a pure decision**

Two `GVDatamoshEngine` instances being distinct objects is already true and proves nothing; the thing at risk is the *funding decision*. Append to `GreyVisionTests/FlagshipRenderTests.swift`:

```swift
    /// Which Slots get real hardware is a decision, so it is tested as a decision.
    /// The bug this prevents is the silent one: a second codec Slot sharing the
    /// first Slot's session, which means one reference chain and a renderer-wide
    /// stall timer that made an idle Slot force the running Slot to resync every
    /// frame.
    func testCodecBudgetFundsTwoSlotsAndRefusesTheThird() {
        var budget = GVDatamoshEngine.Budget(limit: 2)
        XCTAssertTrue(budget.fund(requested: 1))
        XCTAssertTrue(budget.fund(requested: 1), "two single-session Slots fit")
        XCTAssertFalse(budget.fund(requested: 1), "a third Slot must fall back, not oversubscribe")

        // A cascade spends two units, so one cascade alone fills the budget.
        var cascaded = GVDatamoshEngine.Budget(limit: 2)
        XCTAssertTrue(cascaded.fund(requested: 2))
        XCTAssertFalse(cascaded.fund(requested: 1))
    }

    func testCodecBudgetIsTheRendererWideLimit() {
        XCTAssertEqual(GVDatamoshEngine.Budget.defaultLimit, 2,
                       "stated in one place so the renderer and the tests cannot drift")
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodegen generate && xcodebuild -project GreyVision.xcodeproj -scheme GreyVision -destination "$GV_SIMULATOR_DESTINATION" -derivedDataPath /private/tmp/gvverify -only-testing:GreyVisionTests/FlagshipRenderTests/testCodecBudgetFundsTwoSlotsAndRefusesTheThird test`
Expected: FAIL — cannot compile, `GVDatamoshEngine.Budget` does not exist.

- [ ] **Step 3: Implement the budget as a value type**

In `GVDatamoshEngine.swift`, outside the class so it is reachable and obvious:

```swift
    extension GVDatamoshEngine {
        /// How many live round trips the hardware is allowed to fund at once. Each
        /// one is an encoder, a decoder and its own staging ring; two is what fits
        /// inside the frame budget with the rest of the effect stack still running.
        /// A refused Slot is not dropped — it keeps its place in the stack, and the
        /// three instruments running today compose the reconstruction and nothing
        /// else, so a refused Slot shows the frame uncorrupted. That is why the
        /// refusal is counted in render stats rather than inferred from the picture.
        struct Budget {
            static let defaultLimit = 2

            let limit: Int
            private(set) var spent: Int = 0

            init(limit: Int = Budget.defaultLimit) {
                self.limit = limit
            }

            /// Funds `requested` sessions, or nothing. All-or-nothing per Slot: a
            /// cascade that got one of its two sessions would be a mosh that
            /// silently stopped cascading.
            mutating func fund(requested: Int) -> Bool {
                guard requested > 0, spent + requested <= limit else { return false }
                spent += requested
                return true
            }

            mutating func release(_ requested: Int) {
                spent = max(0, spent - requested)
            }

            var liveSessions: Int { spent }
        }
    }
```

- [ ] **Step 4: Give the node the engine and the watchdog**

In `CameraRenderGraphNode` (`CameraMetalSurface.swift:806-902`), beside the existing mosh state:

```swift
    /// The live round trip this Slot's codec mode runs on. Owned by the Slot,
    /// not the renderer: one shared session made the second codec mode ride the
    /// first one's reference chain, and a renderer-wide stall timer made slot A's
    /// gap force slot B to resync. Nil until the budget funds this Slot.
    var codecEngine: GVDatamoshEngine?
    /// Sessions this Slot holds, so release is exact: a cascade gives back two.
    var codecSessionsSpent = 0
    /// Per-slot stall watchdog, in Slot clock rather than renderer clock.
    var datamoshStalledSince: TimeInterval?
    /// Set when the budget refused this Slot; the Slot then runs its shader
    /// transport and the refusal is visible in render stats.
    var codecBudgetRefused = false
```

Add to `reset(reason:)` (`:879`) and `releaseResources()` (`:890`) — the codec must hand hardware back exactly where the mosh textures are already dropped:

```swift
        codecEngine?.stop()
        codecEngine = nil
        codecBudgetRefused = false
        datamoshStalledSince = nil
```

`codecSessionsSpent` is returned to the renderer's budget by the owner before nil-ing, in `releaseResources()` — see Step 5's `releaseCodecBudget(for:)`.

- [ ] **Step 5: Replace the renderer-level engine with per-slot funding**

Delete `private let datamoshEngine: GVDatamoshEngine?` (`:955`), its construction `datamoshEngine = GVDatamoshEngine(device: device)` (`:1142`), `private var datamoshStalledSince` (`:958`), and the `setCodecActive` call site (`:1444-1446`), which cannot express "two Slots want hardware and one cannot have it". Add to the renderer:

```swift
    /// Funded from the graph configuration pass, once per frame, before any Slot
    /// processes: funding is decided for the whole stack at once so two Slots
    /// cannot both pass a `spent < limit` check against the same session.
    var codecBudget = GVDatamoshEngine.Budget()

    func codecEngine(for node: CameraRenderGraphNode) -> GVDatamoshEngine? {
        if let existing = node.codecEngine { return existing }
        let cost = node.codecModeCost
        guard codecBudget.fund(requested: cost), let engine = GVDatamoshEngine(device: device) else {
            node.codecBudgetRefused = true
            node.codecSessionsSpent = 0
            return nil
        }
        node.codecBudgetRefused = false
        node.codecSessionsSpent = cost
        node.codecEngine = engine
        return engine
    }

    /// Called from the node's `releaseResources()` path, which already has an
    /// `owner` weak reference (`:808`) for exactly this kind of handback.
    func releaseCodecBudget(for node: CameraRenderGraphNode) {
        codecBudget.release(node.codecSessionsSpent)
        node.codecSessionsSpent = 0
    }
```

`node.codecModeCost` is a new computed property on `CameraRenderGraphNode`, returning `1` for every codec mode at this point in the plan — a plain integer read off the node's own `stage`, so no renderer state is consulted. Task 6 changes it to `2` for the generation-mosh mode; nothing here needs to know that yet. Reset `codecBudget` to `GVDatamoshEngine.Budget()` at the top of the frame, then re-fund from the configured nodes, so Slots that left the stack cannot leak sessions.

Because the budget is rebuilt every frame, a device that cannot create an engine at all would
otherwise be asked again sixty times a second. Add a per-node latch so the attempt happens once
per session, as the spec's error-handling section requires:

```swift
    /// Set when engine construction failed. The Slot then runs its shader
    /// transport for the rest of the session rather than re-attempting an
    /// allocation the device has already refused, which would be a per-frame
    /// `GVDatamoshEngine(device: nil)` in the hot path.
    var codecUnavailableForSession = false
```

and short-circuit `codecEngines(for:)` on it before touching the budget.

- [ ] **Step 6: Make the pass use the node's engine and its own watchdog**

Rewrite the head of `encodeDatamoshPass` (`:3029`) to take the node and return early when the budget refused it:

```swift
    private func encodeDatamoshPass(node: CameraRenderGraphNode,
                                    effect: WorkspaceAdjustableEffect,
                                    parameters: CameraEffectParameters,
                                    source: MTLTexture,
                                    commandBuffer: MTLCommandBuffer,
                                    decoded: inout GVDatamoshEngine.DecodedFrame?) {
        guard let engine = codecEngine(for: node), let pipeline = datamoshStagePipeline,
              let variant = GVDatamoshEngine.Variant(effect) else { return }
        let configuration = GVDatamoshEngine.configuration(
            variant: variant,
            primary: parameters.sanitized.primary,
            secondary: parameters.sanitized.secondary,
            tertiary: parameters.sanitized.tertiary,
            maximumEncodeEdge: effectQuality.codecEdge
        )
        decoded = engine.latestDecodedFrame
        let renderClock = ProcessInfo.processInfo.systemUptime
        defer { node.datamoshStalledSince = renderClock }
        // Gap detection belongs to the Slot. A renderer-wide timer made an idle
        // DATAMOSH Slot force a sync sample on the Slot that was still running,
        // which repaired the picture the operator was watching.
        if let lastPump = node.datamoshStalledSince, renderClock - lastPump > 0.4 {
            engine.requestKeyframe()
        }
```

Update the call site (`:1929`) to pass `node:`. Keep the rest of the function (staging claim, kernel dispatch, `endFrame` completion handler) unchanged.

The snippet above calls `GVDatamoshEngine.Variant(effect)`, which does not exist yet: the
effect→variant mapping currently lives renderer-side inside `datamoshConfiguration`
(`CameraMetalSurface.swift:2995-3009`, a switch with `default: variant = .datamosh`). Move it into
the engine as a failable initialiser, next to the `Variant` it belongs to, and delete the
renderer-side switch — the mapping and the thing being mapped to should not be in two files:

```swift
    extension GVDatamoshEngine.Variant {
        /// Which instrument this effect plays. Failable so a codec mode added
        /// without a variant lands here as a compile-time question rather than a
        /// runtime shrug: `nil` would silently fall back to DATAMOSH's settings and
        /// the new effect would look like a slightly wrong old one.
        init?(_ effect: WorkspaceAdjustableEffect) {
            switch effect {
            case .datamosh: self = .datamosh
            case .liquidMosh: self = .liquidMosh
            case .heavyMosh: self = .heavyMosh
            default: return nil
            }
        }
    }
```

Every later task in this plan adds its case to this initialiser as part of its Step "register the
effect"; the existing `default: break` in `datamoshConfiguration` goes away with the move, so a
forgotten registration cannot be silently absorbed.

- [ ] **Step 7: Expose the budget in render stats**

Add to `CameraRenderStats` (`:33-55`) beside `shedEffects`:

```swift
    /// Codec Slots running a real round trip this frame. Below the number of
    /// codec modes in the stack means the budget refused one — and since every
    /// codec instrument composes the reconstruction and nothing else, a refused
    /// Slot shows the frame whole. The operator must be able to see that.
    var codecSlots: Int = 0
```

Populate it from `codecBudget.liveSessions` where stats are assembled.

- [ ] **Step 8: Confirm the staging path is the zero-copy one on device (spec §2)**

`GVDatamoshEngine.sharedStagingTexture(for:)` (`GVDatamoshEngine.swift:1004`) already returns an
IOSurface-backed texture and falls back to the CPU row copy only under
`#if targetEnvironment(simulator)` (`:1008`), so §2 of the spec is verification, not
construction. Two checks:

```bash
grep -n "targetEnvironment(simulator)" GreyVision/Engine/Rendering/GVDatamoshEngine.swift
grep -n "sharedStagingTexture" GreyVision/Engine/Rendering/GVDatamoshEngine.swift
```

Then on a physical iPhone, with two codec Slots stacked, read the GPU milliseconds in
`CameraRenderStats` and confirm the frame cost has not doubled relative to a single codec
Slot. Record the numbers in the commit message. If the device path is *not* being taken,
that is a bug to fix in this task before proceeding — the instance cap in Step 5 is sized
for zero-copy, not for two CPU row copies per frame.

- [ ] **Step 9: Run the tests**

Run: `./scripts/verify.sh`
Expected: PASS on the budget tests, and `CameraEffectTests` / `CameraEffectShaderCoverageTests` stay green (no mode numbers touched).

- [ ] **Step 10: Commit**

```bash
git add GreyVision/Engine/Rendering/CameraMetalSurface.swift GreyVisionTests/FlagshipRenderTests.swift
git commit -m "Give each render slot its own codec engine and a live-instance budget"
```

---

### Task 2: Hold keeps the mosh eating itself

The interaction the whole feature exists for. Today, holding the frame makes the codec converge: `.datamosh`, `.liquidMosh` and `.heavyMosh` are absent from `freezesHistoryOnHold` (`WorkspaceEffectParameters.swift:1803-1815`), so `freezeForEffect` never becomes true for them, and `encodeDatamoshPass` feeds `request.input` — the frozen clean still — to the encoder. A static source has no motion, so there is nothing to drag and no divergence to corrupt: the picture settles into a slightly soft still.

The fix: while held, the encoder's input is the decoder's own reconstruction.

**Files:**
- Modify: `GreyVision/Engine/Rendering/GVDatamoshEngine.swift` (`Configuration`, `Variant`, `configuration(variant:…)`)
- Modify: `GreyVision/Engine/Rendering/CameraMetalSurface.swift` (`encodeDatamoshPass`, `holdStyle(for:)` `:1986`)
- Modify: `GreyVision/Features/Workspace/WorkspaceEffectParameters.swift:1803`
- Modify: `GreyVision/Resources/Shaders/CameraShaders.metal` (`gvCameraDatamoshStage` `:4181`)
- Test: `GreyVisionTests/FlagshipRenderTests.swift`

**Interfaces:**
- Consumes: `GVDatamoshEngine.DecodedFrame` (`latestDecodedFrame`), `DatamoshStageUniforms(recycle:decodeReady:)` (`CameraMetalSurface.swift:36`), `Configuration.recycle`.
- Produces: `GVDatamoshEngine.Configuration.selfFeeding: Bool` — when true, the staging kernel writes the previous reconstruction as the next encoder input regardless of the slider; and `static func configuration(variant:primary:secondary:tertiary:maximumEncodeEdge:held:)`.

- [ ] **Step 1: Write the failing test — held mapping self-feeds**

```swift
    /// A hold must not stall the mosh. With the camera frame frozen, the only
    /// thing that keeps a codec corrupting is feeding it its own reconstruction,
    /// so `held` has to force the self-feed on every instrument — including the
    /// two that have no RECYCLE control at all.
    func testHeldConfigurationFeedsTheCodecItsOwnReconstruction() {
        let live = GVDatamoshEngine.configuration(variant: .datamosh,
                                                  primary: 0.5, secondary: 0.5, tertiary: 0.5,
                                                  held: false)
        let held = GVDatamoshEngine.configuration(variant: .datamosh,
                                                  primary: 0.5, secondary: 0.5, tertiary: 0.5,
                                                  held: true)
        XCTAssertEqual(live.recycle, 0, "DATAMOSH has no recycle control while the camera runs")
        XCTAssertEqual(held.recycle, 1, "a held DATAMOSH must encode its own previous output")
        // The reference must keep being withheld, or there is no divergence and
        // therefore no drag: a held frame with an intact chain is a clean still.
        XCTAssertGreaterThan(held.referenceDropEvery, 1)
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild … -only-testing:GreyVisionTests/FlagshipRenderTests/testHeldConfigurationFeedsTheCodecItsOwnReconstruction test`
Expected: FAIL — cannot compile, `configuration(variant:primary:secondary:tertiary:held:)` does not exist.

- [ ] **Step 3: Add the `held` dimension to the pure mapping**

Extend the static mapping in `GVDatamoshEngine.swift:110` and apply the rule after the per-variant switch, so no variant can forget it:

```swift
    static func configuration(variant: Variant,
                              primary: Double,
                              secondary: Double,
                              tertiary: Double,
                              maximumEncodeEdge: Int = 0,
                              held: Bool = false) -> Configuration {
```

At the end of the function, before `return configuration`:

```swift
        // A hold stops the camera but must not stop the mosh. Feeding the
        // encoder its own previous output is the only thing that keeps
        // corrupting a picture with no new motion in it, and it is the reason
        // the artefact still drags, still bleeds chroma, and still melts while
        // the frame underneath it is frozen. Every instrument gets it; the
        // RECYCLE slider only chooses how much on a live frame.
        if held {
            configuration.recycle = 1
            if configuration.referenceDropEvery < 2 {
                configuration.referenceDropEvery = 2
            }
        }
        return configuration
```

- [ ] **Step 4: Confirm the staging kernel already mixes toward the reconstruction**

No shader change is needed, and the plan says so rather than inventing one.
`gvCameraDatamoshStage` (`CameraShaders.metal:4181`) already computes exactly the self-feed the
hold requires:

```metal
    const float recycle = saturate(stage.recycle);
    const float3 recycled = stage.decodeReady == 1u
        ? mix(live, gvCameraSampleDecode(decodeTexture, uv), recycle)
        : live;
```

So `recycle = 1` with a decode present means the encoder input contains **no camera at all** —
which is the hold behaviour wanted. Two things to verify rather than write:

- Read `gvCameraSampleDecode` (`CameraShaders.metal`, used at `:4210`) and confirm it is an
  unfiltered pixel-for-pixel read of the reconstruction. If it filters, the self-feed softens
  each generation and the melt turns into a blur; that would be a real bug in this path.
- Confirm the renderer passes `recycle` straight from `configuration.recycle` —
  `DatamoshStageUniforms(recycle:decodeReady:)` at `CameraMetalSurface.swift:36` already does,
  set from the configuration built in Step 3.

- [ ] **Step 5: Wire the hold through the render pass**

`encodeDatamoshPass` has no access to frame state, so the hold arrives as a parameter from its
caller, where `state` is already in scope (`CameraMetalSurface.swift:1929`, inside
`processGraphNode`, which computes `freezeForEffect` at `:1879`). Change the signature and pass
`settings.temporalHoldActive` — the camera-frozen flag, not `freezeForEffect`, because the codec
self-feed must engage for a codec Slot whether or not that Slot also freezes shared history:

```swift
    private func encodeDatamoshPass(node: CameraRenderGraphNode,
                                    effect: WorkspaceAdjustableEffect,
                                    parameters: CameraEffectParameters,
                                    source: MTLTexture,
                                    commandBuffer: MTLCommandBuffer,
                                    held: Bool,
                                    decoded: inout GVDatamoshEngine.DecodedFrame?) {
        guard let engine = codecEngine(for: node), let pipeline = datamoshStagePipeline,
              let variant = GVDatamoshEngine.Variant(effect) else { return }
        let configuration = GVDatamoshEngine.configuration(
            variant: variant,
            primary: parameters.sanitized.primary,
            secondary: parameters.sanitized.secondary,
            tertiary: parameters.sanitized.tertiary,
            maximumEncodeEdge: effectQuality.codecEdge,
            held: held
        )
```

and at the call site:

```swift
            if isCodecMoshMode(modeValue) {
                encodeDatamoshPass(node: node,
                                   effect: effect,
                                   parameters: node.cameraParameters,
                                   source: request.input,
                                   commandBuffer: request.frame.commandBuffer,
                                   held: state.settings.temporalHoldActive,
                                   decoded: &decodedFrame)
            }
```

Because `held` forces `recycle = 1`, the staging kernel's `mix` already makes the encoder's input the reconstruction — no second source texture is needed, and `request.input` staying frozen is now correct rather than fatal.

- [ ] **Step 6: Give the codec modes their hold treatment**

In `WorkspaceEffectParameters.swift:1803`, add the three codec effects so `freezeForEffect`, `shouldFreezeTemporalHistory` and `holdStyle` all start firing for them:

```swift
        case .datamosh, .liquidMosh, .heavyMosh,
             .moshBrush, .predictionDrift,
```

- [ ] **Step 7: Suppress the watchdog during a hold, and resync on release**

In `encodeDatamoshPass` the gap check from Task 1 must not fire while held, or it repairs the image the hold exists to consume; and on the held→live edge, force one sync sample so the operator gets the camera back immediately instead of waiting for a chain to expire:

```swift
        if !held {
            if let lastPump = node.datamoshStalledSince, renderClock - lastPump > 0.4 {
                engine.requestKeyframe()
            }
        }
        // Releasing a hold hands the codec a live camera again; without a forced
        // sync sample the first frames after release predict from the held
        // reconstruction and the operator sees a smear that is not an effect.
        if node.wasHeldLastFrame && !held {
            engine.requestKeyframe()
        }
        node.wasHeldLastFrame = held
```

Add `var wasHeldLastFrame = false` to `CameraRenderGraphNode` next to `codecEngine`, and reset it in `reset(reason:)` and `releaseResources()`.

- [ ] **Step 8: Run both tests**

Run: `./scripts/verify.sh`
Expected: PASS for the new hold mapping, and the existing `testDatamoshSliderMappingKeepsTheReferenceChainBrokenAtItsDefaults` stays green — the `held` default is `false`, so live behaviour is unchanged.

- [ ] **Step 9: Commit**

```bash
git add GreyVision/Engine/Rendering/GVDatamoshEngine.swift GreyVision/Engine/Rendering/CameraMetalSurface.swift GreyVision/Features/Workspace/WorkspaceEffectParameters.swift GreyVision/Resources/Shaders/CameraShaders.metal GreyVisionTests/FlagshipRenderTests.swift
git commit -m "Make a frame hold feed the codec its own reconstruction instead of stalling it"
```

---

### Task 3: Contextual long-press on the preview

The press-and-hold was deliberately removed and replaced by an explicit freeze toggle — "This replaces the undiscoverable hold gesture" (`CameraRuntime.swift:381-386`). It comes back conditioned: armed only when an effect that holds meaning is in the stack, so it never competes with tap-to-focus on a plain camera.

**Files:**
- Modify: `GreyVision/Engine/Rendering/CameraMetalSurface.swift:541-555` (`CameraMetalView` recogniser setup)
- Modify: `GreyVision/Engine/Capture/CameraRuntime.swift:381` (hold-arm predicate + published state)
- Modify: `GreyVision/Features/Workspace/GVTelemetryStrip.swift` (HOLD badge)
- Test: `GreyVisionTests/CameraEffectStackTests.swift`

**Interfaces:**
- Consumes: `CameraRuntime.toggleFrameFreeze()` (`:383`), `CameraRuntime.isFrameFrozen` (`:33`), `WorkspaceAdjustableEffect.freezesHistoryOnHold`, `holdSeconds` already computed by the renderer (`CameraMetalSurface.swift:1351-1360`).
- Produces: `CameraRuntime.canHoldPreview: Bool` and `CameraRuntime.holdElapsedSeconds: TimeInterval`.

- [ ] **Step 1: Write the failing test — hold arms only when it means something**

```swift
    final class HoldArmingTests: XCTestCase {
        /// The long-press must not exist on a plain camera: it was deleted once
        /// because an always-on hold gesture on the preview is indistinguishable
        /// from the tap and pan that focus and frame. It arms only when the stack
        /// holds an effect whose hold behaviour is defined.
        func testHoldArmsOnlyWhenAStackedEffectFreezesOnHold() {
            let plain: [WorkspaceAdjustableEffect] = [.crt, .halation]
            XCTAssertFalse(plain.contains(where: \.freezesHistoryOnHold))

            let moshed: [WorkspaceAdjustableEffect] = [.crt, .datamosh]
            XCTAssertTrue(moshed.contains(where: \.freezesHistoryOnHold))

            // The three codec instruments are now part of that set; without them
            // the headline hold feature would never arm.
            for effect in [WorkspaceAdjustableEffect.datamosh, .liquidMosh, .heavyMosh] {
                XCTAssertTrue(effect.freezesHistoryOnHold, "\(effect.rawValue) must arm the hold")
            }
        }
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild … -only-testing:GreyVisionTests/CameraEffectStackTests test`
Expected: FAIL — the codec-effect assertions fail if Task 2 Step 6 has not landed, and pass otherwise; add the test as the regression guard for that ordering.

- [ ] **Step 3: Publish the arming predicate and elapsed hold from the runtime**

In `CameraRuntime` (`:33`, `:381`):

```swift
    /// Whether a press-and-hold on the preview would do something. True only
    /// when the stack contains an effect with defined hold behaviour, so the
    /// gesture never shadows tap-to-focus on a plain camera.
    @Published private(set) var canHoldPreview = false
    /// Seconds the current hold has run, for the HOLD badge. Zero when live.
    @Published private(set) var holdElapsedSeconds: TimeInterval = 0

    /// The stack changed, so the gesture is either available or in the way.
    func setPreviewHoldArmed(_ effects: [WorkspaceAdjustableEffect]) {
        canHoldPreview = effects.contains(where: \.freezesHistoryOnHold)
        if !canHoldPreview, isFrameFrozen { toggleFrameFreeze() }
    }

    /// The gesture's engage/release, which is the same frozen state the freeze
    /// button sets — one source of truth, so the badge and the render cannot
    /// disagree about whether the frame is held.
    func setPreviewHold(_ engaged: Bool) {
        guard canHoldPreview, snapshot.state == .running else { return }
        if engaged != isFrameFrozen { toggleFrameFreeze() }
    }
```

The `if !canHoldPreview, isFrameFrozen` release matters: removing the last mosh effect mid-hold must not leave the operator staring at a frozen frame with no visible way to unfreeze it.

- [ ] **Step 4: Add the recogniser to the Metal view**

In `CameraMetalView` (`:541-555`, where `tap`, `fracture`, `touch` and `pinch` are added). The arbitration matters: a long press must win over tap-to-focus, or the hold fires and then the tap lands on the same touch and moves the focus reticle. `require(toFail:)` is the UIKit mechanism for exactly this — the tap is held until the long-press has definitively failed:

```swift
    private var holdRecognizer: UILongPressGestureRecognizer?
    /// Fired on began (hold engaged) and ended/cancelled (released). Wired to the
    /// runtime in `updateUIView`, which is the only place that can see it.
    var onHold: ((Bool) -> Void)?

    private func installHoldRecognizer(below tap: UITapGestureRecognizer) {
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.minimumPressDuration = 0.25
        // Room to wiggle: a hold is a press that stays roughly still, and an
        // operator watching a frozen frame does shift their thumb.
        hold.allowableMovement = 18
        // Only recognises when an effect with defined hold behaviour is armed, so
        // the default case stays exactly as it was: tap focuses, pan drags.
        hold.isEnabled = false
        addGestureRecognizer(hold)
        // The tap waits for the hold to fail. Without this the release of a hold
        // also re-centres focus, which reads as the app moving the reticle itself.
        tap.require(toFail: hold)
        holdRecognizer = hold
    }

    @objc private func handleHold(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began: onHold?(true)
        case .ended, .cancelled: onHold?(false)
        default: break
        }
    }
```

Call `installHoldRecognizer(below:)` where `tap` is added (`:541`), keeping a reference to that tap. In `updateUIView` (`:348-352`) drive both the enabled flag and the existing freeze from the same source so the SwiftUI state and the render state cannot disagree:

```swift
        view.holdRecognizer?.isEnabled = runtime.canHoldPreview
        view.onHold = { engaged in runtime.setPreviewHold(engaged) }
        context.coordinator.renderer?.setTemporalHoldActive(runtime.isFrameFrozen)
```

- [ ] **Step 5: Show the hold in the telemetry strip**

`GVTelemetryStrip` has no hold indicator today. Add one that only appears while held, reading the seconds the renderer already computes (`CameraMetalSurface.swift:1351`):

```swift
            if runtime.isFrameFrozen {
                HStack(spacing: 4) {
                    Circle().fill(GVColor.holdAmber).frame(width: 6, height: 6)
                    Text("HOLD \(runtime.holdElapsedSeconds, format: .number.precision(.fractionLength(1)))s")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                }
                .accessibilityLabel("Frame held")
            }
```

If `GVColor.holdAmber` does not exist, use the existing accent token the recording dot uses rather than adding a colour — the DesignSystem owns the palette.

- [ ] **Step 6: Run the tests and verify the gesture on a device**

Run: `./scripts/verify.sh`
Expected: PASS in CI terms. Then on a physical iPhone: with no mosh effect, press-and-hold does nothing (tap still focuses); with DATAMOSH armed, press-and-hold freezes the frame and the corruption keeps compounding; the badge counts up; releasing restores the live picture within a frame.

- [ ] **Step 7: Commit**

```bash
git add GreyVision/Engine/Rendering/CameraMetalSurface.swift GreyVision/Engine/Capture/CameraRuntime.swift GreyVision/Features/Workspace/GVTelemetryStrip.swift GreyVisionTests/CameraEffectStackTests.swift
git commit -m "Arm a contextual press-and-hold on the preview when a mosh effect is stacked"
```

---

### Task 4: Registering a new codec effect, the required checklist

Four techniques follow, and each must land in every table or it becomes a silent half-effect. This task exists so the later tasks can reference one authoritative list instead of each re-deriving it — and because the repo has already been burned by an effect that was added to one switch and missed in another (two effects sharing mode 4, recorded at `WorkspaceEffectParameters.swift:1285-1288`).

**Registration points for one new `WorkspaceAdjustableEffect`:**

| # | File:line | What goes in |
| --- | --- | --- |
| 1 | `WorkspaceEffectParameters.swift:5-220` | the `case` |
| 2 | `:377` `temporalRenderOrder` | position in the temporal chain. Must appear in `temporalRenderOrder` **or** `metalRenderOrder`, never both — `:436` `defaultPlacementOrder` adds them and an effect in both silently loses rank (`CameraEffectTests.swift:438-444`) |
| 3 | `:1279` `temporalMode` | next contiguous number (47, then 48, 49, 50). Style table is separate and already owns 47-59 |
| 4 | `:439` `datamoshCategoryEffects` | shelf membership; feeds `:715` `timeCategoryEffects` |
| 5 | `:748` `curatedFamily`, `:733` `curatedCategoryEffectGroups` | family card; `:764` `repeatedCuratedCategoryEffects` goes red on duplicate membership |
| 6 | `:798` `computedLabel` and `:921` `detail` | rail label and the one-line technical truth (e.g. `"H.264 REFERENCE DRAG"`) |
| 7 | `:1352` `computedParameterLabels` | exactly 3, else the registry test fails |
| 8 | `:1549` `defaultCameraParameters` | defaults, `isEnabled` must stay false |
| 9 | `:1756` `estimatedCost` | honest budget weight; `liquidMosh` is 2.4, the codec group 1.5 |
| 10 | `:1803` `freezesHistoryOnHold` | yes for every codec instrument |
| 11 | `:2171` `curatedRadialSubcategories(for:)` `"TIME"` | literal MOSH list at `:2175` |
| 12 | `CameraMetalSurface.swift:2982` `isCodecMoshMode` | the new mode number |
| 13 | `CameraMetalSurface.swift:1986` `holdStyle(for:)` | hold bits for the new mode |
| 14 | `GVDatamoshEngine.swift:98` `Variant` + `:110` `configuration(variant:…)` | the slider→codec intent, and `Variant(effect)` mapping |
| 15 | `CameraShaders.metal:3155` `switch (uniforms.mode.x)` | a real arm — `CameraEffectShaderCoverageTests.swift:26/42/61` compares Swift modes against Metal arms |
| 16 | `CameraEffectResourceRequirements.swift:63/77` | `.videoCodec` requirement, plus `:86` `.slotHistory, .moshState` where the shader fallback still needs them |
| 17 | `GVEffectGlyph.swift:23-31` `kind(for:)` | glyph family |
| 18 | `EffectCatalog.swift:54` `variantGroups` | only if it is a variant of an existing card |

Nothing needs adding in `GreyVisionMacCapture`: `GVBroadcastControlCatalog.swift:29` builds the desktop catalogue from `WorkspaceAdjustableEffect.allCases`, and `GVBroadcastControlBridge.swift:58` resolves by rawValue, so the Mac picks new effects up automatically.

**Files:** documentation only — no code changes.
**Test:** none; Tasks 5-8 are executed against this checklist.

- [ ] **Step 1: Add the checklist to the spec as an appendix**

Append the table above to `docs/superpowers/specs/2026-10-01-real-datamosh-hold-timeline-scrub-design.md` under a `## Registration checklist` heading, so a future effect gets the list before it gets a mode number.

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-10-01-real-datamosh-hold-timeline-scrub-design.md
git commit -m "Record the effect registration checklist the shared-mode bug made necessary"
```

---

### Task 5: CHROMA MOSH — colour from the codec, detail from the camera

H.264 and HEVC store chroma at quarter resolution, and at a starved bitrate the chroma residual is quantised so coarsely that colour smears across whole macroblocks while luma stays comparatively intact. Taking **only the decoder's chroma** and recombining it with clean camera luma gives a look no shader can produce honestly: the colour bleeding is the codec's own 4:2:0 quantisation error, and the picture remains sharp underneath it.

**Files:**
- Modify: `GreyVision/Features/Workspace/WorkspaceEffectParameters.swift` (case `chromaMosh`, mode 47, all Task 4 points)
- Modify: `GreyVision/Engine/Rendering/GVDatamoshEngine.swift` (`Variant.chromaMosh`, `Configuration.chromaOnly`)
- Modify: `GreyVision/Engine/Rendering/CameraMetalSurface.swift:2982` (`isCodecMoshMode` 47), `:1986` (`holdStyle`)
- Modify: `GreyVision/Resources/Shaders/CameraShaders.metal` (arm 47; BT.709 luma/chroma split)
- Test: `GreyVisionTests/FlagshipRenderTests.swift`, `GreyVisionTests/CameraEffectTests.swift`

**Interfaces:**
- Consumes: `GVDatamoshEngine.DecodedFrame.texture` (BGRA reconstruction), `request.input` (clean linear camera).
- Produces: `Configuration.chromaOnly: Bool`; shader arm 47 reading `moshDecode` (texture 11, declared `CameraShaders.metal:3082`) and mixing its Cb/Cr into the source's Y.

- [ ] **Step 1: Write the failing registry + mapping tests**

```swift
    func testChromaMoshIsRegisteredAsACodecInstrument() {
        XCTAssertEqual(WorkspaceAdjustableEffect.chromaMosh.temporalMode, 47)
        XCTAssertNil(WorkspaceAdjustableEffect.chromaMosh.styleMode, "47 is taken in the style table")
        XCTAssertEqual(WorkspaceAdjustableEffect.chromaMosh.parameterLabels.count, 3)
        XCTAssertTrue(WorkspaceAdjustableEffect.chromaMosh.freezesHistoryOnHold)
        XCTAssertTrue(WorkspaceAdjustableEffect.datamoshCategoryEffects.contains(.chromaMosh))
        XCTAssertFalse(WorkspaceAdjustableEffect.chromaMosh.defaultCameraParameters.isEnabled)
    }

    func testChromaMoshMappingRequestsChromaOnly() {
        let configuration = GVDatamoshEngine.configuration(variant: .chromaMosh,
                                                            primary: 0.5, secondary: 0.5, tertiary: 0.5)
        XCTAssertTrue(configuration.chromaOnly, "the whole technique is that only chroma comes from the codec")
        XCTAssertGreaterThan(configuration.referenceDropEvery, 1, "colour must be dragged, not merely blurred")
        XCTAssertEqual(configuration.codec, .h264, "4:2:0 macroblock chroma is the H.264 artefact")
    }
```

Run: `xcodebuild … -only-testing:GreyVisionTests/CameraEffectTests/testChromaMoshIsRegisteredAsACodecInstrument test`
Expected: FAIL — no `chromaMosh` case.

- [ ] **Step 2: Add `chromaOnly` to the codec intent**

In `GVDatamoshEngine.Configuration` (`:47-70`) add, with the reasoning inline:

```swift
        /// Take the decoder's chroma and throw its luma away. The reconstruction
        /// is a real 4:2:0 decode, so the colour plane carries the codec's own
        /// quantisation error smeared over whole macroblocks — which is the
        /// artefact — while the luma the operator sees stays the sharp camera
        /// frame. Nothing about the block bleeding is computed by a kernel.
        var chromaOnly = false
```

Add `case chromaMosh` to `Variant` (`:98`) and the arm to `configuration(variant:…)` (`:137`):

```swift
        case .chromaMosh:
            // Colour smear scale is the encode size: a coarser grid drags chroma
            // over larger blocks. Bleed is the bitrate, starved hardest.
            configuration.chromaOnly = true
            configuration.encodeLongEdge = edge(Int(ramp(unit(primary), 480, 96).rounded()))
            configuration.bitrateBitsPerSecond = Int(ramp(unit(tertiary), 8_000, 180_000).rounded())
            configuration.referenceDropEvery = drop(secondary)
            configuration.keyframeIntervalFrames = 240
            configuration.codec = .h264
```

- [ ] **Step 3: Map the effect to the variant**

`Variant(effect)` needs the new case, and `CameraMetalSurface.swift:2982` becomes `case 4, 39, 40, 47`. `holdStyle(for:)` (`:1986`) returns the feedback-runaway bit so a held CHROMA MOSH keeps bleeding colour:

```swift
        case .chromaMosh:
            // FEEDBACK RUNAWAY: on a held frame the reconstruction is the input,
            // so chroma keeps drifting further from a luma that no longer moves.
            return 0b0100
```

- [ ] **Step 4: Add the Metal arm**

In `gvCameraTemporalEffect`'s mode switch (`CameraShaders.metal:3155`), immediately after the
existing `case 4` (`:3192`), using the same locals that switch already establishes — `current`,
`result`, `controls.x/y/z` for the three sliders, `uv`, and the `uniforms.mode.w == 1u` decode
gate — so the arm cannot depend on names that do not exist:

```metal
case 47: { // Chroma Mosh - the camera's detail, the codec's colour
    // The reconstruction is a real 4:2:0 decode, so its chroma carries the
    // codec's own residual quantisation smeared across whole macroblocks.
    // Keeping the camera's luma and taking only the decoder's chroma means the
    // bleeding blocks are the hardware's decision, and the detail loss that
    // would normally accompany it simply does not happen.
    if (uniforms.mode.w == 1u) {
        const float3 moshed = gvCameraSampleDecodeBlocky(moshDecode, uv);
        const float srcY = dot(current, float3(0.2126, 0.7152, 0.0722));
        const float moshY = dot(moshed, float3(0.2126, 0.7152, 0.0722));
        // BT.709 to chroma, and back. These are the same coefficients the
        // encoder's own colour space uses, so the round trip is honest rather
        // than an approximation that tints the picture.
        const float2 srcChroma = float2(dot(current, float3(-0.1146, -0.3854, 0.5)),
                                        dot(current, float3(0.5, -0.4689, -0.0312)));
        const float2 moshChroma = float2(dot(moshed, float3(-0.1146, -0.3854, 0.5)),
                                         dot(moshed, float3(0.5, -0.4689, -0.0312)));
        // BLEND is how much of the codec's colour is admitted; BITS is what makes
        // it coarse, and it is already spent inside the encoder.
        const float blend = saturate(controls.x);
        const float2 outChroma = mix(srcChroma, moshChroma, blend);
        const float3 rebuilt = float3(srcY + 1.0 * outChroma.y,
                                      srcY - 0.39465 * outChroma.x - 0.5806 * outChroma.y,
                                      srcY + 1.986 * outChroma.x);
        result = mix(current, saturate(rebuilt), 0.85 + 0.15 * saturate(moshY));
    }
    break;
}
```

`gvCameraSampleDecodeBlocky` is the helper `case 4` already uses for the reconstruction; reusing
it keeps the block grid identical between DATAMOSH and CHROMA MOSH, which is what makes them
read as the same family.

- [ ] **Step 5: Round-trip test that chroma actually came from the codec**

```swift
    /// The claim is specific: colour from the decoder, detail from the camera.
    /// A frame that encodes a hard colour edge at a starved bitrate must show
    /// chroma error outside the 16x16 grid, and a luma plane that still matches
    /// the source. If the shader were faking this, the luma would move too.
    @MainActor
    func testChromaOnlyKeepsLumaAndBorrowsDecoderChroma() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable on this destination") }
        let engine = try XCTUnwrap(GVDatamoshEngine(device: device))
        var configuration = GVDatamoshEngine.configuration(variant: .chromaMosh,
                                                            primary: 0.9, secondary: 0.9, tertiary: 0.05)
        configuration.encodeLongEdge = 64
        XCTAssertTrue(configuration.chromaOnly)
        // Drive it the way the renderer does, then assert a reconstruction exists
        // at the encode size; the chroma/luma split itself is shader-side and is
        // verified visually on a device.
        var submitted = 0
        let deadline = Date().addingTimeInterval(20)
        while engine.latestDecodedFrame == nil, Date() < deadline {
            guard let staging = engine.beginFrame(configuration: configuration, sourceSize: CGSize(width: 64, height: 64)) else {
                usleep(2_000); continue
            }
            engine.endFrame(staging, configuration: configuration)
            submitted += 1
            usleep(4_000)
        }
        XCTAssertNotNil(engine.latestDecodedFrame, "chroma-only never produced a decode")
        engine.stop()
    }
```

- [ ] **Step 6: Run the full gate, then judge it on a phone**

Run: `./scripts/verify.sh`
Expected: PASS for registry, coverage, and engine tests. On device: a sharp picture whose colour drags in blocks behind moving edges. If the colour instead looks like a blur filter, the bitrate ceiling in Step 2 is too generous — lower `tertiary`'s top value, do not add a shader smear.

- [ ] **Step 7: Commit**

```bash
git add GreyVision/Features/Workspace/WorkspaceEffectParameters.swift GreyVision/Engine/Rendering/GVDatamoshEngine.swift GreyVision/Engine/Rendering/CameraMetalSurface.swift GreyVision/Resources/Shaders/CameraShaders.metal GreyVisionTests/FlagshipRenderTests.swift GreyVisionTests/CameraEffectTests.swift
git commit -m "Add CHROMA MOSH: decoder chroma over camera luma"
```

---

### Task 6: GENERATION MOSH — a mosh of a mosh

Recursive re-encode is the classic technique: feed the encoder its own previous output and corruption compounds through the codec, producing the melting tail. `Configuration.recycle` already does one generation inside one engine. A second chained round trip makes the cascade a generation deeper per frame, with its own bitrate per stage — corruption that no single encode would ever produce.

**Files:** as Task 5, plus `GVDatamoshEngine.swift` for a second stage; mode **48**.
**Interfaces:**
- Consumes: `GVDatamoshEngine` as a reusable single-stage round trip — the cascade is **two
  instances of the existing engine**, not a new engine that knows about stages, so all of the
  round-trip logic written and tested so far is reused rather than duplicated.
- Produces: `CameraRenderGraphNode.codecEngineSecondary: GVDatamoshEngine?`, `GVDatamoshEngine.Configuration.stages: Int`, `Variant.generationMosh`, and `encodeDatamoshStage(engine:pipeline:live:previous:configuration:commandBuffer:)` — the single-stage staging routine extracted in Step 4, now callable twice.

- [ ] **Step 1: Write the failing test**

```swift
    /// Two chained round trips, not one engine told to recycle harder: stage two
    /// must encode what stage one's decoder reconstructed, so each frame crosses
    /// the quantiser twice and the tail melts rather than merely softening.
    func testGenerationMoshAsksForTwoStagesAndTwoProcessors() {
        let configuration = GVDatamoshEngine.configuration(variant: .generationMosh,
                                                            primary: 0.5, secondary: 0.5, tertiary: 0.5)
        XCTAssertEqual(configuration.stages, 2, "a frame must cross two quantisers")
        // Stage two is only meaningful if stage one is starved: the second encode
        // of an already-clean frame is just H.264.
        XCTAssertLessThan(configuration.bitrateBitsPerSecond, 400_000)
        XCTAssertEqual(configuration.recycle, 1, "stage one must be self-feeding")
    }
```

Run: `xcodebuild … -only-testing:GreyVisionTests/FlagshipRenderTests/testGenerationMoshAsksForTwoStagesAndTwoProcessors test`
Expected: FAIL — no `.generationMosh` case and no `stages` property.

- [ ] **Step 2: Add the variant and the stage count**

In `Configuration` (`:47-70`):

```swift
        /// How many codec round trips one displayed frame crosses. Two means the
        /// second encoder receives the first decoder's reconstruction, so
        /// corruption compounds through a fresh quantiser every frame rather than
        /// along one long chain — the difference between a mosh and a melt.
        var stages = 1
```

In `configuration(variant:…)` (`:137`):

```swift
        case .generationMosh:
            // DEPTH is fixed at two stages by the budget; BITS is what each stage
            // gets, and the second is always the hungrier. RECYCLE is forced on:
            // stage one has to be eating itself for stage two to have anything to
            // work on.
            configuration.stages = 2
            configuration.encodeLongEdge = edge(960)
            configuration.bitrateBitsPerSecond = Int(ramp(unit(tertiary), 15_000, 300_000).rounded())
            configuration.referenceDropEvery = drop(secondary)
            configuration.keyframeIntervalFrames = 480
            configuration.recycle = 1
```

- [ ] **Step 3: Fund two sessions and hold the second engine on the node**

Task 1's `codecEngine(for:)` already asks the budget for `node.codecModeCost`. Make the cost
`2` for this mode and allocate both engines inside that one funding call, so there is exactly
one place that decides whether a Slot may hold hardware. Replace `codecEngine(for:)` with the
pair-returning version below — a cascade either gets both sessions or neither, and "neither"
leaves the Slot rendering whole rather than shipping a half-cascade that looks like a soft
single-stage mosh:

```swift
    /// Stage two's session. Only ever funded together with `codecEngine`, because
    /// a half-funded cascade would be a mosh that quietly stopped cascading.
    var codecEngineSecondary: GVDatamoshEngine?
```

```swift
    func codecEngines(for node: CameraRenderGraphNode) -> (GVDatamoshEngine, GVDatamoshEngine?)? {
        if let existing = node.codecEngine {
            return (existing, node.codecEngineSecondary)
        }
        let cost = node.codecModeCost
        guard codecBudget.fund(requested: cost), let primary = GVDatamoshEngine(device: device) else {
            node.codecBudgetRefused = true
            return nil
        }
        // A cascade that cannot afford stage two is not allowed to become a
        // single-stage mosh behind the operator's back: it releases its funding
        // and leaves the Slot rendering whole, which is at least honest.
        if cost == 2, let secondary = GVDatamoshEngine(device: device) {
            node.codecEngineSecondary = secondary
        } else if cost == 2 {
            codecBudget.release(cost)
            node.codecBudgetRefused = true
            primary.stop()
            return nil
        }
        node.codecBudgetRefused = false
        node.codecSessionsSpent = cost
        node.codecEngine = primary
        return (primary, node.codecEngineSecondary)
    }
```

Rename the Task 1 call site to this function, and clear `codecEngineSecondary` in
`reset(reason:)` / `releaseResources()` beside `codecEngine`. Also raise the cost, which is the
other half of Step 3 — without it the budget funds two cascades and oversubscribes the encoder:

```swift
    /// Sessions this Slot needs. One for every single round trip; two for the
    /// cascade, which is the only mode that runs two encoders on one frame.
    var codecModeCost: Int {
        switch stage {
        case .temporal(.generationMosh): 2
        default: 1
        }
    }
```

- [ ] **Step 4: Run the second stage from the same pass**

`encodeDatamoshPass` now binds the pair the funding function returns:

```swift
        guard let engines = codecEngines(for: node), let pipeline = datamoshStagePipeline,
              let variant = GVDatamoshEngine.Variant(effect) else { return }
        let engine = engines.0
```

Then extract the staging dispatch in `encodeDatamoshPass` into a routine that takes an engine plus
the texture the kernel should read as its "previous" input, then call it twice. The extraction is
the whole implementation — `gvCameraDatamoshStage` already mixes `live` and the decode by
`recycle` (Task 2 Step 4), so pointing `decodeTexture` at stage one's reconstruction and running
the identical kernel is genuinely all a second generation needs:

```swift
    /// One generation of the round trip: claim staging, write it from `live` mixed
    /// toward `previous`, hand it to `engine`. `encodeDatamoshPass` calls this once
    /// for every mode; a cascade calls it twice, the second time with stage one's
    /// reconstruction as `previous` and no live frame at all.
    private func encodeDatamoshStage(engine: GVDatamoshEngine,
                                     pipeline: MTLComputePipelineState,
                                     live: MTLTexture,
                                     previous: MTLTexture?,
                                     configuration: GVDatamoshEngine.Configuration,
                                     commandBuffer: MTLCommandBuffer) {
        guard let staging = engine.beginFrame(configuration: configuration,
                                              sourceSize: CGSize(width: live.width, height: live.height))
        else { return }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        var uniforms = DatamoshStageUniforms(recycle: configuration.recycle,
                                             decodeReady: previous == nil ? 0 : 1)
        encoder.label = "greyVISION Datamosh Encoder Input"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(live, index: 0)
        encoder.setTexture(previous ?? live, index: 1)
        encoder.setTexture(staging.texture, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<DatamoshStageUniforms>.stride, index: 0)
        dispatch(encoder, pipeline: pipeline, texture: staging.texture)
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { _ in
            engine.endFrame(staging, configuration: configuration)
        }
    }
```

and in `encodeDatamoshPass`, after the existing stage-one call:

```swift
        // Stage two reads stage one's reconstruction only. If the live frame
        // leaked in here the cascade would reset every frame and the effect would
        // look like a slightly soft single-stage mosh — the most likely way this
        // feature fails quietly.
        if configuration.stages > 1,
           let secondary = node.codecEngineSecondary,
           let stageOne = engines.0.latestDecodedFrame {
            encodeDatamoshStage(engine: secondary,
                                pipeline: pipeline,
                                live: stageOne.texture,
                                previous: secondary.latestDecodedFrame?.texture,
                                configuration: configuration,
                                commandBuffer: commandBuffer)
        }
```

`decoded` for the display path then becomes `node.codecEngineSecondary?.latestDecodedFrame ?? engines.0.latestDecodedFrame` — the operator sees the deepest generation the codec produced.

- [ ] **Step 5: Register the effect and add Metal arm 48**

Apply the full Task 4 checklist with `temporalMode == 48`, and add a shader arm that displays stage two's reconstruction with the same reference-drag compositing as arm 4, plus `estimatedCost` 2.8 — two round trips are the most expensive thing in the temporal group.

- [ ] **Step 6: Run the gate, then judge on a phone**

Run: `./scripts/verify.sh`
Expected: PASS. On device: hold the camera still and the picture should still collapse inward over a few seconds — that is the cascade, and no single-stage mode does it.

- [ ] **Step 7: Commit**

```bash
git add GreyVision/Engine/Rendering/GVDatamoshEngine.swift GreyVision/Engine/Rendering/CameraMetalSurface.swift GreyVision/Features/Workspace/WorkspaceEffectParameters.swift GreyVision/Resources/Shaders/CameraShaders.metal GreyVisionTests/FlagshipRenderTests.swift
git commit -m "Add GENERATION MOSH: two chained codec round trips per frame"
```

---

### Task 7: TIME-LOOP MOSH — prediction against a moment, not a frame

Real inter prediction compares against the immediately preceding frame. Reaching back into `CircularFrameHistory` (`GreyVision/Engine/Infrastructure/CircularFrameHistory.swift:76` `frame(framesAgo:)`, `:88` `frame(closestTo:)`) and encoding an older frame as the *reference* while the current one is the *input* means the codec's own motion compensation carries objects across a real time gap — minutes-long smear that the shader version can only imitate by blending.

**Files:** as before, mode **49**; `GVDatamoshEngine.swift`, `CameraMetalSurface.swift`, `CameraShaders.metal`, `CircularFrameHistory` (read-only use).
**Interfaces:**
- Consumes: `CircularFrameHistory.frame(framesAgo:) -> TemporalFrameReference?` (`:76`).
- Produces: `Configuration.referenceAgeFrames: Int`; a second staging pass whose input is the aged frame.

- [ ] **Step 1: Write the failing test**

```swift
    func testTimeLoopMappingAsksForAnAgedReference() {
        let configuration = GVDatamoshEngine.configuration(variant: .timeLoopMosh,
                                                            primary: 0.5, secondary: 0.5, tertiary: 0.5)
        XCTAssertEqual(configuration.referenceAgeFrames, 15, "half travel should reach back a quarter second")
        let atRest = GVDatamoshEngine.configuration(variant: .timeLoopMosh,
                                                    primary: 0, secondary: 0.5, tertiary: 0.5)
        XCTAssertEqual(atRest.referenceAgeFrames, 0, "no travel means the previous frame, which is ordinary prediction")
    }
```

Run: `xcodebuild … -only-testing:GreyVisionTests/FlagshipRenderTests/testTimeLoopMappingAsksForAnAgedReference test`
Expected: FAIL — no `referenceAgeFrames`, no `.timeLoopMosh`.

- [ ] **Step 2: Add the intent and the variant**

```swift
        /// Frames of age on the reference the codec predicts from. Zero is
        /// ordinary inter prediction. Anything above it and the encoder spends
        /// motion vectors against a picture from a real moment ago, so the drag
        /// carries the past onto the present instead of smearing adjacent frames.
        var referenceAgeFrames = 0
```

```swift
        case .timeLoopMosh:
            // AGE spans the history ring, REACH is how hard the codec is allowed
            // to commit to it (bitrate), DROP keeps the chain diverging.
            configuration.referenceAgeFrames = Int(ramp(unit(primary), 0, 60).rounded())
            configuration.encodeLongEdge = edge(960)
            configuration.bitrateBitsPerSecond = Int(ramp(unit(secondary), 30_000, 900_000).rounded())
            configuration.referenceDropEvery = drop(tertiary)
            configuration.keyframeIntervalFrames = 240
```

- [ ] **Step 3: Source the aged frame in the render pass**

The history ring is already maintained by the temporal engine. In `encodeDatamoshPass`, when `referenceAgeFrames > 0`, pull the reference and use it as the staging kernel's *decode* input — the same `mix` path that gives self-feed, but pointed at history instead of at the reconstruction:

```swift
        // Pull the aged frame the codec will predict from. If the ring has not
        // filled that far, fall back to the reconstruction: a shorter reach is a
        // visible change in the effect, and a nil frame is a black one.
        let reference = configuration.referenceAgeFrames > 0
            ? historyReference(framesAgo: configuration.referenceAgeFrames)
            : nil
```

`historyReference(framesAgo:)` wraps `state.temporalRing` / `CircularFrameHistory.frame(framesAgo:)` and returns the `MTLTexture` from the `TemporalFrameReference`; where the ring hands back a pixel buffer, import it through the engine's existing `textureCache` rather than copying.

- [ ] **Step 4: Register the effect, add Metal arm 50, and guard the ring size**

Apply the Task 4 checklist with `temporalMode == 49`. `estimatedCost` 1.8 — one round trip plus a history read. Verify the ring depth actually holds 60 frames at the working resolution before shipping the slider's top end; `TemporalBufferBank`/`CircularFrameHistory` capacity is the limit, and a slider that reaches past stored history is a dead control. Clamp `referenceAgeFrames` to the ring's real depth inside the variant mapping and say so in the comment.

- [ ] **Step 5: Run the gate, then judge on a phone**

Run: `./scripts/verify.sh`
Expected: PASS. On device: wave a hand, then hold still — the trailing image should be dragged over the current one by the codec's own motion compensation, not cross-faded.

- [ ] **Step 6: Commit**

```bash
git add GreyVision/Engine/Rendering/GVDatamoshEngine.swift GreyVision/Engine/Rendering/CameraMetalSurface.swift GreyVision/Features/Workspace/WorkspaceEffectParameters.swift GreyVision/Resources/Shaders/CameraShaders.metal GreyVisionTests/FlagshipRenderTests.swift
git commit -m "Add TIME-LOOP MOSH: codec prediction against an aged reference frame"
```

---

### Task 8: BEAT GOP — corruption built and released on the beat

`GVBeatDetector` (`GreyVision/Engine/Audio/GVBeatDetector.swift`, onset threshold `1.4` at `:36`, refractory window `:76`) already produces transient cues, and the particle engine already consumes audio. Forcing a sync sample on a transient is a real encoder action with a real consequence: the accumulated reference drift is wiped at that instant, so the mosh breathes in time rather than on a fixed interval.

**Files:** as before, mode **50**; `GVDatamoshEngine.swift`, `CameraMetalSurface.swift`, `WorkspaceEffectParameters.swift`, `CameraShaders.metal`.
**Interfaces:**
- Consumes: `GVBeatDetector` onset cues, `GVDatamoshEngine.requestKeyframe()` (`:149` region), `state.settings.audio`/`audioDynamics`.
- Produces: `Configuration.syncOnTransient: Bool`, `Configuration.transientKeyframeDecay: Float`.

- [ ] **Step 1: Write the failing test**

```swift
    func testBeatMappingForcesSyncSamplesOnlyWhenArmed() {
        let armed = GVDatamoshEngine.configuration(variant: .beatGOP, primary: 0.7, secondary: 0.5, tertiary: 0.5)
        XCTAssertTrue(armed.syncOnTransient)
        XCTAssertGreaterThan(armed.keyframeIntervalFrames, 60, "the fallback interval must let drift accumulate between beats")

        let off = GVDatamoshEngine.configuration(variant: .beatGOP, primary: 0, secondary: 0.5, tertiary: 0.5)
        XCTAssertFalse(off.syncOnTransient, "at rest this is just DATAMOSH, and should look like it")
    }
```

- [ ] **Step 2: Add the intent and the variant**

```swift
        /// Force a sync sample on an audio transient instead of on a frame count.
        /// The encoder action is identical; what changes is that the release of
        /// accumulated corruption lands on a beat, which is a thing an operator
        /// can hear as well as see.
        var syncOnTransient = false
```

```swift
        case .beatGOP:
            configuration.syncOnTransient = unit(primary) > 0.04
            configuration.encodeLongEdge = edge(960)
            configuration.keyframeIntervalFrames = Int(ramp(unit(primary), 0, 900).rounded())
            configuration.referenceDropEvery = drop(secondary)
            configuration.bitrateBitsPerSecond = Int(ramp(unit(tertiary), 40_000, 1_500_000).rounded())
```

- [ ] **Step 3: Drive the keyframe from the beat cue**

Where the renderer already reads audio (`state.settings.audio`) and inside `encodeDatamoshPass`:

```swift
        // A transient is a real resync, so it must not fire twice inside the
        // detector's refractory window, and it must not fire at all while held:
        // a held frame that keeps repairing itself is not a held frame.
        if configuration.syncOnTransient, !held, beatCue.isNewTransient {
            engine.requestKeyframe()
        }
```

`beatCue` comes from the existing `GVBeatDetector` output already flowing into `CameraRenderSettings`; if the beat flag is not yet plumbed to the renderer, pass it through the same `update(...)` call (`:1163`) that carries `audio` and `audioDynamics`, rather than reading the detector from the render thread.

- [ ] **Step 4: Register, arm Metal mode 50, and label honestly**

Task 4 checklist with `temporalMode == 50`. Labels `["PULSE","DROP","BITS"]`, `detail` `"TRANSIENT-FORCED IDR"`, `requiresAudioAnalysis` true (`WorkspaceEffectParameters.swift:695`) so the analyser is switched on for it — a beat effect that silently never got audio is the failure mode to avoid. `estimatedCost` 1.5, matching the codec group.

- [ ] **Step 5: Run the gate, then judge on a phone**

Run: `./scripts/verify.sh`
Expected: PASS. On device with music: the picture should snap clean on hits and deteriorate in between. If it just flickers, the interval is too short — raise `keyframeIntervalFrames`'s floor rather than lowering the threshold in `GVBeatDetector`, which other effects depend on.

- [ ] **Step 6: Commit**

```bash
git add GreyVision/Engine/Rendering/GVDatamoshEngine.swift GreyVision/Engine/Rendering/CameraMetalSurface.swift GreyVision/Features/Workspace/WorkspaceEffectParameters.swift GreyVision/Resources/Shaders/CameraShaders.metal GreyVisionTests/FlagshipRenderTests.swift
git commit -m "Add BEAT GOP: transients force codec sync samples"
```

---

### Task 9: P-FRAME SPLICE — bitstream surgery, device-gated

Splicing one frame's macroblock layer onto another frame's sync sample at NAL level is the original datamosh edit, and the only technique here that edits the stream rather than steering an encoder. It is last, and it is gated: its success depends on undocumented tolerance of the hardware decoder for hand-edited slice data, which cannot be established in a Simulator. Do not begin this task's implementation until a probe on a real iPhone has shown that a hand-spliced unit decodes at all.

**Files:**
- Create: `GreyVision/Engine/Rendering/GVBitstreamSplice.swift`
- Test: `GreyVisionTests/FlagshipRenderTests.swift`

**Interfaces:**
- Consumes: `CMSampleBuffer` access units from the encoder callback (`GVDatamoshEngine.deliver(sampleBuffer:)`), H.264 NAL parsing.
- Produces: `GVBitstreamSplice.splice(current:reference:) -> Data?` returning a modified Annex-B/Avc unit, or nil to mean "deliver the original".

- [ ] **Step 1: Probe on device before writing any product code**

Write a throwaway test that encodes three frames at `keyframeIntervalFrames = 1`, takes the third unit, replaces its slice payload with the second unit's, and attempts a decode. Record whether the decoder emits a frame, an error, or garbage. Capture the raw units to `/private/tmp` so the result is inspectable. If the decoder refuses, this task stops and reports — the other four techniques stand on their own.

Run: `xcodebuild -project GreyVision.xcodeproj -scheme GreyVision -destination 'id=DA48F3DB-C16D-5418-8CD4-428F8BB31168' -configuration Debug test -only-testing:GreyVisionTests/FlagshipRenderTests`
Expected: a recorded verdict. This step produces an answer, not a feature.

- [ ] **Step 2: Only if the probe passed, write the failing test**

```swift
    /// A spliced unit must decode to a real frame or the caller must get nil.
    /// A black frame is not a datamosh; it is a pipeline failure that looks like
    /// one for exactly as long as it takes the operator to notice.
    func testSpliceEitherProducesADecodableUnitOrRefuses() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable on this destination") }
        let splice = GVBitstreamSplice()
        // Two known-good units of the same resolution, captured from the encoder.
        guard let current = GVBitstreamSpliceTestSupport.unit(frame: 1), let reference = GVBitstreamSpliceTestSupport.unit(frame: 2) else {
            throw XCTSkip("no captured access units available")
        }
        let result = splice.splice(current: current, reference: reference)
        if let result {
            XCTAssertFalse(result.isEmpty)
            XCTAssertNotNil(GVBitstreamSpliceTestSupport.decode(result, on: device), "a splice that decodes to nothing must return nil instead")
        }
    }
```

- [ ] **Step 3: Implement the parse, the splice, and the refusal**

Walk NAL units, identify the slice layer of a non-IDR P-unit, and substitute the reference frame's macroblock layer while keeping the current frame's slice header and the reference's sequence parameters; return nil on any structural mismatch (different resolution, different SPS, different profile) rather than emitting a unit that might decode to mush-of-the-wrong-kind. Feed the result to the decoder in place of the original at the single point in `deliver(sampleBuffer:)` where the encoder's unit is currently handed over intact.

- [ ] **Step 4: Wire it as the fifth variant with its own hold behaviour**

Task 4 checklist, `temporalMode == 51`, `Variant.pFrameSplice`. On a hold, the splice source reference must freeze with the frame — splicing against a still-current reference keeps the picture live underneath a hold that claims to be frozen.

- [ ] **Step 5: Run the gate, then judge on a phone**

Run: `./scripts/verify.sh`
Expected: PASS. On device: the unmistakable datamosh carry, where a moving object keeps the colours of the block it came from. If it looks like Task 7, the splice is not happening — check that the substituted layer, not just the header, reached the decoder.

- [ ] **Step 6: Commit**

```bash
git add GreyVision/Engine/Rendering/GVBitstreamSplice.swift GreyVision/Engine/Rendering/GVDatamoshEngine.swift GreyVision/Engine/Rendering/CameraMetalSurface.swift GreyVision/Features/Workspace/WorkspaceEffectParameters.swift GreyVision/Resources/Shaders/CameraShaders.metal GreyVisionTests/FlagshipRenderTests.swift
git commit -m "Add P-FRAME SPLICE: NAL-level macroblock splicing, device-gated"
```

---

### Task 10: Make the refused codec visible, and correct the stale recorder comment

Two finishing items the earlier tasks create rather than discover: the budget fallback in Task 1 must be visible to the operator, and `GVCaptureWriter.swift:87` still claims the microphone "is not wired up" when the live path has routed audio since `CameraRuntime.swift:193`.

**Files:**
- Modify: `GreyVision/Features/Workspace/GVTelemetryStrip.swift`
- Modify: `GreyVision/Engine/Capture/GVCaptureWriter.swift:83-89`
- Test: `GreyVisionTests/CameraEffectStackTests.swift`

- [ ] **Step 1: Write the failing test for the telemetry contract**

```swift
    /// A codec mode that silently fell back to its shader is the one failure the
    /// operator cannot see in the picture: the effect still moves, it is just no
    /// longer the codec. So the count of live round trips is part of the contract.
    func testRenderStatsExposeLiveCodecSlotCount() {
        var stats = CameraRenderStats.idle
        XCTAssertEqual(stats.codecSlots, 0)
        stats.codecSlots = 2
        XCTAssertEqual(stats.codecSlots, 2)
    }
```

- [ ] **Step 2: Show the count beside the shed-effect count**

In `GVTelemetryStrip`, render `codecSlots` only when at least one codec mode is stacked, using the same treatment as the existing `shedEffects` warning: a quiet number when it matches the stack, a highlighted one when it does not.

- [ ] **Step 3: Correct the recorder's documentation**

Replace the stale header at `GVCaptureWriter.swift:83-89`:

```swift
/// Writes processed frames to a QuickTime file.
///
/// Legacy path. It takes video only. The live recorder is
/// `GVRealtimeRecordingSession` (Engine/AR/ARRecordingSession.swift), which owns the
/// microphone handoff: `CameraRuntime` routes audio sample buffers into
/// `recordingMailbox.appendAudio` (CameraRuntime.swift:193) and the session writes them
/// through its own `AVAssetWriterInput`.
```

- [ ] **Step 4: Delete the misleading claim, verify nothing depends on it**

Confirm no code path still records through `GVVideoRecorder` for the main camera. `GVCaptureCoordinator.swift:503` still owns one; if it is unreferenced at runtime, say so in the comment rather than deleting it in this task — removal is its own decision for the human.

- [ ] **Step 5: Run the gate and commit**

Run: `./scripts/verify.sh`
Expected: PASS.

```bash
git add GreyVision/Features/Workspace/GVTelemetryStrip.swift GreyVision/Engine/Capture/GVCaptureWriter.swift GreyVisionTests/CameraEffectStackTests.swift
git commit -m "Surface live codec slot count and correct the stale video-only recorder comment"
```
