import UIKit

/// Writes a captured frame into the take library, and then into Photos.
///
/// The order is the whole point. The JPEG lands in the archive first, so a
/// denied permission, a full library or an interrupted import costs the
/// operator a status line rather than the photograph — the same recovery the
/// recorder has had all along, for the case that used to delete the file.
///
/// One caller today: the renderer's still path. It is not inline in the
/// renderer because the Photos authorisation dance and the filing have nothing
/// to do with Metal.
///
/// The encoding is fixed rather than a parameter. JPEG because the source is a
/// camera frame at several megapixels, and a PNG of one is tens of megabytes
/// for no benefit anyone can see.
enum GVScreenCapture {
    static let quality: CGFloat = 0.95

    static func save(
        _ image: UIImage,
        source: GVTake.Source = .camera,
        message: @escaping @Sendable (String) -> Void
    ) {
        guard let data = image.jpegData(compressionQuality: quality) else {
            message("PHOTO // ENCODE FAILED")
            return
        }
        let url: URL
        do {
            url = try GVTakeArchive.shared.makeStillURL()
            try data.write(to: url, options: .atomic)
        } catch {
            message("PHOTO // WRITE FAILED")
            return
        }
        message("PHOTO // FILING TAKE")
        Task {
            do {
                let take = try await GVTakeArchive.shared.completeRecording(
                    at: url,
                    source: source,
                    exporter: GVSystemPhotosExporter()
                )
                message(take.completionMessage)
            } catch {
                GVLog.recording.error("Still could not be filed: \(error.localizedDescription)")
                message("PHOTO // SAVE FAILED")
            }
        }
    }
}
