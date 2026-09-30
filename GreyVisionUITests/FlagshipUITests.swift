import XCTest

@MainActor
final class FlagshipUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFlagshipSearchControlsAndFamilyVariant() {
        let app = launchWorkspace()
        search("CMYK", in: app)
        let press = app.buttons["workspace.action.cmyk-press"]
        XCTAssertTrue(press.waitForExistence(timeout: 5))
        press.tap()
        let deck = app.descendants(matching: .any)["workspace.parameters.cmykPress"]
        XCTAssertTrue(deck.waitForExistence(timeout: 5))
        let screen = app.descendants(matching: .any)["workspace.param.screen"].firstMatch
        XCTAssertTrue(screen.exists)
        XCTAssertTrue(screen.isHittable)
        capture("CMYK controls")
        search("KALEIDO6", in: app)
        let kaleido = app.buttons["workspace.action.kaleido6"]
        XCTAssertTrue(kaleido.waitForExistence(timeout: 5))
        kaleido.tap()
        let variant = app.buttons["workspace.effect.variant"]
        XCTAssertTrue(variant.waitForExistence(timeout: 5))
        variant.tap()
        let option = app.buttons["KALEIDOSCOPE"]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        XCTAssertTrue(app.descendants(matching: .any)["workspace.parameters.kaleidoscope"].waitForExistence(timeout: 5))
        capture("Family variant")
    }

    func testCaptureChromeSurvivesBothLandscapeOrientations() {
        let app = launchWorkspace()
        defer { XCUIDevice.shared.orientation = .portrait }
        for (orientation, name) in [(UIDeviceOrientation.portrait, "Portrait"), (.landscapeLeft, "Landscape left"), (.landscapeRight, "Landscape right")] {
            XCUIDevice.shared.orientation = orientation
            let record = app.buttons["workspace.record.toggle"]
            XCTAssertTrue(record.waitForExistence(timeout: 5))
            XCTAssertTrue(record.isHittable)
            XCTAssertTrue(app.buttons["workspace.camera"].isHittable)
            capture(name)
        }
        let chrome = app.buttons["workspace.chrome.toggle"]
        chrome.tap()
        XCTAssertEqual(chrome.label, "Show effects")
        capture("Effects collapsed")
        chrome.tap()
        XCTAssertEqual(chrome.label, "Hide effects")
    }

    func testDatamoshControlsAndOpaqueFormatMenus() {
        let app = launchWorkspace()
        for field in ["frameRate", "codec"] {
            let reading = app.descendants(matching: .any)["workspace.status.\(field)"]
            XCTAssertTrue(reading.exists)
            reading.tap()
            XCTAssertTrue(app.descendants(matching: .any)["workspace.field.\(field)"].waitForExistence(timeout: 5))
            capture("Opaque \(field) menu")
            reading.tap()
        }
        search("DATAMOSH", in: app)
        let mosh = app.buttons["workspace.action.datamosh"]
        XCTAssertTrue(mosh.waitForExistence(timeout: 5))
        capture("Datamosh effect button")
        mosh.tap()
        XCTAssertTrue(app.descendants(matching: .any)["workspace.parameters.datamosh"].waitForExistence(timeout: 5))
        let flow = app.descendants(matching: .any)["workspace.param.flow"].firstMatch
        XCTAssertTrue(flow.waitForExistence(timeout: 5))
        let before = flow.value as? String
        let start = flow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -45, dy: 0)))
        XCTAssertNotEqual(flow.value as? String, before)
        capture("Datamosh live controls")
    }

    func testRadialHoldCancelsOrCommitsOnRelease() {
        let app = launchWorkspace()
        let category = app.buttons["workspace.category.color"]
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        category.press(forDuration: 1)
        XCTAssertFalse(app.descendants(matching: .any)["radial.menu.effects"].exists)
        XCTAssertTrue(app.scrollViews["workspace.effects.color"].waitForExistence(timeout: 5))
        capture("Category chips browse without a radial hold")
    }

    func testPreviewHoldCancelsOrCommitsOnRelease() {
        let app = launchWorkspace()
        // Exercise the camera itself, with no category selected first.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.45))
        let deck = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "workspace.parameters.")
        ).firstMatch
        start.press(forDuration: 3)
        XCTAssertFalse(deck.exists, "Releasing at the invocation point must cancel")
        start.press(forDuration: 0.7,
                    thenDragTo: start.withOffset(CGVector(dx: -112, dy: -40)),
                    withVelocity: .slow, thenHoldForDuration: 3)
        XCTAssertTrue(deck.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["radial.menu.effects"].waitForNonExistence(timeout: 3))
        let selected = deck.identifier
        start.press(forDuration: 1)
        XCTAssertTrue(deck.exists, "Cancelling must preserve the selected effect")
        XCTAssertEqual(deck.identifier, selected)
        capture("Preview category then effect selection")
    }

    func testEveryCategoryIsReachableIncludingLiDAR() {
        let app = launchWorkspace()
        let picker = app.buttons["workspace.categories.all"]
        for category in ["all", "color", "time", "motion", "decay", "signal", "optics", "form", "shaders", "audio", "scope", "objects", "blobs", "lidar"] {
            picker.tap()
            let option = app.buttons["workspace.categoryPicker.\(category)"]
            let grid = app.scrollViews["workspace.categoryPicker.scroll"]
            XCTAssertTrue(grid.waitForExistence(timeout: 5))
            for _ in 0 ..< 5 where !option.exists || !option.isHittable {
                let start = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                start.press(forDuration: 0.05, thenDragTo: grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
            }
            XCTAssertTrue(option.isHittable, category)
            option.tap()
            if category == "shaders" {
                let shader = app.buttons["workspace.action.cyber-grid"]
                XCTAssertTrue(shader.waitForExistence(timeout: 5))
                shader.tap()
                XCTAssertTrue(app.descendants(matching: .any)["workspace.parameters.cyberGrid"].waitForExistence(timeout: 5))
            }
            capture("Category \(category)")
        }
        let rail = app.scrollViews["workspace.categories"]
        let lidar = app.buttons["workspace.category.lidar"]
        for _ in 0 ..< 15 where !lidar.isHittable {
            rail.swipeLeft()
        }
        XCTAssertTrue(lidar.isHittable)
        XCTAssertGreaterThan(lidar.frame.minX, app.buttons["workspace.category.recents"].frame.minX)
        capture("LiDAR last in category row")
    }

    func testCategoryRailScrollsFromAChipWithoutOpeningRadial() {
        let app = launchWorkspace()
        let category = app.buttons["workspace.category.color"]
        let originalX = category.frame.midX
        let start = category.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -150, dy: 0)))
        XCTAssertLessThan(category.frame.midX, originalX - 50)
        XCTAssertFalse(app.descendants(matching: .any)["radial.menu.effects"].exists)
        let rail = app.scrollViews["workspace.categories"]
        let lidar = app.buttons["workspace.category.lidar"]
        for _ in 0 ..< 15 where !lidar.isHittable {
            rail.swipeLeft()
        }
        XCTAssertTrue(lidar.isHittable)
        capture("Scrolled to LiDAR")
        for _ in 0 ..< 15 where !category.isHittable {
            rail.swipeRight()
        }
        XCTAssertTrue(category.isHittable)
    }

    func testGIFSplashReachesFormatSetupAndWorkspace() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        let enter = app.buttons["access.enter"]
        XCTAssertTrue(enter.waitForExistence(timeout: 10))
        capture("GIF entry on white")
        enter.tap()
        XCTAssertTrue(app.descendants(matching: .any)["boot.screen"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["boot.telemetry"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["boot.capabilities"].exists)
        capture("Restored greyvector format setup")
        app.buttons["boot.codec"].tap()
        XCTAssertTrue(app.scrollViews["boot.choices.codec"].waitForExistence(timeout: 5))
        capture("Black codec options")
        app.buttons["boot.codec"].tap()
        let launch = app.buttons["boot.launch"]
        let ready = expectation(for: NSPredicate(format: "enabled == true AND hittable == true"), evaluatedWith: launch)
        wait(for: [ready], timeout: 25)
        launch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["workspace.screen"].waitForExistence(timeout: 10))
    }

    func testThinFormatSelectionsAndCameraTools() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        let launch = app.buttons["boot.launch"]
        XCTAssertTrue(launch.waitForExistence(timeout: 15))
        capture("Thin monochrome format setup")
        app.buttons["boot.fps"].tap()
        let fps30 = app.buttons["boot.fps.30-fps"]
        XCTAssertTrue(fps30.waitForExistence(timeout: 5))
        capture("Thin FPS choices")
        fps30.tap()
        XCTAssertTrue(app.scrollViews["boot.choices.fps"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["boot.fps"].label.contains("30"))
        app.buttons["boot.fps"].tap()
        let fps60 = app.buttons["boot.fps.60-fps"]
        XCTAssertTrue(fps60.waitForExistence(timeout: 5))
        fps60.tap()
        XCTAssertTrue(app.scrollViews["boot.choices.fps"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["boot.fps"].label.contains("60"))
        launch.tap()
        XCTAssertTrue(app.buttons["workspace.camera"].waitForExistence(timeout: 10))
        let coach = app.buttons["workspace.chip.coach.close"]
        if coach.exists { coach.tap() }
        capture("Default center reticle")
        app.buttons["workspace.camera"].tap()
        let reticle = app.buttons["workspace.tool.reticle"]
        XCTAssertTrue(reticle.waitForExistence(timeout: 5))
        XCTAssertEqual(reticle.value as? String, "active")
        for removed in ["level", "hold", "anamorphic"] {
            XCTAssertFalse(app.buttons["workspace.tool.\(removed)"].exists)
        }
        capture("Simplified camera tools")
        reticle.tap()
        XCTAssertEqual(reticle.value as? String, "inactive")
        reticle.tap()
        XCTAssertEqual(reticle.value as? String, "active")
    }

    func testCreatorSplashAndOpenGateLaunch() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        let launch = app.buttons["boot.launch"]
        XCTAssertTrue(launch.waitForExistence(timeout: 15))
        let attribution = app.staticTexts["boot.attribution"]
        XCTAssertTrue(attribution.exists)
        XCTAssertGreaterThan(attribution.frame.minY, launch.frame.maxY)
        XCTAssertLessThan(attribution.frame.maxY, app.frame.maxY)
        XCTAssertEqual(app.buttons["boot.social"].label, "Grey creator artwork")
        XCTAssertFalse(app.staticTexts["GV.CORE // CLEAN ROOM"].exists)
        XCTAssertFalse(app.staticTexts["VERSION 3.3"].exists)
        capture("Creator splash and bottom attribution")
        app.buttons["boot.res"].tap()
        let openGate = app.buttons["boot.res.open-gate"]
        let rail = app.scrollViews["boot.choices.res"]
        for _ in 0 ..< 4 where !openGate.isHittable {
            rail.swipeLeft()
        }
        XCTAssertTrue(openGate.isHittable)
        openGate.tap()
        launch.tap()
        XCTAssertTrue(app.buttons["workspace.camera"].waitForExistence(timeout: 15))
        // Workspace navigation alone is not evidence that capture started.
        let resolution = app.descendants(matching: .any)["workspace.status.resolution"]
        let running = NSPredicate(format: "value CONTAINS '4032' OR value CONTAINS '3024'")
        expectation(for: running, evaluatedWith: resolution)
        waitForExpectations(timeout: 20)
        XCTAssertEqual(app.state, .runningForeground)
        capture("Open Gate active sensor")
    }

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

    private func search(_ term: String, in app: XCUIApplication) {
        let toggle = app.buttons["workspace.search.toggle"]
        XCTAssertTrue(toggle.exists)
        let field = app.textFields["workspace.search.field"]
        if !field.exists { toggle.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        if let previous = field.value as? String, previous != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        }
        field.typeText(term)
    }

    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
