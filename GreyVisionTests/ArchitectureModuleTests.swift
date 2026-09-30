@testable import GreyVision
import XCTest

@MainActor
final class ArchitectureModuleTests: XCTestCase {
    func testCaptureSourceTransitionStopsBeforeStartingDepth() async {
        let events = EventLog()
        let camera = CameraAdapterFake(events: events)
        let depth = DepthAdapterFake(events: events)
        let objects = ObjectAdapterFake(events: events)
        let transition = CaptureSourceTransition(camera: camera, depth: depth, objects: objects)

        transition.activateDepth(effect: .pointCloud, fallback: .standard)
        await waitUntil { transition.state.runtimeStatus == .running }

        XCTAssertEqual(events.values, ["objects.stop", "camera.stop", "depth.start.POINT CLOUD"])
        XCTAssertEqual(transition.state.mode, .lidar)
        XCTAssertEqual(transition.state.runtimeStatus, .running)
    }

    func testCaptureSourceTransitionRollsBackToCamera() async {
        let events = EventLog()
        let camera = CameraAdapterFake(events: events)
        let depth = DepthAdapterFake(events: events, starts: false)
        let objects = ObjectAdapterFake(events: events)
        let transition = CaptureSourceTransition(camera: camera, depth: depth, objects: objects)

        transition.activateDepth(effect: .fog, fallback: .standard)
        await waitUntil { transition.state.runtimeStatus == .running }

        XCTAssertEqual(
            events.values,
            ["objects.stop", "camera.stop", "depth.start.DEPTH FOG", "camera.start"]
        )
        XCTAssertEqual(transition.state.mode, .camera)
        XCTAssertEqual(transition.state.runtimeStatus, .running)
    }

    func testEffectEditingSessionOwnsExclusiveAndAddSelection() throws {
        let editor = EffectEditingSession()

        XCTAssertTrue(editor.select(.vhs))
        XCTAssertEqual(editor.activeEffects, [.vhs])
        XCTAssertNotNil(editor.focusedSlot)

        XCTAssertTrue(editor.select(.grain))
        XCTAssertEqual(editor.activeEffects, [.grain])

        editor.setStackArmed(true)
        XCTAssertTrue(editor.select(.echo))
        XCTAssertEqual(Set(editor.activeEffects), Set([.grain, .echo]))

        let focused = try XCTUnwrap(editor.focusedSlot)
        XCTAssertEqual(editor.effectStack.slot(focused)?.effect, .echo)
        XCTAssertEqual(editor.soloFocused(), .echo)
        XCTAssertEqual(editor.activeEffects, [.echo])
    }

    func testExplicitExclusiveSelectionReplacesAnArmedStackAtCommitTime() {
        let editor = EffectEditingSession()
        XCTAssertTrue(editor.select(.vhs))
        editor.setStackArmed(true)
        XCTAssertTrue(editor.select(.grain))
        XCTAssertEqual(Set(editor.activeEffects), Set([.vhs, .grain]))

        XCTAssertTrue(editor.selectExclusively(.echo))

        XCTAssertFalse(editor.isStackArmed)
        XCTAssertEqual(editor.activeEffects, [.echo])
        XCTAssertEqual(editor.selectedEffect, .echo)
    }

    func testEffectEditingHistoryRestoresCommittedComposition() {
        let editor = EffectEditingSession()
        editor.select(.vhs)
        editor.recordHistory()
        editor.select(.grain)
        editor.recordHistory()

        XCTAssertEqual(editor.activeEffects, [.grain])
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.activeEffects, [.vhs])
        XCTAssertTrue(editor.redo())
        XCTAssertEqual(editor.activeEffects, [.grain])
    }

    func testRecordingTransactionRoutesTheSingleRecordIntentBySource() async {
        let transaction = GVRecordingTransaction()
        let camera = CameraRuntime()
        let objects = ARObjectRuntime()

        // start() prepares on a Task: the mailbox latch lands a hop later.
        transaction.start(cameraRuntime: camera, objectsRuntime: objects, sourceMode: .camera)
        await waitUntil { camera.recordingMailbox.isStartPending }

        // A source change cannot redirect the stop intent to the wrong writer.
        transaction.stop(cameraRuntime: camera, objectsRuntime: objects, sourceMode: .objects)
        XCTAssertFalse(camera.recordingMailbox.isStartPending)

        // The objects path is adapter-owned (the surface vends the size), so
        // the transaction's own path — not the runtime's dock-driven request
        // flag — is what proves the intent landed on the right writer.
        transaction.start(cameraRuntime: camera, objectsRuntime: objects, sourceMode: .objects)
        await waitUntil {
            if case let .recording(path, _) = transaction.state { return path == .objects }
            return false
        }
    }

    private func waitUntil(
        timeoutIterations: Int = 100,
        condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0 ..< timeoutIterations {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for transition")
    }
}

@MainActor
private final class EventLog {
    private(set) var values: [String] = []
    func append(_ value: String) {
        values.append(value)
    }
}

@MainActor
private final class CameraAdapterFake: CameraSourceAdapter {
    let events: EventLog
    var starts = true

    init(events: EventLog) {
        self.events = events
    }

    func start(configuration _: CaptureConfiguration) async -> Bool {
        events.append("camera.start")
        return starts
    }

    func stop() async {
        events.append("camera.stop")
    }

    func stopSoon() {
        events.append("camera.stopSoon")
    }
}

@MainActor
private final class DepthAdapterFake: DepthSourceAdapter {
    let events: EventLog
    let starts: Bool
    var isSupported = true
    var selectedEffect = DepthEffectMode.pointCloud

    init(events: EventLog, starts: Bool = true) {
        self.events = events
        self.starts = starts
    }

    func select(_ effect: DepthEffectMode) {
        selectedEffect = effect
    }

    func start(effect: DepthEffectMode) async -> Bool {
        events.append("depth.start.\(effect.label)")
        return starts
    }

    func stop() async {
        events.append("depth.stop")
    }

    func stopSoon() {
        events.append("depth.stopSoon")
    }
}

@MainActor
private final class ObjectAdapterFake: ObjectSourceAdapter {
    let events: EventLog
    var isSupported = true
    var starts = true

    init(events: EventLog) {
        self.events = events
    }

    func start() async -> Bool {
        events.append("objects.start")
        return starts
    }

    func stop() async {
        events.append("objects.stop")
    }

    func stopSoon() {
        events.append("objects.stopSoon")
    }
}
