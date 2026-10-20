import Foundation
@testable import GreyVision
import XCTest

final class TakeLibraryTests: XCTestCase {
    func testDeniedPhotosExportKeepsCompletedMovieAvailableAfterRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = GVTakeArchive(directory: directory)
        let url = try archive.makeRecordingURL()
        let movieBytes = Data([1, 3, 5, 7])
        try movieBytes.write(to: url)

        let take = try await archive.completeRecording(at: url, source: .camera, exporter: DeniedPhotoExporter())

        XCTAssertEqual(take.photosStatus, .failed)
        XCTAssertEqual(try Data(contentsOf: url), movieBytes)
        let reopened = GVTakeArchive(directory: directory)
        let restored = try await reopened.load()
        XCTAssertEqual(restored, [take])
        XCTAssertEqual(reopened.url(for: take), url)
    }

    func testRetryExportsSameMovieAndPersistsSuccessWithoutDuplicatingTake() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = GVTakeArchive(directory: directory)
        let url = try archive.makeRecordingURL()
        try Data([2, 4, 6]).write(to: url)
        let take = try await archive.completeRecording(at: url, source: .objects, exporter: DeniedPhotoExporter())
        let exporter = SuccessfulPhotoExporter()

        let retried = try await archive.exportToPhotos(take, exporter: exporter)
        let exportedURLs = await exporter.urls
        let restored = try await GVTakeArchive(directory: directory).load()

        XCTAssertEqual(exportedURLs, [url])
        XCTAssertEqual(retried.id, take.id)
        XCTAssertEqual(retried.photosStatus, .saved)
        XCTAssertEqual(restored, [retried])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testUnfinishedMovieIsNotListedAsACompletedTake() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = GVTakeArchive(directory: directory)
        let first = try archive.makeRecordingURL()
        let second = try archive.makeRecordingURL()
        XCTAssertNotEqual(first, second)
        try Data([8, 9]).write(to: first)

        let takes = try await archive.load()

        XCTAssertTrue(takes.isEmpty)
    }

    /// The library sheet is open while a take is being filed, so a write that
    /// nobody announces leaves a plate showing a list that no longer matches
    /// the disk.
    func testArchiveAnnouncesEveryChangeItMakes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = GVTakeArchive(directory: directory)
        let url = try archive.makeRecordingURL()
        try Data([1, 2, 3]).write(to: url)

        let filed = expectation(forNotification: .gvTakeArchiveChanged, object: nil)
        let take = try await archive.completeRecording(at: url, source: .camera, exporter: DeniedPhotoExporter())
        await fulfillment(of: [filed], timeout: 1)

        let deleted = expectation(forNotification: .gvTakeArchiveChanged, object: nil)
        try await archive.delete(take)
        await fulfillment(of: [deleted], timeout: 1)
    }

    /// A still is the same failure with the same stakes: the shutter fired, the
    /// frame exists, and Photos can refuse it.
    func testStillThatPhotosRefusesIsFiledAsATake() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = GVTakeArchive(directory: directory)
        let url = try archive.makeStillURL()
        XCTAssertEqual(url.pathExtension, "jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: url)

        let take = try await archive.completeRecording(at: url, source: .camera, exporter: DeniedPhotoExporter())

        XCTAssertEqual(take.kind, .still)
        XCTAssertEqual(take.photosStatus, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let restored = try await GVTakeArchive(directory: directory).load()
        XCTAssertEqual(restored, [take])
        XCTAssertEqual(restored.first?.completionMessage, take.completionMessage)
    }

    /// Sidecars written before stills existed carry no kind. They are on real
    /// devices right now, and a library that cannot read them is a library that
    /// lost the user's footage.
    func testSidecarWithoutAKindStillLoadsAsAMovie() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = GVTakeArchive(directory: directory)
        let movie = try archive.makeRecordingURL()
        try Data([1, 2, 3, 4]).write(to: movie)
        let id = try XCTUnwrap(UUID(uuidString: movie.deletingPathExtension().lastPathComponent))
        try Data(
            """
            {"id":"\(id.uuidString)","createdAt":0,"source":"camera","photosStatus":"saved","photosError":null}
            """.utf8
        ).write(to: directory.appendingPathComponent(id.uuidString).appendingPathExtension("json"))

        let restored = try await GVTakeArchive(directory: directory).load()

        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.id, id)
        XCTAssertEqual(restored.first?.kind, .movie)
    }

    /// Photos has two different creation requests. A JPEG handed to the video
    /// one is refused for a reason the user cannot act on.
    func testStillExportGoesToTheImageChannel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = GVTakeArchive(directory: directory)
        let url = try archive.makeStillURL()
        try Data([0xFF, 0xD8, 0xFF]).write(to: url)
        let exporter = SuccessfulPhotoExporter()

        let take = try await archive.completeRecording(at: url, source: .camera, exporter: exporter)
        let images = await exporter.imageURLs
        let videos = await exporter.urls

        XCTAssertEqual(take.photosStatus, .saved)
        XCTAssertEqual(images, [url])
        XCTAssertTrue(videos.isEmpty)
    }
}

private struct DeniedPhotoExporter: GVPhotosExporting {
    func saveVideo(at _: URL) async throws {
        throw GVRecordingError.accessDenied
    }

    func saveImage(at _: URL) async throws {
        throw GVRecordingError.accessDenied
    }
}

private actor SuccessfulPhotoExporter: GVPhotosExporting {
    private(set) var urls: [URL] = []
    private(set) var imageURLs: [URL] = []

    func saveVideo(at url: URL) async throws {
        urls.append(url)
    }

    func saveImage(at url: URL) async throws {
        imageURLs.append(url)
    }
}
