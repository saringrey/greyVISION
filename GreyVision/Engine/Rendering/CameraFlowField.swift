import Foundation
import Metal

/// The shared optical-flow pipeline.
///
/// One flow field for the whole engine. Datamosh, motion hold, motion
/// transplant and flow sort all read these textures rather than each running
/// their own estimator, which is the difference between one cheap pass and
/// four expensive ones fighting for the same frame budget.
///
/// Everything is GPU-resident and fixed size. Nothing is read back to the CPU,
/// no per-frame allocation happens after `prepare`, and the footprint cannot
/// grow: five RG16F textures at a fixed working resolution.
///
/// Flow is estimated at a reduced resolution on purpose. Motion vectors are
/// low-frequency data — the useful signal is where a region went, not where a
/// pixel went — so a quarter-scale estimate upsamples cleanly and costs a
/// sixteenth of the work.
final class CameraFlowField {
    /// Longest edge of the flow working resolution. Vectors are smooth enough
    /// that this upsamples without visible blocking, and the cost of the
    /// search scales with the square of this number.
    private static let workingEdge = 192

    /// Live per-frame estimate.
    private(set) var current: MTLTexture?
    /// Previous frame's estimate, for temporal smoothing of the field itself.
    private(set) var previous: MTLTexture?
    /// Motion accumulated over time. This is what makes displacement outlive
    /// the frame that created it, and it is the core of realtime datamosh.
    private(set) var persistent: MTLTexture?
    /// Write half of the persistent-field ping-pong pair. Accumulating back
    /// into `persistent` while sampling it is an undefined read/write hazard
    /// on tile GPUs and was the reason datamosh could collapse or stop moving.
    private(set) var persistentOutput: MTLTexture?
    /// A snapshot of `persistent`, held while MOTION HOLD is engaged or
    /// captured for MOTION TRANSPLANT.
    private(set) var frozen: MTLTexture?

    /// Luma of the previous frame, the reference the search matches against.
    private(set) var previousLuma: MTLTexture?
    private(set) var currentLuma: MTLTexture?

    /// False until two frames have been seen. Consumers must not read the
    /// field before this, or the first frame will displace against noise.
    private(set) var isPrimed = false
    /// Newly allocated private textures have undefined contents. The renderer
    /// consumes this latch and clears all vector fields before the first read.
    private(set) var needsClear = false
    /// Set once a snapshot exists in `frozen`.
    private(set) var hasSnapshot = false

    private let device: MTLDevice
    private var width = 0
    private var height = 0

    init(device: MTLDevice) {
        self.device = device
    }

    /// Allocates the field for a given source size. Cheap and idempotent once
    /// the size has settled.
    @discardableResult
    func prepare(sourceWidth: Int, sourceHeight: Int, maximumEdge: Int = 192) -> Bool {
        guard sourceWidth > 0, sourceHeight > 0 else { return false }

        let longest = max(sourceWidth, sourceHeight)
        let scale = min(Double(min(max(maximumEdge, 64), Self.workingEdge)) / Double(longest), 1)
        let targetWidth = max(Int((Double(sourceWidth) * scale).rounded()), 16)
        let targetHeight = max(Int((Double(sourceHeight) * scale).rounded()), 16)

        if targetWidth == width, targetHeight == height, current != nil {
            return true
        }

        width = targetWidth
        height = targetHeight
        isPrimed = false
        hasSnapshot = false
        needsClear = true

        let vectors = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        vectors.usage = [.shaderRead, .shaderWrite]
        vectors.storageMode = .private

        let luma = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        luma.usage = [.shaderRead, .shaderWrite]
        luma.storageMode = .private

        guard let currentTexture = device.makeTexture(descriptor: vectors),
              let previousTexture = device.makeTexture(descriptor: vectors),
              let persistentTexture = device.makeTexture(descriptor: vectors),
              let persistentOutputTexture = device.makeTexture(descriptor: vectors),
              let frozenTexture = device.makeTexture(descriptor: vectors),
              let lumaA = device.makeTexture(descriptor: luma),
              let lumaB = device.makeTexture(descriptor: luma)
        else {
            reset()
            return false
        }

        currentTexture.label = "greyVISION Flow Current"
        previousTexture.label = "greyVISION Flow Previous"
        persistentTexture.label = "greyVISION Flow Persistent"
        persistentOutputTexture.label = "greyVISION Flow Persistent Output"
        frozenTexture.label = "greyVISION Flow Frozen"
        lumaA.label = "greyVISION Flow Luma A"
        lumaB.label = "greyVISION Flow Luma B"

        current = currentTexture
        previous = previousTexture
        persistent = persistentTexture
        persistentOutput = persistentOutputTexture
        frozen = frozenTexture
        currentLuma = lumaA
        previousLuma = lumaB
        return true
    }

    /// Rotates the luma pair and the flow pair after a frame is encoded.
    ///
    /// Swapping references rather than blitting keeps the per-frame cost at
    /// zero: this frame's luma becomes next frame's reference in place.
    func advance() {
        swap(&currentLuma, &previousLuma)
        swap(&current, &previous)
        if !isPrimed {
            // One full frame has now been through the pipeline, so the next
            // estimate has a genuine reference to match against.
            isPrimed = true
        }
    }

    /// Makes the field just written by the accumulator the field consumers
    /// read this frame. Swapping references avoids a full-texture copy.
    func advancePersistent() {
        swap(&persistent, &persistentOutput)
    }

    func markCleared() {
        needsClear = false
    }

    /// Marks the current persistent field as captured.
    func markSnapshot() {
        hasSnapshot = true
    }

    func clearSnapshot() {
        hasSnapshot = false
    }

    /// Drops every reference. Called when the surface tears down so the GPU
    /// allocations go with it rather than living until the next size change.
    func reset() {
        current = nil
        previous = nil
        persistent = nil
        persistentOutput = nil
        frozen = nil
        currentLuma = nil
        previousLuma = nil
        width = 0
        height = 0
        isPrimed = false
        hasSnapshot = false
        needsClear = false
    }

    var size: (width: Int, height: Int) {
        (width, height)
    }

    /// Fixed footprint in megabytes, for the diagnostics readout.
    var megabytes: Double {
        // 5 vector textures at 4 bytes per texel, 2 luma at 2 bytes.
        let bytes = width * height * (5 * 4 + 2 * 2)
        return Double(bytes) / (1024 * 1024)
    }
}
