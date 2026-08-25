import Foundation

/// The one place that knows how a telemetry reading maps onto the capture
/// layer.
///
/// Tapping a value in the status line has to open the control for *that*
/// value. Previously it opened whichever deck happened to be nearest — the
/// camera popout for exposure, the settings popout for format — and the
/// settings popout does not contain a frame-rate control at all, so tapping
/// `60 FPS` opened a row of unrelated toggles. The knowledge needed to do it
/// properly was split between the side rail, which knew how to scrub a value,
/// and the workspace, which knew which deck to open. Neither was the owner.
///
/// Three shapes, because the capture layer has exactly three:
///
/// - `continuous` — `CameraRuntime` has a live setter. Scrub it.
/// - `discrete` — the value is part of the session configuration, so changing
///   it means tearing the session down and starting it again. Pick from the
///   list the device reported.
/// - `readOnly` — the pipeline reports it and nothing can set it. Say so,
///   rather than drawing a control that quietly does nothing.
enum GVFieldControl {
    enum Shape: Equatable {
        case continuous(Continuous)
        case discrete(Discrete)
        case readOnly(String)
    }

    /// A value with a live setter, described in the units the *track* drives.
    ///
    /// ISO and shutter are driven in stops rather than in their own units.
    /// Both double per stop, so a linear track spends three quarters of its
    /// travel above ISO 1600 and crawls through the range every real scene
    /// actually sits in. `display(_:drive:)` prints the real number; only the
    /// track is logarithmic.
    struct Continuous: Equatable {
        let range: ClosedRange<Double>
        let step: Double
        let drive: Double
    }

    struct Discrete: Equatable {
        let options: [Option]
        let selectedID: String
    }

    /// One entry in a discrete field's list.
    struct Option: Identifiable, Equatable {
        let id: String
        let label: String
    }

    // MARK: - Scales

    /// ISO travel, in stops. 32–6400 covers every current iPhone sensor with
    /// room at both ends; the controller clamps to the active format, which is
    /// the only thing that knows the real limits.
    static let isoStops: ClosedRange<Double> = 5 ... 12.65
    /// Shutter travel, in stops of denominator. 1/8 to 1/8000.
    static let shutterStops: ClosedRange<Double> = 3 ... 12.97
    /// White balance in kelvin. Tungsten to open shade.
    static let kelvinRange: ClosedRange<Double> = 2000 ... 8000
}

// MARK: - Description

extension GVFieldControl {
    /// What control this field should open, given what the pipeline is
    /// currently reporting.
    ///
    /// Pure, so the mapping can be tested without a camera.
    static func shape(
        for field: GVTelemetryField,
        snapshot: CameraRuntimeSnapshot,
        exposure: CameraDeviceTelemetry,
        setup: CaptureSetupDraft,
        isRecording: Bool = false
    ) -> Shape {
        switch field {
        case .zoom, .exposure:
            return lensShape(for: field, snapshot: snapshot)

        case .iso, .shutter, .whiteBalance:
            return exposureShape(for: field, exposure: exposure)

        case .frameRate, .resolution, .codec:
            // Every format change restarts the capture session, which would
            // pull the source out from under a running writer mid-take. The
            // control states the reason rather than offering a pick that ends
            // the recording.
            if isRecording { return .readOnly("LOCKED DURING TAKE") }
            return formatShape(for: field, snapshot: snapshot, setup: setup)

        case .dynamicRange:
            // `CaptureConfiguration.prefersHDR` is fixed at false and there is
            // no setter anywhere in the capture layer. A picker here would be
            // a control that lies.
            return .readOnly("SET BY ACTIVE FORMAT // NO LIVE CONTROL")
        }
    }

    /// The two values read from the device snapshot rather than from exposure
    /// telemetry. Both report their own limits, and a lens with none of a
    /// given range says so.
    private static func lensShape(
        for field: GVTelemetryField,
        snapshot: CameraRuntimeSnapshot
    ) -> Shape {
        switch field {
        case .zoom:
            let span = snapshot.maximumZoom - snapshot.minimumZoom
            guard span > 0 else { return .readOnly("LENS REPORTS NO ZOOM RANGE") }
            return .continuous(Continuous(
                range: snapshot.minimumZoom ... snapshot.maximumZoom,
                step: 0.01,
                drive: snapshot.zoom
            ))

        case .exposure:
            let span = snapshot.maximumExposureBias - snapshot.minimumExposureBias
            guard span > 0 else { return .readOnly("DEVICE REPORTS NO BIAS RANGE") }
            return .continuous(Continuous(
                range: snapshot.minimumExposureBias ... snapshot.maximumExposureBias,
                step: 1.0 / 3.0,
                drive: snapshot.exposureBias
            ))

        default:
            return .readOnly("NO CONTROL")
        }
    }

    /// The exposure triangle, read from the mailbox the capture device
    /// publishes each frame. Before the first frame there is nothing to seed a
    /// track from, and a track seeded from zero would misreport the camera.
    private static func exposureShape(
        for field: GVTelemetryField,
        exposure: CameraDeviceTelemetry
    ) -> Shape {
        switch field {
        case .iso:
            guard exposure.isValid, exposure.iso > 0 else { return .readOnly("NO EXPOSURE READING") }
            return .continuous(Continuous(
                range: isoStops,
                // Third stops are the cine convention, but ISO is the field
                // people nudge to taste, so it gets sixths.
                step: 1.0 / 6.0,
                drive: clamp(log2(Double(exposure.iso)), to: isoStops)
            ))

        case .shutter:
            guard exposure.isValid, exposure.shutterDenominator > 0 else {
                return .readOnly("NO EXPOSURE READING")
            }
            return .continuous(Continuous(
                range: shutterStops,
                step: 1.0 / 3.0,
                drive: clamp(log2(Double(exposure.shutterDenominator)), to: shutterStops)
            ))

        case .whiteBalance:
            guard exposure.isValid, exposure.whiteBalanceKelvin > 0 else {
                return .readOnly("NO WHITE BALANCE READING")
            }
            return .continuous(Continuous(
                range: kelvinRange,
                step: 50,
                drive: clamp(Double(exposure.whiteBalanceKelvin), to: kelvinRange)
            ))

        default:
            return .readOnly("NO CONTROL")
        }
    }

    /// The three session-configuration fields, once it is known the session
    /// can safely be restarted.
    private static func formatShape(
        for field: GVTelemetryField,
        snapshot: CameraRuntimeSnapshot,
        setup: CaptureSetupDraft
    ) -> Shape {
        switch field {
        case .frameRate:
            return .discrete(Discrete(
                options: CaptureSetupDraft.FrameRate.allCases.map {
                    Option(id: String($0.rawValue), label: $0.label)
                },
                selectedID: String(setup.frameRate.rawValue)
            ))

        case .resolution:
            return .discrete(Discrete(
                options: CaptureSetupDraft.Resolution.allCases.filter(\.isSelectable).map {
                    Option(id: $0.rawValue, label: $0.rawValue)
                },
                selectedID: setup.resolution.rawValue
            ))

        case .codec:
            // What the device said it can write, not what the enum can spell.
            // Falling back to the OS-available set keeps the picker usable on
            // the synthetic source, where nothing has been probed yet.
            let curatedOS = CaptureSetupDraft.VideoCodec.curated.filter(\.isOperatingSystemAvailable)
            let available = snapshot.availableVideoCodecs.isEmpty
                ? curatedOS
                : snapshot.availableVideoCodecs.filter { CaptureSetupDraft.VideoCodec.curated.contains($0) }
            let choices = available.isEmpty ? curatedOS : available
            return .discrete(Discrete(
                options: choices.map { Option(id: $0.rawValue, label: $0.compactLabel) },
                selectedID: setup.videoCodec.rawValue
            ))

        default:
            return .readOnly("NO CONTROL")
        }
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

// MARK: - Readout

extension GVFieldControl {
    /// The value as the operator reads it, from the value the track carries.
    ///
    /// The inverse of the log mapping in `shape(for:...)` lives here so the
    /// two can never drift apart.
    static func display(_ field: GVTelemetryField, drive: Double) -> String {
        switch field {
        case .zoom:
            String(format: "%.2f\u{00D7}", drive)
        case .exposure:
            String(format: "%+.1f EV", drive)
        case .iso:
            "\(Int(pow(2, drive).rounded()))"
        case .shutter:
            "1/\(Int(pow(2, drive).rounded()))"
        case .whiteBalance:
            "\(Int(drive.rounded()))K"
        case .frameRate, .resolution, .dynamicRange, .codec:
            ""
        }
    }
}

// MARK: - Commit

@MainActor
extension GVFieldControl {
    /// Applies a track value, in drive units, to the live capture device.
    ///
    /// Every setter here clamps inside `CameraController` against the active
    /// format, which is the only thing that knows the real limits — so this
    /// converts units and nothing else.
    static func commit(_ field: GVTelemetryField, drive: Double, to runtime: CameraRuntime) {
        switch field {
        case .zoom:
            runtime.setZoom(drive)
        case .exposure:
            runtime.setExposureBias(drive)
        case .iso:
            runtime.setISO(pow(2, drive))
        case .shutter:
            runtime.setShutterDenominator(Int(pow(2, drive).rounded()))
        case .whiteBalance:
            runtime.setWhiteBalanceKelvin(Int(drive.rounded()))
        case .frameRate, .resolution, .dynamicRange, .codec:
            break
        }
    }
}

// MARK: - Format

extension GVFieldControl {
    /// Writes a picked option into the capture draft.
    ///
    /// Returns false when nothing changed, so the caller can skip the session
    /// restart rather than blacking the preview out for no reason. The restart
    /// itself belongs to `AppModel`; this only edits the draft.
    static func apply(
        _ field: GVTelemetryField,
        optionID: String,
        to setup: inout CaptureSetupDraft
    ) -> Bool {
        switch field {
        case .frameRate:
            guard
                let raw = Int(optionID),
                let rate = CaptureSetupDraft.FrameRate(rawValue: raw),
                rate != setup.frameRate
            else { return false }
            setup.frameRate = rate
            return true

        case .resolution:
            guard
                let resolution = CaptureSetupDraft.Resolution(rawValue: optionID),
                resolution != setup.resolution
            else { return false }
            setup.resolution = resolution
            return true

        case .codec:
            guard
                let codec = CaptureSetupDraft.VideoCodec(rawValue: optionID),
                codec != setup.videoCodec
            else { return false }
            setup.videoCodec = codec
            return true

        case .zoom, .exposure, .iso, .shutter, .whiteBalance, .dynamicRange:
            return false
        }
    }
}
