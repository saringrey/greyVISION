import CoreGraphics
import Foundation
import Metal

/// Burns the tracking overlay into the frames that leave the device.
///
/// The display list is rasterised off the render thread, into one of two
/// overlay textures, only when the tracking result changes (at most 30 times a
/// second). The first raster is awaited so a cold still or take has marks;
/// subsequent frames blend the latest ready overlay in one compute pass.
/// Rasterising on the writer queue for every written frame — the first
/// version — cost most of a 4K take's frames.
final class GVTrackingBurnIn: @unchecked Sendable {
    /// Overlay long edge. Marks are line art; 1920 is sharp on a 4K take once
    /// blended, at a quarter of the raster cost.
    static let maximumEdge = 1920

    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private let queue = DispatchQueue(label: "com.saringrey.greyvision.tracking.burnin", qos: .userInitiated)
    private let lock = NSLock()
    /// CPU writes and GPU readers are mutually exclusive, under `lock`.
    private final class Overlay: @unchecked Sendable {
        let texture: MTLTexture
        var readers = 0

        init(_ texture: MTLTexture) { self.texture = texture }
    }

    private var textures: [Overlay] = []
    private var readyIndex: Int?
    private var rasterizing = false
    private var lastRasterTime = -Double.infinity
    private var lastSnapshotTime = -Double.infinity
    private var captureTexture: MTLTexture?

    init?(device: MTLDevice, library: MTLLibrary) {
        guard let function = library.makeFunction(name: "gvTrackingComposite"),
              let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }
        self.device = device
        self.pipeline = pipeline
    }

    /// Returns a texture holding `frame` with the tracking overlay over it, or
    /// `frame` itself when there is nothing to burn. Call only on frames that
    /// feed a still, a take or the link, on one render thread / command queue.
    func composite(frame: MTLTexture, snapshot: GVTrackingSnapshot?, commandBuffer: MTLCommandBuffer, now: Double) -> MTLTexture {
        guard let snapshot else {
            lock.withLock {
                readyIndex = nil
                // An already queued raster must not republish after tracking stops.
                textures = []
            }
            return frame
        }
        requestRaster(snapshot, frameSize: CGSize(width: frame.width, height: frame.height), now: now)
        guard let overlay = lock.withLock({ () -> Overlay? in
            guard let readyIndex else { return nil }
            let overlay = textures[readyIndex]
            overlay.readers += 1
            return overlay
        }) else { return frame }
        guard let output = captureTexture(like: frame),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            lock.withLock { overlay.readers -= 1 }
            return frame
        }
        commandBuffer.addCompletedHandler { [self, overlay] _ in
            lock.withLock { overlay.readers -= 1 }
        }
        encoder.label = "greyVISION Tracking Burn-in"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(frame, index: 0)
        encoder.setTexture(overlay.texture, index: 1)
        encoder.setTexture(output, index: 2)
        let width = pipeline.threadExecutionWidth
        encoder.dispatchThreads(MTLSize(width: output.width, height: output.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: max(pipeline.maxTotalThreadsPerThreadgroup / width, 1), depth: 1))
        encoder.endEncoding()
        return output
    }

    // MARK: Raster

    private func requestRaster(_ snapshot: GVTrackingSnapshot, frameSize: CGSize, now: Double) {
        let overlaySize = Self.overlaySize(for: frameSize)
        let needsInitialRaster = lock.withLock {
            readyIndex == nil || textures.first.map {
                $0.texture.width != overlaySize.width || $0.texture.height != overlaySize.height
            } ?? true
        }
        // Only cold capture / size changes wait. Drain an old raster before replacing its slots.
        if needsInitialRaster { queue.sync {} }
        let start = lock.withLock { () -> (Int, Overlay)? in
            let fresh = needsInitialRaster || snapshot.timestamp != lastSnapshotTime || now - lastRasterTime >= 1.0 / 30
            guard fresh, !rasterizing else { return nil }
            if textures.first.map({ $0.texture.width != overlaySize.width || $0.texture.height != overlaySize.height }) ?? true {
                textures = (0 ..< 2).compactMap { _ in Self.makeOverlay(device: device, size: overlaySize).map(Overlay.init) }
                readyIndex = nil
            }
            guard textures.count == 2,
                  let target = textures.indices.first(where: { $0 != readyIndex && textures[$0].readers == 0 })
            else { return nil }
            rasterizing = true
            lastRasterTime = now
            lastSnapshotTime = snapshot.timestamp
            return (target, textures[target])
        }
        guard let (target, overlay) = start else { return }
        let raster: @Sendable () -> Void = { [self, overlay] in
            let drawn = Self.raster(snapshot, frameSize: frameSize, into: overlay.texture, now: now)
            lock.withLock {
                if drawn, textures.indices.contains(target), textures[target] === overlay { readyIndex = target }
                rasterizing = false
            }
        }
        if needsInitialRaster { queue.sync(execute: raster) }
        else { queue.async(execute: raster) }
    }

    private static func raster(_ snapshot: GVTrackingSnapshot, frameSize: CGSize, into texture: MTLTexture, now: Double) -> Bool {
        let width = texture.width, height = texture.height
        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ), let data = context.data else { return false }
        // Drawn in frame coordinates, scaled down to the overlay.
        context.scaleBy(x: CGFloat(width) / frameSize.width, y: CGFloat(height) / frameSize.height)
        snapshot.burn(into: context, width: Int(frameSize.width), height: Int(frameSize.height), now: now)
        // Quartz's row 0 is the image's top, which is Metal's row 0 as well.
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: data, bytesPerRow: bytesPerRow)
        return true
    }

    private static func overlaySize(for frame: CGSize) -> (width: Int, height: Int) {
        let scale = min(1, Double(maximumEdge) / Double(max(frame.width, frame.height, 1)))
        return (max(Int(frame.width * scale), 1), max(Int(frame.height * scale), 1))
    }

    private static func makeOverlay(device: MTLDevice, size: (width: Int, height: Int)) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: size.width, height: size.height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    private func captureTexture(like frame: MTLTexture) -> MTLTexture? {
        if let captureTexture, captureTexture.width == frame.width, captureTexture.height == frame.height,
           captureTexture.pixelFormat == frame.pixelFormat
        {
            return captureTexture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: frame.pixelFormat, width: frame.width, height: frame.height, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        captureTexture = device.makeTexture(descriptor: descriptor)
        return captureTexture
    }
}
