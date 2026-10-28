import AVFoundation
import Photos

/// Asks for every media permission the instrument uses, once, at launch.
///
/// The prompts run one after another — iOS queues concurrent requests anyway,
/// and a sequence keeps each sheet's reason readable on its own. A permission
/// that was already decided returns immediately, so on every launch after the
/// first this is three status reads and no UI.
///
/// The runtimes keep their own request paths: a permission revoked in
/// Settings mid-session still surfaces where it is needed. This only moves the
/// first ask to the moment the operator opens the app, instead of the first
/// time they tap a control that needs it.
enum GVLaunchPermissions {
    struct Outcome: Equatable {
        var camera: Bool
        var microphone: Bool
        var photoLibrary: Bool
    }

    @MainActor
    static func requestAll() async -> Outcome {
        let camera = await requestCapture(.video)
        let microphone = await requestMicrophone()
        let photos = await requestPhotoLibrary()
        GVLog.capture.notice(
            "Launch permissions camera=\(camera, privacy: .public) mic=\(microphone, privacy: .public) photos=\(photos, privacy: .public)"
        )
        return Outcome(camera: camera, microphone: microphone, photoLibrary: photos)
    }

    private static func requestCapture(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: type)
        default: false
        }
    }

    /// The record permission covers both the capture writer's audio track and
    /// the audio-reactive analyser, so one prompt serves both.
    private static func requestMicrophone() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: true
        case .undetermined: await AVAudioApplication.requestRecordPermission()
        default: false
        }
    }

    /// Add-only: the app writes takes to the library and never reads it, so
    /// it asks for no more than that.
    private static func requestPhotoLibrary() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited: true
        case .notDetermined: await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized
        default: false
        }
    }
}
