import XCTest

extension XCUIElement {
    /// Drives a `GVTerminalParameterRow` the way a finger does.
    ///
    /// The row is a custom scrub surface, not a `Slider`. It reports itself as
    /// one to VoiceOver through `accessibilityRepresentation`, which is why it
    /// resolves under `app.sliders`, but that substitution carries no scrubber
    /// geometry — so `adjust(toNormalizedSliderPosition:)` has nothing to
    /// synthesise an event against and fails. A horizontal drag exercises the
    /// gesture the operator actually performs.
    func scrub(by fraction: CGFloat) {
        let start = coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = coordinate(withNormalizedOffset: CGVector(dx: 0.5 + fraction, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
}

@MainActor
final class BootstrapUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchCombinesEntryAndFormatSelection() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertFalse(app.buttons["access.enter"].exists)
        XCTAssertTrue(app.buttons["boot.codec"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["boot.launch"].isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["boot.screen"].waitForExistence(timeout: 15))
    }

    func testLaunchHasASCIIWordmarkWithoutAudioOrTelemetryClutter() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["boot.screen"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["boot.social"].label, "grey VISION")
        XCTAssertFalse(app.buttons["boot.audio"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["boot.signal"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["boot.telemetry"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["boot.capabilities"].exists)
    }

    func testBootFormatDockWorkspaceStateMachine() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        // Queried as any descendant, not staticTexts: the mark is now an
        // accessibility container (`children: .ignore` with its own label),
        // so it no longer surfaces as a static text element.
        XCTAssertTrue(
            app.descendants(matching: .any)["boot.screen"].waitForExistence(timeout: 15)
        )

        let codecButton = app.buttons["boot.codec"]
        XCTAssertTrue(codecButton.waitForExistence(timeout: 3))
        let resolutionButton = app.buttons["boot.resolution"]
        XCTAssertTrue(resolutionButton.exists)
        XCTAssertTrue(resolutionButton.label.contains("4K"))
        codecButton.tap()
        // Identifier is the option's own slug, and the curated list spells the
        // full format name: PRORES 422 HQ, not the "422 HQ" the card prints.
        XCTAssertTrue(app.buttons["boot.codec.prores-422-hq"].waitForExistence(timeout: 3))
        app.buttons["boot.codec.prores-422-hq"].tap()
        XCTAssertTrue(app.scrollViews["boot.choices.codec"].waitForNonExistence(timeout: 3))

        app.buttons["boot.fps"].tap()
        let frameRateChoices = app.scrollViews["boot.choices.fps"]
        XCTAssertTrue(frameRateChoices.waitForExistence(timeout: 3))
        frameRateChoices.swipeLeft()
        XCTAssertTrue(app.buttons["boot.fps.120-fps"].waitForExistence(timeout: 3))
        app.buttons["boot.fps.120-fps"].tap()
        XCTAssertTrue(frameRateChoices.waitForNonExistence(timeout: 3))

        let launchMark = app.descendants(matching: .any)["boot.launch"]
        XCTAssertTrue(launchMark.waitForExistence(timeout: 3))
        launchMark.tap()

        XCTAssertTrue(app.descendants(matching: .any)["workspace.screen"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["camera.source"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["camera.metal.preview"]
                .waitForExistence(timeout: 3)
        )

        XCTAssertTrue(app.descendants(matching: .any)["camera.metal.preview"]
            .waitForExistence(timeout: 3))

        // The old FRAME category check (grid effect + density scrub) was
        // removed: that category and its parameter deck no longer exist in
        // the dock, so there is nothing left to drive.

        let cameraButton = app.buttons["workspace.camera"]
        XCTAssertTrue(cameraButton.waitForExistence(timeout: 3))
        cameraButton.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.camera.deck"]
                .waitForExistence(timeout: 3)
        )
        // The deck is scrub rows now, not +/- buttons. ZOOM and EXPOSURE are
        // the two that map to live capture-device setters, so they are the two
        // worth asserting; TORCH, WB and FOCUS are capability-gated.
        XCTAssertTrue(app.sliders["workspace.camera.zoom"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.sliders["workspace.camera.exposure"].exists)
        XCTAssertFalse(app.staticTexts["CAMERA CONTROL"].exists)
    }

    /// Search and recents are the two routes into 133 effects that do not
    /// require remembering which of nineteen families an effect was filed
    /// under, so both are worth a test.
    func testSearchFindsAnEffectAndSelectingItPopulatesRecents() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-workspace"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["workspace.screen"].waitForExistence(timeout: 5))

        let searchToggle = app.buttons["workspace.search"]
        XCTAssertTrue(searchToggle.waitForExistence(timeout: 3))
        XCTAssertEqual(searchToggle.value as? String, "collapsed")
        searchToggle.tap()
        XCTAssertEqual(searchToggle.value as? String, "expanded")

        let field = app.textFields["workspace.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("HALATION")

        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.effects.search"]
                .waitForExistence(timeout: 3)
        )
        let match = app.buttons["workspace.action.halation"]
        XCTAssertTrue(match.waitForExistence(timeout: 3), "Search must reach an effect by name")
        match.tap()

        // Selecting through search still opens the effect's parameter deck.
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.parameters.halation"]
                .waitForExistence(timeout: 3)
        )

        // Close search; the effect just used must now be on the recents shelf.
        searchToggle.tap()
        let recents = app.buttons["workspace.category.recents"]
        XCTAssertTrue(recents.waitForExistence(timeout: 3))
        recents.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.effects.recents"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.buttons["workspace.action.halation"].waitForExistence(timeout: 3),
            "A selected effect must land on the recents shelf"
        )
    }

    func testWorkspaceAdaptsToLandscapeAndExpandsCaptureSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-workspace"]
        app.launch()

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.descendants(matching: .any)["workspace.screen"].waitForExistence(timeout: 5))

        let settingsButton = app.buttons["workspace.settings"]
        let cameraButton = app.buttons["workspace.camera"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 3))
        XCTAssertTrue(cameraButton.exists)
        XCTAssertFalse(app.descendants(matching: .any)["workspace.camera.deck"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["workspace.settings.deck"].exists)
        // Record and photo moved out of the hidden settings deck into a
        // permanent capture row beside the FX toggle: a take must be
        // startable whenever the shot is framed, deck open or not.
        XCTAssertTrue(app.buttons["workspace.record.toggle"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["workspace.capture.photo"].exists)
        XCTAssertFalse(app.buttons["workspace.clear-effects"].exists)
        XCTAssertFalse(app.buttons["workspace.menu"].exists)
        // Recipes is a rail item, so it has to survive the landscape
        // rotation. An operator framing a shot sideways still needs to reach it.
        XCTAssertTrue(app.buttons["workspace.recipes"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["workspace.takes"].exists)
        XCTAssertFalse(app.buttons["workspace.timeline"].exists)
        XCTAssertFalse(app.buttons["workspace.social"].exists)
        XCTAssertFalse(app.buttons["workspace.exit"].exists)

        cameraButton.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.camera.deck"]
                .waitForExistence(timeout: 3)
        )

        settingsButton.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.camera.deck"]
                .waitForNonExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.settings.deck"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["workspace.clear-effects"].waitForExistence(timeout: 3))

        // Record drives the writer now rather than printing a Gate 5 notice,
        // and the simulator has no capture hardware to record from — proving
        // the recording path is a device test, not this one. Clear Effects is
        // the deck action that is deterministic everywhere, so it is the one
        // used to prove the deck's buttons are live.
        app.buttons["workspace.clear-effects"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.toast"].waitForExistence(timeout: 3)
        )

        settingsButton.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.settings.deck"]
                .waitForNonExistence(timeout: 3)
        )
        // The capture row is permanent: closing the deck does not take the
        // record control away.
        XCTAssertTrue(app.buttons["workspace.record.toggle"].exists)

        XCUIDevice.shared.orientation = .portrait
    }

    func testRGBSplitOpensCompactParametersAndUpdatesLiveControls() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-workspace"]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["camera.metal.preview"]
                .waitForExistence(timeout: 5)
        )
        let categories = app.scrollViews["workspace.categories"]
        XCTAssertTrue(categories.waitForExistence(timeout: 3))
        categories.swipeLeft()

        let glitchCategory = app.buttons["workspace.category.glitch"]
        XCTAssertTrue(glitchCategory.waitForExistence(timeout: 3))
        glitchCategory.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.parameters.rgbSplit"]
                .waitForExistence(timeout: 3)
        )
        let stackButton = app.buttons["workspace.parameter.effect.toggle"]
        XCTAssertTrue(stackButton.exists)
        XCTAssertEqual(stackButton.value as? String, "disarmed")
        stackButton.tap()
        XCTAssertEqual(stackButton.value as? String, "armed")

        // Families open the browser rather than a second horizontal card rail
        // or a radial ring. Both of those are gone.
        glitchCategory.tap()
        let signalTear = app.buttons["workspace.effect.signalTear"]
        XCTAssertTrue(signalTear.waitForExistence(timeout: 5))
        signalTear.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.parameters.signalTear"]
                .waitForExistence(timeout: 3)
        )

        app.descendants(matching: .any)["camera.metal.preview"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.parameters.signalTear"]
                .waitForNonExistence(timeout: 3)
        )
    }

    func testSpatialAndTemporalEffectsExposeLiveCompactControls() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-workspace"]
        app.launch()

        let block = app.buttons["workspace.category.block"]
        XCTAssertTrue(block.waitForExistence(timeout: 5))
        block.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.parameters.pixelate"]
                .waitForExistence(timeout: 3)
        )
        let blockSlider = app.sliders["workspace.parameter.pixelate.block"]
        XCTAssertTrue(blockSlider.exists)
        XCTAssertTrue(app.sliders["workspace.parameter.pixelate.blend"].exists)
        let blockBefore = blockSlider.value as? String
        blockSlider.scrub(by: 0.32)
        XCTAssertNotEqual(blockSlider.value as? String, blockBefore, "Scrubbing BLOCK must move its readout")

        let feedbackCategory = app.buttons["workspace.category.feedback"]
        XCTAssertTrue(feedbackCategory.exists)
        feedbackCategory.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.parameters.feedback"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.sliders["workspace.parameter.feedback.zoom"].exists)
    }

    /// Tapping a reading in the status line has to open the control for that
    /// reading and nothing else.
    ///
    /// It used to open whichever deck was nearest — and for frame rate,
    /// resolution and codec the deck it opened contains no such control, so a
    /// third of the row was tappable and did nothing.
    func testTappingAStatusReadingOpensThatFieldsControlAlone() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-workspace"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["workspace.screen"].waitForExistence(timeout: 5))

        let frameRate = app.descendants(matching: .any)["workspace.status.frameRate"]
        XCTAssertTrue(frameRate.waitForExistence(timeout: 3))
        frameRate.tap()

        let control = app.descendants(matching: .any)["workspace.field.frameRate"]
        XCTAssertTrue(control.waitForExistence(timeout: 3), "FPS must open an FPS control")
        XCTAssertFalse(
            app.descendants(matching: .any)["workspace.settings.deck"].exists,
            "FPS must not open the generic settings deck"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["workspace.field.iso"].exists,
            "Only the tapped field's control opens"
        )

        // A second tap on the same reading puts it away.
        frameRate.tap()
        XCTAssertTrue(control.waitForNonExistence(timeout: 3))

        // Codec is the other end of the range: a device-reported list rather
        // than three fixed rates.
        let codec = app.descendants(matching: .any)["workspace.status.codec"]
        XCTAssertTrue(codec.exists)
        codec.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace.field.codec"].waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.descendants(matching: .any)["workspace.field.frameRate"].exists)

        // Dynamic range has no setter anywhere in the capture layer, so its
        // control states that rather than drawing a picker that does nothing.
        app.descendants(matching: .any)["workspace.status.dynamicRange"].tap()
        let range = app.descendants(matching: .any)["workspace.field.dynamicRange"]
        XCTAssertTrue(range.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["workspace.field.dynamicRange.hdr"].exists)
    }

    func testLiDARCategoryIsPresentAndTruthfulOnSimulator() throws {
        #if !targetEnvironment(simulator)
            throw XCTSkip("This test verifies the explicit simulator-unavailable LiDAR state.")
        #else
            let app = XCUIApplication()
            app.launchArguments = ["--uitesting-workspace"]
            app.launch()

            XCTAssertTrue(app.descendants(matching: .any)["workspace.screen"].waitForExistence(timeout: 5))
            let categories = app.scrollViews["workspace.categories"]
            XCTAssertTrue(categories.waitForExistence(timeout: 3))
            categories.swipeLeft()

            let lidarCategory = app.buttons["workspace.category.lidar"]
            XCTAssertTrue(lidarCategory.waitForExistence(timeout: 3))
            lidarCategory.tap()
            XCTAssertTrue(
                app.descendants(matching: .any)["workspace.effects.lidar"]
                    .waitForExistence(timeout: 3)
            )

            let pointCloud = app.buttons["workspace.action.point-cloud"]
            XCTAssertTrue(pointCloud.waitForExistence(timeout: 3))
            pointCloud.tap()
            XCTAssertTrue(app.staticTexts["workspace.effect.notice"].waitForExistence(timeout: 3))
        #endif
    }
}
