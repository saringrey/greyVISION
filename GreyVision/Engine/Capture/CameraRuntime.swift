@preconcurrency import AVFoundation
import Combine
import Foundation
import UIKit

@MainActor
final class CameraRuntime: ObservableObject {
    @Published private(set) var snapshot = CameraRuntimeSnapshot.idle
    @Published private(set) var capabilities = CameraCapabilities.synthetic

    private let controller: CameraController
    private var activeConfiguration: CaptureConfiguration?

    var captureSession: AVCaptureSession {
        controller.captureSession
    }

    @Published private(set) var isRecording = false
    /// When the writer came online, for the take's timecode readout. Nil while
    /// idle so the HUD cannot show a running clock over a stopped writer.
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var recordingMessage: String?
    @Published private(set) var screenshotMessage: String?

    let recordingMailbox = CameraRecordingMailbox()
    let screenshotMailbox = CameraScreenshotMailbox()

    var latestFrameMailbox: LatestCapturedFrameMailbox {
        controller.latestFrameMailbox
    }

    /// The workspace record control: starts the writer (it boots on the
    /// renderer's next frame with the real effect size) or stops and exports
    /// the clip to Photos.
    func toggleRecording() {
        if isRecording || recordingMailbox.isStartPending {
            recordingMailbox.requestStop()
        } else {
            let codec = snapshot.requestedVideoCodec.avVideoCodecType ?? .hevc
            let fps = snapshot.framesPerSecond
            recordingMailbox.requestStart(codecRawValue: codec.rawValue, fps: fps)
        }
    }

    /// Called by the renderer when the writer actually comes online / finishes.
    ///
    /// The button reflects the writer, not the tap. Latching the control on tap
    /// would show a take in progress during the frame or two before the writer
    /// resolves the real effect size, and would keep showing one if it failed.
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
        if let cgImage = image.cgImage {
            recordCapture(still: cgImage)
        }
        GVScreenCapture.save(image) { [weak self] message in
            Task { @MainActor in self?.screenshotMessage = message }
        }
    }

    @Published private(set) var lastCapture: GVLastCapture?

    func recordCapture(still image: CGImage) {
        lastCapture = GVLastCapture(mediaType: .still(image: image), thumbnail: UIImage(cgImage: image))
    }

    func recordCapture(video url: URL) {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil)
        let thumbnail = cgImage.map { UIImage(cgImage: $0) }
        lastCapture = GVLastCapture(mediaType: .video(url: url), thumbnail: thumbnail)
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
    }

    @discardableResult
    func start(configuration: CaptureConfiguration) async -> Bool {
        activeConfiguration = configuration
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
                availableLensCount: 0,
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

            snapshot.state = .configuring
            do {
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
        snapshot = .idle
    }

    func stopSoon() {
        #if !targetEnvironment(simulator)
            controller.stopSoon()
        #endif
        activeConfiguration = nil
        snapshot = .idle
    }

    func setFrameHandler(_ handler: (@Sendable (CapturedFrame) -> Void)?) {
        controller.setFrameHandler(handler)
    }

    func setZoom(_ zoom: Double) {
        guard !snapshot.isSynthetic else { return }
        let clamped = min(max(zoom, snapshot.minimumZoom), snapshot.maximumZoom)
        snapshot.zoom = clamped
        controller.setZoom(clamped)
    }

    func setExposureBias(_ bias: Double) {
        guard !snapshot.isSynthetic else { return }
        let clamped = min(max(bias, snapshot.minimumExposureBias), snapshot.maximumExposureBias)
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
        snapshot.torchEnabled = enabled
        controller.setTorchEnabled(enabled)
    }

    func setFocusLocked(_ locked: Bool) {
        guard snapshot.state == .running, !snapshot.isSynthetic else { return }
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
        snapshot.whiteBalanceLocked = locked
        controller.setWhiteBalanceLocked(locked)
    }

    func cycleLens() async -> Bool {
        guard var configuration = activeConfiguration else { return false }
        let lenses = capabilities.devices(at: configuration.position)
        guard lenses.count > 1 else { return false }
        let currentIndex = lenses.firstIndex { $0.id == snapshot.deviceID } ?? 0
        let followingIndex = lenses.index(after: currentIndex)
        let nextIndex = followingIndex == lenses.endIndex ? lenses.startIndex : followingIndex
        configuration.preferredDeviceID = lenses[nextIndex].id
        return await start(configuration: configuration)
    }

    func refreshVideoRotation() {
        guard !snapshot.isSynthetic else { return }
        let interfaceOrientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .interfaceOrientation ?? .portrait

        let rotation: (CGFloat, CapturedFrameOrientation) = switch interfaceOrientation {
        case .portrait:
            (90, .portrait)
        case .portraitUpsideDown:
            (270, .portraitUpsideDown)
        case .landscapeLeft:
            (0, .landscapeLeft)
        case .landscapeRight:
            (180, .landscapeRight)
        default:
            (90, .portrait)
        }
        controller.updateVideoRotation(angle: rotation.0, orientation: rotation.1)
    }

    private func snapshot(from info: ActiveCameraInfo) -> CameraRuntimeSnapshot {
        CameraRuntimeSnapshot(
            state: .running,
            sourceLabel: info.deviceName.uppercased(),
            formatLabel: "\(info.dimensions.label) / \(info.framesPerSecond) FPS",
            deviceID: info.deviceID,
            deviceType: info.deviceType.uppercased(),
            position: info.position,
            framesPerSecond: info.framesPerSecond,
            requestedVideoCodec: info.requestedVideoCodec,
            availableVideoCodecs: info.availableVideoCodecs,
            isRequestedVideoCodecAvailable: info.availableVideoCodecs.contains(info.requestedVideoCodec),
            codecAvailabilityReason: info.availableVideoCodecs.contains(info.requestedVideoCodec)
                ? nil
                : "ACTIVE FORMAT DOES NOT ADVERTISE \(info.requestedVideoCodec.rawValue)",
            isSynthetic: false,
            hdrEnabled: info.hdrEnabled,
            // Mirrors the controller's widest-stop default.
            zoom: info.minimumZoom < 1.0 ? 0.5 : 1,
            minimumZoom: info.minimumZoom,
            maximumZoom: info.maximumZoom,
            exposureBias: 0,
            minimumExposureBias: info.minimumExposureBias,
            maximumExposureBias: info.maximumExposureBias,
            torchAvailable: info.torchAvailable,
            torchEnabled: false,
            whiteBalanceLocked: info.whiteBalanceLocked,
            availableLensCount: info.capabilities.devices(at: info.position).count,
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
}
