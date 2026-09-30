import Photos
import UIKit

/// Saves interface-inclusive captures to Photos.
///
/// The Metal render path can only ever produce the clean image — camera plus
/// effects, no chrome. Anything that must show the instrument itself has to
/// come from the window or the screen, which is what this handles.
enum GVScreenCapture {
    static func save(_ image: UIImage, message: @escaping @Sendable (String) -> Void) {
        guard let png = image.pngData() else {
            message("SCREENSHOT // ENCODE FAILED")
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("greyvision-ui-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
        } catch {
            message("SCREENSHOT // WRITE FAILED")
            return
        }
        requestAddAccess { granted in
            guard granted else {
                try? FileManager.default.removeItem(at: url)
                message("SCREENSHOT // PHOTOS ACCESS DENIED")
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            } completionHandler: { success, error in
                try? FileManager.default.removeItem(at: url)
                if success {
                    message("PHOTO // SAVED TO CAMERA ROLL")
                } else {
                    message("SCREENSHOT // SAVE FAILED")
                    GVLog.recording.error(
                        "UI screenshot save failed: \(error?.localizedDescription ?? "unknown")"
                    )
                }
            }
        }
    }

    private static func requestAddAccess(_ completion: @escaping @Sendable (Bool) -> Void) {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            completion(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                completion(status == .authorized || status == .limited)
            }
        default:
            completion(false)
        }
    }
}
