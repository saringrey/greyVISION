import Foundation
import Metal

/// The renderer's side of `GVTrackingFeed`: one small compute pass that turns
/// the clean source frame into an analysis frame, read back when the command
/// buffer completes. Two buffers alternate so a completion handler still
/// reading one never races the next capture writing it.
final class GVTrackingFeedEncoder {
    private let pipeline: MTLComputePipelineState
    private let buffers: [MTLBuffer]
    private var slot = 0
    private let longEdge: Int

    init?(device: MTLDevice, library: MTLLibrary, longEdge: Int = GVTrackingFeed.longEdge) {
        guard let function = library.makeFunction(name: "gvTrackingDownsample"),
              let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }
        let length = longEdge * longEdge * 4
        let buffers = (0 ..< 2).compactMap { _ in device.makeBuffer(length: length, options: .storageModeShared) }
        guard buffers.count == 2 else { return nil }
        self.pipeline = pipeline
        self.buffers = buffers
        self.longEdge = longEdge
    }

    /// Encodes a capture when the feed asks for one. Call once per drawn
    /// frame, after the source frame is ready and before effects run.
    func encodeIfNeeded(source: MTLTexture, commandBuffer: MTLCommandBuffer, feed: GVTrackingFeed,
                        time: Double, viewAspect: Double)
    {
        guard feed.shouldCapture(at: time) else { return }
        let region = GVTrackingFeed.visibleRegion(sourceWidth: source.width, sourceHeight: source.height, viewAspect: viewAspect)
        let (width, height) = GVTrackingFeed.size(sourceWidth: source.width, sourceHeight: source.height, region: region,
                                                 longEdge: longEdge)
        let buffer = buffers[slot]
        slot = (slot + 1) % buffers.count
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            feed.abandon()
            return
        }
        var size = SIMD2<UInt32>(UInt32(width), UInt32(height))
        encoder.label = "greyVISION Tracking Downsample"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBytes(&size, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
        var crop = SIMD4<Float>(Float(region.minX), Float(region.minY), Float(region.width), Float(region.height))
        encoder.setBytes(&crop, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        let threadWidth = pipeline.threadExecutionWidth
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: max(pipeline.maxTotalThreadsPerThreadgroup / threadWidth, 1), depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { [weak feed] completed in
            guard let feed else { return }
            guard completed.status == .completed else {
                feed.abandon()
                return
            }
            let count = width * height * 4
            let pixels = [UInt8](UnsafeBufferPointer(
                start: buffer.contents().bindMemory(to: UInt8.self, capacity: count), count: count
            ))
            feed.deliver(GVTrackingFrame(width: width, height: height, pixels: pixels, timestamp: time, region: region))
        }
    }
}
