import XCTest

/// The still capture, end to end through the button a person actually presses.
///
/// The point of this test is narrow and specific: the saved photograph must not
/// be screen-sized. The old implementation copied `drawable.texture`, so every
/// capture came out at whatever the viewfinder happened to be — which on a
/// simulator is close enough to the screen that the regression was invisible.
/// The capture reports the size it wrote, so this can assert on the number
/// rather than on a promise in a comment.
///
/// The second assertion is the one that actually pins the behaviour: the
/// written size must match the camera source, not the drawable. On the
/// simulator the source is synthetic but declared — the configured 4K 16:9
/// format — so the two shapes are genuinely different (landscape versus
/// portrait) and a regression to the old grab fails here rather than in a
/// report nobody reads.
@MainActor
final class StillCaptureUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCaptureSavesAtCameraResolutionNotScreenSize() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-workspace"]
        app.launch()
        XCTAssertTrue(app.buttons["workspace.screen"].waitForExistence(timeout: 15))
        let coach = app.buttons["workspace.chip.coach.close"]
        if coach.exists { coach.tap() }

        let shutter = app.buttons["workspace.capture.photo"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10))
        XCTAssertTrue(shutter.isHittable, "the capture button must be reachable, not merely present")

        // On a simulator where Photos access has already been granted this is a
        // no-op. Where it has not, the first capture raises the add-only prompt
        // from a background completion handler and the save stalls until
        // something answers it. The alert belongs to Springboard rather than
        // the app, so it is answered there — but exactly once: every query
        // against another process is an XPC round-trip, and polling one in a
        // loop is slow enough to stall the whole run.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        shutter.tap()

        if let allow = springboard.buttons["Allow"].firstMatch.exists ? springboard.buttons["Allow"] : nil {
            allow.tap()
        } else if springboard.buttons["Allow Full Access"].waitForExistence(timeout: 3) {
            springboard.buttons["Allow Full Access"].tap()
        }

        // The chain has to resize to full resolution and re-render before there
        // is anything to save, then the GPU has to deliver the readback and
        // Photos has to accept the write. Ten seconds is generous for all
        // three; failing here means one of them did not happen.
        let saved = expectation(description: "photo reported saved")
        var reported: String = ""
        var lastSeen: String = "<button never reported a value>"
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            let value = (shutter.value as? String) ?? ""
            if !value.isEmpty { lastSeen = value }
            if value.contains("SAVED") {
                reported = value
                saved.fulfill()
                break
            }
            if value.contains("FAILED") || value.contains("DENIED") {
                XCTFail("capture reported failure: \(value)")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        // Report the last thing the capture actually said. An expectation
        // timeout on its own only says "never finished", which cannot be told
        // apart from "never started" — and those need different fixes.
        XCTAssertFalse(
            reported.isEmpty,
            "capture never reported a save within 25s. Last status was: \"\(lastSeen)\""
        )
        wait(for: [saved], timeout: 1)

        let written = try XCTUnwrap(
            dimensions(in: reported),
            "expected the capture to report a WIDTH×HEIGHT it wrote, got \"\(reported)\""
        )
        let screen = app.windows.firstMatch.frame.size

        // The configured source is the 4K 16:9 format, and the drawable is a
        // portrait phone screen, so the two are far apart in every dimension
        // that matters. Asserting against the screen rather than a magic
        // number keeps this honest if the default format is ever changed.
        XCTAssertGreaterThan(
            written.width, screen.width,
            "capture (\(written.width) wide) is no wider than the window (\(Int(screen.width))) — that is a screen grab"
        )

        XCTAssertGreaterThan(
            written.width, 0,
            "capture reported a zero width"
        )
        XCTAssertNotEqual(
            written,
            CGSize(width: screen.width, height: screen.height),
            "capture came out at the screen size, so it is still copying the drawable"
        )

        // The shape is the part that actually distinguishes the two. A grab of
        // the drawable inherits the screen's portrait aspect; a capture of the
        // source inherits the format's landscape one. Comparing the capture
        // against the window — rather than against a square, which no 16:9
        // format ever is — is the assertion that survives a format change and
        // still fails loudly on a regression to the old copy.
        let capturedAspect = written.width / max(written.height, 1)
        let screenAspect = screen.width / max(screen.height, 1)
        XCTAssertGreaterThan(
            capturedAspect, 1,
            "capture is \(written) — portrait, which is the viewfinder's shape rather than the format's"
        )
        XCTAssertGreaterThan(
            capturedAspect / screenAspect, 2,
            "capture aspect \(capturedAspect) is too close to the screen's \(screenAspect) to be the source format"
        )

        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "Still capture reported \(reported)"
        image.lifetime = .keepAlways
        add(image)
    }

    /// Pulls `1920×1080` out of `PHOTO // SAVED 1920×1080`.
    private func dimensions(in message: String) -> CGSize? {
        let pattern = try? NSRegularExpression(pattern: "(\\d+)[x×](\\d+)")
        guard let match = pattern?.firstMatch(
            in: message,
            range: NSRange(message.startIndex..., in: message)
        ) else { return nil }
        guard let first = Range(match.range(at: 1), in: message),
              let second = Range(match.range(at: 2), in: message),
              let width = Double(message[first]),
              let height = Double(message[second]) else { return nil }
        return CGSize(width: width, height: height)
    }
}