import XCTest

/// The workflow bundle: the recipe collection and the shutter self-timer.
///
/// These are driven as an operator drives them — from the dock rail — because
/// every one of them was reachable in code and unreachable on screen before
/// this pass.
@MainActor
final class CreativeWorkflowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchWorkspace() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-workspace"]
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.screen"].waitForExistence(timeout: 5),
            "Workspace must come up under the test launch arguments"
        )
        return app
    }

    func testRecipesOpenFromTheRailAndAStarSurvivesRelaunch() {
        let app = launchWorkspace()

        app.buttons["workspace.recipes"].tap()
        let close = app.buttons["workspace.chip.preset.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 3), "The recipes drawer must open from the rail")

        let stars = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "preset.star.")
        )
        XCTAssertTrue(stars.count > 1, "The seeded collection needs at least two rows to filter")

        // Star the first recipe and leave the second one out, whatever the
        // container happened to hold from an earlier run.
        let starred = stars.element(boundBy: 0)
        let starredName = name(of: starred)
        setStarred(true, on: starred, name: starredName)
        let unstarred = stars.element(boundBy: 1)
        let unstarredName = name(of: unstarred)
        setStarred(false, on: unstarred, name: unstarredName)

        close.tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["workspace.recipes"].waitForExistence(timeout: 5))
        app.buttons["workspace.recipes"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 3))

        XCTAssertTrue(
            starButton("Unstar", starredName).waitForExistence(timeout: 3),
            "A starred recipe has to still be starred after relaunch"
        )

        // The filter keeps the collection and drops what was not chosen.
        app.buttons["workspace.chip.preset.filter.starred"].tap()
        XCTAssertTrue(
            app.buttons["workspace.chip.preset.close"].exists,
            "Filtering is a control inside the plate, not a tap away from it: the drawer has to stay open"
        )
        XCTAssertTrue(starButton("Unstar", starredName).exists)
        XCTAssertFalse(
            starButton("Star", unstarredName).exists,
            "The starred filter must hide recipes that were not starred"
        )
    }

    /// Rows are addressed by name because the drawer's rows are identified by
    /// recipe UUID, which a UI test cannot know in advance.
    private func name(of star: XCUIElement) -> String {
        star.label
            .replacingOccurrences(of: "Star ", with: "")
            .replacingOccurrences(of: "Unstar ", with: "")
    }

    private func starButton(_ verb: String, _ name: String) -> XCUIElement {
        XCUIApplication().buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                "preset.star.",
                "\(verb) \(name)"
            )
        ).element
    }

    /// Always moves the control at least once. A container left over from an
    /// earlier run can already hold the wanted state, and a test that then
    /// taps nothing proves nothing.
    private func setStarred(_ target: Bool, on star: XCUIElement, name: String) {
        let wanted = target ? "Unstar \(name)" : "Star \(name)"
        let other = target ? "Star \(name)" : "Unstar \(name)"
        if star.label == wanted {
            star.tap()
            XCTAssertEqual(star.label, other, "Tapping a starred recipe has to clear the mark")
        }
        star.tap()
        XCTAssertEqual(star.label, wanted, "Tapping the mark has to set it")
    }

    func testSelfTimerDelaysTheShutterAndCanBeCancelled() {
        let app = launchWorkspace()

        app.buttons["workspace.settings"].tap()
        let timer = app.buttons["workspace.countdown"]
        XCTAssertTrue(timer.waitForExistence(timeout: 3))
        // The delay is a preference, so it may still be on a 10 or 30 second
        // stop from an earlier run. Walk the cycle to the three second one.
        for _ in 0 ..< 4 where !timer.label.contains("3s") {
            timer.tap()
        }
        XCTAssertTrue(timer.label.contains("3s"), "The self-timer has to offer a three second stop")

        app.buttons["workspace.settings"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.settings.deck"].waitForNonExistence(timeout: 3)
        )

        app.buttons["workspace.capture.photo"].tap()
        let cancel = app.buttons["workspace.countdown.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 2), "The shutter must count down before it fires")
        cancel.tap()
        XCTAssertTrue(
            cancel.waitForNonExistence(timeout: 2),
            "Cancelling the countdown has to take the shutter away"
        )
    }
}
