@testable import GreyVision
import AVFoundation
import Metal

// NOTE: several tests were removed here. They asserted against an API set
// (relighting, memoryEffect, subjectComposite, frameAverage,
// CameraSubjectIsolationParameters, GVModulationMatrix*) that exists in a
// different branch of this project, not in this source tree. They were
// failing to compile, not failing to pass. Restore them alongside the
// features, not before.
import XCTest

final class BootstrapTests: XCTestCase {
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
    func testAppRouteMovesBootWorkspaceAndBack() async {
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
        let model = AppModel(arguments: ["GreyVisionTests"], bootTelemetry: telemetry)

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
            let stillIntent = CaptureStillIntent()
            XCTAssertTrue(CaptureStillIntent.openAppWhenRun)
            _ = stillIntent

            let recordIntent = ToggleRecordingIntent()
            XCTAssertTrue(ToggleRecordingIntent.openAppWhenRun)
            _ = recordIntent

            var effectIntent = SetEffectIntent()
            effectIntent.effectName = "DATAMOSH"
            XCTAssertEqual(effectIntent.effectName, "DATAMOSH")

            let shortcuts = GVAppShortcutsProvider.appShortcuts
            XCTAssertEqual(shortcuts.count, 2)
        }
    }

    func testLastCaptureHoldsStillAndVideo() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("sample.mp4")
        let videoCapture = GVLastCapture(mediaType: .video(url: tempURL), thumbnail: nil)
        XCTAssertEqual(videoCapture, videoCapture)
        if case let .video(url) = videoCapture.mediaType {
            XCTAssertEqual(url, tempURL)
        } else {
            XCTFail("Expected video capture")
        }
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

    func testRearSelectionPrefersDualWideOverTripleDualAndWide() {
        let candidates = [
            candidate("wide", .builtInWideAngleCamera),
            candidate("dual", .builtInDualCamera),
            candidate("triple", .builtInTripleCamera),
            candidate("dualwide", .builtInDualWideCamera)
        ]

        XCTAssertEqual(
            CameraDiscovery.selectCandidate(from: candidates, position: .rear, preferredDeviceID: nil)?.uniqueID,
            "dualwide"
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

    func testPreferredIDWinsOverPriority() {
        let candidates = [
            candidate("wide", .builtInWideAngleCamera),
            candidate("ultra", .builtInUltraWideCamera)
        ]

        XCTAssertEqual(
            CameraDiscovery.selectCandidate(from: candidates, position: .rear, preferredDeviceID: "ultra")?.uniqueID,
            "ultra"
        )
    }

    func testUnknownPreferredIDFallsThroughToPriority() {
        let candidates = [
            candidate("wide", .builtInWideAngleCamera),
            candidate("tele", .builtInTelephotoCamera)
        ]

        XCTAssertEqual(
            CameraDiscovery.selectCandidate(from: candidates, position: .rear, preferredDeviceID: "ghost")?.uniqueID,
            "wide"
        )
    }

    func testSelectionWithoutPriorityMatchReturnsFirstCandidate() {
        let candidates = [
            candidate("ultra", .builtInUltraWideCamera),
            candidate("tele", .builtInTelephotoCamera)
        ]

        XCTAssertEqual(
            CameraDiscovery.selectCandidate(from: candidates, position: .front, preferredDeviceID: nil)?.uniqueID,
            "ultra"
        )
    }

    func testSelectionWithNoCandidatesIsNil() {
        XCTAssertNil(
            CameraDiscovery.selectCandidate(from: [], position: .rear, preferredDeviceID: nil)
        )
    }
}
