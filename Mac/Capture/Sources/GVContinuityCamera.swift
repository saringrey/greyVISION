import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import Foundation

/// The Mac's *other* way of seeing an iPhone: Continuity Camera.
///
/// ## How this differs from the link
///
/// `GVPhoneLink` receives GreyVision's **processed** output — the effect stack
/// as the operator built it — over the app's own Bonjour/TLS connection.
/// Continuity Camera is a **system** service: macOS presents a nearby iPhone
/// as an ordinary `AVCaptureDevice`, and what arrives is the raw camera with
/// Apple's processing. There is no API for a third-party iOS app to publish
/// frames into it, so GreyVision's effects can never travel this way — which
/// is exactly why the link exists at all.
///
/// Both are worth having and they answer different questions. Continuity is
/// zero-setup: no pairing code, no app running on the phone, clean picture.
/// The link gives the composition and can be driven from the FX panel. Two
/// sources behind one picker is what makes this one app rather than two
/// sharing a window.
///
/// ## Isolation
///
/// The same split the rest of this target uses — `GVPhoneLink` /
/// `CaptureReceiver`, and `GVBroadcastEngine` / `GVBroadcastRuntime` on the
/// phone. `GVContinuityCameraEngine` owns the capture session and the Core
/// Image context and never touches the main actor; `GVContinuityCamera` is
/// `@MainActor` and holds only what SwiftUI reads. A delegate that hopped to
/// the main actor per frame would put every frame behind whatever the window
/// is doing.

// MARK: - Engine

/// Owns the capture session. Never touches the main actor.
final class GVContinuityCameraEngine: NSObject, @unchecked Sendable {
    struct DeviceInfo: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        /// True when macOS classified this as a Continuity Camera rather than
        /// a generic USB camera. Only knowable on macOS 14+; older systems
        /// report every external camera identically, so the picker says
        /// "external" rather than claiming a certainty it does not have.
        let isContinuity: Bool
    }

    var onImage: (@Sendable (NSImage) -> Void)?
    var onDevices: (@Sendable ([DeviceInfo]) -> Void)?
    var onStatus: (@Sendable (String, Bool) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "greyvision.maccapture.continuity")
    private let context = CIContext()
    private var discovery: AVCaptureDevice.DiscoverySession?
    private var deviceObservation: NSKeyValueObservation?
    private var activeInput: AVCaptureDeviceInput?

    override init() {
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        beginDiscovery()
        requestCameraAccessIfNeeded()
    }

    deinit {
        deviceObservation?.invalidate()
    }

    // MARK: Discovery

    /// macOS 14 split external cameras into `.external` and
    /// `.continuityCamera`. Before that everything non-built-in arrived as
    /// `.externalUnknown`, which is what Apple's own `ContinuityCam` sample
    /// uses — the fallback is documented behaviour, not a guess.
    private func beginDiscovery() {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            // Continuity devices can be classified as `.continuityCamera`,
            // `.external`, or `.externalUnknown` depending on the macOS
            // release and device state. Include all three so a live iPhone
            // does not disappear from the picker merely because its
            // classification changed while waking.
            types = [.builtInWideAngleCamera, .external, .externalUnknown, .continuityCamera]
        } else {
            types = [.builtInWideAngleCamera, .externalUnknown]
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )
        self.discovery = discovery

        // An iPhone appears and disappears as it is woken, unlocked or carried
        // out of range. Observing rather than snapshotting once is what keeps
        // the picker honest.
        deviceObservation = discovery.observe(\.devices, options: [.initial, .new]) { [weak self] discovery, _ in
            self?.publishDevices(discovery.devices)
        }
        publishDevices(discovery.devices)
    }

    private func requestCameraAccessIfNeeded() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.onStatus?("Camera access denied in System Settings › Privacy & Security.", true)
                return
            }
            self.queue.async { [weak self] in
                self?.beginDiscovery()
            }
        }
    }

    private func publishDevices(_ discoveredDevices: [AVCaptureDevice]) {
        var devices = discoveredDevices
        let directDevices = AVCaptureDevice.devices(for: .video)
            .filter { device in
                if #available(macOS 14.0, *) {
                    return device.deviceType == .continuityCamera
                        || device.localizedName.localizedCaseInsensitiveContains("iphone")
                }
                return device.localizedName.localizedCaseInsensitiveContains("iphone")
            }
        for device in directDevices where !devices.contains(where: { $0.uniqueID == device.uniqueID }) {
            devices.append(device)
        }
        onDevices?(devices.map(Self.info))
    }

    func refreshDiscovery() {
        queue.async { [weak self] in
            guard let self else { return }
            self.publishDevices(self.discovery?.devices ?? [])
        }
    }

    private static func info(for device: AVCaptureDevice) -> DeviceInfo {
        var isContinuity = false
        if #available(macOS 14.0, *) {
            isContinuity = device.deviceType == .continuityCamera
        }
        return DeviceInfo(id: device.uniqueID, name: device.localizedName, isContinuity: isContinuity)
    }

    // MARK: Lifecycle

    func start(deviceID: String) {
        // Permission first. Building the input before the grant lands produces
        // a session that runs and delivers nothing, which reads as a bug in
        // the app rather than as a missing authorisation.
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            queue.async { [weak self] in self?.configureAndRun(deviceID: deviceID) }
        case .notDetermined:
            onStatus?("Waiting for camera permission…", false)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                guard granted else {
                    self.onStatus?("Camera access denied.", true)
                    return
                }
                self.queue.async { self.configureAndRun(deviceID: deviceID) }
            }
        case .denied, .restricted:
            onStatus?("Camera access denied in System Settings › Privacy & Security.", true)
        @unknown default:
            onStatus?("Camera access unavailable.", true)
        }
    }

    private func configureAndRun(deviceID: String) {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            onStatus?("That camera is no longer available.", true)
            return
        }

        session.beginConfiguration()
        if let activeInput {
            session.removeInput(activeInput)
            self.activeInput = nil
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                onStatus?("This Mac refused that camera input.", true)
                return
            }
            session.addInput(input)
            activeInput = input
        } catch {
            session.commitConfiguration()
            onStatus?("Camera input failed: \(error.localizedDescription)", true)
            return
        }
        if !session.outputs.contains(output), session.canAddOutput(output) {
            session.addOutput(output)
        }
        session.commitConfiguration()

        onStatus?("\(device.localizedName.uppercased()) // LIVE", false)
        guard !session.isRunning else { return }
        // Blocks while the device warms up, which is exactly why it is here
        // and not on the main actor.
        session.startRunning()
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            self.session.beginConfiguration()
            if let activeInput = self.activeInput {
                self.session.removeInput(activeInput)
                self.activeInput = nil
            }
            self.session.commitConfiguration()
        }
    }
}

// MARK: - Frames

extension GVContinuityCameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from _: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = ciImage.extent
        guard let cgImage = context.createCGImage(ciImage, from: extent) else { return }
        onImage?(NSImage(cgImage: cgImage, size: extent.size))
    }
}

// MARK: - UI-facing state

/// What `CaptureView` binds to for the CONTINUITY source.
@MainActor
final class GVContinuityCamera: ObservableObject {
    @Published private(set) var devices: [GVContinuityCameraEngine.DeviceInfo] = []
    @Published private(set) var frame: NSImage?
    @Published private(set) var status = "No camera selected."
    @Published private(set) var isError = false
    @Published private(set) var isRunning = false
    @Published private(set) var selectedDeviceID: String?

    private let engine = GVContinuityCameraEngine()

    init() {
        engine.onImage = { [weak self] image in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.frame = image
            }
        }
        engine.onDevices = { [weak self] devices in
            Task { @MainActor in
                guard let self else { return }
                self.devices = devices
                // A device that vanished mid-session cannot keep delivering.
                if let selected = self.selectedDeviceID, !devices.contains(where: { $0.id == selected }) {
                    self.engine.stop()
                    self.isRunning = false
                    self.frame = nil
                    self.selectedDeviceID = nil
                    self.status = "Camera disconnected."
                    self.isError = true
                }

                guard let preferred = self.preferredDevice else {
                    self.status = "Waiting for your iPhone Continuity Camera…"
                    return
                }
                guard self.selectedDeviceID == nil, !self.isRunning else { return }
                self.start(deviceID: preferred.id)
            }
        }
        engine.onStatus = { [weak self] text, isError in
            Task { @MainActor in
                self?.status = text
                self?.isError = isError
            }
        }
        engine.refreshDiscovery()
    }

    /// The Continuity Camera in the list, if macOS identified one. Offers a
    /// sensible default instead of making the operator pick their own phone
    /// out of the USB cameras.
    var preferredDevice: GVContinuityCameraEngine.DeviceInfo? {
        devices.first { $0.isContinuity } ?? devices.first
    }

    func start(deviceID: String) {
        selectedDeviceID = deviceID
        isError = false
        isRunning = true
        engine.start(deviceID: deviceID)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        frame = nil
        status = "Camera stopped."
        isError = false
        engine.stop()
    }
}
