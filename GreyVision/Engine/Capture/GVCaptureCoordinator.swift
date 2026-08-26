import AVFoundation
import Foundation
import Photos
import ReplayKit
import SwiftUI
import UIKit

/// How a capture treats the interface itself.
///
/// - `clean`: the render-target writer. The saved video is exactly what the
///   effect pipeline produced — no buttons, no telemetry.
/// - `hud`: a screen capture of the whole instrument, interface included.
enum GVCaptureMode: String, CaseIterable, Identifiable {
    /// HUD screen-recording removed: ReplayKit teardown crashed on device.
    /// The instrument records the render target. Full stop.
    case clean

    var id: String { rawValue }

    var label: String { "CLEAN" }
    var detail: String { "RENDERER ONLY // NO INTERFACE" }
}

/// The single capture authority.
///
/// Before this existed, every control drove `CameraRuntime.toggleRecording()`
/// directly and nothing structurally prevented two surfaces from fighting over
/// one writer or reporting contradictory state. Now every button asks this
/// object; it holds ONE `isRecording`, and a second caller during a take stops
/// it rather than starting a competing one.
///
/// CLEAN mode drives the native render pipeline. HUD mode captures the actual
/// display through ReplayKit — the only way the interface can exist in the
/// saved file.
@MainActor
final class GVCaptureCoordinator: ObservableObject {
    @Published private(set) var mode: GVCaptureMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }

    /// Elapsed seconds for the active HUD take. The renderer path surfaces its
    /// own timecode through the recording HUD.
    @Published private(set) var hudElapsed: TimeInterval = 0

    @Published var statusMessage: String?

    private static let modeKey = "gv.capture.mode"

    // HUD take plumbing
    private var hudURL: URL?
    private var hudWriter: AVAssetWriter?
    private var hudInput: AVAssetWriterInput?
    private var hudAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let hudQueue = DispatchQueue(label: "gv.capture.hud")
    private var hudStart: Date?
    private var ticker: Task<Void, Never>?

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.modeKey)
        mode = GVCaptureMode(rawValue: raw ?? "") ?? .clean
    }

    func setMode(_ newMode: GVCaptureMode, cameraRuntime: CameraRuntime) {
        guard !isTakeLive(cameraRuntime) else {
            statusMessage = "CAPTURE // MODE LOCKED WHILE RECORDING"
            return
        }
        mode = newMode
    }

    /// Toggles whichever take applies. Safe from any surface: calling while a
    /// take is live STOPS it instead of starting a second one.
    ///
    /// The decision reads the runtime's live state — including a start that
    /// is still pending on the writer mailbox. Copying `isRecording` at tap
    /// time was always false, because the renderer latches the writer a frame
    /// or two later; that made every start report "writer unavailable" and
    /// left this coordinator one tap behind the truth.
    private func isTakeLive(_ cameraRuntime: CameraRuntime) -> Bool {
        cameraRuntime.isRecording || cameraRuntime.recordingMailbox.isStartPending
    }

    func toggleRecording(cameraRuntime: CameraRuntime) {
        if isTakeLive(cameraRuntime) {
            stop(cameraRuntime: cameraRuntime)
        } else {
            start(cameraRuntime: cameraRuntime)
        }
    }

    func start(cameraRuntime: CameraRuntime) {
        guard !isTakeLive(cameraRuntime) else {
            statusMessage = "CAPTURE // ALREADY RECORDING"
            return
        }
        cameraRuntime.toggleRecording()
        statusMessage = "REC // CLEAN RENDER"
    }

    func stop(cameraRuntime: CameraRuntime) {
        guard isTakeLive(cameraRuntime) else { return }
        cameraRuntime.toggleRecording()
    }

    /// One screenshot entry point. CLEAN grabs the render target; HUD grabs
    /// the composed screen, interface and all.
    func takeScreenshot(cameraRuntime: CameraRuntime) {
        cameraRuntime.takeScreenshot()
    }

    nonisolated private static func requestPhotoAccess(_ completion: @escaping (Bool) -> Void) {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            completion(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { completion($0 == .authorized || $0 == .limited) }
        default:
            completion(false)
        }
    }
}
