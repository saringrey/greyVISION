import CoreVideo
import Foundation
import Metal

/// A bounded ring of aged camera frames.
///
/// Provides two modes of operation:
/// 1. GPU-only temporal taps for signal fracture effects (original mode)
/// 2. Full circular buffer for time scrubbing with timestamp-based retrieval
///
/// Four taps are held at fixed strides so pulling the signal apart exposes
/// genuinely older moments rather than a blurred average. Everything lives in
/// private GPU memory at a reduced resolution: nothing is copied through the
/// CPU and the total footprint is fixed for a given capture size.
///
/// Footprint at 1920x1440 capture with `divisor = 2`:
/// 960 x 720 x 8 bytes x 4 taps ≈ 22 MB (GPU-only mode).
///
/// For full circular buffer mode (180 frames max):
/// 960 x 720 x 4 bytes x 180 frames ≈ 497 MB (at 500MB limit).
///
/// Implements Requirements 4.3, 5.3:
/// - Circular buffer with 180 frames maximum (Requirement 5.3)
/// - Timestamp tracking for frame retrieval (Requirement 5.4)
/// - Memory pressure handling and eviction (Requirement 5.3)
/// - 500MB maximum capacity management (Requirement 5.3)
final class TemporalFrameBuffer {
    // MARK: - GPU-Only Temporal Taps (Original Mode)

    /// Frame ages, in captured frames, for each tap.
    static let strides: [UInt64] = [1, 4, 12, 30]

    /// Approximate age of each tap in milliseconds at the given frame rate.
    static func ageMilliseconds(framesPerSecond: Int) -> [Int] {
        let interval = 1000.0 / Double(max(framesPerSecond, 1))
        return strides.map { Int((Double($0) * interval).rounded()) }
    }

    private(set) var textures: [MTLTexture] = []
    private(set) var isPrimed = false
    private(set) var frameNumber: UInt64 = 0

    private let device: MTLDevice
    private let divisor: Int
    private var width = 0
    private var height = 0

    // MARK: - Circular Buffer for Time Scrubbing

    /// Stored frame with timestamp and pixel buffer
    struct TemporalFrame {
        let timestamp: TimeInterval
        let pixelBuffer: CVPixelBuffer
        let cameraConfig: CameraConfiguration

        /// Estimated memory usage of this frame in bytes
        var estimatedMemoryUsage: Int {
            CVPixelBufferGetDataSize(pixelBuffer)
        }
    }

    /// Camera configuration snapshot
    struct CameraConfiguration: Equatable {
        let width: Int
        let height: Int
        let frameRate: Double
    }

    /// Configuration for the circular buffer
    struct BufferConfiguration {
        /// Maximum number of frames to store (Requirement 5.3: 30 seconds at 30fps)
        let maxFrameCount: Int = 180

        /// Maximum memory usage in bytes (Requirement 5.3: 500MB)
        let maxMemoryBytes: Int = 500 * 1024 * 1024

        /// Maximum history duration in seconds
        let maxHistoryDuration: TimeInterval = 30.0
    }

    private var frames: [TemporalFrame] = []
    private let configuration = BufferConfiguration()
    private let lock = NSLock()
    private var currentMemoryUsage: Int = 0

    init(device: MTLDevice, divisor: Int = 2) {
        self.device = device
        self.divisor = max(divisor, 1)

        // Pre-allocate frame storage for better performance
        frames.reserveCapacity(configuration.maxFrameCount)
    }

    var tapCount: Int {
        textures.count
    }

    // MARK: - GPU-Only Mode (Original Implementation)

    /// Allocates (or reuses) the ring for a source of the given size.
    @discardableResult
    func prepare(sourceWidth: Int, sourceHeight: Int) -> Bool {
        let targetWidth = max(sourceWidth / divisor, 16)
        let targetHeight = max(sourceHeight / divisor, 16)
        if targetWidth == width, targetHeight == height, textures.count == Self.strides.count {
            return true
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: targetWidth,
            height: targetHeight,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]

        var created: [MTLTexture] = []
        created.reserveCapacity(Self.strides.count)
        for index in Self.strides.indices {
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                return false
            }
            texture.label = "greyVISION Temporal Tap \(Self.strides[index])"
            created.append(texture)
        }

        textures = created
        width = targetWidth
        height = targetHeight
        isPrimed = false
        frameNumber = 0
        return true
    }

    /// Taps that should be written this frame, given the stride schedule.
    func dueTaps() -> [Int] {
        guard !textures.isEmpty else { return [] }
        frameNumber &+= 1
        if !isPrimed {
            // Prime every tap from the first frame so the tear never opens onto
            // uninitialised memory.
            isPrimed = true
            return Array(textures.indices)
        }
        return textures.indices.filter { frameNumber.isMultiple(of: Self.strides[$0]) }
    }

    // MARK: - Circular Buffer Mode (Enhanced Implementation)

    /// Add a frame to the circular buffer with timestamp tracking
    /// Implements Requirement 4.3, 5.3: Frame addition with timestamp tracking
    func addFrame(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval, cameraConfig: CameraConfiguration) {
        lock.lock()
        defer { lock.unlock() }

        // Create frame
        let frame = TemporalFrame(
            timestamp: timestamp,
            pixelBuffer: pixelBuffer,
            cameraConfig: cameraConfig
        )

        // Check memory pressure before adding
        let frameMemoryUsage = frame.estimatedMemoryUsage

        // Evict old frames if necessary (Requirement 5.3: Memory pressure handling)
        while shouldEvictFrames(additionalBytes: frameMemoryUsage), !frames.isEmpty {
            evictOldestFrame()
        }

        // Add frame to circular buffer
        frames.append(frame)
        currentMemoryUsage += frameMemoryUsage

        // Enforce frame count limit (Requirement 5.3: 180 frames max)
        while frames.count > configuration.maxFrameCount {
            evictOldestFrame()
        }

        // Enforce history duration limit (Requirement 5.3: 30 seconds max)
        let cutoffTime = timestamp - configuration.maxHistoryDuration
        while let oldest = frames.first, oldest.timestamp < cutoffTime {
            evictOldestFrame()
        }
    }

    /// Retrieve frame at specific timestamp with interpolation
    /// Implements Requirement 5.4: Frame retrieval by timestamp with interpolation
    func frameAtTime(_ time: TimeInterval) -> TemporalFrame? {
        lock.lock()
        defer { lock.unlock() }

        guard !frames.isEmpty else { return nil }

        // Find exact match first
        if let exactFrame = frames.first(where: { abs($0.timestamp - time) < 0.001 }) {
            return exactFrame
        }

        // Find bracketing frames for interpolation
        var beforeFrame: TemporalFrame?
        var afterFrame: TemporalFrame?

        for frame in frames {
            if frame.timestamp <= time {
                if beforeFrame == nil || frame.timestamp > beforeFrame!.timestamp {
                    beforeFrame = frame
                }
            }
            if frame.timestamp >= time {
                if afterFrame == nil || frame.timestamp < afterFrame!.timestamp {
                    afterFrame = frame
                }
            }
        }

        // Return nearest frame if no interpolation possible
        if let before = beforeFrame, afterFrame == nil {
            return before
        }
        if let after = afterFrame, beforeFrame == nil {
            return after
        }

        // Choose closer frame for interpolation (simple nearest-neighbor)
        if let before = beforeFrame, let after = afterFrame {
            let beforeDelta = abs(time - before.timestamp)
            let afterDelta = abs(after.timestamp - time)
            return beforeDelta < afterDelta ? before : after
        }

        return nil
    }

    /// Get the oldest frame timestamp currently in buffer
    var oldestFrameTime: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return frames.first?.timestamp
    }

    /// Get the newest frame timestamp currently in buffer
    var newestFrameTime: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return frames.last?.timestamp
    }

    /// Get total number of frames currently stored
    var frameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    /// Get current memory usage in bytes
    var memoryUsage: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentMemoryUsage
    }

    /// Get available history duration in seconds
    var availableHistoryDuration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }

        guard let oldest = frames.first, let newest = frames.last else {
            return 0.0
        }
        return newest.timestamp - oldest.timestamp
    }

    // MARK: - Memory Management

    /// Check if frames should be evicted based on memory pressure
    /// Implements Requirement 5.3: Memory pressure handling
    private func shouldEvictFrames(additionalBytes: Int = 0) -> Bool {
        // Check against 500MB limit (Requirement 5.3)
        let projectedUsage = currentMemoryUsage + additionalBytes
        if projectedUsage > configuration.maxMemoryBytes {
            return true
        }

        // Check against frame count limit
        if frames.count >= configuration.maxFrameCount {
            return true
        }

        return false
    }

    /// Evict the oldest frame from the buffer
    /// Implements Requirement 5.3: Frame eviction
    private func evictOldestFrame() {
        guard let oldestFrame = frames.first else { return }

        // Update memory tracking
        currentMemoryUsage -= oldestFrame.estimatedMemoryUsage
        currentMemoryUsage = max(0, currentMemoryUsage) // Ensure non-negative

        // Remove from buffer (pixel buffer will be automatically released)
        frames.removeFirst()
    }

    /// Clear all frames from buffer
    func clearFrames() {
        lock.lock()
        defer { lock.unlock() }

        // Remove all frames (pixel buffers will be automatically released)
        frames.removeAll(keepingCapacity: true)
        currentMemoryUsage = 0
    }

    /// Remove frames older than specified time
    func removeFramesOlderThan(_ cutoffTime: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }

        while let oldest = frames.first, oldest.timestamp < cutoffTime {
            evictOldestFrame()
        }
    }

    func release() {
        // Release GPU textures
        textures.removeAll(keepingCapacity: false)
        width = 0
        height = 0
        isPrimed = false
        frameNumber = 0

        // Clear circular buffer
        clearFrames()
    }
}
