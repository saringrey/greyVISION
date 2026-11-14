import XCTest

/// Walks the effect browser through its states and captures each one.
///
/// The browser is the surface a creator spends its time in, and none of its
/// states can be checked by reading the code: the preview grid's layout, the
/// pinned shelf of categories, the empty states and the search results all
/// depend on how the live catalog resolves at runtime. This walks them in a
/// single session and leaves the screenshots in the result bundle.
@MainActor
final class EffectBrowserUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEffectBrowserWalksItsStates() {
        let app = launchWorkspace()
        app.buttons["workspace.categories.all"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["workspace.browser"].waitForExistence(timeout: 10))
        settle(2.5)
        capture("01 Browser, all effects")

        // A family opens as a shelf of pictures.
        let glitch = app.buttons["workspace.browser.category.glitch"]
        XCTAssertTrue(glitch.waitForExistence(timeout: 5))
        glitch.tap()
        XCTAssertTrue(app.scrollViews["workspace.effects.glitch"].waitForExistence(timeout: 5))
        settle(2.5)
        capture("02 A single family")

        // Search spans every shelf.
        let search = app.textFields["workspace.search.field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("mosh")
        settle(2.0)
        capture("03 Search across every shelf")

        // Changing the shelf clears the search and lands on a saved list,
        // which is allowed to be empty.
        let favorites = app.buttons["workspace.browser.category.favorites"]
        XCTAssertTrue(favorites.waitForExistence(timeout: 5))
        favorites.tap()
        settle(1.0)
        capture("04 A saved list")

        // And it holds up sideways.
        XCUIDevice.shared.orientation = .landscapeLeft
        settle(2.5)
        capture("05 Sideways")
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - Helpers

    private func launchWorkspace() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-workspace"]
        app.launch()
        XCTAssertTrue(app.buttons["workspace.screen"].waitForExistence(timeout: 10))
        let coach = app.buttons["workspace.chip.coach.close"]
        if coach.exists { coach.tap() }
        return app
    }

    /// Lets the preview renders land before the shutter opens.
    private func settle(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
