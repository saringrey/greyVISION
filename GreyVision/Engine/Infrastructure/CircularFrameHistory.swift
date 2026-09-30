import Foundation
import Metal

struct CircularFrameHistoryConfiguration: Equatable, Sendable {
    var dimensions: RenderDimensions
    var pixelFormat: MTLPixelFormat
    var requestedCapacity: Int
    var memoryBudgetBytes: Int
    var usage: MTLTextureUsage

    init(
        dimensions: RenderDimensions,
        pixelFormat: MTLPixelFormat = .rgba16Float,
        requestedCapacity: Int,
        memoryBudgetBytes: Int,
        usage: MTLTextureUsage = [.shaderRead, .shaderWrite]
    ) {
        self.dimensions = dimensions
        self.pixelFormat = pixelFormat
        self.requestedCapacity = max(requestedCapacity, 1)
        self.memoryBudgetBytes = max(memoryBudgetBytes, 1)
        self.usage = usage
    }
}

struct TemporalFrameReference: @unchecked Sendable {
    let texture: MTLTexture
    let timestamp: TimeInterval
    let sequence: UInt64
}

enum CircularFrameHistoryError: Error, Equatable {
    case invalidDimensions
    case budgetTooSmall
    case allocationFailed
    case incompatibleSource
    case commandEncoderUnavailable
}

final class CircularFrameHistory: @unchecked Sendable {
    typealias Resampler = (
        _ source: MTLTexture,
        _ destination: MTLTexture,
        _ commandBuffer: MTLCommandBuffer
    ) -> Bool

    private struct Slot {
        let texture: MTLTexture
        var timestamp: TimeInterval = 0
        var sequence: UInt64 = 0
        var isValid = false
    }

    private let device: MTLDevice
    private(set) var configuration: CircularFrameHistoryConfiguration
    private var slots: [Slot] = []
    private var nextWriteIndex = 0
    private var validCount = 0
    private var sequence: UInt64 = 0

    init(device: MTLDevice, configuration: CircularFrameHistoryConfiguration) throws {
        self.device = device
        self.configuration = configuration
        try allocate(configuration: configuration)
    }

    var capacity: Int { slots.count }
    var count: Int { validCount }
    var allocatedBytes: Int {
        guard let first = slots.first else { return 0 }
        return slots.count * first.texture.width * first.texture.height *
            TexturePool.bytesPerPixel(first.texture.pixelFormat)
    }

    /// `framesAgo == 0` is the newest committed frame; 1 is its predecessor.
    func frame(framesAgo: Int) -> TemporalFrameReference? {
        guard framesAgo >= 0, framesAgo < validCount, !slots.isEmpty else { return nil }
        let index = (nextWriteIndex - 1 - framesAgo + slots.count * 2) % slots.count
        let slot = slots[index]
        guard slot.isValid else { return nil }
        return TemporalFrameReference(
            texture: slot.texture,
            timestamp: slot.timestamp,
            sequence: slot.sequence
        )
    }

    func frame(closestTo timestamp: TimeInterval) -> TemporalFrameReference? {
        (0 ..< validCount)
            .compactMap { frame(framesAgo: $0) }
            .min { abs($0.timestamp - timestamp) < abs($1.timestamp - timestamp) }
    }

    func age(of frame: TemporalFrameReference, at timestamp: TimeInterval) -> TimeInterval {
        max(timestamp - frame.timestamp, 0)
    }

    /// Encodes a same-size/same-format GPU copy into the next ring slot.
    @discardableResult
    func encodeAppend(
        source: MTLTexture,
        timestamp: TimeInterval,
        commandBuffer: MTLCommandBuffer
    ) throws -> TemporalFrameReference {
        guard source.width == configuration.dimensions.width,
              source.height == configuration.dimensions.height,
              source.pixelFormat == configuration.pixelFormat
        else { throw CircularFrameHistoryError.incompatibleSource }
        guard !slots.isEmpty else { throw CircularFrameHistoryError.allocationFailed }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw CircularFrameHistoryError.commandEncoderUnavailable
        }

        let destination = slots[nextWriteIndex].texture
        blit.label = "greyVISION temporal history append"
        blit.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: .init(x: 0, y: 0, z: 0),
            sourceSize: .init(width: source.width, height: source.height, depth: 1),
            to: destination,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: .init(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()

        sequence &+= 1
        slots[nextWriteIndex].timestamp = timestamp.isFinite ? timestamp : 0
        slots[nextWriteIndex].sequence = sequence
        slots[nextWriteIndex].isValid = true
        let reference = TemporalFrameReference(
            texture: destination,
            timestamp: slots[nextWriteIndex].timestamp,
            sequence: sequence
        )
        nextWriteIndex = (nextWriteIndex + 1) % slots.count
        validCount = min(validCount + 1, slots.count)
        return reference
    }

    /// Preserves newest frames only when a GPU resampler is supplied. Without
    /// one, format changes intentionally reset rather than issuing an invalid blit.
    func reconfigure(
        _ newConfiguration: CircularFrameHistoryConfiguration,
        commandBuffer: MTLCommandBuffer? = nil,
        resampler: Resampler? = nil
    ) throws {
        let previous = (0 ..< validCount).compactMap { frame(framesAgo: $0) }
        let oldConfiguration = configuration
        configuration = newConfiguration
        do {
            try allocate(configuration: newConfiguration)
        } catch {
            configuration = oldConfiguration
            throw error
        }

        guard let commandBuffer, let resampler else { return }
        let preserveCount = min(previous.count, capacity)
        guard preserveCount > 0 else { return }
        for age in stride(from: preserveCount - 1, through: 0, by: -1) {
            let old = previous[age]
            let destination = slots[nextWriteIndex].texture
            guard resampler(old.texture, destination, commandBuffer) else {
                reset()
                return
            }
            slots[nextWriteIndex].timestamp = old.timestamp
            slots[nextWriteIndex].sequence = old.sequence
            slots[nextWriteIndex].isValid = true
            nextWriteIndex = (nextWriteIndex + 1) % slots.count
            validCount += 1
            sequence = max(sequence, old.sequence)
        }
    }

    func trim(to maximumCount: Int) {
        let target = min(max(maximumCount, 0), slots.count)
        guard target < slots.count else { return }
        configuration.requestedCapacity = max(target, 1)
        if target == 0 {
            slots.removeAll(keepingCapacity: false)
            nextWriteIndex = 0
            validCount = 0
            return
        }
        // Memory pressure prioritizes bounded allocation over preserving pixels.
        try? allocate(configuration: configuration)
    }

    func reset() {
        for index in slots.indices {
            slots[index].timestamp = 0
            slots[index].sequence = 0
            slots[index].isValid = false
        }
        nextWriteIndex = 0
        validCount = 0
    }

    private func allocate(configuration: CircularFrameHistoryConfiguration) throws {
        guard configuration.dimensions.isValid else {
            throw CircularFrameHistoryError.invalidDimensions
        }
        let key = TexturePoolKey(
            width: configuration.dimensions.width,
            height: configuration.dimensions.height,
            pixelFormat: configuration.pixelFormat,
            usage: configuration.usage
        )
        let frameBytes = TexturePool.estimatedBytes(for: key)
        let budgetCapacity = configuration.memoryBudgetBytes / max(frameBytes, 1)
        let capacity = min(configuration.requestedCapacity, budgetCapacity)
        guard capacity > 0 else { throw CircularFrameHistoryError.budgetTooSmall }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: key.pixelFormat,
            width: key.width,
            height: key.height,
            mipmapped: false
        )
        descriptor.usage = key.usage
        descriptor.storageMode = key.storageMode
        var created: [Slot] = []
        created.reserveCapacity(capacity)
        for index in 0 ..< capacity {
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw CircularFrameHistoryError.allocationFailed
            }
            texture.label = "greyVISION history \(index)"
            created.append(Slot(texture: texture))
        }
        slots = created
        nextWriteIndex = 0
        validCount = 0
    }
}
