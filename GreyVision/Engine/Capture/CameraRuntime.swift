@preconcurrency import AVFoundation
import Combine
import Foundation
import UIKit

@MainActor
final class CameraRuntime: ObservableObject {
    @Published private(set) var snapshot = CameraRuntimeSnapshot.idle
    @Published private(set) var capabilities = CameraCapabilities.synthetic
    /// The operator's render-quality choice. Ladder definitions live in
    /// `GVRenderQuality`; this only carries the selection. Kept off the
    /// snapshot because it is a preference rather than a fact about the
    /// capture session, and because the Metal surface reads it on every
    /// SwiftUI pass to decide the refresh-rate ceiling.
    @Published var renderQuality: GVRenderQuality = .automatic

    private let controller: CameraController
    private var activeConfiguration: CaptureConfiguration?
    private var torchPulseTask: Task<Void, Never>?
    private var captureWatchdogTask: Task<Void, Never>?
    private var nativeStopContinuation: CheckedContinuation<Bool, Never>?
    private var nativeFinishedResult: Bool?
    /// The library destination handed to the sensor writer, kept so a start that
    /// never came up can be cleaned up.
    private var nativeTakeURL: URL?

    var captureSession: AVCaptureSession {
        controller.captureSession
    }

    @Published private(set) var isRecording = false
    /// When the writer came online, for the take's timecode readout. Nil while
    /// idle so the HUD cannot show a running clock over a stopped writer.
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var recordingMessage: String?
    @Published private(set) var screenshotMessage: String?
    @Published private(set) var isFrameFrozen = false
    @Published private(set) var datamoshTransport = GVDatamoshTransport()

    func sendDatamosh(_ action: GVDatamoshTransport.Action) {
        datamoshTransport.send(action)
    }

    let recordingMailbox = CameraRecordingMailbox()
    /// Where the recording transaction hears the outcome of a finished take —
    /// including one kept in the library because Photos refused it. A message
    /// string cannot carry this: two identical outcomes in a row are not an
    /// `onChange` event, and the second take would look like it never happened.
    var takeOutcomeHandler: (@MainActor (Result<GVTake, any Error>) -> Void)?
    let screenshotMailbox = CameraScreenshotMailbox()
    var latestFrameMailbox: LatestCapturedFrameMailbox {
        controller.latestFrameMailbox
    }

    /// Called by the renderer when the writer actually comes online / finishes.
    /// Forwards to the transaction so it owns the single source of truth.
    func setRecordingActive(_ active: Bool) {
        isRecording = active
        recordingStartedAt = active ? .now : nil
        if active {
            recordingMessage = "RECORD // WRITING FRAMES"
        }
    }

    func setRecordingMessage(_ message: String) {
        recordingMessage = message
    }

    /// Starts the AVFoundation sensor path used exclusively by ProRes RAW.
    /// The processed renderer remains online as a 4:2:2 preview proxy, but no
    /// demosaiced/effected frame is substituted into the RAW movie.
    func startNativeRAWRecording(codec: AVVideoCodecType) async -> Bool {
        nativeFinishedResult = nil
        // The sensor writes this file itself, so it goes to the take library
        // before recording starts rather than to tmp: a RAW take that survived
        // only until the next purge was not a take the operator could find.
        guard let outputURL = try? GVTakeArchive.shared.makeRecordingURL() else {
            recordingMessage = "RECORD // TAKE LIBRARY UNAVAILABLE"
            return false
        }
        nativeTakeURL = outputURL
        return await withCheckedContinuation { continuation in
            controller.startNativeRAWRecording(
                codec: codec,
                outputURL: outputURL,
                onStarted: { [weak self] started in
                    Task { @MainActor in
                        guard let self else {
                            continuation.resume(returning: false)
                            return
                        }
                        if started {
                            self.isRecording = true
                            self.recordingStartedAt = .now
                            self.recordingMessage = "RECORD // SENSOR RAW"
                        } else if let stale = self.nativeTakeURL {
                            try? FileManager.default.removeItem(at: stale)
                            self.nativeTakeURL = nil
                        }
                        continuation.resume(returning: started)
                    }
                },
                onFinished: { [weak self] result in
                    Task { @MainActor in
                        await self?.handleNativeRAWFinished(result)
                    }
                }
            )
        }
    }

    func stopNativeRAWRecording() async -> Bool {
        if let nativeFinishedResult {
            self.nativeFinishedResult = nil
            return nativeFinishedResult
        }
        return await withCheckedContinuation { continuation in
            nativeStopContinuation = continuation
            controller.stopNativeRAWRecording()
        }
    }

    private func handleNativeRAWFinished(_ result: NativeCaptureResult) async {
        isRecording = false
        recordingStartedAt = nil
        let filed: Bool
        switch result {
        case let .success(url):
            // Filing happens before the Photos verdict reaches the transaction,
            // so a refused permission leaves a take in the library instead of
            // deleting footage the sensor already captured.
            let take = await fileCompletedTake(url, source: .raw)
            nativeTakeURL = nil
            filed = take != nil
        case let .failure(reason):
            if let nativeTakeURL { try? FileManager.default.removeItem(at: nativeTakeURL) }
            nativeTakeURL = nil
            filed = false
            recordingMessage = "RECORD // \(reason.uppercased())"
            takeOutcomeHandler?(.failure(GVRecordingError.finishFailed(reason)))
        }
        if let continuation = nativeStopContinuation {
            nativeStopContinuation = nil
            continuation.resume(returning: filed)
        } else {
            nativeFinishedResult = filed
        }
    }

    /// Reported by the renderer when the writer could not start or the export
    /// failed, so a dead take says so instead of just not appearing in Photos.
    func reportRecordingFailure(_ reason: String) {
        isRecording = false
        recordingStartedAt = nil
        recordingMessage = "RECORD // \(reason.uppercased())"
    }

    /// The workspace capture control: asks the renderer for a photograph.
    ///
    /// The renderer holds the effect chain at full sensor resolution while this
    /// request is pending, re-renders it at that size, and resolves the chain
    /// output — camera plus every armed effect, no HUD, no scanlines, no
    /// letterbox — into a JPEG for Photos. What lands in the camera roll is the
    /// frame the operator composed, not a picture of the screen showing it.
    func takeScreenshot() {
        screenshotMessage = "PHOTO // RENDERING AT SENSOR RESOLUTION"
        screenshotMailbox.requestCapture()
        armCaptureWatchdog()
    }

    /// A shutter that is never serviced has to say so.
    ///
    /// The request lives in a mailbox that only the render loop drains, so
    /// every failure mode that is not a Metal failure — the surface fell back
    /// to a non-Metal preview, the view left the hierarchy, the renderer is
    /// paused — looks identical from here: a button that flashes and no
    /// photograph. Left alone that is the worst possible outcome, because
    /// nothing on screen distinguishes it from a capture in progress.
    ///
    /// The renderer overwrites this the moment it takes the frame, and again
    /// when the save resolves, so the watchdog only ever fires when nobody
    /// else has spoken.
    private func armCaptureWatchdog() {
        captureWatchdogTask?.cancel()
        captureWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            guard self.screenshotMessage == "PHOTO // RENDERING AT SENSOR RESOLUTION" else { return }
            self.screenshotMessage = "PHOTO // RENDERER DID NOT RESPOND"
        }
    }

    /// Called by the renderer when the capture is saved or failed.
    func setScreenshotMessage(_ message: String) {
        screenshotMessage = message
        // Any word from the renderer means the request was serviced, so the
        // watchdog has nothing left to say.
        if message != "PHOTO // RENDERING AT SENSOR RESOLUTION" {
            captureWatchdogTask?.cancel()
        }
    }

    var deviceTelemetryMailbox: CameraDeviceTelemetryMailbox {
        controller.deviceTelemetryMailbox
    }

    init() {
        controller = CameraController()
        controller.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.consume(event)
            }
        }
        controller.setAudioHandler { [weak self] sampleBuffer in
            self?.recordingMailbox.appendAudio(sampleBuffer)
        }
        // The live camera's take is written inside the render loop, so its file
        // URL has no path back to the runtime except through this mailbox, which
        // the runtime already owns — and without it a normal recording would
        // never be filed or exported.
        recordingMailbox.setTakeSavedHandler { [weak self] url in
            Task { @MainActor [weak self] in
                await self?.fileCompletedTake(url, source: .camera)
            }
        }
    }

    /// Files a finished movie in the take library, then attempts the Photos
    /// export. The library write comes first: a take that cannot be exported is
    /// still a take, and an export that never runs because the app was killed in
    /// between leaves a pending record the library can retry.
    @discardableResult
    private func fileCompletedTake(_ url: URL, source: GVTake.Source) async -> GVTake? {
        recordingMessage = "RECORD // FILING TAKE"
        do {
            let take = try await GVTakeArchive.shared.completeRecording(at: url, source: source, exporter: GVSystemPhotosExporter())
            recordingMessage = take.completionMessage
            takeOutcomeHandler?(.success(take))
            if take.photosStatus == .failed, let reason = take.photosError {
                GVLog.recording.error("Photos export failed for take \(take.id, privacy: .public): \(reason, privacy: .public)")
            }
            return take
        } catch {
            recordingMessage = "RECORD // TAKE COULD NOT BE FILED"
            takeOutcomeHandler?(.failure(error))
            GVLog.recording.error("Take filing failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    @discardableResult
    func start(configuration: CaptureConfiguration) async -> Bool {
        activeConfiguration = configuration
        isFrameFrozen = false
        datamoshTransport.send(.reset)
        torchPulseTask?.cancel()
        torchPulseTask = nil
        if snapshot.torchEnabled {
            snapshot.torchEnabled = false
            controller.setTorchEnabled(false)
        }
        snapshot.position = configuration.position
        snapshot.errorMessage = nil
        snapshot.interruptionReason = nil

        #if targetEnvironment(simulator)
            capabilities = .synthetic
            snapshot = CameraRuntimeSnapshot(
                state: .running,
                sourceLabel: "SIM SOURCE",
                formatLabel: "\(configuration.dimensions.label) / \(configuration.framesPerSecond) FPS",
                deviceID: "sim.synthetic.v1",
                deviceType: "DETERMINISTIC",
                position: configuration.position,
                framesPerSecond: configuration.framesPerSecond,
                requestedVideoCodec: configuration.videoCodec,
                availableVideoCodecs: [],
                isRequestedVideoCodecAvailable: false,
                codecAvailabilityReason: "SIMULATOR CANNOT VERIFY HARDWARE CODECS",
                isSynthetic: true,
                // The synthetic source claims a real sensor format rather than
                // mirroring the viewfinder. Deriving its size from the drawable
                // meant the simulator could never demonstrate anything that
                // depends on source resolution — including a photograph taken
                // at sensor resolution, which came out the same size as the
                // screen it was taken from.
                sourceDimensions: configuration.dimensions,
                hdrEnabled: false,
                zoom: 1,
                minimumZoom: 1,
                maximumZoom: 1,
                exposureBias: 0,
                minimumExposureBias: 0,
                maximumExposureBias: 0,
                torchAvailable: false,
                torchEnabled: false,
                whiteBalanceLocked: false,
                interruptionReason: nil,
                errorMessage: nil
            )
            GVLog.capture.notice("Deterministic simulator camera source started")
            return true
        #else
            snapshot.state = .requestingPermission
            guard await requestCameraPermission() else {
                snapshot.state = .denied
                snapshot.sourceLabel = "PERMISSION DENIED"
                snapshot.errorMessage = "Camera permission is required for live capture."
                return false
            }
            guard !Task.isCancelled else { return false }

            let microphoneGranted = await requestMicrophonePermission()
            if !microphoneGranted {
                GVLog.capture.warning("Microphone permission denied; recording will be video-only")
            }
            guard !Task.isCancelled else { return false }

            snapshot.state = .configuring
            do {
                refreshVideoRotation()
                let info = try await controller.start(configuration: configuration)
                guard !Task.isCancelled else {
                    await controller.stop()
                    return false
                }
                capabilities = info.capabilities
                snapshot = snapshot(from: info)
                refreshVideoRotation()
                return true
            } catch {
                snapshot.state = .failed
                snapshot.sourceLabel = "CAMERA FAILURE"
                snapshot.errorMessage = error.localizedDescription
                return false
            }
        #endif
    }

    func stop() async {
        #if !targetEnvironment(simulator)
            await controller.stop()
        #endif
        activeConfiguration = nil
        isFrameFrozen = false
        datamoshTransport.send(.reset)
        torchPulseTask?.cancel()
        torchPulseTask = nil
        snapshot = .idle
    }

    func stopSoon() {
        #if !targetEnvironment(simulator)
            controller.stopSoon()
        #endif
        activeConfiguration = nil
        isFrameFrozen = false
        datamoshTransport.send(.reset)
        torchPulseTask?.cancel()
        torchPulseTask = nil
        snapshot = .idle
    }

    func setFrameHandler(_ handler: (@Sendable (CapturedFrame) -> Void)?) {
        controller.setFrameHandler(handler)
    }

    func setZoom(_ zoom: Double) {
        guard !snapshot.isSynthetic else { return }
        let clamped = min(max(zoom, snapshot.minimumZoom), snapshot.maximumZoom)
        guard clamped != snapshot.zoom else { return }
        snapshot.zoom = clamped
        controller.setZoom(clamped)
    }

    /// Steps to the next lens stop, wrapping back to the widest. Returns the
    /// label of the lens now in use, or nil when there is only one.
    @discardableResult
    func cycleLens() -> String? {
        let stops = snapshot.lensZoomFactors
        guard stops.count > 1 else { return nil }
        let next = stops[(snapshot.currentLensIndex + 1) % stops.count]
        setZoom(next)
        return snapshot.lensLabel(for: next)
    }

    func setExposureBias(_ bias: Double) {
        guard !snapshot.isSynthetic else { return }
        let clamped = min(max(bias, snapshot.minimumExposureBias), snapshot.maximumExposureBias)
        guard clamped != snapshot.exposureBias else { return }
        snapshot.exposureBias = clamped
        controller.setExposureBias(clamped)
    }

    func focus(at devicePoint: CGPoint) {
        guard snapshot.state == .running, !snapshot.isSynthetic else { return }
        controller.focus(at: devicePoint)
    }

    /// Manual exposure, driven from the telemetry strip and the side rail.
    ///
    /// These leave the device in custom exposure mode. `resumeAutoExposure()`
    /// is the way back, and the strip surfaces it as a long press.
    func setISO(_ iso: Double) {
        guard snapshot.state == .running, !snapshot.isSynthetic else { return }
        snapshot.exposureLocked = true
        controller.setISO(Float(iso))
    }

    func setShutterDenominator(_ denominator: Int) {
        guard snapshot.state == .running, !snapshot.isSynthetic else { return }
        snapshot.exposureLocked = true
        controller.setShutterDenominator(denominator)
    }

    func setWhiteBalanceKelvin(_ kelvin: Int) {
        guard snapshot.state == .running, !snapshot.isSynthetic else { return }
        controller.setWhiteBalanceKelvin(kelvin)
    }

    /// Hands metering back to the device.
    ///
    /// Was reachable from nowhere. `setISO` and `setShutterDenominator` both
    /// drop the device into custom exposure, and until this was wired the only
    /// way out of a manual exposure was restarting the engine — which is not a
    /// thing an operator should have to discover.
    func resumeAutoExposure() {
        guard snapshot.state == .running, !snapshot.isSynthetic else { return }
        snapshot.whiteBalanceLocked = false
        snapshot.exposureLocked = false
        controller.resumeAutoExposure()
    }

    func setTorchEnabled(_ enabled: Bool) {
        guard snapshot.torchAvailable, !snapshot.isSynthetic else { return }
        guard enabled != snapshot.torchEnabled else { return }
        snapshot.torchEnabled = enabled
        controller.setTorchEnabled(enabled)
    }

    /// A short torch burst for an intentional in-camera flash, without adding
    /// a persistent light mode to the compact camera deck.
    func pulseTorch() {
        guard snapshot.torchAvailable, !snapshot.isSynthetic else { return }
        torchPulseTask?.cancel()
        snapshot.torchEnabled = true
        controller.setTorchEnabled(true)
        torchPulseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.snapshot.torchEnabled = false
            self?.controller.setTorchEnabled(false)
        }
    }

    /// Holds the last rendered frame until the operator releases it from the
    /// explicit camera control. This replaces the undiscoverable hold gesture.
    func toggleFrameFreeze() {
        guard snapshot.state == .running else { return }
        isFrameFrozen.toggle()
    }

    func setFocusLocked(_ locked: Bool) {
        guard snapshot.state == .running, !snapshot.isSynthetic else { return }
        guard locked != snapshot.focusLocked else { return }
        snapshot.focusLocked = locked
        controller.setFocusLocked(locked)
    }

    /// Manual lens drive for rack-focus pulls. Marks focus as operator-owned,
    /// same contract as ISO/shutter.
    func setLensPosition(_ value: Float) {
        guard snapshot.state == .running, !snapshot.isSynthetic else { return }
        snapshot.focusLocked = true
        controller.setLensPosition(value)
    }

    /// Current lens position from the telemetry mailbox, when fresh.
    var liveLensPosition: Float? {
        let telemetry = deviceTelemetryMailbox.latest
        return telemetry.isValid ? telemetry.lensPosition : nil
    }

    func setWhiteBalanceLocked(_ locked: Bool) {
        guard snapshot.state == .running, !snapshot.isSynthetic else { return }
        guard locked != snapshot.whiteBalanceLocked else { return }
        snapshot.whiteBalanceLocked = locked
        controller.setWhiteBalanceLocked(locked)
    }

    func refreshVideoRotation(_ requestedOrientation: UIInterfaceOrientation? = nil) {
        guard !snapshot.isSynthetic else { return }
        let interfaceOrientation = requestedOrientation ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .interfaceOrientation ?? .portrait

        let rotation: (CGFloat, CapturedFrameOrientation)? = switch interfaceOrientation {
        case .portrait:
            (90, .portrait)
        case .portraitUpsideDown:
            (270, .portraitUpsideDown)
        // UIInterfaceOrientation is expressed from the viewer's perspective,
        // while AVCaptureConnection rotates from the camera sensor. The two
        // landscape cases are opposite; using the matching case flips the feed.
        case .landscapeLeft:
            (180, .landscapeLeft)
        case .landscapeRight:
            (0, .landscapeRight)
        default:
            nil
        }
        guard let rotation else { return }
        controller.updateVideoRotation(angle: rotation.0, orientation: rotation.1)
    }

    private func snapshot(from info: ActiveCameraInfo) -> CameraRuntimeSnapshot {
        let codecAvailable = info.availableVideoCodecs.contains(info.requestedVideoCodec)
        return CameraRuntimeSnapshot(
            state: .running,
            sourceLabel: info.deviceName.uppercased(),
            formatLabel: "\(info.dimensions.label) / \(info.framesPerSecond) FPS",
            deviceID: info.deviceID,
            deviceType: info.deviceType.uppercased(),
            position: info.position,
            framesPerSecond: info.framesPerSecond,
            requestedVideoCodec: info.requestedVideoCodec,
            availableVideoCodecs: info.availableVideoCodecs,
            isRequestedVideoCodecAvailable: codecAvailable,
            codecAvailabilityReason: codecAvailable ? nil : "ACTIVE FORMAT DOES NOT ADVERTISE \(info.requestedVideoCodec.rawValue)",
            isSynthetic: false,
            sourceDimensions: info.dimensions,
            hdrEnabled: info.hdrEnabled,
            zoom: 1,
            minimumZoom: info.minimumZoom,
            maximumZoom: info.maximumZoom,
            exposureBias: 0,
            minimumExposureBias: info.minimumExposureBias,
            maximumExposureBias: info.maximumExposureBias,
            torchAvailable: info.torchAvailable,
            torchEnabled: false,
            whiteBalanceLocked: info.whiteBalanceLocked,
            interruptionReason: nil,
            errorMessage: nil,
            lensZoomFactors: info.lensZoomFactors,
            displayZoomMultiplier: info.displayZoomMultiplier
        )
    }

    private func consume(_ event: CameraEvent) {
        switch event {
        case let .interrupted(reason):
            snapshot.state = .interrupted
            snapshot.interruptionReason = reason
        case .resumed:
            snapshot.state = .running
            snapshot.interruptionReason = nil
        case .mediaServicesReset:
            snapshot.state = .running
            snapshot.interruptionReason = nil
            GVLog.capture.notice("Media services reset; capture session restarted")
        case let .failed(message):
            snapshot.state = .failed
            snapshot.errorMessage = message
        }
    }

    private func requestCameraPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
