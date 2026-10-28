@testable import GreyVision
import Metal
import QuartzCore
import XCTest

/// The render stack as a data structure.
///
/// `CameraEffectStackParameters` shipped with ordered, individually identified
/// slots and no way to address one. Every read and write went through the
/// effect-keyed subscript, which resolves to the first slot carrying that
/// effect — so `duplicate` produced a second node that could never hold
/// different settings from the first, and reordering had no caller at all.
///
/// These cover the slot-addressed path the parameter deck now edits through.
final class CameraEffectStackTests: XCTestCase {
    func testDuplicatedSlotsTuneIndependently() throws {
        var stack = CameraEffectStackParameters()
        stack.reset(.datamosh)
        let original = try XCTUnwrap(stack.firstSlotID(for: .datamosh))
        let copy = try XCTUnwrap(stack.duplicate(original))
        XCTAssertNotEqual(original, copy)

        var edited = try XCTUnwrap(stack[slot: copy])
        edited.primary = 0.11
        stack[slot: copy] = edited

        XCTAssertEqual(stack[slot: copy]?.primary, 0.11)
        XCTAssertEqual(
            stack[slot: original]?.primary,
            WorkspaceAdjustableEffect.datamosh.defaultCameraParameters.primary,
            "editing a duplicate must not write through to the original"
        )
        XCTAssertEqual(stack.orderedSlots.count, 2)
    }

    /// The effect-keyed subscript is still the API almost everything uses, and
    /// it has to keep meaning "the first slot for this effect" — otherwise the
    /// renderer and the presets would start disagreeing about which node they
    /// are describing.
    func testEffectSubscriptStillResolvesToTheFirstSlot() throws {
        var stack = CameraEffectStackParameters()
        stack.reset(.trails)
        let original = try XCTUnwrap(stack.firstSlotID(for: .trails))
        let copy = try XCTUnwrap(stack.duplicate(original))

        var edited = try XCTUnwrap(stack[slot: copy])
        edited.primary = 0.93
        stack[slot: copy] = edited

        XCTAssertEqual(stack[.trails].primary, stack[slot: original]?.primary)
        XCTAssertNotEqual(stack[.trails].primary, 0.93)
    }

    func testRenderPositionFollowsOrder() {
        var stack = CameraEffectStackParameters()
        stack.reset(.pixelate)
        stack.reset(.grain)
        let slots = stack.orderedSlots
        XCTAssertEqual(slots.count, 2)
        XCTAssertEqual(stack.renderPosition(of: slots[0].id), 1)
        XCTAssertEqual(stack.renderPosition(of: slots[1].id), 2)

        stack.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(stack.renderPosition(of: slots[0].id), 2, "moving a slot must change where it renders")
        XCTAssertEqual(stack.renderPosition(of: slots[1].id), 1)
    }

    /// Reset keeps the slot powered as it was. Resetting a live node back to
    /// defaults and having it silently switch off would read as a crash of the
    /// effect rather than as a parameter change.
    func testResettingASlotPreservesItsPowerState() throws {
        var stack = CameraEffectStackParameters()
        stack.reset(.echo)
        let slot = try XCTUnwrap(stack.firstSlotID(for: .echo))
        var parameters = try XCTUnwrap(stack[slot: slot])
        parameters.primary = 0.02
        parameters.isEnabled = false
        stack[slot: slot] = parameters

        stack.reset(slot: slot)
        XCTAssertEqual(stack[slot: slot]?.primary, WorkspaceAdjustableEffect.echo.defaultCameraParameters.primary)
        XCTAssertEqual(stack[slot: slot]?.isEnabled, false)
    }

    func testRemovingASlotLeavesTheOthers() throws {
        var stack = CameraEffectStackParameters()
        stack.reset(.vhs)
        stack.reset(.grain)
        let first = try XCTUnwrap(stack.firstSlotID(for: .vhs))
        stack.remove(first)

        XCTAssertNil(stack.firstSlotID(for: .vhs))
        XCTAssertNotNil(stack.firstSlotID(for: .grain))
        XCTAssertNil(stack[slot: first])
    }

    /// The scopes are not in the AUDIO family but read the same FFT. If they
    /// do not arm the analyser they draw a flat line and read as broken.
    func testSpectrumScopesArmTheAnalyser() {
        for effect in [WorkspaceAdjustableEffect.spectrumBars, .radialSpectrum, .lissajous] {
            XCTAssertTrue(effect.requiresAudioAnalysis, effect.label)
        }
        // The frame scopes measure the image, not the signal, and must not
        // switch the microphone on to do it.
        for effect in [WorkspaceAdjustableEffect.vectorscope, .waveformMonitor, .rgbParade] {
            XCTAssertFalse(effect.requiresAudioAnalysis, effect.label)
        }
    }

    /// The recorder's `outputURL` is the only handle its caller has on the movie it
    /// just wrote, and it has to still be there while the stop is in flight — the
    /// coordinator reads it from the finish callback. A URL for a movie the recorder
    /// then deletes goes with it, so nothing downstream is handed a dead path.
    func testRecorderNamesItsFileThroughTheStop() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable in this test environment.")
        }
        let recorder = GVVideoRecorder()
        XCTAssertNil(recorder.outputURL, "an idle recorder must not advertise a file")
        guard recorder.start(
            device: device,
            width: 128,
            height: 128,
            framesPerSecond: 30,
            codec: .h264
        ) else {
            throw XCTSkip("H.264 writer is unavailable on this destination.")
        }
        let written = try XCTUnwrap(recorder.outputURL, "a live writer must name its file")

        var urlDuringStop: URL?
        var stateDuringStop: GVRecordingState?
        // Nothing was appended, so this take is discarded when the writer closes.
        let saved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            recorder.finish { finished in
                continuation.resume(returning: finished)
            }
            urlDuringStop = recorder.outputURL
            stateDuringStop = recorder.stateMailbox.latest
        }

        XCTAssertEqual(stateDuringStop, .finishing, "the read above has to land inside the stop")
        XCTAssertEqual(urlDuringStop, written, "the URL must outlive the stop, not precede it")
        XCTAssertFalse(saved, "a take with no frames never reached Photos")
        XCTAssertNil(recorder.outputURL, "a discarded movie must not stay addressable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: written.path))
    }

    /// The camera path reaches the runtime through the recording mailbox, which
    /// already outlives the renderer that finishes the take. The handler stays
    /// installed for the life of the runtime — clearing it after one report left
    /// every later take unnoted — and reports are deduplicated by movie URL, so a
    /// repeated report cannot make the timeline note the same take twice.
    func testRecordingMailboxReportsASavedTakeOnce() {
        let mailbox = CameraRecordingMailbox()
        let seen = GVSavedTakeCollector()
        mailbox.setTakeSavedHandler { seen.append($0) }
        let url = URL(fileURLWithPath: "/private/tmp/greyvision-camera-take.mov")

        mailbox.reportTakeSaved(url)
        XCTAssertEqual(seen.urls, [url], "the runtime has to hear about the take it just saved")

        mailbox.reportTakeSaved(url)
        XCTAssertEqual(seen.urls, [url], "one take is one report")
    }

    // MARK: - A refused codec round trip is visible

    /// A codec Slot the budget refused still renders — it shows the frame whole.
    /// That is indistinguishable in the picture from an effect that stopped
    /// working, so the count of live round trips is part of the contract instead.
    func testRenderStatsExposeLiveCodecSlotCount() {
        var stats = CameraRenderStats.idle
        XCTAssertEqual(stats.codecSlots, 0)
        XCTAssertEqual(stats.codecSlotsRequested, 0)
        stats.codecSlotsRequested = 2
        stats.codecSlots = 2
        XCTAssertEqual(stats.codecSlots, 2)
    }

    /// The reading the operator needs is the shortfall. One live trip is a
    /// healthy stack of one and a starved stack of two, and the strip can only
    /// tell those apart if the stats carry how many were asked for.
    func testRenderStatsDistinguishAFundedSlotFromARefusedOne() {
        var stats = CameraRenderStats.idle
        stats.codecSlotsRequested = 1
        stats.codecSlots = 1
        XCTAssertFalse(stats.hasRefusedCodecSlot, "a stack that got everything it asked for is quiet")
        stats.codecSlotsRequested = 2
        XCTAssertTrue(stats.hasRefusedCodecSlot, "the same one trip is a refusal at two Slots")
    }

    private func makePreviewBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, 128, 128, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil, &buffer
        ) == kCVReturnSuccess, let buffer else {
            throw XCTSkip("could not allocate a test pixel buffer")
        }
        return buffer
    }
}

/// A `Sendable` sink for the URLs a mailbox reports, so a test can count firings
/// without capturing mutable state in a `@Sendable` closure.
private final class GVSavedTakeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []

    var urls: [URL] { lock.withLock { stored } }

    func append(_ url: URL) {
        lock.withLock { stored.append(url) }
    }
}
