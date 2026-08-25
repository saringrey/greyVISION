@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

final class CameraController: NSObject, @unchecked Sendable, FrameSource {
    let sourceID = "avfoundation.camera"
    let captureSession = AVCaptureSession()
    let latestFrameMailbox = LatestCapturedFrameMailbox()
    let deviceTelemetryMailbox = CameraDeviceTelemetryMailbox()

    private let sessionQueue = DispatchQueue(label: "com.saringrey.greyvision.capture.session", qos: .userInitiated)
    private let outputQueue = DispatchQueue(label: "com.saringrey.greyvision.camera.output", qos: .userInteractive)
    
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let handlerLock = NSLock()
    private let metadataLock = NSLock()

    private var activeDevice: AVCaptureDevice?
    private var notificationTokens: [NSObjectProtocol] = []
    private var frameHandler: (@Sendable (CapturedFrame) -> Void)?
    private var eventHandler: (@Sendable (CameraEvent) -> Void)?
    private var audioHandler: (@Sendable (CMSampleBuffer) -> Void)?
    private var frameOrientation = CapturedFrameOrientation.portrait
    /// Read on the output queue for HUD telemetry; guarded by `metadataLock`.
    private var telemetryDevice: AVCaptureDevice?
    private var telemetryFrameCounter: UInt64 = 0

    override init() {
        super.init()
        captureSession.automaticallyConfiguresCaptureDeviceForWideColor = false
        videoOutput.alwaysDiscardsLateVideoFrames = true
    }

    func setFrameHandler(_ handler: (@Sendable (CapturedFrame) -> Void)?) {
        handlerLock.withLock {
            frameHandler = handler
        }
    }

    func setEventHandler(_ handler: (@Sendable (CameraEvent) -> Void)?) {
        handlerLock.withLock {
            eventHandler = handler
        }
    }

    func setAudioHandler(_ handler: (@Sendable (CMSampleBuffer) -> Void)?) {
        handlerLock.withLock {
            audioHandler = handler
        }
    }

    func start(configuration: CaptureConfiguration) async throws -> ActiveCameraInfo {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                do {
                    if captureSession.isRunning {
                        captureSession.stopRunning()
                    }
                    removeNotificationObservers()
                    let activeInfo = try configure(configuration: configuration)
                    installNotificationObservers()
                    captureSession.startRunning()
                    continuation.resume(returning: activeInfo)
                } catch {
                    GVLog.capture.error("Camera start failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                tearDownSession()
                continuation.resume()
            }
        }
    }

    func stopSoon() {
        sessionQueue.async { [weak self] in
            self?.tearDownSession()
        }
    }

    func setZoom(_ requestedZoom: Double) {
        sessionQueue.async { [weak self] in
            guard let self, let activeDevice else { return }
            do {
                try activeDevice.lockForConfiguration()
                defer { activeDevice.unlockForConfiguration() }
                let clamped = min(
                    max(CGFloat(requestedZoom), activeDevice.minAvailableVideoZoomFactor),
                    activeDevice.maxAvailableVideoZoomFactor
                )
                activeDevice.ramp(toVideoZoomFactor: clamped, withRate: 6)
            } catch {
                emit(.failed(message: "Zoom configuration failed: \(error.localizedDescription)"))
            }
        }
    }

    func setExposureBias(_ requestedBias: Double) {
        sessionQueue.async { [weak self] in
            guard let self, let activeDevice else { return }
            do {
                try activeDevice.lockForConfiguration()
                defer { activeDevice.unlockForConfiguration() }
                let clamped = min(
                    max(Float(requestedBias), activeDevice.minExposureTargetBias),
                    activeDevice.maxExposureTargetBias
                )
                activeDevice.setExposureTargetBias(clamped)
            } catch {
                emit(.failed(message: "Exposure configuration failed: \(error.localizedDescription)"))
            }
        }
    }

    /// Drives ISO directly, holding the current shutter.
    ///
    /// This is what makes the telemetry strip's ISO field a control rather
    /// than a readout. Setting ISO requires custom exposure mode, so the
    /// device leaves continuous auto-exposure — `resumeAutoExposure()` puts it
    /// back. Clamped against the active format, which is the only place that
    /// knows the real range.
    func setISO(_ requested: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let activeDevice else { return }
            guard activeDevice.isExposureModeSupported(.custom) else { return }
            do {
                try activeDevice.lockForConfiguration()
                defer { activeDevice.unlockForConfiguration() }
                let format = activeDevice.activeFormat
                let clamped = min(max(requested, format.minISO), format.maxISO)
                activeDevice.setExposureModeCustom(
                    duration: AVCaptureDevice.currentExposureDuration,
                    iso: clamped
                )
            } catch {
                emit(.failed(message: "ISO configuration failed: \(error.localizedDescription)"))
            }
        }
    }

    /// Shutter as the denominator of 1/x, holding the current ISO.
    func setShutterDenominator(_ denominator: Int) {
        sessionQueue.async { [weak self] in
            guard let self, let activeDevice, denominator > 0 else { return }
            guard activeDevice.isExposureModeSupported(.custom) else { return }
            do {
                try activeDevice.lockForConfiguration()
                defer { activeDevice.unlockForConfiguration() }
                let format = activeDevice.activeFormat
                let requested = CMTime(value: 1, timescale: CMTimeScale(denominator))
                let clamped = CMTimeClampToRange(
                    requested,
                    range: CMTimeRange(
                        start: format.minExposureDuration,
                        end: format.maxExposureDuration
                    )
                )
                activeDevice.setExposureModeCustom(duration: clamped, iso: AVCaptureDevice.currentISO)
            } catch {
                emit(.failed(message: "Shutter configuration failed: \(error.localizedDescription)"))
            }
        }
    }

    /// White balance by colour temperature.
    ///
    /// Gains are clamped before being applied: `deviceWhiteBalanceGains(for:)`
    /// will happily return gains outside the device's supported range for
    /// extreme temperatures, and setting those throws.
    func setWhiteBalanceKelvin(_ kelvin: Int) {
        sessionQueue.async { [weak self] in
            guard let self, let activeDevice else { return }
            guard activeDevice.isWhiteBalanceModeSupported(.locked) else { return }
            do {
                try activeDevice.lockForConfiguration()
                defer { activeDevice.unlockForConfiguration() }
                let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                    temperature: Float(kelvin),
                    tint: 0
                )
                var gains = activeDevice.deviceWhiteBalanceGains(for: values)
                let maximum = activeDevice.maxWhiteBalanceGain
                gains.redGain = min(max(gains.redGain, 1), maximum)
                gains.greenGain = min(max(gains.greenGain, 1), maximum)
                gains.blueGain = min(max(gains.blueGain, 1), maximum)
                activeDevice.setWhiteBalanceModeLocked(with: gains)
            } catch {
                emit(.failed(message: "White balance configuration failed: \(error.localizedDescription)"))
            }
        }
    }

    /// Hands exposure back to the camera.
    func resumeAutoExposure() {
        sessionQueue.async { [weak self] in
            guard let self, let activeDevice else { return }
            do {
                try activeDevice.lockForConfiguration()
                defer { activeDevice.unlockForConfiguration() }
                if activeDevice.isExposureModeSupported(.continuousAutoExposure) {
                    activeDevice.exposureMode = .continuousAutoExposure
                }
                if activeDevice.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    activeDevice.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            } catch {
                emit(.failed(message: "Auto exposure restore failed: \(error.localizedDescription)"))
            }
        }
    }

    /// Locks or releases autofocus.
    ///
    /// `.locked` freezes the lens where it is; releasing restores continuous
    /// autofocus rather than leaving the device in one-shot mode.
    func setFocusLocked(_ locked: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let activeDevice else { return }
            do {
                try activeDevice.lockForConfiguration()
                defer { activeDevice.unlockForConfiguration() }
                let mode: AVCaptureDevice.FocusMode = locked ? .locked : .continuousAutoFocus
                if activeDevice.isFocusModeSupported(mode) {
                    activeDevice.focusMode = mode
                }
            } catch {
                emit(.failed(message: "Focus lock failed: \(error.localizedDescription)"))
            }
        }
    }

    /// Drives the lens to an absolute position (0 near ... 1 far).
    ///
    /// Forces `.locked` focus first — a manual pull makes no sense while
    /// continuous autofocus is fighting the driver.
    func setLensPosition(_ value: Float) {
        sessionQueue.async { [weak self] in
            guard let self, let activeDevice else { return }
            guard activeDevice.isFocusModeSupported(.locked) else { return }
            do {
                try activeDevice.lockForConfiguration()
                defer { activeDevice.unlockForConfiguration() }
                if activeDevice.focusMode != .locked {
                    activeDevice.focusMode = .locked
                }
                // lensPosition itself is read-only; the only write path is
                // the locked-mode setter, which needs device support.
                if activeDevice.isLockingFocusWithCustomLensPositionSupported {
                    activeDevice.setFocusModeLocked(
                        lensPosition: max(min(value, 1), 0),
                        completionHandler: nil
                    )
                }
            } catch {
                emit(.failed(message: "Lens position failed: \(error.localizedDescription)"))
            }
        }
    }

    func focus(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let activeDevice else { return }
            do {
                try activeDevice.lockForConfiguration()
                defer { activeDevice.unlockForConfiguration() }

                if activeDevice.isFocusPointOfInterestSupported {
                    activeDevice.focusPointOfInterest = devicePoint
                    if activeDevice.isFocusModeSupported(.autoFocus) {
                        activeDevice.focusMode = .autoFocus
                    }
                }
                if activeDevice.isExposurePointOfInterestSupported {
                    activeDevice.exposurePointOfInterest = devicePoint
                    if activeDevice.isExposureModeSupported(.continuousAutoExposure) {
                        activeDevice.exposureMode = .continuousAutoExposure
                    }
                }
            } catch {
                emit(.failed(message: "Focus configuration failed: \(error.localizedDescription)"))
            }
        }
    }

    func setTorchEnabled(_ enabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let activeDevice, activeDevice.hasTorch else { return }
            do {
                try activeDevice.lockForConfiguration()
                defer { activeDevice.unlockForConfiguration() }
                if enabled {
                    try activeDevice.setTorchModeOn(level: min(AVCaptureDevice.maxAvailableTorchLevel, 0.65))
                } else {
                    activeDevice.torchMode = .off
                }
            } catch {
                emit(.failed(message: "Torch configuration failed: \(error.localizedDescription)"))
            }
        }
    }

    func setWhiteBalanceLocked(_ locked: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let activeDevice else { return }
            do {
                try activeDevice.lockForConfiguration()
                defer { activeDevice.unlockForConfiguration() }
                let requestedMode: AVCaptureDevice.WhiteBalanceMode = locked ? .locked : .continuousAutoWhiteBalance
                if activeDevice.isWhiteBalanceModeSupported(requestedMode) {
                    activeDevice.whiteBalanceMode = requestedMode
                }
            } catch {
                emit(.failed(message: "White-balance configuration failed: \(error.localizedDescription)"))
            }
        }
    }

    func updateVideoRotation(angle: CGFloat, orientation: CapturedFrameOrientation) {
        metadataLock.withLock {
            frameOrientation = orientation
        }
        sessionQueue.async { [weak self] in
            guard let connection = self?.videoOutput.connection(with: .video) else { return }
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
    }

    private func configure(configuration: CaptureConfiguration) throws -> ActiveCameraInfo {
        let capabilities = CameraDiscovery.capabilities()
        let device = try CameraDiscovery.device(configuration: configuration, capabilities: capabilities)
        let selectedFormat = try CameraDiscovery.format(device: device, configuration: configuration)

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.inputs.forEach(captureSession.removeInput)
        captureSession.outputs.forEach(captureSession.removeOutput)
        captureSession.sessionPreset = .inputPriority

        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw GVError.captureFailure(message: "The selected camera input cannot be attached.")
        }
        captureSession.addInput(input)

        let resolvedFPS = try configureDevice(
            device,
            format: selectedFormat,
            configuration: configuration
        )

        let supportedPixelFormats = videoOutput.availableVideoPixelFormatTypes
        let pixelFormat: OSType = supportedPixelFormats.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)

        guard captureSession.canAddOutput(videoOutput) else {
            throw GVError.captureFailure(message: "The native-YUV video output cannot be attached.")
        }
        captureSession.addOutput(videoOutput)

        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           captureSession.canAddInput(audioInput) {
            captureSession.addInput(audioInput)
            audioOutput.setSampleBufferDelegate(self, queue: outputQueue)
            if captureSession.canAddOutput(audioOutput) {
                captureSession.addOutput(audioOutput)
            }
        }

        let availableCodecTypes = videoOutput.availableVideoCodecTypesForAssetWriter(writingTo: .mov)
        let availableVideoCodecs = CaptureSetupDraft.VideoCodec.supportedChoices(from: availableCodecTypes)

        if let connection = videoOutput.connection(with: .video) {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = configuration.position == .front
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = configuration.framesPerSecond >= 120 ? .off : .standard
            }
        }

        activeDevice = device
        metadataLock.withLock {
            telemetryDevice = device
            telemetryFrameCounter = 0
        }
        let dimensionsValue = CMVideoFormatDescriptionGetDimensions(selectedFormat.formatDescription)
        let dimensions = CaptureDimensions(width: dimensionsValue.width, height: dimensionsValue.height)
        let logMessage = "\(device.localizedName) \(dimensions.label) @ \(resolvedFPS)"
        GVLog.capture.notice("Camera running: \(logMessage, privacy: .public)")

        return ActiveCameraInfo(
            capabilities: capabilities,
            deviceID: device.uniqueID,
            deviceName: device.localizedName,
            deviceType: device.deviceType.rawValue,
            position: configuration.position,
            dimensions: dimensions,
            framesPerSecond: resolvedFPS,
            pixelFormat: pixelFormat,
            hdrEnabled: device.isVideoHDREnabled,
            minimumZoom: Double(device.minAvailableVideoZoomFactor),
            maximumZoom: Double(device.maxAvailableVideoZoomFactor),
            minimumExposureBias: Double(device.minExposureTargetBias),
            maximumExposureBias: Double(device.maxExposureTargetBias),
            torchAvailable: device.hasTorch,
            requestedVideoCodec: configuration.videoCodec,
            availableVideoCodecs: availableVideoCodecs,
            whiteBalanceLocked: device.whiteBalanceMode == .locked
        )
    }

    private func configureDevice(
        _ device: AVCaptureDevice,
        format: AVCaptureDevice.Format,
        configuration: CaptureConfiguration
    ) throws -> Int {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        device.activeFormat = format
        let requestedFPS = Double(configuration.framesPerSecond)
        let bestRange = format.videoSupportedFrameRateRanges.min { lhs, rhs in
            let lhsResolved = min(max(requestedFPS, lhs.minFrameRate), lhs.maxFrameRate)
            let rhsResolved = min(max(requestedFPS, rhs.minFrameRate), rhs.maxFrameRate)
            return abs(lhsResolved - requestedFPS) < abs(rhsResolved - requestedFPS)
        }
        let resolvedRate = bestRange.map {
            min(max(requestedFPS, $0.minFrameRate), $0.maxFrameRate)
        } ?? requestedFPS
        let resolvedFPS = max(1, Int(resolvedRate.rounded()))
        let duration = CMTime(seconds: 1 / max(resolvedRate, 1), preferredTimescale: 60000)
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.automaticallyAdjustsVideoHDREnabled = false

        // Open on the widest native stop when the virtual device reaches
        // below 1.0 — that ultra-wide FOV is what a fresh launch expects.
        device.isVideoHDREnabled = configuration.prefersHDR && format.isVideoHDRSupported

        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        let shouldLockWhiteBalance = configuration.videoCodec == .proResRAW &&
            device.isWhiteBalanceModeSupported(.locked)
        if shouldLockWhiteBalance {
            device.whiteBalanceMode = .locked
        } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        if device.isLowLightBoostSupported {
            device.automaticallyEnablesLowLightBoostWhenAvailable = true
        }
        return resolvedFPS
    }

    private func installNotificationObservers() {
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: captureSession,
                queue: nil
            ) { [weak self] notification in
                let reason = Self.interruptionReason(notification)
                self?.emit(.interrupted(reason: reason))
            },
            center.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: captureSession,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                sessionQueue.async { [weak self] in
                    guard let self else { return }
                    if !captureSession.isRunning {
                        captureSession.startRunning()
                    }
                    emit(.resumed)
                }
            },
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: captureSession,
                queue: nil
            ) { [weak self] notification in
                guard let self else { return }
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
                if error?.code == .mediaServicesWereReset {
                    sessionQueue.async { [weak self] in
                        guard let self else { return }
                        if !captureSession.isRunning {
                            captureSession.startRunning()
                        }
                        emit(.mediaServicesReset)
                    }
                } else {
                    emit(.failed(message: error?.localizedDescription ?? "Unknown capture-session error."))
                }
            }
        ]
    }

    private func removeNotificationObservers() {
        let center = NotificationCenter.default
        notificationTokens.forEach(center.removeObserver)
        notificationTokens.removeAll(keepingCapacity: true)
    }

    private func tearDownSession() {
        if let activeDevice, activeDevice.hasTorch, activeDevice.torchMode == .on {
            do {
                try activeDevice.lockForConfiguration()
                activeDevice.torchMode = .off
                activeDevice.unlockForConfiguration()
            } catch {
                GVLog.capture.error("Torch cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        removeNotificationObservers()
        captureSession.beginConfiguration()
        captureSession.inputs.forEach(captureSession.removeInput)
        captureSession.outputs.forEach(captureSession.removeOutput)
        captureSession.commitConfiguration()
        activeDevice = nil
        metadataLock.withLock { telemetryDevice = nil }
        deviceTelemetryMailbox.clear()
        latestFrameMailbox.clear()
        GVLog.capture.notice("Camera session stopped and detached")
    }

    private func emit(_ event: CameraEvent) {
        let handler = handlerLock.withLock { eventHandler }
        handler?(event)
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === audioOutput {
            let handler = handlerLock.withLock { audioHandler }
            handler?(sampleBuffer)
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let dimensions = CaptureDimensions(
            width: Int32(CVPixelBufferGetWidth(pixelBuffer)),
            height: Int32(CVPixelBufferGetHeight(pixelBuffer))
        )
        let orientation = metadataLock.withLock { frameOrientation }
        let frame = CapturedFrame(
            sampleBuffer: sampleBuffer,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            dimensions: dimensions,
            orientation: orientation,
            isMirrored: connection.isVideoMirrored
        )
        latestFrameMailbox.publish(frame)
        sampleDeviceTelemetry()
        let handler = handlerLock.withLock { frameHandler }
        handler?(frame)
    }

    /// Samples exposure state roughly six times a second. Reading these
    /// properties is cheap and does not require locking the device.
    private func sampleDeviceTelemetry() {
        let device: AVCaptureDevice? = metadataLock.withLock {
            telemetryFrameCounter &+= 1
            guard telemetryFrameCounter.isMultiple(of: 10) else { return nil }
            return telemetryDevice
        }
        guard let device else { return }

        let duration = device.exposureDuration
        let seconds = CMTimeGetSeconds(duration)
        let denominator = seconds > 0 ? Int((1 / seconds).rounded()) : 0
        let temperature = device.temperatureAndTintValues(
            for: device.deviceWhiteBalanceGains
        ).temperature
        let kelvin = temperature.isFinite ? Int(temperature.rounded()) : 5000
        deviceTelemetryMailbox.publish(
            CameraDeviceTelemetry(
                iso: device.iso,
                shutterDenominator: denominator,
                whiteBalanceKelvin: kelvin,
                lensPosition: device.lensPosition,
                isValid: true
            )
        )
    }
}

private extension CameraController {
    static func interruptionReason(_ notification: Notification) -> String {
        guard let rawValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber,
              let reason = AVCaptureSession.InterruptionReason(rawValue: rawValue.intValue)
        else {
            return "UNKNOWN"
        }

        switch reason.rawValue {
        case 1:
            return "APP BACKGROUNDED"
        case 2:
            return "AUDIO DEVICE IN USE"
        case 3:
            return "CAMERA IN USE"
        case 4:
            return "MULTIPLE FOREGROUND APPS"
        case 5:
            return "SYSTEM PRESSURE"
        case 6:
            return "SENSITIVE CONTENT MITIGATION"
        default:
            return "UNKNOWN"
        }
    }
}
