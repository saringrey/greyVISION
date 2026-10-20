import AVFoundation
import AVKit
import Foundation
import Observation

/// The take library's view model.
///
/// Disk and Photos work belongs to the archive actor, so the sheet keeps a
/// `@MainActor` snapshot of the outcome and never blocks on the filesystem.
@MainActor
@Observable
final class GVTakeLibraryModel {
    private(set) var takes: [GVTake] = []
    private(set) var isLoading = false
    var notice: String?

    private let archive: GVTakeArchive
    private var posters: [UUID: UIImage] = [:]
    private var archiveObserver: (any NSObjectProtocol)?

    init(archive: GVTakeArchive = .shared) {
        self.archive = archive
    }

    /// Keeps a plate that is already on screen current with the disk.
    ///
    /// Takes are filed by the camera runtime, the objects runtime and the
    /// render loop's writer, none of which can reach this list; without it an
    /// operator who records while the library is open sees a list that stopped
    /// matching the archive the moment the take finished.
    func followArchiveChanges() {
        guard archiveObserver == nil else { return }
        archiveObserver = NotificationCenter.default.addObserver(
            forName: .gvTakeArchiveChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    func stopFollowingArchiveChanges() {
        if let archiveObserver {
            NotificationCenter.default.removeObserver(archiveObserver)
        }
        archiveObserver = nil
    }

    func url(for take: GVTake) -> URL {
        archive.url(for: take)
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            takes = try await archive.load()
        } catch {
            notice = "TAKE LIBRARY UNREADABLE · \(error.localizedDescription)"
        }
    }

    /// Retries the Photos export of a take that is already on disk. The movie is
    /// never rewritten or copied: the same file goes to the same library, and a
    /// second refusal updates the record rather than deleting the footage.
    func exportToPhotos(_ take: GVTake) async {
        do {
            let updated = try await archive.exportToPhotos(take, exporter: GVSystemPhotosExporter())
            replace(updated)
            notice = updated.photosStatus == .saved
                ? "SAVED TO PHOTOS"
                : "PHOTOS STILL REFUSED · THE TAKE IS IN THE LIBRARY"
        } catch {
            notice = "EXPORT FAILED · \(error.localizedDescription)"
        }
    }

    /// A frame out of the take, cached for the life of the model.
    ///
    /// A quarter of the way in rather than the head: the first frame of a clip
    /// is routinely black or a shutter flash, and it identifies nothing. A still
    /// is its own frame, so it is read straight off the file.
    func poster(for take: GVTake) async -> UIImage? {
        if let cached = posters[take.id] { return cached }
        let url = archive.url(for: take)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if !take.kind.isMovie {
            guard let image = UIImage(contentsOfFile: url.path) else { return nil }
            posters[take.id] = image
            return image
        }
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 168, height: 168)
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let seconds = duration > 0 ? min(duration * 0.25, duration - 0.05) : 0
        guard let cgImage = try? await generator.image(at: CMTime(seconds: max(seconds, 0), preferredTimescale: 600)).image
        else { return nil }
        let image = UIImage(cgImage: cgImage)
        posters[take.id] = image
        return image
    }

    func delete(_ take: GVTake) async {
        do {
            try await archive.delete(take)
            takes.removeAll { $0.id == take.id }
            notice = "DELETED \(take.source.label.uppercased()) TAKE"
        } catch {
            notice = "DELETE FAILED · \(error.localizedDescription)"
        }
    }

    private func replace(_ take: GVTake) {
        if let index = takes.firstIndex(where: { $0.id == take.id }) {
            takes[index] = take
        } else {
            takes.insert(take, at: 0)
        }
    }
}
