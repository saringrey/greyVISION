import AVFoundation
import CoreVideo
@testable import GreyVision
import XCTest

/// Reads one frame out of a recorded take, which is what lets the timeline show a
/// graded still of a movie instead of a live camera frame.
///
/// These do not mock AVFoundation. A mock would prove the wrapper calls itself
/// correctly and nothing about whether a hardware decoder yields a frame at the
/// requested time, which is the entire risk. Each test writes a real two-second
/// movie, reads it back, and deletes it.
final class GVTakeFrameReaderTests: XCTestCase {
    /// A decoder can only begin at a sync sample, so the honest contract is "the
    /// newest frame at or before the target". An implementation that always
    /// returned frame zero would pass a test that only checks a frame came back,
    /// and would be useless for scrubbing — so brightness has to move with time.
    @MainActor
    func testFrameAtReturnsALaterAndBrighterFrame() async throws {
        let url = try await GVTakeFixture.makeMovie(seconds: 2, framesPerSecond: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = GVTakeFrameReader(url: url)

        guard let early = await reader.frame(at: 0.1), let late = await reader.frame(at: 1.7) else {
            throw XCTSkip("no video decoder available on this destination")
        }
        XCTAssertEqual(CVPixelBufferGetWidth(early), CVPixelBufferGetWidth(late))
        let earlyLuma = GVPixelSampler.meanLuma(early)
        let lateLuma = GVPixelSampler.meanLuma(late)
        XCTAssertGreaterThan(lateLuma, earlyLuma + 0.05, "the luma ramp must advance with the requested time")
    }

    @MainActor
    func testMissingFileReturnsNilRatherThanThrowing() async {
        let reader = GVTakeFrameReader(url: URL(fileURLWithPath: "/private/tmp/greyvision-does-not-exist.mov"))
        let frame = await reader.frame(at: 0.5)
        XCTAssertNil(frame, "an unopenable take is a no-preview case, not an error the UI has to catch")
    }

    /// A drag produces far more requests than a decoder can service, so a newer
    /// request supersedes an older one. Superseded is not the same as abandoned:
    /// every caller still has to be answered, because a continuation nobody resumes
    /// is a leaked task and a playhead that stops responding mid-gesture.
    @MainActor
    func testSupersededRequestsCompleteRatherThanHang() async throws {
        let url = try await GVTakeFixture.makeMovie(seconds: 2, framesPerSecond: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = GVTakeFrameReader(url: url)
        guard await reader.frame(at: 1.4) != nil else {
            throw XCTSkip("no video decoder available on this destination")
        }

        // Answers are `Bool`, not buffers: `CVPixelBuffer` is not `Sendable` and
        // cannot cross the group boundary that proves every request completed.
        let answers = await withTaskGroup(of: Bool.self) { group in
            for index in 0 ..< 8 {
                group.addTask { await reader.frame(at: Double(index) * 0.2) != nil }
            }
            var seen: [Bool] = []
            for await didRead in group {
                seen.append(didRead)
            }
            return seen
        }

        XCTAssertEqual(answers.count, 8, "eight requests, eight answers")
        XCTAssertTrue(answers.contains(true), "a read that is not superseded produced a frame")
    }
}

// MARK: - Fixtures

enum GVFixtureError: Error {
    case writerWouldNotStart
    case writerFailed(String)
    case bufferUnavailable
}

enum GVPixelSampler {
    /// Mean luma over every 17th pixel: a stride, not a full walk, so a test does
    /// not hold a buffer locked across 16k pixels.
    static func meanLuma(_ buffer: CVPixelBuffer) -> Double {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(buffer)
        else { return -1 }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let pitch = CVPixelBufferGetBytesPerRow(buffer)
        var total = 0.0
        var count = 0.0
        base.withMemoryRebound(to: UInt8.self, capacity: pitch * height) { bytes in
            for index in stride(from: 0, to: width * height, by: 17) {
                let offset = index * 4
                let blue = Double(bytes[offset])
                let green = Double(bytes[offset + 1])
                let red = Double(bytes[offset + 2])
                total += (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255
                count += 1
            }
        }
        return count > 0 ? total / count : -1
    }
}

/// Writes a small H.264 movie whose luma ramps with time, so a reader stuck on
/// frame zero is detectable by brightness alone.
enum GVTakeFixture {
    static func makeMovie(seconds: Double, framesPerSecond: Int) async throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("greyvision-fixture-\(UUID().uuidString).mov")
        let width = 128, height = 128
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else { throw GVFixtureError.writerWouldNotStart }
        writer.add(input)
        try writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frames = Int(seconds * Double(framesPerSecond))
        for index in 0 ..< frames {
            while !input.isReadyForMoreMediaData {
                usleep(2_000)
            }
            let buffer = try makeFrame(index: index, of: frames, width: width, height: height)
            adaptor.append(buffer, withPresentationTime: CMTime(
                value: CMTimeValue(index),
                timescale: CMTimeScale(framesPerSecond)
            ))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw GVFixtureError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        return url
    }

    private static func makeFrame(index: Int, of frames: Int, width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &buffer
        ) == kCVReturnSuccess, let buffer
        else { throw GVFixtureError.bufferUnavailable }
        let level = UInt8(255.0 * Double(index) / Double(max(frames - 1, 1)))
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(buffer)
        else { throw GVFixtureError.bufferUnavailable }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let pitch = CVPixelBufferGetBytesPerRow(buffer)
        base.withMemoryRebound(to: UInt8.self, capacity: pitch * height) { bytes in
            for row in 0 ..< height {
                for column in 0 ..< width {
                    let offset = row * pitch + column * 4
                    bytes[offset] = level
                    bytes[offset + 1] = level
                    bytes[offset + 2] = level
                    bytes[offset + 3] = 255
                }
            }
        }
        return buffer
    }
}
