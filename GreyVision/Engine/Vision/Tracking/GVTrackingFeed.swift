import CoreGraphics
import Foundation

/// One downsampled analysis frame: tightly packed RGBA8 in sRGB, top-left
/// origin, upright in interface orientation — the same frame the preview
/// shows, before any effect has touched it.
struct GVTrackingFrame: Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt8]
    /// Uptime the frame was rendered.
    let timestamp: Double
    /// The part of the full working frame this analysis frame covers, in
    /// normalised coordinates — the preview's visible crop.
    var region = CGRect(x: 0, y: 0, width: 1, height: 1)

    @inline(__always)
    func rgb(_ x: Int, _ y: Int) -> SIMD3<Float> {
        let index = (y * width + x) * 4
        return SIMD3(Float(pixels[index]), Float(pixels[index + 1]), Float(pixels[index + 2])) / 255
    }

    func makeCGImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// The hand-off between the renderer and the tracker.
///
/// The renderer asks `shouldCapture(at:)` once per drawn frame; only while
/// tracking is running, and only at the analysis rate, does it spend a small
/// GPU downsample and hand the bytes to `deliver`. Tracking therefore sees
/// exactly what the preview sees — camera, simulator feed or a scrubbed take
/// — instead of being wired to one capture source's sample buffers.
final class GVTrackingFeed: @unchecked Sendable {
    /// Long edge of the analysis frame. Large enough for Vision to read a
    /// word or find a face across a room, small enough to copy and segment
    /// in a millisecond or two.
    static let longEdge = 384

    private let lock = NSLock()
    private var consumer: (@Sendable (GVTrackingFrame) -> Void)?
    private var interval = 1.0 / 15
    private var lastCapture = -Double.infinity
    private var inFlight = false
    private var snapshot: GVTrackingSnapshot?

    var isActive: Bool { lock.withLock { consumer != nil } }

    func attach(rate: Double, consumer: @escaping @Sendable (GVTrackingFrame) -> Void) {
        lock.withLock {
            self.consumer = consumer
            interval = 1 / max(rate, 1)
            lastCapture = -Double.infinity
            inFlight = false
        }
    }

    func setRate(_ rate: Double) {
        lock.withLock { interval = 1 / max(rate, 1) }
    }

    func detach() {
        lock.withLock {
            consumer = nil
            inFlight = false
            snapshot = nil
        }
    }

    /// The newest tracking result, for anything that draws it outside the
    /// interface — the recorder and the still capture. Nil while tracking is off.
    var latestSnapshot: GVTrackingSnapshot? { lock.withLock { snapshot } }

    func publish(_ snapshot: GVTrackingSnapshot) {
        lock.withLock {
            guard consumer != nil else { return }
            self.snapshot = snapshot
        }
    }

    /// True when the renderer should downsample this frame. At most one
    /// capture is in flight, so a slow analysis pass sheds frames instead of
    /// queueing them.
    func shouldCapture(at time: Double) -> Bool {
        lock.withLock {
            guard consumer != nil, !inFlight, time - lastCapture >= interval * 0.92 else { return false }
            lastCapture = time
            inFlight = true
            return true
        }
    }

    func deliver(_ frame: GVTrackingFrame) {
        let consumer = lock.withLock { () -> (@Sendable (GVTrackingFrame) -> Void)? in
            inFlight = false
            return self.consumer
        }
        consumer?(frame)
    }

    /// Clears the in-flight flag when a capture could not be encoded.
    func abandon() {
        lock.withLock { inFlight = false }
    }

    /// The centred crop of a source that an aspect-fill preview of the given
    /// aspect (width / height) actually shows, in normalised coordinates.
    static func visibleRegion(sourceWidth: Int, sourceHeight: Int, viewAspect: Double) -> CGRect {
        let sourceAspect = Double(max(sourceWidth, 1)) / Double(max(sourceHeight, 1))
        guard viewAspect.isFinite, viewAspect > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        if sourceAspect > viewAspect {
            let width = viewAspect / sourceAspect
            return CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
        }
        let height = sourceAspect / viewAspect
        return CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
    }

    /// Analysis frame size for the visible part of a source: long edge
    /// `longEdge`, even edges.
    static func size(sourceWidth: Int, sourceHeight: Int, region: CGRect,
                     longEdge: Int = longEdge) -> (width: Int, height: Int) {
        let visibleWidth = Double(sourceWidth) * region.width
        let visibleHeight = Double(sourceHeight) * region.height
        let scale = Double(longEdge) / max(visibleWidth, visibleHeight, 1)
        let width = max(Int((visibleWidth * scale).rounded()) & ~1, 8)
        let height = max(Int((visibleHeight * scale).rounded()) & ~1, 8)
        return (width, height)
    }
}
