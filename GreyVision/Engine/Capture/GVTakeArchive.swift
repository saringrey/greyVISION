import Foundation
import Photos

struct GVTake: Identifiable, Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case camera, raw, objects

        var label: String {
            switch self {
            case .camera: "Camera"
            case .raw: "Sensor RAW"
            case .objects: "Objects"
            }
        }
    }

    /// What the archive is holding. Stills joined later, so a record written
    /// before them has no `kind` key and decodes as a movie.
    enum Kind: String, Codable, Sendable {
        case movie, still

        var fileExtension: String {
            switch self {
            case .movie: "mov"
            case .still: "jpg"
            }
        }

        var isMovie: Bool { self == .movie }

        /// The writer decides what a take is by what it produced, so the
        /// extension is the one piece of provenance that cannot be lost.
        init?(fileExtension: String) {
            switch fileExtension.lowercased() {
            case "mov": self = .movie
            case "jpg", "jpeg": self = .still
            default: return nil
            }
        }
    }

    enum PhotosStatus: String, Codable, Sendable {
        case pending, saved, failed
    }

    let id: UUID
    let createdAt: Date
    let source: Source
    let kind: Kind
    var photosStatus: PhotosStatus
    var photosError: String?

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, source, kind, photosStatus, photosError
    }

    init(
        id: UUID,
        createdAt: Date,
        source: Source,
        kind: Kind = .movie,
        photosStatus: PhotosStatus,
        photosError: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.kind = kind
        self.photosStatus = photosStatus
        self.photosError = photosError
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        source = try container.decode(Source.self, forKey: .source)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .movie
        photosStatus = try container.decode(PhotosStatus.self, forKey: .photosStatus)
        photosError = try container.decodeIfPresent(String.self, forKey: .photosError)
    }

    var completionMessage: String {
        let prefix = kind.isMovie ? "RECORD" : "PHOTO"
        return photosStatus == .saved
            ? "\(prefix) // SAVED TO PHOTOS"
            : "\(prefix) // KEPT IN TAKE LIBRARY · PHOTOS NOT SAVED"
    }
}

protocol GVPhotosExporting: Sendable {
    func saveVideo(at url: URL) async throws
    func saveImage(at url: URL) async throws
}

struct GVSystemPhotosExporter: GVPhotosExporting {
    func saveVideo(at url: URL) async throws {
        try await add {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
        }
    }

    func saveImage(at url: URL) async throws {
        try await add {
            PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
        }
    }

    private func add(_ changes: @escaping () -> Void) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw GVRecordingError.accessDenied
        }
        try await PHPhotoLibrary.shared().performChanges(changes)
    }
}

actor GVTakeArchive {
    static let shared = GVTakeArchive(directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Takes", isDirectory: true))

    private nonisolated let directory: URL
    private var exportsInFlight: Set<UUID> = []

    enum ArchiveError: LocalizedError {
        case invalidFile, invalidMetadata

        var errorDescription: String? {
            switch self {
            case .invalidFile: "A completed take is missing or outside the take library."
            case .invalidMetadata: "A take record could not be read. The original file has been kept."
            }
        }
    }

    init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }
    nonisolated func makeRecordingURL() throws -> URL {
        try makeURL(kind: .movie)
    }

    /// Where a still from the shutter goes. The renderer writes the JPEG here
    /// before Photos is asked for anything, so a refusal has nowhere to lose it.
    nonisolated func makeStillURL() throws -> URL {
        try makeURL(kind: .still)
    }

    private nonisolated func makeURL(kind: GVTake.Kind) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(kind.fileExtension)
    }

    nonisolated func url(for take: GVTake) -> URL {
        directory.appendingPathComponent(take.id.uuidString).appendingPathExtension(take.kind.fileExtension)
    }

    func load() throws -> [GVTake] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        return try files.filter { $0.pathExtension == "json" }.map { file in
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ArchiveError.invalidMetadata
            }
            let take = try JSONDecoder().decode(GVTake.self, from: Data(contentsOf: file))
            guard file.deletingPathExtension().lastPathComponent == take.id.uuidString else {
                throw ArchiveError.invalidMetadata
            }
            try validateFile(url(for: take), kind: take.kind)
            return take
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func completeRecording(at url: URL, source: GVTake.Source, exporter: any GVPhotosExporting) async throws -> GVTake {
        guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
              let kind = GVTake.Kind(fileExtension: url.pathExtension)
        else { throw ArchiveError.invalidFile }
        try validateFile(url, kind: kind)
        let take: GVTake
        if FileManager.default.fileExists(atPath: metadataURL(id).path) {
            take = try read(id)
        } else {
            take = GVTake(id: id, createdAt: .now, source: source, kind: kind, photosStatus: .pending)
            try persist(take)
        }
        return try await exportToPhotos(take, exporter: exporter)
    }

    /// Files every finished movie or still that has no record yet — a session
    /// killed between the writer finishing and the filing — and retries any
    /// take whose Photos export failed or never ran. Without this, a take that
    /// missed its one export attempt never reached the camera roll.
    func recoverUnsavedTakes(exporter: any GVPhotosExporting) async {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            guard GVTake.Kind(fileExtension: file.pathExtension) != nil,
                  let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent)
            else { continue }
            if FileManager.default.fileExists(atPath: metadataURL(id).path) {
                guard let take = try? read(id), take.photosStatus != .saved else { continue }
                _ = try? await exportToPhotos(take, exporter: exporter)
            } else {
                // Skip a file still being written (a recording in progress
                // has no record yet either) and leave old strays alone rather
                // than surprise the camera roll with weeks-old footage.
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let age = Date.now.timeIntervalSince(modified)
                guard age > 120, age < 7 * 24 * 3600 else { continue }
                _ = try? await completeRecording(at: file, source: .camera, exporter: exporter)
            }
        }
    }

    func exportToPhotos(_ take: GVTake, exporter: any GVPhotosExporting) async throws -> GVTake {
        var current = try read(take.id)
        guard current.photosStatus != .saved, exportsInFlight.insert(take.id).inserted else { return current }
        defer { exportsInFlight.remove(take.id) }
        let file = url(for: current)
        try validateFile(file, kind: current.kind)
        current.photosStatus = .pending
        current.photosError = nil
        try persist(current)
        do {
            if current.kind.isMovie {
                try await exporter.saveVideo(at: file)
            } else {
                try await exporter.saveImage(at: file)
            }
            current.photosStatus = .saved
        } catch {
            current.photosStatus = .failed
            current.photosError = error.localizedDescription
        }
        try persist(current)
        return current
    }

    func delete(_ take: GVTake) throws {
        try FileManager.default.removeItem(at: url(for: take))
        let metadata = metadataURL(take.id)
        if FileManager.default.fileExists(atPath: metadata.path) {
            try FileManager.default.removeItem(at: metadata)
        }
        announceChange()
    }

    private func read(_ id: UUID) throws -> GVTake {
        let take = try JSONDecoder().decode(GVTake.self, from: Data(contentsOf: metadataURL(id)))
        guard take.id == id else { throw ArchiveError.invalidMetadata }
        return take
    }

    private func metadataURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func persist(_ take: GVTake) throws {
        try JSONEncoder().encode(take).write(to: metadataURL(take.id), options: .atomic)
        announceChange()
    }

    /// Every surface that lists takes reads the archive off disk, so a write
    /// that is not announced leaves an open plate showing a stale list.
    private func announceChange() {
        NotificationCenter.default.post(name: .gvTakeArchiveChanged, object: nil)
    }

    private func validateFile(_ url: URL, kind: GVTake.Kind) throws {
        guard url.isFileURL, url.pathExtension == kind.fileExtension,
              url.deletingLastPathComponent().resolvingSymlinksInPath() == directory.resolvingSymlinksInPath(),
              UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
        else { throw ArchiveError.invalidFile }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else {
            throw ArchiveError.invalidFile
        }
    }
}

extension Notification.Name {
    /// Posted by `GVTakeArchive` whenever the set of takes on disk changes.
    static let gvTakeArchiveChanged = Notification.Name("gv.take-archive.changed")
}
