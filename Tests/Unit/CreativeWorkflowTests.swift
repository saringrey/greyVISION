@testable import GreyVision
import XCTest

@MainActor
final class CreativeWorkflowTests: XCTestCase {
    func testCountdownFiresOnceAtDeadline() {
        let countdown = GVCaptureCountdown()
        let start = ContinuousClock.now
        countdown.start(.photo, delay: .three, now: start)
        XCTAssertEqual(countdown.remaining, 3)
        XCTAssertNil(countdown.advance(at: start.advanced(by: .milliseconds(1200))))
        XCTAssertEqual(countdown.remaining, 2)

        XCTAssertEqual(countdown.advance(at: start.advanced(by: .seconds(3))), .photo)
        XCTAssertNil(countdown.advance(at: start.advanced(by: .seconds(4))))
        XCTAssertNil(countdown.deadline)
    }

    func testCancellingOrReplacingCountdownCannotFireAnOldIntent() {
        let countdown = GVCaptureCountdown()
        let start = ContinuousClock.now
        countdown.start(.photo, delay: .three, now: start)
        countdown.cancel()
        XCTAssertNil(countdown.advance(at: start.advanced(by: .seconds(4))))

        countdown.start(.photo, delay: .three, now: start)
        countdown.start(.video, delay: .ten, now: start)
        XCTAssertNil(countdown.advance(at: start.advanced(by: .seconds(3))))
        XCTAssertEqual(countdown.advance(at: start.advanced(by: .seconds(10))), .video)
    }

    func testTimerOffFiresImmediately() {
        let countdown = GVCaptureCountdown()
        let start = ContinuousClock.now
        countdown.start(.photo, delay: .off, now: start)
        XCTAssertEqual(countdown.advance(at: start), .photo)
        XCTAssertNil(countdown.advance(at: start))
    }

    func testStarredRecipeSurvivesRenameAndRelaunch() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GVPresetStore(directory: directory)
        let recipe = try XCTUnwrap(store.presets.first)
        let originalStack = recipe.stack

        store.toggleStar(recipe.id)
        store.rename(recipe.id, to: "My look")

        let reloaded = GVPresetStore(directory: directory)
        XCTAssertTrue(reloaded.starredIDs.contains(recipe.id))
        XCTAssertEqual(reloaded.presets.first { $0.id == recipe.id }?.name, "MY LOOK")
        XCTAssertEqual(reloaded.presets.first { $0.id == recipe.id }?.stack, originalStack)
        reloaded.delete(recipe.id)
        XCTAssertFalse(GVPresetStore(directory: directory).starredIDs.contains(recipe.id))
    }

    func testCatalogUpgradePreservesLegacyCompositionAndRespectsDeletions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var stack = CameraEffectStackParameters()
        stack.setEnabled(true, for: .vhs)
        stack[.vhs].primary = 0.73
        let legacy = GVPreset(
            name: "MY ORIGINAL",
            codecRaw: CaptureSetupDraft.VideoCodec.h264.rawValue,
            frameRate: 30,
            resolutionRaw: CaptureSetupDraft.Resolution.fullHD.rawValue,
            rgbSplit: .init(),
            stack: stack
        )
        try JSONEncoder().encode([legacy]).write(to: directory.appendingPathComponent("recipes.json"))

        let store = GVPresetStore(directory: directory)
        XCTAssertEqual(store.presets.first { $0.id == legacy.id }, legacy)
        XCTAssertGreaterThan(store.presets.count, 1)
        for recipe in store.presets { store.delete(recipe.id) }

        XCTAssertTrue(GVPresetStore(directory: directory).presets.isEmpty)
    }

    func testUnreadableRecipeLibraryIsNotOverwrittenWithFactoryContent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recipes.json")
        let original = Data("incomplete library".utf8)
        try original.write(to: url)

        let store = GVPresetStore(directory: directory)

        XCTAssertNotNil(store.storageError)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
