@testable import GreyVision
import XCTest

/// Guards the mapping between a telemetry reading and the control that drives
/// it.
///
/// Before this existed, tapping a reading opened whichever deck was nearest:
/// exposure fields opened the camera popout, format fields opened the settings
/// popout — which contains no format controls at all, so a third of the status
/// line was tappable and did nothing useful. The mapping is the whole feature,
/// so it is the thing under test.
final class FieldControlTests: XCTestCase {
    // MARK: - Fixtures

    private func snapshot(
        zoom: Double = 2,
        minimumZoom: Double = 1,
        maximumZoom: Double = 8,
        bias: Double = 0,
        codecs: [CaptureSetupDraft.VideoCodec] = [.hevc, .h264]
    ) -> CameraRuntimeSnapshot {
        var value = CameraRuntimeSnapshot.idle
        value.state = .running
        value.zoom = zoom
        value.minimumZoom = minimumZoom
        value.maximumZoom = maximumZoom
        value.exposureBias = bias
        value.minimumExposureBias = -8
        value.maximumExposureBias = 8
        value.availableVideoCodecs = codecs
        return value
    }

    private func telemetry(iso: Float = 400, shutter: Int = 120, kelvin: Int = 5200) -> CameraDeviceTelemetry {
        var value = CameraDeviceTelemetry()
        value.iso = iso
        value.shutterDenominator = shutter
        value.whiteBalanceKelvin = kelvin
        value.isValid = true
        return value
    }

    // MARK: - Shape

    /// Every field opens a control, and the kind of control matches what the
    /// capture layer can actually do with it. A field that fell through to the
    /// wrong arm here is exactly the bug this replaced.
    func testEveryFieldOpensTheControlItsSetterSupports() {
        let snapshot = snapshot()
        let telemetry = telemetry()
        let setup = CaptureSetupDraft()

        for field in GVTelemetryField.allCases {
            let shape = GVFieldControl.shape(
                for: field,
                snapshot: snapshot,
                exposure: telemetry,
                setup: setup
            )
            switch field {
            case .zoom, .exposure, .iso, .shutter, .whiteBalance:
                guard case .continuous = shape else {
                    return XCTFail("\(field) has a live setter and must scrub")
                }
            case .frameRate, .resolution, .codec:
                guard case .discrete = shape else {
                    return XCTFail("\(field) is session configuration and must offer a list")
                }
            case .dynamicRange:
                // No HDR setter exists anywhere in the capture layer, and a
                // picker that silently does nothing is worse than a stated
                // limitation.
                guard case .readOnly = shape else {
                    return XCTFail("\(field) has no setter and must say so")
                }
            }
        }
    }

    /// The pipeline reports nothing before the first frame. Drawing a track
    /// seeded from zero would put ISO at the bottom of its range and hand the
    /// operator a control that lies about the current state.
    func testExposureFieldsRefuseToDrawWithoutAReading() {
        for field in [GVTelemetryField.iso, .shutter, .whiteBalance] {
            let shape = GVFieldControl.shape(
                for: field,
                snapshot: snapshot(),
                exposure: .unavailable,
                setup: CaptureSetupDraft()
            )
            guard case .readOnly = shape else {
                return XCTFail("\(field) drew a track with no reading behind it")
            }
        }
    }

    /// A fixed lens reports a zero-width zoom range. A track across an empty
    /// range divides by nothing and reads as fully left at every value.
    func testFixedRangesDoNotDrawATrack() {
        let shape = GVFieldControl.shape(
            for: .zoom,
            snapshot: snapshot(zoom: 1, minimumZoom: 1, maximumZoom: 1),
            exposure: telemetry(),
            setup: CaptureSetupDraft()
        )
        guard case .readOnly = shape else { return XCTFail("Zero zoom span must not scrub") }
    }

    /// A format change tears the capture session down and starts it again.
    /// Doing that mid-take pulls the source out from under a running writer,
    /// so the control refuses rather than ending the recording.
    func testFormatFieldsLockDuringATake() {
        for field in [GVTelemetryField.frameRate, .resolution, .codec] {
            let shape = GVFieldControl.shape(
                for: field,
                snapshot: snapshot(),
                exposure: telemetry(),
                setup: CaptureSetupDraft(),
                isRecording: true
            )
            guard case .readOnly = shape else {
                return XCTFail("\(field) must not offer a session restart mid-take")
            }
        }
    }

    /// The codec list is what the device said it can write, not what the enum
    /// can spell. Offering ProRes 4444 XQ on a device that rejects it produces
    /// a recording that fails at the writer, well after the take started.
    func testCodecChoicesComeFromTheDevice() {
        let shape = GVFieldControl.shape(
            for: .codec,
            snapshot: snapshot(codecs: [.hevc, .proRes422HQ, .proRes422]),
            exposure: telemetry(),
            setup: CaptureSetupDraft()
        )
        guard case let .discrete(discrete) = shape else { return XCTFail("Codec must offer a list") }
        XCTAssertEqual(discrete.options.map(\.id), ["HEVC", "PRORES 422 HQ"])
        XCTAssertEqual(discrete.selectedID, CaptureSetupDraft().videoCodec.rawValue)
    }
}

// MARK: - Scales

extension FieldControlTests {
    /// ISO and shutter are driven in stops and displayed in their own units.
    /// If the log mapping and its inverse ever drift, the readout stops
    /// describing what the track is about to set — which is invisible until
    /// someone checks a file's metadata after the shoot.
    func testLogarithmicFieldsRoundTripThroughTheirReadout() {
        let cases: [(GVTelemetryField, Double, String)] = [
            (.iso, 400, "400"),
            (.iso, 32, "32"),
            (.iso, 6400, "6400"),
            (.shutter, 48, "1/48"),
            (.shutter, 8000, "1/8000")
        ]

        for (field, unitValue, expected) in cases {
            let drive = log2(unitValue)
            XCTAssertEqual(GVFieldControl.display(field, drive: drive), expected, "\(field) at \(unitValue)")
        }
    }

    /// The track is seeded from the live reading, so a value the device is
    /// reporting outside the designed range has to clamp rather than push the
    /// index off the end of the scale.
    func testOutOfRangeReadingsClampIntoTheTrack() {
        let shape = GVFieldControl.shape(
            for: .iso,
            // Well above the 6400 top of the scale.
            snapshot: snapshot(),
            exposure: telemetry(iso: 25_600),
            setup: CaptureSetupDraft()
        )
        guard case let .continuous(continuous) = shape else { return XCTFail("ISO must scrub") }
        XCTAssertEqual(continuous.drive, GVFieldControl.isoStops.upperBound, accuracy: 0.0001)
        XCTAssertTrue(continuous.range.contains(continuous.drive))
    }

    /// Every scale has to cover the value the device is most likely to report,
    /// or the track opens pinned to an end.
    func testScalesCoverOrdinaryReadings() {
        XCTAssertTrue(GVFieldControl.isoStops.contains(log2(400)))
        XCTAssertTrue(GVFieldControl.shutterStops.contains(log2(120)))
        XCTAssertTrue(GVFieldControl.kelvinRange.contains(5200))
    }
}

// MARK: - Commit

extension FieldControlTests {
    /// A pick that changes nothing must report so. Every format change costs a
    /// session teardown and about a second of black preview, and re-selecting
    /// the codec already in use should not spend that.
    func testPickingTheCurrentValueDoesNotRestartTheSession() {
        var setup = CaptureSetupDraft()
        XCTAssertFalse(GVFieldControl.apply(.codec, optionID: setup.videoCodec.rawValue, to: &setup))
        XCTAssertFalse(GVFieldControl.apply(.frameRate, optionID: String(setup.frameRate.rawValue), to: &setup))
        XCTAssertFalse(GVFieldControl.apply(.resolution, optionID: setup.resolution.rawValue, to: &setup))
    }

    func testPickingAFormatWritesItIntoTheDraft() {
        var setup = CaptureSetupDraft()
        setup.frameRate = .realtime
        setup.resolution = .ultraHD
        setup.videoCodec = .hevc

        XCTAssertTrue(GVFieldControl.apply(.frameRate, optionID: "120", to: &setup))
        XCTAssertEqual(setup.frameRate, .highSpeed)

        XCTAssertTrue(GVFieldControl.apply(.resolution, optionID: "1080P", to: &setup))
        XCTAssertEqual(setup.resolution, .fullHD)

        XCTAssertTrue(GVFieldControl.apply(.codec, optionID: "PRORES 422", to: &setup))
        XCTAssertEqual(setup.videoCodec, .proRes422)
    }

    /// A malformed identifier must leave the draft alone rather than land on
    /// whatever `allCases.first` happens to be.
    func testUnknownOptionsAreRefused() {
        var setup = CaptureSetupDraft()
        let before = setup
        XCTAssertFalse(GVFieldControl.apply(.frameRate, optionID: "999", to: &setup))
        XCTAssertFalse(GVFieldControl.apply(.resolution, optionID: "8K", to: &setup))
        XCTAssertFalse(GVFieldControl.apply(.codec, optionID: "AV1", to: &setup))
        XCTAssertEqual(setup, before)
    }

    /// Fields with live setters are driven by the track, not by the picker.
    /// Routing one through `apply` would silently do nothing.
    func testContinuousFieldsAreNotPickable() {
        var setup = CaptureSetupDraft()
        for field in [GVTelemetryField.iso, .shutter, .whiteBalance, .zoom, .exposure, .dynamicRange] {
            XCTAssertFalse(GVFieldControl.apply(field, optionID: "anything", to: &setup), "\(field)")
        }
    }
}
