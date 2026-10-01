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
    private var nativeStopContinuation: CheckedContinuation<Bool, Never>?
    private var nativeFinishedResult: Bool?

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

    /// The most recent take this session wrote and saved. The timeline scrub
    /// preview reads a frame out of this file. It is a session-lifetime value, not
    /// a permanent library reference: a relaunch legitimately starts with none, and
    /// the UI has to say so rather than show an empty well.
    @Published private(set) var lastCompletedTake: URL?

    let recordingMailbox = CameraRecordingMailbox()
    let screenshotMailbox = CameraScreenshotMailbox()
    /// One pending scrub-preview frame. A mailbox rather than a published value
    /// because the render thread and the main actor must not share observable state,
    /// for the same reason `recordingMailbox` exists.
    let previewMailbox = CameraPreviewMailbox()
    /// The viewfinder is showing a frame out of the recorded take instead of the
    /// camera. Published because the badge is SwiftUI; it follows the same window the
    /// renderer uses, so the label and the picture always describe one state.
    @Published private(set) var isShowingTakePreview = false

    private var previewReader: GVTakeFrameReader?
    private var previewReaderTake: URL?
    private var previewExpiryTask: Task<Void, Never>?

    var latestFrameMailbox: LatestCapturedFrameMailbox {
        controller.latestFrameMailbox
    }

    /// Recording is now delegated to GVRecordingTransaction.
    /// This method is kept for any legacy callers but does nothing.
    @available(*, deprecated, message: "Use GVRecordingTransaction.toggleRecording instead")
    func toggleRecording() {
        // No-op: recording is owned by GVRecordingTransaction
    }

    /// Records the take that just finished, for anything that has to read it back.
    func noteCompletedTake(_ url: URL) {
        lastCompletedTake = url
    }

    /// Asks for the graded frame at a playhead position.
    ///
    /// Fire-and-forget: the frame lands in `previewMailbox` and the render loop
    /// substitutes it for a camera sample. Each request opens a reader walk from a
    /// sync sample, so the caller quantises how often this is called; the reader
    /// coalesces whatever arrives anyway.
    func requestPreviewFrame(at seconds: TimeInterval) {
        guard let take = lastCompletedTake else { return }
        // One reader per take. It holds nothing but the URL and its coalescing
        // state, so replacing it when a new take lands is enough — and building one
        // per request would throw away the coalescing that keeps a drag from
        // queueing decodes behind each other.
        if previewReaderTake != take {
            previewReader = GVTakeFrameReader(url: take)
            previewReaderTake = take
        }
        guard let reader = previewReader else { return }

        isShowingTakePreview = true
        previewExpiryTask?.cancel()
        previewExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(CameraPreviewMailbox.visibleFor))
            guard let self, !Task.isCancelled else { return }
            self.isShowingTakePreview = false
        }

        Task { [weak self] in
            guard let buffer = await reader.frame(at: seconds) else { return }
            self?.previewMailbox.publish(buffer)
        }
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
        return await withCheckedContinuation { continuation in
            controller.startNativeRAWRecording(
                codec: codec,
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
        let saved: Bool
        switch result {
        case let .success(url):
            saved = await withCheckedContinuation { continuation in
                GVPhotoLibrary.saveVideo(at: url) { didSave in
                    continuation.resume(returning: didSave)
                }
            }
            // The sensor owns this file, so this is where the take becomes
            // addressable for the session. A save Photos refused is not a take.
            if saved {
                noteCompletedTake(url)
            }
            recordingMessage = saved ? "RECORD // RAW SAVED TO PHOTOS" : "RECORD // RAW SAVE FAILED"
        case let .failure(reason):
            saved = false
            recordingMessage = "RECORD // \(reason.uppercased())"
        }
        if let continuation = nativeStopContinuation {
            nativeStopContinuation = nil
            continuation.resume(returning: saved)
        } else {
            nativeFinishedResult = saved
        }
    }

    /// Reported by the renderer when the writer could not start or the export
    /// failed, so a dead take says so instead of just not appearing in Photos.
    func reportRecordingFailure(_ reason: String) {
        isRecording = false
        recordingStartedAt = nil
        recordingMessage = "RECORD // \(reason.uppercased())"
    }

    /// The workspace screenshot control: requests a capture of the next
    /// rendered frame and exports the PNG to Photos when the GPU delivers it.
    /// Captures the whole window, interface included.
    ///
    /// The renderer's own still path reads the Metal texture, which is the
    /// camera and effects with no chrome over them. Snapshotting the window
    /// composites the live layer together with the SwiftUI interface, so what
    /// lands in Photos is what was on screen.
    func takeScreenshot() {
        screenshotMessage = "SCREENSHOT // CAPTURING"
        guard let window = Self.keyWindow else {
            // No window to read: fall back to the clean render rather than
            // failing outright.
            screenshotMailbox.requestCapture()
            return
        }

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            // `afterScreenUpdates` is required for the Metal layer to be
            // present; without it the camera reads back black.
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        GVScreenCapture.save(image) { [weak self] message in
            Task { @MainActor in self?.screenshotMessage = message }
        }
    }

    private static var keyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        if #available(iOS 15.0, *) {
            if let window = activeScene?.keyWindow {
                return window
            }
        }
        return activeScene?.windows.first { $0.isKeyWindow }
    }

    /// Called by the renderer when the capture is saved or failed.
    func setScreenshotMessage(_ message: String) {
        screenshotMessage = message
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
        // the runtime already owns. Without it `lastCompletedTake` only ever
        // fills in on the RAW and objects paths, and the timeline scrub preview
        // has nothing to open after a normal recording.
        recordingMailbox.setTakeSavedHandler { [weak self] url in
            Task { @MainActor [weak self] in
                self?.noteCompletedTake(url)
            }
        }
    }

    @discardableResult
    func start(configuration: CaptureConfiguration) async -> Bool {
        activeConfiguration = configuration
        isFrameFrozen = false
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
            errorMessage: nil
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
