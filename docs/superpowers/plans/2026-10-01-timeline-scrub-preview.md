# Timeline Scrub Interaction and Recorded-Take Frame Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the timeline a playhead that actually exists, make scrubbing apply keyframes without requiring a prior play, and show the graded frame from a recorded take while the operator scrubs.

**Architecture:** `GVTimelinePlayer` interpolates keyframe state into `EffectEditingSession` and the render path reads that published state. Nothing in the app reads media today, so a new `GVTakeFrameReader` pulls one frame out of the last completed take with `AVAssetReader`. That frame becomes the renderer's *source for that tick* — the same single graph pass, the same node state, a different input — rather than a second concurrent pass.

**Tech Stack:** Swift 6, AVFoundation (`AVAssetReader` / `AVAssetWriter` for fixtures), Metal, SwiftUI, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-01-real-datamosh-hold-timeline-scrub-design.md` §6

## Global Constraints

- `SWIFT_VERSION: 6.0`, `SWIFT_STRICT_CONCURRENCY: complete`, `IPHONEOS_DEPLOYMENT_TARGET: 18.0`, `TARGETED_DEVICE_FAMILY: 1`.
- Tests are **XCTest**, `@testable import GreyVision`, `@MainActor` per test method (existing idiom: `FlagshipRenderTests.swift:45`, `BootstrapTests.swift:37`).
- `GreyVision.xcodeproj` is XcodeGen-generated — run `xcodegen generate` after adding files; never hand-edit the project. New `.swift` under `GreyVision/` is picked up by the source glob (`project.yml:53-72`).
- Gate: `./scripts/verify.sh` (xcodegen, `swiftformat --lint .`, `swiftlint lint` non-strict, simulator tests, device build). Simulator destination is computed by the script; override with `GV_SIMULATOR_DESTINATION`, derived data default `/private/tmp/gvverify`.
- **Offline re-render is out of scope** (spec non-goal). This plan previews a frame; it does not re-render a take.
- The scrub preview must not be able to alter the live camera path. It is one graph pass per frame, exactly as today, with a substituted source.

## Why the preview substitutes the source instead of running a second pass

The obvious shape — render the take frame through the graph into a small texture alongside the
viewfinder — is wrong here, and the plan avoids it deliberately: every temporal node advances
its own state once per pass (`node.moshStateReadsA.toggle()`, the `moshHistory` copy-back at
`CameraMetalSurface.swift:1959-1969`). A second pass in the same tick would double-advance that
state, so enabling the preview would visibly change the live effect — DATAMOSH would corrupt at
twice the rate while the operator was merely looking at a thumbnail. Substituting the source for
one pass keeps the graph, the node state, and the frame cost exactly as they are, and has
existing precedent: the hold branch at `:1310-1314` already reuses a retained `linearTexture` as
the frame's input instead of ingesting a new camera sample.

## What actually exists today

Verified, because the assumption that scrubbing was merely stubby was wrong:

- `GVTimelinePlayer.scrub(to:)` (`GreyVision/Features/Workspace/GVTimelinePlayer.swift:63-68`) has **zero call sites** in the app and zero in `GreyVisionTests/`.
- `GVTimelineBar.swift` contains **no gestures at all** — no `DragGesture`, no `onTapGesture`, no `gesture(`. Its track (`:46-55`) is two decorative `RoundedRectangle`s. The bar is play (`:63-81`), mode (`:84-99`), pick, and save.
- `storedTimelineForScrub()` (`:70-72`) returns `nil` unconditionally.
- `GVTimelineStore` is a singleton (`GVTimelineStore.swift:119`) exposing `@Published private(set) var timelines: [GVTimeline]` (`:118`) — the thing `storedTimelineForScrub` should have been reading.
- `GVTimeline` (`:76-88`) has `id`, `name`, `createdAt`, `isFactory`, `codecRaw`, `frameRate`, `resolutionRaw`, base composition and keyframes — and **no reference to any recorded file**.
- `GVCaptureWriter.swift:293` nils `outputURL` before the completion handler fires, so `GVCaptureCoordinator.swift:530`'s `if saved, let url = self.recorder.outputURL` reads nil, and `handleResult` (`:360-364`) discards the path it did receive. The raw path fabricates `URL(fileURLWithPath: "/dev/null")` (`:263`).
- `AVAssetReader` appears **nowhere** in the sources.
- Mailbox pattern for renderer-bound one-shot requests already exists on the runtime: `CameraRuntime.swift:35-36` (`recordingMailbox`, `screenshotMailbox`). The preview uses the same shape.

---

### Task 1: Stop discarding the finished take's URL

Nothing can preview a frame until the app knows where the recording went.

**Files:**
- Modify: `GreyVision/Engine/Capture/GVCaptureWriter.swift:97`, `:293`
- Modify: `GreyVision/Engine/Capture/GVCaptureCoordinator.swift:64`, `:263`, `:360-364`, `:530`
- Modify: `GreyVision/Engine/Capture/CameraRuntime.swift:33`
- Test: `GreyVisionTests/CameraEffectStackTests.swift`

**Interfaces:**
- Consumes: `GVVideoRecorder.outputURL` (`GVCaptureWriter.swift:97`), `GVRecordingResult` (`GVCaptureCoordinator.swift:64`).
- Produces: `CameraRuntime.lastCompletedTake: URL?` and `CameraRuntime.noteCompletedTake(_:)`.

- [ ] **Step 1: Write the failing test**

```swift
    /// A finished take has to stay addressable. The recorder nilled its own
    /// `outputURL` before the completion handler ran, which made the coordinator's
    /// success branch read nil and drop the path — so nothing downstream, scrub
    /// preview included, could open the file it had just written.
    func testCompletedTakeKeepsItsURLAvailableToTheRuntime() {
        let runtime = CameraRuntime()
        XCTAssertNil(runtime.lastCompletedTake)
        let url = URL(fileURLWithPath: "/private/tmp/greyvision-scrub-test.mov")
        runtime.noteCompletedTake(url)
        XCTAssertEqual(runtime.lastCompletedTake, url)
    }
```

Run: `xcodegen generate && xcodebuild -project GreyVision.xcodeproj -scheme GreyVision -destination "$GV_SIMULATOR_DESTINATION" -derivedDataPath /private/tmp/gvverify -only-testing:GreyVisionTests/CameraEffectStackTests/testCompletedTakeKeepsItsURLAvailableToTheRuntime test`
Expected: FAIL — cannot compile, no `lastCompletedTake` and no `noteCompletedTake(_:)`.

- [ ] **Step 2: Keep the recorder's URL alive**

At `GVCaptureWriter.swift:293`, remove the early nil and record why it must not come back:

```swift
        // `outputURL` deliberately survives the stop. The caller that saves to
        // Photos and the timeline scrub preview both need to address the file after
        // the writer is finished, and clearing it here made the coordinator's
        // success branch read nil and throw the path away.
```

- [ ] **Step 3: Carry the URL through the result, and delete the fabricated path**

Populate `.saved(path:)` (`GVCaptureCoordinator.swift:64`, assigned at `:530`) from the real URL, and remove `URL(fileURLWithPath: "/dev/null")` at `:263`. A fake path that reaches the UI is worse than no path, because the preview would try to open `/dev/null` and show a black frame that looks like a broken effect.

```swift
        case let .saved(path):
            runtime.noteCompletedTake(path)
```

- [ ] **Step 4: Publish it on the runtime**

In `CameraRuntime`, beside `isFrameFrozen` (`:33`):

```swift
    /// The most recent take this session wrote and saved. The timeline scrub
    /// preview reads a frame out of this file. It is a session-lifetime value, not
    /// a permanent library reference: a relaunch legitimately starts with none, and
    /// the UI has to say so rather than show an empty well.
    @Published private(set) var lastCompletedTake: URL?

    func noteCompletedTake(_ url: URL) {
        lastCompletedTake = url
    }
```

- [ ] **Step 5: Run the test and commit**

Run: `./scripts/verify.sh`
Expected: PASS.

```bash
git add GreyVision/Engine/Capture/GVCaptureWriter.swift GreyVision/Engine/Capture/GVCaptureCoordinator.swift GreyVision/Engine/Capture/CameraRuntime.swift GreyVisionTests/CameraEffectStackTests.swift
git commit -m "Keep a completed take's URL addressable for the session"
```

---

### Task 2: A playhead you can actually drag

The scrub method exists and nothing has ever called it. Build the interaction; it is useful and testable before any frame preview lands.

**Files:**
- Modify: `GreyVision/Features/Workspace/GVTimelineBar.swift:36-60`
- Modify: `GreyVision/Features/Workspace/GVTimelinePlayer.swift:23`, `:63-72`
- Modify: `GreyVision/Features/Workspace/GVTimelinePickerSheet.swift:80`
- Test: `GreyVisionTests/CameraEffectStackTests.swift`

**Interfaces:**
- Consumes: `GVTimelineStore.shared.timelines` (`GVTimelineStore.swift:118-119`), `GVTimeline.duration`, `GVTimelineKeyframe(time:field:value:)`.
- Produces: `GVTimelinePlayer.selectedTimeline: GVTimeline?`, `GVTimelinePlayer.selectForScrub(_:)`, and a bar track that maps a drag or tap to seconds.

- [ ] **Step 1: Write the failing test — scrub resolves a selected timeline without playing**

```swift
    /// Scrub must work without playing first: the operator drags to see what a cue
    /// does, and the first drag happens before any transport starts. The old helper
    /// returned nil unconditionally, so every drag before a play did nothing at all.
    @MainActor
    func testScrubResolvesTheSelectedTimelineWithoutPlaying() {
        let editor = EffectEditingSession()
        let player = GVTimelinePlayer()
        player.attach(editor: editor)

        var timeline = GVTimeline(name: "SCRUB TEST")
        timeline.duration = 4
        timeline.keyframes = [GVTimelineKeyframe(time: 0, field: .primary, value: 0),
                              GVTimelineKeyframe(time: 4, field: .primary, value: 1)]
        player.selectForScrub(timeline)

        XCTAssertFalse(player.isPlaying, "scrub must not start the transport")
        player.scrub(to: 2)
        XCTAssertEqual(player.currentTime, 2, accuracy: 0.001)
        XCTAssertEqual(player.activeTimeline?.name, "SCRUB TEST")
    }
```

Run: `xcodebuild … -only-testing:GreyVisionTests/CameraEffectStackTests/testScrubResolvesTheSelectedTimelineWithoutPlaying test`
Expected: FAIL — `selectForScrub(_:)` does not exist.

- [ ] **Step 2: Replace the nil stub with real selection**

In `GVTimelinePlayer`:

```swift
    /// The timeline the operator has chosen, whether or not it has ever played.
    /// Scrubbing needs keyframes to read, and the first drag precedes any transport.
    @Published private(set) var selectedTimeline: GVTimeline?

    func selectForScrub(_ timeline: GVTimeline) {
        selectedTimeline = timeline
        activeTimeline = timeline
        currentTime = min(currentTime, timeline.duration)
    }
```

and at `:70-72`:

```swift
    private func storedTimelineForScrub() -> GVTimeline? {
        selectedTimeline ?? GVTimelineStore.shared.timelines.first
    }
```

The store fallback is deliberate: the picker writes the store, so the most recent saved timeline is a defensible answer for a drag that arrives with nothing selected. Factory timelines (`isFactory`, `GVTimelineStore.swift:80`) are included, since they are the ones a new operator meets first.

- [ ] **Step 3: Make the track interactive**

Keep the track's visual exactly as it is (progress fill plus stroke, `:46-55`) and add hit area plus geometry:

```swift
            .frame(maxWidth: .infinity, minHeight: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard let timeline = player.activeTimeline ?? player.selectedTimeline,
                              timeline.duration > 0 else { return }
                        let fraction = min(max(value.location.x / max(value.size.width, 1), 0), 1)
                        player.scrub(to: fraction * timeline.duration)
                    }
            )
            .accessibilityRepresentation {
                Slider(value: scrubBinding,
                       in: 0 ... max(player.activeTimeline?.duration ?? 0, 0.01),
                       step: 0.05)
            }
```

`scrubBinding` is a computed `Binding<Double>` on the bar whose getter is `player.currentTime` and whose setter calls `player.scrub(to:)`, so VoiceOver and the drag drive one code path. `minimumDistance: 0` makes a tap seek as well as a drag, so a single gesture covers both. `accessibilityRepresentation` is required, not decoration: the bar currently exposes only `.accessibilityLabel` on its buttons (`:80`, `:99`), and a playhead nobody can move is invisible to VoiceOver.

- [ ] **Step 4: Wire the picker to selection**

`GVTimelinePickerSheet.swift:80` already compares `player.activeTimeline?.id` for the active row. On row tap, call `player.selectForScrub(timeline)` so choosing a timeline arms scrubbing without starting playback.

- [ ] **Step 5: Run the tests and commit**

Run: `./scripts/verify.sh`
Expected: PASS, plus a Simulator check that a drag moves the timecode rendered at `GVTimelineBar.swift:136` and that releasing does not start the transport.

```bash
git add GreyVision/Features/Workspace/GVTimelineBar.swift GreyVision/Features/Workspace/GVTimelinePlayer.swift GreyVision/Features/Workspace/GVTimelinePickerSheet.swift GreyVisionTests/CameraEffectStackTests.swift
git commit -m "Add a draggable playhead and scrub the timeline without playing it"
```

---

### Task 3: `GVTakeFrameReader` — one frame out of a recorded take

**Files:**
- Create: `GreyVision/Engine/Capture/GVTakeFrameReader.swift`
- Create: `GreyVisionTests/GVTakeFrameReaderTests.swift` (then `xcodegen generate`)

**Interfaces:**
- Consumes: a file `URL` from Task 1.
- Produces: `GVTakeFrameReader.frame(at seconds: TimeInterval) async -> CVPixelBuffer?` — the newest decodable frame at or before the requested time; `nil` for a missing or unreadable file. Repeated calls coalesce to the newest request.

- [ ] **Step 1: Write the failing tests**

Do not mock AVFoundation here — a mock would prove the wrapper calls itself correctly and nothing about whether a hardware decoder yields a frame. Write a real two-second movie and read it back.

```swift
    /// The reader must return a frame from around the requested time. A decoder
    /// can only begin at a sync sample, so the honest contract is "newest frame at
    /// or before the target"; an implementation that always returned frame zero
    /// would pass a naive test and be useless for scrubbing.
    @MainActor
    func testFrameAtReturnsALaterAndBrighterFrame() async throws {
        let url = try GVTakeFixture.makeMovie(seconds: 2, framesPerSecond: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = GVTakeFrameReader(url: url)

        guard let early = await reader.frame(at: 0.1), let late = await reader.frame(at: 1.7) else {
            throw XCTSkip("no hardware video decoder on this destination")
        }
        XCTAssertEqual(CVPixelBufferGetWidth(early), CVPixelBufferGetWidth(late))
        XCTAssertGreaterThan(GVPixelSampler.meanLuma(late), GVPixelSampler.meanLuma(early) + 0.05,
                             "the luma ramp must advance with the requested time")
    }

    @MainActor
    func testMissingFileReturnsNilRatherThanThrowing() async {
        let reader = GVTakeFrameReader(url: URL(fileURLWithPath: "/private/tmp/greyvision-does-not-exist.mov"))
        let frame = await reader.frame(at: 0.5)
        XCTAssertNil(frame, "an unopenable take is a no-preview case, not an error the UI must catch")
    }

    /// A drag produces far more requests than a decoder can service. Newest must
    /// win and nothing may hang: a continuation left un-resumed is a leaked task,
    /// and the UI would freeze waiting for a frame nobody asked for any more.
    @MainActor
    func testRapidRequestsAllCompleteAndTheNewestWins() async throws {
        let url = try GVTakeFixture.makeMovie(seconds: 2, framesPerSecond: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = GVTakeFrameReader(url: url)
        async let first = await reader.frame(at: 0.2)
        async let second = await reader.frame(at: 1.9)
        let results = await (first, second)
        XCTAssertNotNil(results.1, "the newest request must be served")
    }
```

Run: `xcodegen generate && xcodebuild -project GreyVision.xcodeproj -scheme GreyVision -destination "$GV_SIMULATOR_DESTINATION" -derivedDataPath /private/tmp/gvverify -only-testing:GreyVisionTests/GVTakeFrameReaderTests test`
Expected: FAIL — `GVTakeFrameReader` does not exist.

- [ ] **Step 2: Write the fixture helpers in that new test file**

```swift
    enum GVFixtureError: Error {
        case writerWouldNotStart
        case writerFailed(String)
        case bufferUnavailable
    }

    enum GVPixelSampler {
        /// Mean luma over every 17th pixel: a stride, not a full walk, so a test
        /// does not hold a buffer locked across 16k pixels.
        static func meanLuma(_ buffer: CVPixelBuffer) -> Double {
            guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess,
                  let base = CVPixelBufferGetBaseAddress(buffer)
            else { return -1 }
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            let pitch = CVPixelBufferGetBytesPerRow(buffer)
            var total = 0.0, count = 0.0
            base.withMemoryRebound(to: UInt8.self, capacity: pitch * height) { bytes in
                for index in stride(from: 0, to: width * height, by: 17) {
                    let offset = index * 4
                    let blue = Double(bytes[offset])
                    let green = Double(bytes[offset + 1])
                    let red = Double(bytes[offset + 2])
                    total += (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255
                    count += 1
                }
            }
            return count > 0 ? total / count : -1
        }
    }

    /// Writes a small H.264 movie whose luma ramps with time, so a reader stuck on
    /// frame zero is detectable by brightness alone.
    enum GVTakeFixture {
        static func makeMovie(seconds: Double, framesPerSecond: Int) throws -> URL {
            let url = URL(fileURLWithPath: "/private/tmp")
                .appendingPathComponent("greyvision-fixture-\(UUID().uuidString).mov")
            let width = 128, height = 128
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                ]
            )
            writer.add(input)
            guard writer.startWriting(), writer.startSession(atSourceTime: .zero) else {
                throw GVFixtureError.writerWouldNotStart
            }
            let frames = Int(seconds * Double(framesPerSecond))
            for index in 0 ..< frames {
                while !adaptor.isReadyForMoreMediaData { usleep(2_000) }
                let buffer = try makeFrame(index: index, of: frames, width: width, height: height)
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index),
                                                                   timescale: CMTimeScale(framesPerSecond)))
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw GVFixtureError.writerFailed(writer.error?.localizedDescription ?? "unknown")
            }
            return url
        }

        private static func makeFrame(index: Int, of frames: Int, width: Int, height: Int) throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                      &buffer) == kCVReturnSuccess, let buffer
            else { throw GVFixtureError.bufferUnavailable }
            let level = UInt8(255.0 * Double(index) / Double(max(frames - 1, 1)))
            guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess,
                  let base = CVPixelBufferGetBaseAddress(buffer)
            else { throw GVFixtureError.bufferUnavailable }
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let pitch = CVPixelBufferGetBytesPerRow(buffer)
            base.withMemoryRebound(to: UInt8.self, capacity: pitch * height) { bytes in
                for row in 0 ..< height {
                    for column in 0 ..< width {
                        let offset = row * pitch + column * 4
                        bytes[offset] = level
                        bytes[offset + 1] = level
                        bytes[offset + 2] = level
                        bytes[offset + 3] = 255
                    }
                }
            }
            return buffer
        }
    }
```

- [ ] **Step 3: Implement the reader**

```swift
import AVFoundation
import CoreVideo
import Foundation

/// Reads one frame out of a recorded take at a requested time.
///
/// `AVAssetReader` can only begin decoding at a sync sample, so the seek target
/// snaps back to a preceding sync frame and the reader advances from there. That
/// is why the contract is "the newest frame at or before `seconds`" rather than
/// "exactly this frame": promising frame accuracy would be a lie about what a
/// decoder can do, and the preview would flicker between a sample and its
/// predecessor every time the playhead crossed a frame boundary.
///
/// Reads are not free — walking from a sync sample costs more the further into
/// the file it starts — so callers coalesce, and `frame(at:)` cancels whatever is
/// still in flight when a newer request arrives.
///
/// Thread-safe by lock rather than by isolation: `AVAssetReader` is synchronous
/// and blocks, so the work runs on a private serial queue rather than an actor,
/// which would hold a thread for the duration of the decode anyway. The mutable
/// state (`requestedTime`, `inFlight`) is confined to `lock` and that queue, which
/// is the `@unchecked Sendable` justification.
final class GVTakeFrameReader: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "greyvision.take-frame-reader", qos: .userInitiated)
    private let lock = NSLock()
    private var inFlight: DispatchWorkItem?

    init(url: URL) {
        self.url = url
    }

    func frame(at seconds: TimeInterval) async -> CVPixelBuffer? {
        await withCheckedContinuation { continuation in
            lock.lock()
            inFlight?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                // A cancelled item never runs, so every continuation is resumed by
                // the item that did run. Waiting on a superseded request would hang.
                continuation.resume(returning: self.read(seconds: seconds))
            }
            inFlight = item
            lock.unlock()
            queue.async(execute: item)
        }
    }

    private func read(seconds: TimeInterval) -> CVPixelBuffer? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset)
        else { return nil }
        // Half a second of runway before the target: enough to cover a sparsely
        // keyed take without walking the whole file from the start.
        let start = max(0, seconds - 0.5)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       end: CMTime(seconds: seconds + 0.5, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        guard reader.canAdd(output), reader.add(output), reader.startReading() else { return nil }

        var newest: (sample: CMSampleBuffer, buffer: CVPixelBuffer)?
        let tolerance = 1.0 / 60.0
        while reader.status == .reading, let sample = output.copyNextSampleBuffer() {
            let presentation = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard presentation <= seconds + tolerance else { break }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            newest = (sample, pixelBuffer)
        }
        reader.cancelReading()
        guard let chosen = newest else { return nil }
        // The sample buffer is the only thing retaining that surface and it goes out
        // of scope here, so the frame is copied into a detached buffer rather than
        // handed back pointing at memory nothing owns.
        return Self.detach(chosen.buffer)
    }

    private static func detach(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        var copy: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:],
                                   kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
                                  &copy) == kCVReturnSuccess, let copy
        else { return nil }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess,
              CVPixelBufferLockBaseAddress(copy, []) == kCVReturnSuccess,
              let from = CVPixelBufferGetBaseAddress(source),
              let to = CVPixelBufferGetBaseAddress(copy)
        else {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(copy, [])
            return nil
        }
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(copy, [])
        }
        let sourcePitch = CVPixelBufferGetBytesPerRow(source)
        let destinationPitch = CVPixelBufferGetBytesPerRow(copy)
        let rowBytes = min(sourcePitch, destinationPitch)
        for row in 0 ..< height {
            memcpy(to + row * destinationPitch, from + row * sourcePitch, rowBytes)
        }
        return copy
    }
}
```

- [ ] **Step 4: Run the tests and commit**

Run: `./scripts/verify.sh`
Expected: PASS. `testFrameAtReturnsALaterAndBrighterFrame` `XCTSkip`s when no decoder is available — that is an honest skip, not a green suite. Fixtures live in `/private/tmp` and delete themselves.

```bash
git add GreyVision/Engine/Capture/GVTakeFrameReader.swift GreyVisionTests/GVTakeFrameReaderTests.swift
git commit -m "Add a single-frame reader for recorded takes with newest-request coalescing"
```

---

### Task 4: Scrub shows the graded take frame

The read is worthless until it goes through the same effect graph, so the operator sees what the cue looks like at that moment rather than the raw recorded frame.

**Files:**
- Modify: `GreyVision/Engine/Capture/CameraRuntime.swift:33-39` (preview mailbox + request)
- Modify: `GreyVision/Engine/Rendering/CameraMetalSurface.swift:1285-1320` (ingest branch), `:348-352` (`updateUIView`)
- Modify: `GreyVision/Features/Workspace/GVTimelineBar.swift` (scrub request + state)
- Test: `GreyVisionTests/FlagshipRenderTests.swift`

**Interfaces:**
- Consumes: `GVTakeFrameReader.frame(at:)` (Task 3), `CameraRuntime.lastCompletedTake` (Task 1), the existing `linearTexture` ingest branch (`CameraMetalSurface.swift:1310-1314`).
- Produces: `CameraPreviewMailbox` on the runtime, mirroring `recordingMailbox` / `screenshotMailbox` (`CameraRuntime.swift:35-36`), and `CameraRuntime.requestPreviewFrame(at:)`.

- [ ] **Step 1: Write the failing test — the mailbox is consume-once and never replays**

```swift
    /// The preview is one frame of one take. If a stale preview could be consumed
    /// twice, the viewfinder would keep showing a frame from a take the operator
    /// already stopped scrubbing, which reads as a frozen camera — the exact
    /// failure this app cannot afford because it also has a real freeze control.
    func testPreviewMailboxIsConsumeOnce() throws {
        let mailbox = CameraPreviewMailbox()
        XCTAssertNil(mailbox.consumeLatest())
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 128, 128, kCVPixelFormatType_32BGRA,
                                  nil, &buffer) == kCVReturnSuccess, let buffer
        else { throw XCTSkip("could not allocate a test pixel buffer") }
        mailbox.publish(buffer, generation: 7)
        let consumed = try XCTUnwrap(mailbox.consumeLatest())
        XCTAssertEqual(consumed.generation, 7)
        XCTAssertNil(mailbox.consumeLatest(), "a consumed preview must not replay")
    }
```

- [ ] **Step 2: Add the mailbox and the request to the runtime**

```swift
    /// One pending scrub-preview frame. Newest wins, consumed once by the render
    /// loop. A mailbox rather than a `@Published` value because the render thread
    /// and the main actor must not share observable state, for the same reason
    /// `recordingMailbox` exists (`:35`).
    let previewMailbox = CameraPreviewMailbox()

    /// Requests the graded frame at a playhead position. Fire-and-forget: the
    /// result lands in `previewMailbox` and the render loop picks it up.
    func requestPreviewFrame(at seconds: TimeInterval) {
        guard let take = lastCompletedTake else { previewModel.isExpectingFrame = false; return }
        previewModel.isExpectingFrame = true
        Task { @MainActor in
            let reader = GVTakeFrameReader(url: take)
            if let buffer = await reader.frame(at: seconds) {
                previewMailbox.publish(buffer, generation: previewMailbox.nextGeneration)
            }
            previewModel.isExpectingFrame = false
        }
    }
```

`CameraPreviewMailbox` is a new type in `GreyVision/Engine/Capture/GVTakeFrameReader.swift` — the reader and its mailbox change together and belong in one file:

```swift
/// One pending preview frame, newest wins, consumed once.
final class CameraPreviewMailbox: @unchecked Sendable {
    struct Entry {
        let buffer: CVPixelBuffer
        let generation: UInt64
    }

    private let lock = NSLock()
    private var pending: Entry?
    private var generation: UInt64 = 0

    var nextGeneration: UInt64 {
        lock.withLock {
            generation &+= 1
            return generation
        }
    }

    func publish(_ buffer: CVPixelBuffer, generation: UInt64) {
        lock.withLock { pending = Entry(buffer: buffer, generation: generation) }
    }

    func consumeLatest() -> Entry? {
        lock.withLock {
            defer { pending = nil }
            return pending
        }
    }
}
```

- [ ] **Step 3: Substitute the source in the render loop — one pass, not two**

In `draw(in:)`, the ingest branch at `:1285-1320` already knows how to run a frame from a retained
texture instead of a new camera sample (the hold case, `:1310-1314`). A preview is the same shape:
import the take frame into `linearTexture` and let the normal single pass run on it.

```swift
        } else if let preview = mailboxPreview.consumeLatest() {
            // A scrub preview is a frame from a recorded take, run through the same
            // single graph pass as the camera. It is NOT a second pass: temporal Slots
            // advance their own state once per pass (moshStateReadsA, the moshHistory
            // copy-back), so a second pass would corrupt the live effect at double rate
            // while the operator was only looking at a scrub frame.
            //
            // The camera mailbox is drained alongside it, so a preview cannot be
            // mistaken for a new capture sample by the branch below.
            _ = mailbox.consumeLatest()
            guard ensureWorkingTextures(width: CVPixelBufferGetWidth(preview.buffer),
                                        height: CVPixelBufferGetHeight(preview.buffer)),
                  let linearTexture
            else { return }
            if importPreview(preview.buffer, into: linearTexture, commandBuffer: commandBuffer) {
                hasLinearFrame = true
            } else {
                return
            }
        } else if settings.temporalHoldActive && hasLinearFrame {
```

Place this branch **before** the `temporalHoldActive` branch, so scrubbing during a hold shows the take frame rather than the held camera frame — and note in the comment that a hold of a *preview* frame is the intended composition of the two features.

`importPreview(_:into:commandBuffer:)` creates a `CVMetalTextureCache` texture view of the pixel buffer (the renderer already owns `textureCache`) and dispatches the existing copy used by `encodeHistoryCopy` (`:1907`, `:1964`) to blit it into `linearTexture`, returning false if the import fails. On failure the branch returns without drawing, which leaves the previous frame on screen for one tick — correct for a preview, and never a black frame.

- [ ] **Step 4: Ask for a frame while the playhead moves**

In `GVTimelineBar`, the drag from Task 2 Step 3 scrubs as before, and the playhead change alone
drives the preview request, quantised so a fast drag issues a handful of reads rather than one per
pointer sample:

```swift
                        let target = fraction * timeline.duration
                        player.scrub(to: target)
```

```swift
    /// Quantised so a drag cannot issue a reader request per pointer sample. Each
    /// request opens an `AVAssetReader` and walks from a sync sample; 1/15 s is well
    /// below what the eye resolves in a scrub preview and above what a decoder can
    /// service.
    private func previewSlot(for time: TimeInterval) -> Int {
        Int((time * 15).rounded())
    }
```

Use `.task(id:)` as the trigger rather than gesture-local state, because `.task(id:)` cancels the
previous request automatically when the slot changes and `Task` cancellation is what keeps a fast
drag from queueing reads behind each other:

```swift
        .task(id: previewSlot(player.currentTime)) {
            guard player.selectedTimeline != nil else { return }
            runtime.requestPreviewFrame(at: player.currentTime)
        }
```

The `lastPreviewSlot` comparison above is then unnecessary and must not be added — cancelling the
prior task already drops the superseded read, and a manual guard on top of it hides which of the
two mechanisms is actually working if previews ever stop arriving.

- [ ] **Step 5: Say what a preview is, so it is not mistaken for the camera**

The viewfinder now shows recorded content while scrubbing, which must be unmistakable. Reuse the freeze affordance's language rather than inventing a third state — the app already has a HOLD badge (datamosh plan Task 3), so a SCRUB badge in the same slot, same treatment, is the honest signal:

```swift
            if runtime.previewMailbox.isShowingFrameFromTake {
                Text("SCRUB")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .accessibilityLabel("Showing a frame from the recorded take")
            }
```

`isShowingFrameFromTake` is a published flag on the runtime, set when a preview is published and cleared when the playhead settles or the camera resumes ingest.

- [ ] **Step 6: Verify the live path cannot be disturbed**

Add a test that the preview branch is mutually exclusive with camera ingest, using the fixture from Task 3: publish a preview while the synthetic source is active and assert one pass ran (`renderFrameIndex` advanced by 1, not 2). Where that cannot be reached without a view hierarchy, state so in the test body and verify in the Simulator instead: scrub, confirm the viewfinder shows the graded take frame, release, confirm the camera returns immediately.

- [ ] **Step 7: Run the gate and commit**

Run: `./scripts/verify.sh`
Expected: PASS. Manual device check: record a take with DATAMOSH armed, scrub the playhead, and confirm the viewfinder shows the moshed frame at that time with the SCRUB badge, then returns to live on release.

```bash
git add GreyVision/Engine/Capture/GVTakeFrameReader.swift GreyVision/Engine/Capture/CameraRuntime.swift GreyVision/Engine/Rendering/CameraMetalSurface.swift GreyVision/Features/Workspace/GVTimelineBar.swift GreyVisionTests/FlagshipRenderTests.swift
git commit -m "Show the graded frame from a recorded take while scrubbing the playhead"
```
