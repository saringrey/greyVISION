import AppIntents
import AVFoundation
@testable import GreyVision
import Metal

// NOTE: several tests were removed here. They asserted against an API set
// (relighting, memoryEffect, subjectComposite, frameAverage,
// CameraSubjectIsolationParameters, GVModulationMatrix*) that exists in a
// different branch of this project, not in this source tree. They were
// failing to compile, not failing to pass. Restore them alongside the
// features, not before.
import XCTest

final class BootstrapTests: XCTestCase {
    func testSplashHighlightsChangeCharacterAndStayBounded() {
        let letters = Array(GVSplashLettering.text)
        for row in 0 ..< 18 {
            for cycle in 0 ..< 20 {
                let time = Double(cycle) * 2.8
                let current = GVSplashLettering.highlight(at: time, row: row)
                let next = GVSplashLettering.highlight(at: time + 2.8, row: row)
                XCTAssertNotEqual(current.character, next.character)
                XCTAssertNotEqual(letters[current.character], " ")
                XCTAssertTrue((0 ... 1).contains(current.strength))
                XCTAssertLessThan(GVSplashLettering.dotRadius(at: time, row: row) * 1.12, 0.5)
            }
        }
        for tick in 0 ..< 400 {
            let time = Double(tick) / 10
            let dimmed = (0 ..< 18).filter {
                GVSplashLettering.rowBrightness(at: time, row: $0, count: 18) < 1
            }
            XCTAssertLessThanOrEqual(dimmed.count, 1)
        }
    }

    @MainActor
    func testReticleDefaultsOnAndPreservesNewOptOut() throws {
        let suite = "ReticleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "gv.preferences.cam.reticle")
        let preferences = GVPreferences(defaults: defaults)
        XCTAssertTrue(preferences.reticleEnabled)
        preferences.reticleEnabled = false
        XCTAssertFalse(GVPreferences(defaults: defaults).reticleEnabled)
    }

    func testDiagnosticsBeginIdleAndEmpty() async {
        let store = DiagnosticsStore()
        let snapshot = await store.snapshot()

        XCTAssertEqual(snapshot, .initial)
        XCTAssertEqual(snapshot.engineState, .idle)
        XCTAssertEqual(snapshot.renderedFrames, 0)
        XCTAssertEqual(snapshot.droppedFrames, 0)
    }

    func testStructuredErrorExplainsUnavailableCapability() {
        let error = GVError.capabilityUnavailable(
            feature: "Scene Depth",
            reason: "LiDAR is not present"
        )

        XCTAssertEqual(
            error.errorDescription,
            "Scene Depth is unavailable: LiDAR is not present"
        )
    }

    @MainActor
    func testAppRouteMovesBootWorkspaceAndBack() async throws {
        let suiteName = "BootstrapTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let telemetry = BootTelemetry(
            operatingSystem: "TEST",
            deviceModel: "IPHONE",
            metalDevice: "METAL",
            discoveredCameras: 2,
            processorCount: 8,
            thermalState: "NOMINAL",
            lowPowerMode: false,
            depthSensor: "ONLINE",
            audioDSP: "ARMED",
            frameHeapMegabytes: 1024
        )
        let model = AppModel(
            arguments: ["GreyVisionTests"],
            bootTelemetry: telemetry,
            preferences: GVPreferences(defaults: defaults)
        )

        // Cold launch opens on the access gate; `.boot` is only reachable
        // through it. Starting the engine from `.gate` must be a no-op.
        XCTAssertEqual(model.route, .gate)
        XCTAssertEqual(model.runtimeStatus, .offline)
        model.startEngine()
        XCTAssertEqual(model.route, .gate, "startEngine must not skip the gate")

        model.unlockAccess()
        XCTAssertEqual(model.route, .boot)
        XCTAssertEqual(model.runtimeStatus, .offline)

        model.startEngine()
        XCTAssertEqual(model.route, .workspace)
        XCTAssertEqual(model.runtimeStatus, .starting)

        for _ in 0 ..< 50 where model.runtimeStatus != .running {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #if targetEnvironment(simulator)
            XCTAssertEqual(model.runtimeStatus, .running)
            XCTAssertEqual(model.camera.snapshot.sourceLabel, "SIM SOURCE")
            XCTAssertTrue(model.camera.snapshot.isSynthetic)
        #endif

        model.returnToBoot()
        XCTAssertEqual(model.route, .boot)
        XCTAssertEqual(model.runtimeStatus, .offline)
    }

    func testCaptureDraftMapsToTypedConfiguration() {
        var draft = CaptureSetupDraft()
        draft.cameraPosition = .front
        draft.videoCodec = .proRes422HQ
        draft.resolution = .ultraHD
        draft.frameRate = .cinematic

        let configuration = CaptureConfiguration(draft: draft)

        XCTAssertEqual(configuration.position, .front)
        XCTAssertEqual(configuration.videoCodec, .proRes422HQ)
        XCTAssertEqual(configuration.dimensions, .ultraHD)
        XCTAssertEqual(configuration.framesPerSecond, 30)
        XCTAssertFalse(configuration.prefersHDR)
    }

    func testCaptureResolutionsMapToNativeFormatTargets() {
        XCTAssertEqual(
            CaptureSetupDraft.Resolution.allCases,
            [.hd720, .fullHD, .ultraHD, .openGate]
        )
        XCTAssertEqual(CaptureSetupDraft().resolution, .ultraHD)
        XCTAssertEqual(CaptureConfiguration.standard.resolution, .ultraHD)
        XCTAssertEqual(CaptureConfiguration.standard.dimensions, .ultraHD)
        XCTAssertEqual(CaptureConfiguration(draft: CaptureSetupDraft()).dimensions, .ultraHD)

        var draft = CaptureSetupDraft()
        draft.resolution = .hd720
        XCTAssertEqual(CaptureConfiguration(draft: draft).dimensions, .hd720)
        draft.resolution = .fullHD
        XCTAssertEqual(CaptureConfiguration(draft: draft).dimensions, .fullHD)
        draft.resolution = .openGate
        XCTAssertEqual(CaptureConfiguration(draft: draft).dimensions, .openGate)
        XCTAssertEqual(CaptureConfiguration(draft: draft).resolution, .openGate)
    }

    func testHighSpeedDraftRequestsOneHundredTwentyFPS() {
        var draft = CaptureSetupDraft()
        draft.frameRate = .highSpeed

        let configuration = CaptureConfiguration(draft: draft)

        XCTAssertEqual(configuration.framesPerSecond, 120)
        XCTAssertEqual(draft.frameRate.availabilityNote, "HIGH SPEED // FORMAT CHECKED LIVE")
    }

    /// The boot chooser prints these on the cards and in its readout, so they
    /// are model data rather than view copy: the labels and the readout cannot
    /// drift away from the formats they describe.
    func testCodecSpecLabelsDescribeTheCuratedLadder() {
        let codec = CaptureSetupDraft.VideoCodec.self
        XCTAssertEqual(codec.h264.chromaLabel, "4:2:0")
        XCTAssertEqual(codec.h264.bitDepthLabel, "8-BIT")
        XCTAssertEqual(codec.hevc.chromaLabel, "4:2:0")
        XCTAssertEqual(codec.proRes422HQ.chromaLabel, "4:2:2")
        XCTAssertEqual(codec.proRes422HQ.bitDepthLabel, "10-BIT")
        XCTAssertEqual(codec.proRes4444XQ.chromaLabel, "4:4:4")
        XCTAssertEqual(codec.proRes4444XQ.bitDepthLabel, "12-BIT")
        XCTAssertEqual(codec.proResRAWHQ.chromaLabel, "RAW BAYER")
        XCTAssertEqual(codec.proResRAWHQ.bitDepthLabel, "12-BIT")

        // Every case has to answer, not just the curated five: the enum still
        // decodes drafts written by older builds.
        for entry in codec.allCases {
            XCTAssertFalse(entry.chromaLabel.isEmpty, "\(entry.rawValue)")
            XCTAssertFalse(entry.bitDepthLabel.isEmpty, "\(entry.rawValue)")
            XCTAssertFalse(entry.tierLabel.isEmpty, "\(entry.rawValue)")
            XCTAssertFalse(entry.fidelityLabel.isEmpty, "\(entry.rawValue)")
            XCTAssertTrue((1 ... 5).contains(entry.fidelityClass), "\(entry.rawValue)")
        }

        // The curated list is ordered by fidelity, which is what lets it read as
        // one ladder rather than as five unrelated names.
        let classes = CaptureSetupDraft.VideoCodec.curated.map(\.fidelityClass)
        XCTAssertEqual(classes, classes.sorted())
        XCTAssertEqual(Set(classes).count, classes.count, "each curated step is its own rung")
    }

    func testResolutionAndFrameRateReadoutsStayInStepWithTheirNotes() {
        XCTAssertEqual(CaptureSetupDraft.Resolution.allCases.map(\.detailClass), [1, 2, 3, 4])
        XCTAssertEqual(CaptureSetupDraft.FrameRate.allCases.map(\.motionClass), [1, 2, 3])
        XCTAssertEqual(CaptureSetupDraft.FrameRate.highSpeed.cadenceLabel, "HIGH SPEED")

        for raster in CaptureSetupDraft.Resolution.allCases {
            // The note is built from the two parts the rail prints, so a
            // reworded raster cannot leave the sentence behind.
            XCTAssertEqual(raster.availabilityNote, "\(raster.pixelLabel) // \(raster.detailLabel)")
            XCTAssertFalse(raster.pixelLabel.isEmpty)
        }
    }

    func testDepthGeometryReconstructsMetricXYZAndRejectsInvalidSamples() {
        let intrinsics = SIMD4<Float>(100, 100, 50, 50)

        let center = DepthGeometry.cameraPoint(
            pixel: SIMD2<Float>(50, 50),
            depthMeters: 2,
            intrinsics: intrinsics
        )
        let offset = DepthGeometry.cameraPoint(
            pixel: SIMD2<Float>(60, 70),
            depthMeters: 2,
            intrinsics: intrinsics
        )

        XCTAssertEqual(center, SIMD3<Float>(0, 0, 2))
        XCTAssertEqual(offset, SIMD3<Float>(0.2, 0.4, 2))
        XCTAssertNil(
            DepthGeometry.cameraPoint(
                pixel: SIMD2<Float>(60, 70),
                depthMeters: .nan,
                intrinsics: intrinsics
            )
        )
        XCTAssertNil(
            DepthGeometry.cameraPoint(
                pixel: SIMD2<Float>(60, 70),
                depthMeters: 0,
                intrinsics: intrinsics
            )
        )
    }

    func testDepthParametersClampToMetalContract() {
        let parameters = DepthEffectParameters(
            nearMeters: -1,
            farMeters: 99,
            intensity: 8,
            pointSize: 22,
            sampleStride: 0,
            confidenceThreshold: 8,
            yawDegrees: 90,
            pitchDegrees: -90,
            falloff: 2,
            detail: -1,
            bandCenter: 3,
            bandWidth: 0
        ).sanitized

        XCTAssertEqual(parameters.nearMeters, 0.08)
        XCTAssertEqual(parameters.farMeters, 8)
        XCTAssertEqual(parameters.intensity, 1.5)
        XCTAssertEqual(parameters.pointSize, 7)
        XCTAssertEqual(parameters.sampleStride, 1)
        XCTAssertEqual(parameters.confidenceThreshold, 2)
        XCTAssertEqual(parameters.yawDegrees, 35)
        XCTAssertEqual(parameters.pitchDegrees, -28)
        XCTAssertEqual(parameters.falloff, 1)
        XCTAssertEqual(parameters.detail, 0)
        XCTAssertEqual(parameters.bandCenter, 1)
        XCTAssertEqual(parameters.bandWidth, 0.01)
    }

    func testRGBSplitParametersClampToRendererContract() {
        let parameters = RGBSplitEffectParameters(
            isEnabled: true,
            amount: 2,
            angleDegrees: 541,
            mix: -1
        ).sanitized

        XCTAssertTrue(parameters.isEnabled)
        XCTAssertEqual(parameters.amount, 0.08)
        XCTAssertEqual(parameters.angleDegrees, 181)
        XCTAssertEqual(parameters.mix, 0)
    }

    func testCaptureCodecMapsToPublicAVFoundationTypes() {
        XCTAssertEqual(CaptureSetupDraft.VideoCodec.h264.avVideoCodecType, .h264)
        XCTAssertEqual(CaptureSetupDraft.VideoCodec.hevc.avVideoCodecType, .hevc)
        XCTAssertEqual(CaptureSetupDraft.VideoCodec.hevcWithAlpha.avVideoCodecType, .hevcWithAlpha)
        XCTAssertEqual(CaptureSetupDraft.VideoCodec.proRes422Proxy.avVideoCodecType, .proRes422Proxy)
        XCTAssertEqual(CaptureSetupDraft.VideoCodec.proRes422LT.avVideoCodecType, .proRes422LT)
        XCTAssertEqual(CaptureSetupDraft.VideoCodec.proRes422.avVideoCodecType, .proRes422)
        XCTAssertEqual(CaptureSetupDraft.VideoCodec.proRes422HQ.avVideoCodecType, .proRes422HQ)
        XCTAssertEqual(CaptureSetupDraft.VideoCodec.proRes4444.avVideoCodecType, .proRes4444)
        XCTAssertEqual(CaptureSetupDraft.VideoCodec.proRes4444XQ.avVideoCodecType?.rawValue, "ap4x")
        XCTAssertEqual(CaptureSetupDraft.VideoCodec.jpegXL.avVideoCodecType?.rawValue, "jxlc")

        if #available(iOS 26.0, *) {
            XCTAssertEqual(CaptureSetupDraft.VideoCodec.proResRAW.avVideoCodecType, .proResRAW)
            XCTAssertEqual(CaptureSetupDraft.VideoCodec.proResRAWHQ.avVideoCodecType, .proResRAWHQ)
            XCTAssertTrue(CaptureSetupDraft.VideoCodec.proResRAW.isOperatingSystemAvailable)
            XCTAssertTrue(CaptureSetupDraft.VideoCodec.proResRAWHQ.isOperatingSystemAvailable)
        } else {
            XCTAssertNil(CaptureSetupDraft.VideoCodec.proResRAW.avVideoCodecType)
            XCTAssertNil(CaptureSetupDraft.VideoCodec.proResRAWHQ.avVideoCodecType)
            XCTAssertFalse(CaptureSetupDraft.VideoCodec.proResRAW.isOperatingSystemAvailable)
            XCTAssertFalse(CaptureSetupDraft.VideoCodec.proResRAWHQ.isOperatingSystemAvailable)
        }
    }

    func testCapabilitiesFilterByCameraPosition() {
        let rear = CameraDeviceCapability(
            id: "rear",
            name: "Rear",
            position: .rear,
            deviceType: "wide",
            minimumZoom: 1,
            maximumZoom: 5,
            hasTorch: true,
            supportsFocusPoint: true,
            supportsExposurePoint: true,
            formats: []
        )
        let front = CameraDeviceCapability(
            id: "front",
            name: "Front",
            position: .front,
            deviceType: "true-depth",
            minimumZoom: 1,
            maximumZoom: 2,
            hasTorch: false,
            supportsFocusPoint: true,
            supportsExposurePoint: true,
            formats: []
        )
        let capabilities = CameraCapabilities(devices: [rear, front], discoveryReason: nil)

        XCTAssertEqual(capabilities.devices(at: .rear), [rear])
        XCTAssertEqual(capabilities.devices(at: .front), [front])
        XCTAssertEqual(capabilities.device(id: "front"), front)
    }

    func testHorizonNormalizesCardinalOrientationsAndUsesHysteresis() {
        let quarterTurn = Double.pi / 2
        XCTAssertEqual(GVHorizonModel.deviation(from: 0), 0, accuracy: 0.000_001)
        XCTAssertEqual(GVHorizonModel.deviation(from: quarterTurn), 0, accuracy: 0.000_001)
        XCTAssertEqual(GVHorizonModel.deviation(from: -quarterTurn), 0, accuracy: 0.000_001)
        XCTAssertEqual(GVHorizonModel.deviation(from: .pi), 0, accuracy: 0.000_001)

        let onePointTwoDegrees = 1.2 * Double.pi / 180
        XCTAssertFalse(GVHorizonModel.isLevel(deviation: onePointTwoDegrees, wasLevel: false))
        XCTAssertTrue(GVHorizonModel.isLevel(deviation: onePointTwoDegrees, wasLevel: true))
    }

    @MainActor
    func testSimulatorRuntimeIsExplicitlySynthetic() async {
        #if targetEnvironment(simulator)
            let runtime = CameraRuntime()

            let started = await runtime.start(configuration: .standard)

            XCTAssertTrue(started)
            XCTAssertEqual(runtime.snapshot.state, .running)
            XCTAssertEqual(runtime.snapshot.sourceLabel, "SIM SOURCE")
            XCTAssertTrue(runtime.snapshot.isSynthetic)

            await runtime.stop()
            XCTAssertEqual(runtime.snapshot, .idle)
        #endif
    }

    func testRealtimeRecordingSessionLifecycle() async {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-recording-\(UUID().uuidString).mp4")
        let session = GVRealtimeRecordingSession(
            outputURL: tempURL,
            size: CGSize(width: 320, height: 240),
            saveToPhotos: false
        )
        let started = session.start()
        XCTAssertTrue(started)

        guard let pixelBuffer = session.nextPixelBuffer() else {
            XCTFail("nextPixelBuffer should vend a buffer")
            return
        }
        XCTAssertEqual(CVPixelBufferGetWidth(pixelBuffer), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(pixelBuffer), 240)

        session.append(pixelBuffer, timestamp: 0.0)

        try? await Task.sleep(for: .milliseconds(100))

        let finishExpectation = expectation(description: "Session finishes")
        session.finish { result in
            switch result {
            case let .success(url):
                XCTAssertEqual(url, tempURL)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
                try? FileManager.default.removeItem(at: url)
            case let .failure(error):
                XCTFail("Recording session finish failed: \(error)")
            }
            finishExpectation.fulfill()
        }
        await fulfillment(of: [finishExpectation], timeout: 5.0)
    }

    func testAppIntentsAndShortcutsAreDefined() {
        if #available(iOS 16.0, *) {
            // The two hardware intents open the app; the composition verbs do
            // not, because they can be carried out by the workspace whenever it
            // next appears rather than by force-launching the operator into the
            // camera.
            XCTAssertTrue(CaptureStillIntent.openAppWhenRun)
            XCTAssertTrue(ToggleRecordingIntent.openAppWhenRun)
            XCTAssertFalse(UndoEditIntent.openAppWhenRun)
            XCTAssertFalse(RedoEditIntent.openAppWhenRun)
            XCTAssertFalse(SoloFocusedEffectIntent.openAppWhenRun)
            XCTAssertFalse(RemoveFocusedEffectIntent.openAppWhenRun)
            XCTAssertFalse(ToggleStackArmedIntent.openAppWhenRun)
            XCTAssertFalse(ToggleBypassIntent.openAppWhenRun)
            XCTAssertFalse(ToggleAudioReactiveIntent.openAppWhenRun)

            let effectIntent: SelectEffectIntent = {
                var intent = SelectEffectIntent()
                intent.effectName = "DATAMOSH"
                return intent
            }()
            XCTAssertEqual(effectIntent.effectName, "DATAMOSH")
        }
    }

    /// Every shortcut the provider advertises has to be a real intent, and the
    /// composition verbs have to be among them. The previous assertion pinned
    /// the count to two, which is how a set of empty stubs could look correct:
    /// adding a working shortcut would have failed the test, and removing one
    /// would not have.
    ///
    /// `AppShortcut` publishes initializers and nothing else, so the pairs it
    /// holds cannot be read back — the phrases and the intent are private to
    /// the framework. What can be checked is the half that is ours: that the
    /// provider registers a phrase set for every verb, and that every verb's
    /// intent actually posts its command instead of quietly doing nothing.
    func testShortcutProviderCoversEveryCompositionVerb() async throws {
        if #available(iOS 16.0, *) {
            XCTAssertGreaterThanOrEqual(
                GVAppShortcutsProvider.appShortcuts.count,
                10,
                "The provider registers one phrase set per verb; dropping one silently removes a voice command."
            )

            let bridge = GVIntentBridge.shared
            defer { bridge.dismissForTesting() }
            let verbs: [(String, GVIntentCommand, () async throws -> Void)] = [
                ("CaptureStillIntent", .captureStill, { _ = try await CaptureStillIntent().perform() }),
                ("ToggleRecordingIntent", .toggleRecording, { _ = try await ToggleRecordingIntent().perform() }),
                ("UndoEditIntent", .undo, { _ = try await UndoEditIntent().perform() }),
                ("RedoEditIntent", .redo, { _ = try await RedoEditIntent().perform() }),
                ("SoloFocusedEffectIntent", .soloFocused, { _ = try await SoloFocusedEffectIntent().perform() }),
                ("RemoveFocusedEffectIntent", .removeFocused, { _ = try await RemoveFocusedEffectIntent().perform() }),
                ("ToggleStackArmedIntent", .toggleStackArmed, { _ = try await ToggleStackArmedIntent().perform() }),
                ("ToggleBypassIntent", .toggleBypass, { _ = try await ToggleBypassIntent().perform() }),
                ("ToggleAudioReactiveIntent", .armAudio, { _ = try await ToggleAudioReactiveIntent().perform() }),
                ("NextShelfIntent", .nextShelf, { _ = try await NextShelfIntent().perform() })
            ]
            for (name, expected, perform) in verbs {
                bridge.dismissForTesting()
                try await perform()
                XCTAssertEqual(bridge.consume(), expected, "\(name) posted the wrong command.")
            }
        }
    }

    /// An intent posts a command rather than editing the composition, so it
    /// can run when the workspace does not exist. The bridge is that seam and
    /// it has to actually deliver: post, read back, clear.
    @MainActor
    func testIntentBridgeDeliversAndClearsItsCommand() {
        let bridge = GVIntentBridge.shared
        bridge.dismissForTesting()

        bridge.post(.soloFocused)
        XCTAssertEqual(bridge.pendingCommand, .soloFocused)
        XCTAssertEqual(bridge.consume(), .soloFocused)
        XCTAssertNil(bridge.pendingCommand, "A consumed command must not be replayed.")
    }

    func testAudioReactiveDynamics() {
        var snapshot = AudioReactiveSnapshot(rms: 0.5, bass: 0.8, mid: 0.4, treble: 0.2, peak: 0.9)
        snapshot.dominantFrequency = 440.0
        snapshot.transient = 0.75
        snapshot.sustain = 0.3
        snapshot.silence = 0.0

        let bands = snapshot.metalBands
        XCTAssertEqual(bands.x, 0.5)
        XCTAssertEqual(bands.y, 0.8)
        XCTAssertEqual(bands.z, 0.4)
        XCTAssertEqual(bands.w, 0.2)

        let dynamics = snapshot.metalDynamics
        XCTAssertEqual(dynamics.x, 0.9)
        XCTAssertEqual(dynamics.y, 0.75)
        XCTAssertEqual(dynamics.z, 0.3)
        XCTAssertEqual(dynamics.w, 0.0)
    }

    // MARK: - Camera device selection priority

    private func candidate(
        _ id: String,
        _ type: AVCaptureDevice.DeviceType
    ) -> CameraDiscovery.DeviceCandidate {
        CameraDiscovery.DeviceCandidate(uniqueID: id, deviceTypeRawValue: type.rawValue)
    }

    func testRearSelectionPrefersWideOverVirtualCameras() {
        let candidates = [
            candidate("wide", .builtInWideAngleCamera),
            candidate("dual", .builtInDualCamera),
            candidate("triple", .builtInTripleCamera),
            candidate("dualwide", .builtInDualWideCamera)
        ]

        XCTAssertEqual(
            CameraDiscovery.selectCandidate(from: candidates, position: .rear, preferredDeviceID: nil)?.uniqueID,
            "wide"
        )
    }

    func testFrontSelectionPrefersTrueDepth() {
        let candidates = [
            candidate("wide", .builtInWideAngleCamera),
            candidate("truedepth", .builtInTrueDepthCamera)
        ]

        XCTAssertEqual(
            CameraDiscovery.selectCandidate(from: candidates, position: .front, preferredDeviceID: nil)?.uniqueID,
            "truedepth"
        )
    }

    func testPreferredWideIDWinsOverPriority() {
        let candidates = [
            candidate("wide", .builtInWideAngleCamera),
            candidate("dual", .builtInDualCamera)
        ]

        XCTAssertEqual(
            CameraDiscovery.selectCandidate(from: candidates, position: .rear, preferredDeviceID: "wide")?.uniqueID,
            "wide"
        )
    }

    func testUnknownPreferredIDFallsThroughToPriority() {
        let candidates = [
            candidate("wide", .builtInWideAngleCamera),
            candidate("dual", .builtInDualCamera)
        ]

        XCTAssertEqual(
            CameraDiscovery.selectCandidate(from: candidates, position: .rear, preferredDeviceID: "ghost")?.uniqueID,
            "wide"
        )
    }

    func testSelectionWithoutSupportedCameraReturnsNil() {
        let candidates = [
            CameraDiscovery.DeviceCandidate(uniqueID: "other", deviceTypeRawValue: "OTHER"),
            CameraDiscovery.DeviceCandidate(uniqueID: "fallback", deviceTypeRawValue: "FALLBACK")
        ]

        XCTAssertNil(CameraDiscovery.selectCandidate(from: candidates, position: .front, preferredDeviceID: nil))
    }

    func testSelectionWithNoCandidatesIsNil() {
        XCTAssertNil(
            CameraDiscovery.selectCandidate(from: [], position: .rear, preferredDeviceID: nil)
        )
    }

    // MARK: - OPEN GATE format selection

    private static let openGateTargetPixels = Int64(4032) * Int64(3024)

    private func format(
        _ width: Int32,
        _ height: Int32,
        fps: ClosedRange<Double> = 1 ... 30,
        hdr: Bool = false
    ) -> CameraDiscovery.FormatCandidate {
        CameraDiscovery.FormatCandidate(
            width: width,
            height: height,
            frameRateRanges: [fps],
            supportsHDR: hdr
        )
    }

    /// The regression that held OPEN GATE out of the pickers: a Pro-class
    /// rear camera reports 4:3 stills formats far above the sensor's video
    /// readout, and picking the largest one jetsams the app.
    func testOpenGateRejectsStillsGradeSensorFormats() {
        let candidates = [
            format(1920, 1080, fps: 1 ... 60),
            format(4032, 3024, fps: 1 ... 30),
            format(8064, 6048, fps: 1 ... 12)
        ]
        let chosen = CameraDiscovery.selectOpenGateFormat(
            from: candidates,
            targetPixels: Self.openGateTargetPixels,
            requestedFrameRate: 30,
            prefersHDR: false
        )
        XCTAssertEqual(chosen, 1)
    }

    /// The old code discarded its own frame-rate filter whenever nothing
    /// matched — which at the default 60fps is always for a 4:3 format — and
    /// fell straight back to the largest format on the device.
    func testOpenGateHoldsTheCeilingWhenNoFormatMeetsTheRequestedRate() {
        let candidates = [
            format(4032, 3024, fps: 1 ... 30),
            format(8064, 6048, fps: 1 ... 12)
        ]
        let chosen = CameraDiscovery.selectOpenGateFormat(
            from: candidates,
            targetPixels: Self.openGateTargetPixels,
            requestedFrameRate: 60,
            prefersHDR: false
        )
        XCTAssertEqual(chosen, 0)
    }

    func testOpenGatePrefersFourByThreeOverWiderFormats() {
        let candidates = [
            format(3840, 2160, fps: 1 ... 60),
            format(4032, 3024, fps: 1 ... 30)
        ]
        let chosen = CameraDiscovery.selectOpenGateFormat(
            from: candidates,
            targetPixels: Self.openGateTargetPixels,
            requestedFrameRate: 30,
            prefersHDR: false
        )
        XCTAssertEqual(chosen, 1)
    }

    func testOpenGateKeepsFullSensorReadoutInsteadOfAHighRateBinnedFormat() {
        let candidates = [
            format(2016, 1512, fps: 1 ... 60),
            format(4032, 3024, fps: 1 ... 30)
        ]
        let chosen = CameraDiscovery.selectOpenGateFormat(
            from: candidates,
            targetPixels: Self.openGateTargetPixels,
            requestedFrameRate: 60,
            prefersHDR: false
        )
        XCTAssertEqual(chosen, 1)
    }

    func testOpenGateBreaksResolutionTiesOnHDRWhenRequested() {
        let candidates = [
            format(4032, 3024, fps: 1 ... 30, hdr: false),
            format(4032, 3024, fps: 1 ... 30, hdr: true)
        ]
        XCTAssertEqual(
            CameraDiscovery.selectOpenGateFormat(
                from: candidates,
                targetPixels: Self.openGateTargetPixels,
                requestedFrameRate: 30,
                prefersHDR: true
            ),
            1
        )
    }

    func testOpenGateNeverFallsBackAboveTheMemoryCeiling() {
        let candidates = [
            format(8064, 6048, fps: 1 ... 12),
            format(5760, 4320, fps: 1 ... 20)
        ]
        let chosen = CameraDiscovery.selectOpenGateFormat(
            from: candidates,
            targetPixels: Self.openGateTargetPixels,
            requestedFrameRate: 30,
            prefersHDR: false
        )
        XCTAssertNil(chosen)
    }

    func testOpenGateRejectsNonSensorAndNonVideoFormats() {
        for candidate in [format(3840, 2160), format(2016, 1512),
                          format(4032, 3024, fps: 1 ... 12), format(0, 0)]
        {
            XCTAssertNil(CameraDiscovery.selectOpenGateFormat(
                from: [candidate], targetPixels: Self.openGateTargetPixels,
                requestedFrameRate: 60, prefersHDR: false
            ))
        }
    }

    func testOpenGateSelectionWithNoFormatsIsNil() {
        XCTAssertNil(
            CameraDiscovery.selectOpenGateFormat(
                from: [],
                targetPixels: Self.openGateTargetPixels,
                requestedFrameRate: 30,
                prefersHDR: false
            )
        )
    }
}
