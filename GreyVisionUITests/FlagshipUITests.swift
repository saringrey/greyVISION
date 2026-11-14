import XCTest

@MainActor
final class FlagshipUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFlagshipSearchControlsAndFamilyVariant() {
        let app = launchWorkspace()
        search("CMYK", in: app)
        let press = app.buttons["workspace.effect.cmykPress"]
        XCTAssertTrue(press.waitForExistence(timeout: 5))
        press.tap()
        let deck = app.descendants(matching: .any)["workspace.parameters.cmykPress"]
        XCTAssertTrue(deck.waitForExistence(timeout: 5))
        let screen = app.descendants(matching: .any)["workspace.param.screen"].firstMatch
        XCTAssertTrue(screen.exists)
        XCTAssertTrue(screen.isHittable)
        capture("CMYK controls")
        search("KALEIDO6", in: app)
        let kaleido = app.buttons["workspace.effect.kaleido6"]
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
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            let controls = app.descendants(matching: .any)["workspace.capture.controls"]
            XCTAssertTrue(controls.waitForExistence(timeout: 5))
            for id in ["workspace.categories.all", "workspace.capture.photo", "workspace.record.toggle"] {
                XCTAssertTrue(app.buttons[id].isHittable, id)
            }
            XCTAssertFalse(app.descendants(matching: .any)["workspace.bottom.dock"].exists)
            XCTAssertLessThan(controls.frame.height, app.frame.height * 0.25)
            capture("Three controls \(orientation.rawValue)")
        }
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
        let mosh = app.buttons["workspace.effect.datamosh"]
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

    func testConsolidatedEffectsEntryAndCategoryRail() {
        let app = launchWorkspace()
        app.buttons["workspace.categories.all"].tap()
        let rail = app.scrollViews["workspace.browser.categories"]
        XCTAssertTrue(rail.waitForExistence(timeout: 5))
        let look = app.buttons["workspace.browser.category.look"]
        for _ in 0..<5 where !look.isHittable { rail.swipeLeft() }
        look.tap()
        XCTAssertTrue(app.scrollViews["workspace.effects.look"].waitForExistence(timeout: 5))
        capture("Image-led effect library")
    }

    func testPreviewGallerySelectionAutomaticallyShowsAdjustmentsInBothOrientations() {
        let app = launchWorkspace()
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            search("CMYK", in: app)
            let tile = app.buttons["workspace.effect.cmykPress"]
            XCTAssertTrue(tile.waitForExistence(timeout: 5))
            tile.tap()
            XCTAssertTrue(app.descendants(matching: .any)["workspace.parameters.cmykPress"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.descendants(matching: .any)["workspace.browser"].exists)
            XCTAssertTrue(app.buttons["workspace.capture.photo"].isHittable)
            XCTAssertTrue(app.buttons["workspace.record.toggle"].isHittable)
            capture("Live effect adjustments \(orientation.rawValue)")
        }
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
        let selected = deck.identifier
        start.press(forDuration: 1)
        XCTAssertTrue(deck.exists, "Cancelling must preserve the selected effect")
        XCTAssertEqual(deck.identifier, selected)
        capture("Preview category then effect selection")
    }

    func testEveryFamilyIsReachableIncludingDatamoshAndDepth() {
        let app = launchWorkspace()
        let picker = app.buttons["workspace.categories.all"]
        picker.tap()
        XCTAssertTrue(app.scrollViews["workspace.browser.categories"].waitForExistence(timeout: 5))
        // The four saved lists that sit above the shelves, the eight shelves
        // the catalogue holds, and the depth modes that close the row.
        for category in ["all", "active", "favorites", "recents",
                         "glitch", "time", "analog", "look", "lens", "warp",
                         "generative", "audio", "spatial", "blobs"] {
            let option = app.buttons["workspace.browser.category.\(category)"]
            let sidebar = app.scrollViews["workspace.browser.categories"]
            for _ in 0 ..< 10 where !option.exists || !option.isHittable { sidebar.swipeLeft() }
            XCTAssertTrue(option.waitForExistence(timeout: 5), category)
            XCTAssertTrue(option.isHittable, category)
            option.tap()
            if category == "spatial" {
                // Real depth modes, gated on hardware rather than the catalogue.
                XCTAssertTrue(app.scrollViews["workspace.depth.modes"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["workspace.depth.0"].exists)
            } else if category == "blobs" {
                // The tracking presets are their own shelf, not effects.
                XCTAssertTrue(app.scrollViews["workspace.tracking.presets"].waitForExistence(timeout: 5))
            } else {
                // A saved list can legitimately be empty on a fresh install,
                // and an empty list teaches the interface instead of listing.
                let list = app.scrollViews["workspace.effects.\(category)"]
                let empty = app.descendants(matching: .any)["workspace.effects.empty"]
                XCTAssertTrue(list.waitForExistence(timeout: 3) || empty.waitForExistence(timeout: 3), category)
            }
            capture("Family \(category)")
        }
        // The glitch shelf holds the codec effects, the sorts and the rest of
        // the picture-as-data family.
        let glitch = app.buttons["workspace.browser.category.glitch"]
        for _ in 0..<10 where !glitch.isHittable { app.scrollViews["workspace.browser.categories"].swipeRight() }
        glitch.tap()
        XCTAssertTrue(app.buttons["workspace.effect.datamosh"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["workspace.effect.sort"].exists, "Sorts live in the glitch shelf")
    }

    func testLeftSidebarResearchGroupsScrollAndReturnToAll() {
        let app = launchWorkspace()
        app.buttons["workspace.categories.all"].tap()
        let sidebar = app.scrollViews["workspace.browser.categories"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        // The shelves furthest along the row: they have to be reachable by
        // scrolling, and they have to say which one is open.
        for category in ["warp", "generative"] {
            let group = app.buttons["workspace.browser.category.\(category)"]
            for _ in 0 ..< 4 {
                if group.exists && group.isHittable { break }
                sidebar.swipeLeft()
            }
            XCTAssertTrue(group.exists, category)
            XCTAssertTrue(group.isHittable, category)
            group.tap()
            XCTAssertTrue(app.scrollViews["workspace.effects.\(category)"].waitForExistence(timeout: 5))
            XCTAssertEqual(group.value as? String, "selected")
        }
        capture("Direct left-side research groups")
        let all = app.buttons["workspace.browser.category.all"]
        for _ in 0 ..< 4 {
            if all.exists && all.isHittable { break }
            sidebar.swipeRight()
        }
        XCTAssertTrue(all.isHittable)
        all.tap()
        XCTAssertTrue(app.scrollViews["workspace.effects.all"].waitForExistence(timeout: 5))
    }

    func testQuickShelvesRemainInsideEffectsBrowser() {
        let app = launchWorkspace()
        app.buttons["workspace.categories.all"].tap()
        let rail = app.scrollViews["workspace.browser.categories"]
        for shelf in ["active", "favorites", "recents"] {
            let category = app.buttons["workspace.browser.category.\(shelf)"]
            for _ in 0..<5 where !category.isHittable { rail.swipeLeft() }
            XCTAssertTrue(category.isHittable)
            category.tap()
            XCTAssertEqual(category.value as? String, "selected")
        }
        XCTAssertTrue(app.buttons["workspace.capture.modes"].isHittable)
    }

    func testUnifiedLaunchOffersCodecBeforeEnteringCamera() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertFalse(app.buttons["access.enter"].exists)
        let codec = app.buttons["boot.codec"]
        XCTAssertTrue(codec.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["boot.launch"].isHittable)
        codec.tap()
        let h264 = app.buttons["boot.codec.h.264"]
        XCTAssertTrue(h264.waitForExistence(timeout: 5))
        h264.tap()
        XCTAssertTrue(app.scrollViews["boot.choices.codec"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(codec.label.contains("H.264"))
        capture("Unified signal launch")
    }

    func testSilentASCIILaunchReachesWorkspaceWithoutSecondMenu() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        let title = app.buttons["boot.social"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "grey VISION")
        XCTAssertTrue(app.buttons["boot.codec"].isHittable)
        XCTAssertFalse(app.buttons["boot.audio"].exists)
        app.buttons["boot.launch"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["workspace.screen"].waitForExistence(timeout: 10))
    }

    func testASCIISplashFitsPortraitAndLandscapeWithoutAudioControls() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let title = app.buttons["boot.social"]
            let launch = app.buttons["boot.launch"]
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            XCTAssertTrue(launch.isHittable)
            XCTAssertEqual(title.label, "grey VISION")
            XCTAssertGreaterThan(title.frame.height, 100)
            XCTAssertGreaterThanOrEqual(title.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(title.frame.maxX, app.frame.maxX)
            XCTAssertFalse(app.buttons["boot.audio"].exists)
            capture("ASCII nebula splash \(orientation.rawValue)")
        }
    }

    func testNebulaBackgroundDragPreservesFormatSelection() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        let codec = app.buttons["boot.codec"]
        XCTAssertTrue(codec.waitForExistence(timeout: 10))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.58))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.62))
        start.press(forDuration: 0.1, thenDragTo: end)
        codec.tap()
        let panel = app.descendants(matching: .any)["boot.format.panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        capture("Blue codec submenu after nebula touch")
        codec.tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        app.buttons["boot.fps"].tap()
        let fps30 = app.buttons["boot.fps.30-fps"]
        XCTAssertTrue(fps30.waitForExistence(timeout: 5))
        fps30.tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["boot.fps"].label.contains("30"))
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
        XCTAssertEqual(app.buttons["boot.social"].label, "grey VISION")
        XCTAssertFalse(app.staticTexts["GV.CORE // CLEAN ROOM"].exists)
        XCTAssertFalse(app.staticTexts["VERSION 3.3"].exists)
        capture("Creator splash and bottom attribution")
        app.buttons["boot.resolution"].tap()
        let openGate = app.buttons["boot.res.open-gate"]
        let rail = app.scrollViews["boot.choices.resolution"]
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
        let toggle = app.buttons["workspace.categories.all"]
        XCTAssertTrue(toggle.exists)
        let field = app.textFields["workspace.search.field"]
        if !field.exists { toggle.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        if let previous = field.value as? String, previous != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        }
        field.typeText(term + "\n")
    }

    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
