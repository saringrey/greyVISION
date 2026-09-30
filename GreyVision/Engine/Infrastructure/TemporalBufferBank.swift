import Foundation
import Metal

enum TemporalBufferResetReason: String, Codable, Sendable {
    case explicit
    case sourceChanged
    case orientationChanged
    case renderRestarted
    case memoryWarning
    case effectDisabled
}

enum TemporalBufferScope: Equatable, Sendable {
    case all
    case history(String)
    case effect(String)
}

final class TemporalBufferBank: @unchecked Sendable {
    static let sourceHistoryName = "engine.source"
    static let renderedHistoryName = "engine.rendered"

    private let device: MTLDevice
    private let lock = NSLock()
    private var histories: [String: CircularFrameHistory] = [:]
    private var pingPongs: [String: PingPongTextures] = [:]

    let memoryBudgetBytes: Int

    init(device: MTLDevice, memoryBudgetBytes: Int = 192 * 1024 * 1024) {
        self.device = device
        self.memoryBudgetBytes = max(memoryBudgetBytes, 1)
    }

    func history(named name: String) -> CircularFrameHistory? {
        lock.withLock { histories[name] }
    }

    @discardableResult
    func makeHistory(
        named name: String,
        dimensions: RenderDimensions,
        pixelFormat: MTLPixelFormat = .rgba16Float,
        capacity: Int
    ) throws -> CircularFrameHistory {
        try lock.withLock {
            if let existing = histories[name] { return existing }
            let remaining = max(memoryBudgetBytes - allocatedBytesLocked, 0)
            let configuration = CircularFrameHistoryConfiguration(
                dimensions: dimensions,
                pixelFormat: pixelFormat,
                requestedCapacity: capacity,
                memoryBudgetBytes: remaining
            )
            let history = try CircularFrameHistory(device: device, configuration: configuration)
            histories[name] = history
            return history
        }
    }

    /// `offset == 0` is newest, `-1` is one frame older, and so on.
    func texture(inHistory name: String, offset: Int) -> MTLTexture? {
        guard offset <= 0 else { return nil }
        return history(named: name)?.frame(framesAgo: abs(offset))?.texture
    }

    @discardableResult
    func makePingPong(named name: String, key: TexturePoolKey) -> PingPongTextures? {
        lock.withLock {
            if let existing = pingPongs[name] { return existing }
            guard allocatedBytesLocked + TexturePool.estimatedBytes(for: key) * 2 <= memoryBudgetBytes,
                  let pair = PingPongTextures(device: device, key: key, label: "greyVISION \(name)")
            else { return nil }
            pingPongs[name] = pair
            return pair
        }
    }

    func pingPong(named name: String) -> PingPongTextures? {
        lock.withLock { pingPongs[name] }
    }

    func reset(_ scope: TemporalBufferScope = .all, reason _: TemporalBufferResetReason = .explicit) {
        lock.withLock {
            switch scope {
            case .all:
                histories.values.forEach { $0.reset() }
            case let .history(name):
                histories[name]?.reset()
            case let .effect(identifier):
                let prefix = "effect.\(identifier)."
                histories.filter { $0.key.hasPrefix(prefix) }.forEach { $0.value.reset() }
                pingPongs = pingPongs.filter { !$0.key.hasPrefix(prefix) }
            }
        }
    }

    func handleMemoryWarning() {
        lock.withLock {
            histories.values.forEach { $0.trim(to: 2) }
            pingPongs.removeAll(keepingCapacity: false)
        }
    }

    var allocatedBytes: Int { lock.withLock { allocatedBytesLocked } }

    private var allocatedBytesLocked: Int {
        histories.values.reduce(0) { $0 + $1.allocatedBytes } +
            pingPongs.values.reduce(0) {
                $0 + $1.read.width * $1.read.height *
                    TexturePool.bytesPerPixel($1.read.pixelFormat) * 2
            }
    }
}
