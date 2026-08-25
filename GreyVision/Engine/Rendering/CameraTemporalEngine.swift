import Foundation
import Metal
import QuartzCore

/// Timestamped frame history with interpolated sampling.
///
/// ## What this adds over `TemporalFrameBuffer`
///
/// The existing ring holds four taps at fixed frame strides. That is enough to
/// ask "give me something older", but not enough to ask "give me 1.4 seconds
/// ago" — the question every temporal effect actually wants to ask. Four fixed
/// strides also drift with frame rate: tap 3 is 500ms at 60fps and 1000ms at
/// 30fps, so an effect tuned on one device is wrong on another.
///
/// This engine stores frames in a texture array with a timestamp per slice, so
/// effects address history in **seconds** and get the same result regardless of
/// capture rate. Sampling between two slices gives temporal interpolation
/// rather than a hard cut between taps.
///
/// ## Ownership and cost
///
/// One array texture, allocated once per resolution. Writes are a blit into a
/// slice; nothing is copied through the CPU and nothing is allocated per frame.
/// Footprint is fixed and known up front:
///
///     slots × width × height × 4 bytes
///
/// At the default 16 slots and half-resolution 960×720 that is ~44MB. Under
/// memory pressure the engine sheds slots and then resolution, in that order,
/// because losing history depth degrades an effect gracefully while losing
/// resolution makes it look broken.
final class CameraTemporalEngine {
    /// A stored frame's identity. Kept CPU-side; the GPU reads timestamps from
    /// `timestampBuffer`.
    struct Slot {
        var timestamp: CFTimeInterval = 0
        var isValid = false
    }

    /// Maximum history depth. 16 slices at 60fps covers about a quarter second
    /// at every-frame capture, so the engine deliberately does not record every
    /// frame — see `minimumInterval`.
    static let maximumSlots = 16
    /// Hard ceiling on history footprint. Chosen well under the point where
    /// iOS starts terminating a camera app holding large GPU allocations.
    static let memoryBudgetBytes = 96 * 1024 * 1024

    private(set) var texture: MTLTexture?
    /// Per-slice capture time, in seconds relative to `originTime`. Float
    /// rather than double because the shader reads it and Metal has no double.
    private(set) var timestampBuffer: MTLBuffer?
    private(set) var slots: [Slot] = []
    private(set) var head = 0
    private(set) var slotCount = 0
    private(set) var isPrimed = false

    private let device: MTLDevice
    private var width = 0
    private var height = 0
    private var originTime: CFTimeInterval = CACurrentMediaTime()
    private var lastWrite: CFTimeInterval = 0
    private var divisor = 2

    /// Seconds between recorded frames.
    ///
    /// Recording every frame would fill 16 slices in a quarter second and make
    /// the deepest history younger than most effects want. Sampling at ~12Hz
    /// spans about 1.3 seconds, which covers the useful range for ghosting,
    /// occlusion and displacement while leaving interpolation to fill the gaps.
    private var minimumInterval: CFTimeInterval = 1.0 / 12.0

    init(device: MTLDevice) {
        self.device = device
    }

    /// Total span of history currently held, in seconds.
    var historySeconds: Double {
        let valid = slots.filter(\.isValid).map(\.timestamp)
        guard let oldest = valid.min(), let newest = valid.max() else { return 0 }
        return newest - oldest
    }

    var megabytes: Double {
        Double(width * height * 4 * slotCount) / (1024 * 1024)
    }

    /// Allocates for a source size. Idempotent once the size has settled.
    @discardableResult
    func prepare(sourceWidth: Int, sourceHeight: Int) -> Bool {
        guard sourceWidth > 0, sourceHeight > 0 else { return false }

        var targetSlots = Self.maximumSlots
        var targetWidth = max(sourceWidth / divisor, 16)
        var targetHeight = max(sourceHeight / divisor, 16)

        // Shed depth first, then resolution. A shallower history still looks
        // like the effect; a blurry one looks like a bug.
        while targetWidth * targetHeight * 4 * targetSlots > Self.memoryBudgetBytes {
            if targetSlots > 6 {
                targetSlots -= 2
            } else {
                targetWidth = max(targetWidth / 2, 16)
                targetHeight = max(targetHeight / 2, 16)
            }
        }

        if targetWidth == width, targetHeight == height, targetSlots == slotCount, texture != nil {
            return true
        }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .bgra8Unorm
        descriptor.width = targetWidth
        descriptor.height = targetHeight
        descriptor.arrayLength = targetSlots
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private

        guard let array = device.makeTexture(descriptor: descriptor),
              let buffer = device.makeBuffer(
                  length: MemoryLayout<Float>.stride * targetSlots,
                  options: .storageModeShared
              )
        else {
            reset()
            return false
        }

        array.label = "greyVISION Temporal Ring"
        buffer.label = "greyVISION Temporal Timestamps"

        texture = array
        timestampBuffer = buffer
        width = targetWidth
        height = targetHeight
        slotCount = targetSlots
        slots = Array(repeating: Slot(), count: targetSlots)
        head = 0
        isPrimed = false
        originTime = CACurrentMediaTime()
        lastWrite = 0
        writeTimestamps()
        return true
    }

    /// Whether this frame should be recorded.
    ///
    /// Rate-limited rather than every-frame, so the ring spans a useful
    /// duration instead of the last few hundred milliseconds.
    func shouldRecord(now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        guard texture != nil else { return false }
        return now - lastWrite >= minimumInterval
    }

    /// Advances the write cursor and stamps the new slice.
    ///
    /// Called after the blit is encoded. The timestamp is recorded at encode
    /// time rather than completion time: the frame being written is the one the
    /// renderer is holding now, and waiting for the GPU would stamp it late.
    func commitWrite(now: CFTimeInterval = CACurrentMediaTime()) {
        guard slotCount > 0 else { return }
        slots[head].timestamp = now - originTime
        slots[head].isValid = true
        lastWrite = now
        head = (head + 1) % slotCount
        if slots.allSatisfy(\.isValid) {
            isPrimed = true
        }
        writeTimestamps()
    }

    /// The slice the next write should target.
    var writeSlice: Int { head }

    /// Uniform block describing the ring to a shader.
    var uniforms: TemporalRingUniforms {
        TemporalRingUniforms(
            slotCount: UInt32(slotCount),
            head: UInt32(head),
            validCount: UInt32(slots.filter(\.isValid).count),
            isPrimed: isPrimed ? 1 : 0,
            currentTime: Float(CACurrentMediaTime() - originTime),
            historySpan: Float(historySeconds),
            padding: .zero
        )
    }

    func reset() {
        texture = nil
        timestampBuffer = nil
        slots = []
        slotCount = 0
        head = 0
        width = 0
        height = 0
        isPrimed = false
        lastWrite = 0
    }

    /// Drops history depth without reallocating, for memory-pressure response.
    func shed() {
        guard slotCount > 6 else { return }
        divisor = min(divisor * 2, 8)
        let currentWidth = width * divisor
        let currentHeight = height * divisor
        reset()
        prepare(sourceWidth: currentWidth, sourceHeight: currentHeight)
    }

    private func writeTimestamps() {
        guard let timestampBuffer else { return }
        let pointer = timestampBuffer.contents().bindMemory(to: Float.self, capacity: slotCount)
        for index in 0 ..< slotCount {
            // Invalid slices are stamped far in the past so a shader searching
            // for the nearest age can never select one.
            pointer[index] = slots[index].isValid ? Float(slots[index].timestamp) : -1e9
        }
    }
}

/// Ring description handed to shaders. Layout must match `GVTemporalRing` in
/// CameraShaders.metal.
struct TemporalRingUniforms {
    var slotCount: UInt32
    var head: UInt32
    var validCount: UInt32
    var isPrimed: UInt32
    var currentTime: Float
    var historySpan: Float
    var padding: SIMD2<Float>
}
