import AVFoundation
import CoreVideo
import Foundation
import QuartzCore

/// Reads one frame out of a recorded take at a requested time.
///
/// Output is biplanar YUV in the video range — the shape a hardware decoder gives
/// back for ordinary H.264/HEVC, and the shape the render loop's existing
/// YUV-to-linear kernel already consumes. Asking for BGRA here would have meant a
/// second conversion kernel for a frame that is only ever previewed.
///
/// `AVAssetReader` can only begin decoding at a sync sample, so the seek target
/// snaps back to a preceding sync frame and the read advances from there. That is
/// why the contract is "the newest frame at or before `seconds`" rather than
/// "exactly this frame": promising frame accuracy would be a lie about what a
/// decoder can do, and a preview would flicker between a sample and its
/// predecessor every time the playhead crossed a frame boundary.
///
/// Reads are not free — walking from a sync sample costs more the further into the
/// file it starts — so a drag has to be able to give one up. A newer request
/// supersedes an older one, and a superseded read answers `nil` instead of
/// decoding a frame the playhead has already left behind. It still answers: a
/// caller waiting on a request nobody serves any more is a leaked task and a
/// gesture that stops responding mid-drag.
///
/// Thread-safe by lock plus a serial queue rather than by actor isolation, because
/// `AVAssetReader` is synchronous and blocks and an actor would hold a thread for
/// the duration of the decode anyway. `url` never changes and `generation` is
/// confined to `lock`, which is the `@unchecked Sendable` justification.
final class GVTakeFrameReader: @unchecked Sendable {
    /// How far back from the target a read starts looking for a sync sample:
    /// enough to cover a sparsely keyed take without walking the whole file.
    private static let runway = 0.5

    private let url: URL
    private let queue = DispatchQueue(label: "greyvision.take-frame-reader", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0

    init(url: URL) {
        self.url = url
    }

    /// The newest decodable frame at or before `seconds`.
    ///
    /// `nil` covers every "no preview" case — a missing file, a take with no video
    /// track, a reader the destination will not open, and a request a newer one has
    /// replaced — so the caller never has to catch anything to show nothing.
    func frame(at seconds: TimeInterval) async -> CVPixelBuffer? {
        let mine = lock.withLock {
            generation += 1
            return generation
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                let superseded = self.lock.withLock { self.generation > mine }
                continuation.resume(returning: superseded ? nil : self.read(seconds: seconds))
            }
        }
    }

    private func read(seconds: TimeInterval) -> CVPixelBuffer? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset)
        else { return nil }

        let start = CMTime(seconds: max(0, seconds - Self.runway), preferredTimescale: 600)
        let end = CMTime(seconds: seconds + Self.runway, preferredTimescale: 600)
        reader.timeRange = CMTimeRange(start: start, end: end)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var newest: CVPixelBuffer?
        // One frame of slack: presentation stamps are the timescale the writer chose,
        // and a sample exactly on the boundary is the frame being asked for.
        let tolerance = 1.0 / 60.0
        while reader.status == .reading, let sample = output.copyNextSampleBuffer() {
            let presentation = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard presentation <= seconds + tolerance else { break }
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
                newest = pixelBuffer
            }
        }
        reader.cancelReading()
        guard let chosen = newest else { return nil }
        // The sample buffer is the only thing retaining that surface, and it is gone
        // when this returns, so the frame is copied into a detached buffer rather
        // than handed back pointing at memory nothing owns.
        return Self.detach(chosen)
    }

    /// Copies the decoded surface out of the sample buffer that owns it.
    ///
    /// Plane by plane: a biplanar YUV frame is two allocations with two pitches, and
    /// copying only the first would hand back grey monochrome while looking exactly
    /// like a frame that decoded.
    private static func detach(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        var destination: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, CVPixelBufferGetPixelFormatType(source),
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferMetalCompatibilityKey: true
            ] as CFDictionary,
            &destination
        ) == kCVReturnSuccess, let destination
        else { return nil }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess,
              CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess
        else {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(destination, [])
            return nil
        }
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(destination, [])
        }
        for plane in 0 ..< CVPixelBufferGetPlaneCount(source) {
            guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let to = CVPixelBufferGetBaseAddressOfPlane(destination, plane)
            else { return nil }
            let sourcePitch = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let destinationPitch = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
            let rowBytes = min(sourcePitch, destinationPitch)
            for row in 0 ..< CVPixelBufferGetHeightOfPlane(source, plane) {
                memcpy(to + row * destinationPitch, from + row * sourcePitch, rowBytes)
            }
        }
        return destination
    }
}

/// One pending scrub-preview frame: newest wins, and it holds the viewfinder until
/// a newer one replaces it or the scrub settles.
///
/// Deliberately not consume-once. The renderer reads this once per draw, so a frame
/// taken on the first draw would put the live camera back on screen one tick after
/// the operator moved the playhead — a preview you cannot look at is not a preview.
/// What bounds it instead is a window: past `visibleFor` the frame is dropped
/// without being cleared, so a stale preview cannot leave the viewfinder showing a
/// take after the scrub ended. That is the failure a consume-once latch exists to
/// avoid, and it is the one this instrument cannot afford, because it also has a
/// real freeze control and the two must not be confusable.
final class CameraPreviewMailbox: @unchecked Sendable {
    struct Entry {
        let buffer: CVPixelBuffer
        /// Bumped on every publish, so a renderer that has already drawn this frame
        /// can tell a refresh from a repeat without comparing buffers.
        let generation: UInt64
        let publishedAt: CFTimeInterval
    }

    /// How long a preview holds the viewfinder without being refreshed. A drag
    /// republishes far faster than this, so in practice it only expires on release.
    static let visibleFor: CFTimeInterval = 1.2

    private let lock = NSLock()
    private var pending: Entry?
    private var generation: UInt64 = 0

    func publish(_ buffer: CVPixelBuffer) {
        lock.withLock {
            generation &+= 1
            pending = Entry(buffer: buffer, generation: generation, publishedAt: CACurrentMediaTime())
        }
    }

    /// The frame to draw, or nil once the window has passed.
    func frame(now: CFTimeInterval) -> Entry? {
        lock.withLock {
            guard let pending, now - pending.publishedAt < Self.visibleFor else { return nil }
            return pending
        }
    }
}
