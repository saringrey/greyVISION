import CoreVideo
import Foundation

/// Recycles the pixel buffers the render thread copies finished frames into.
///
/// A pool rather than a fresh allocation per frame: `CVPixelBufferCreate` at
/// 60fps on a 4K surface is a measurable stall, and the encoder holds each
/// buffer only until it has read it, so a handful in rotation is enough.
///
/// Separate from the recorder's pool, which belongs to an `AVAssetWriter`
/// adaptor and only exists while a recording is running. Broadcasting is
/// independent of recording — either, both or neither can be live.
final class GVBroadcastFramePool: @unchecked Sendable {
    /// Deep enough that the encoder can hold two or three while the renderer
    /// fills the next. Beyond that a stalled encoder just accumulates latency,
    /// so the pool running dry is the correct backstop rather than a problem
    /// to solve with more buffers.
    private static let bufferCount = 4

    private let lock = NSLock()
    private var pool: CVPixelBufferPool?
    private var width = 0
    private var height = 0

    /// Returns a recycled buffer, rebuilding the pool if the frame size
    /// changed. Nil when the pool is exhausted, which the caller should treat
    /// as "skip this frame" rather than as an error.
    func buffer(width: Int, height: Int) -> CVPixelBuffer? {
        lock.withLock {
            if pool == nil || self.width != width || self.height != height {
                guard let rebuilt = Self.makePool(width: width, height: height) else { return nil }
                pool = rebuilt
                self.width = width
                self.height = height
            }
            guard let pool else { return nil }
            var buffer: CVPixelBuffer?
            let auxiliary = [
                kCVPixelBufferPoolAllocationThresholdKey as String: Self.bufferCount
            ] as CFDictionary
            // The threshold variant fails rather than growing without bound
            // when the encoder is behind. Unbounded growth here would show up
            // as latency, not as a crash, which is far harder to diagnose.
            let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                kCFAllocatorDefault,
                pool,
                auxiliary,
                &buffer
            )
            return status == kCVReturnSuccess ? buffer : nil
        }
    }

    func flush() {
        lock.withLock {
            pool = nil
            width = 0
            height = 0
        }
    }

    private static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            // Written by a Metal kernel, read by VideoToolbox. Both need the
            // buffer to be IOSurface-backed or the handoff copies.
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey as String: bufferCount] as CFDictionary,
            attributes as CFDictionary,
            &pool
        )
        return status == kCVReturnSuccess ? pool : nil
    }
}
