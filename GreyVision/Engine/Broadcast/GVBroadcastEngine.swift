import CoreMedia
import Foundation
import QuartzCore

/// Live telemetry for the link, polled by the UI rather than pushed to it.
///
/// Same shape as `CameraRenderStats`: the render thread must never schedule
/// SwiftUI work, so it writes numbers into a mailbox and the UI reads them on
/// its own clock.
struct GVBroadcastStats: Equatable, Sendable {
    var framesPerSecond: Double = 0
    var kilobitsPerSecond: Double = 0
    var droppedFrames = 0
    var width = 0
    var height = 0
    var codec = ""

    static let idle = GVBroadcastStats()
}

/// Wires the encoder to the link and owns everything the render thread
/// touches.
///
/// Deliberately not `@MainActor`: `submit` is called from a Metal
/// command-buffer completion handler. Hopping to the main actor per frame
/// would put encode latency behind whatever SwiftUI is doing, which is the one
/// thing a live link cannot afford.
final class GVBroadcastEngine: @unchecked Sendable {
    private let encoder = GVBroadcastEncoder()
    private let link = GVBroadcastLink()
    private let lock = NSLock()

    private var isRunning = false
    private var startTimestamp: CFTimeInterval = 0
    private var announcedSize = CGSize.zero
    private var latestFormat: GVBroadcastVideoFormat?

    /// Rolling one-second window. A running average over the whole session
    /// hides exactly the thing the operator is watching for — the moment the
    /// link starts falling behind.
    private var windowStart: CFTimeInterval = 0
    private var windowFrames = 0
    private var windowBytes = 0
    private var publishedStats = GVBroadcastStats.idle

    private var bitrate: Int
    private let frameRate: Int

    var onStateChange: (@Sendable (GVBroadcastLinkState) -> Void)?

    init(bitrate: Int = 12_000_000, frameRate: Int = 30) {
        self.bitrate = bitrate
        self.frameRate = frameRate

        encoder.setHandlers(
            onFrame: { [weak self] frame in self?.dispatch(frame) },
            onFormat: { [weak self] format in self?.publishFormat(format) }
        )
        link.onStateChange = { [weak self] state in
            guard let self else { return }
            // A peer that just attached has no parameter sets and no sync
            // sample. Send what we already have, then force a keyframe so it
            // has something to decode against within one frame instead of
            // waiting up to two seconds for the next scheduled one.
            if case .connected = state {
                self.resendHandshake()
                self.encoder.requestKeyframe()
            }
            self.onStateChange?(state)
        }
        link.onCommand = { [weak self] command in
            guard let self else { return }
            switch command {
            case .requestKeyframe:
                self.encoder.requestKeyframe()
            case let .setBitrate(value):
                let clamped = min(max(value, 1_000_000), 60_000_000)
                self.lock.withLock { self.bitrate = clamped }
                self.encoder.setBitrate(clamped)
            }
        }
    }

    var isConnected: Bool { link.isConnected }

    // MARK: - Lifecycle

    func start(serviceName: String, passcode: String) {
        lock.withLock {
            isRunning = true
            startTimestamp = CACurrentMediaTime()
            windowStart = startTimestamp
            windowFrames = 0
            windowBytes = 0
            latestFormat = nil
            announcedSize = .zero
        }
        link.start(serviceName: serviceName, passcode: passcode)
    }

    func stop() {
        lock.withLock {
            isRunning = false
            publishedStats = .idle
        }
        link.stop()
        encoder.invalidate()
    }

    // MARK: - Frame intake

    /// Hands one finished frame to the encoder. Called on the render thread.
    ///
    /// Everything here is either a lock-guarded read or a VideoToolbox call
    /// that is safe off the main thread; nothing allocates per frame beyond
    /// what the encoder itself needs.
    func submit(_ pixelBuffer: CVPixelBuffer, hostTime: CFTimeInterval) {
        let running = lock.withLock { isRunning }
        // Nothing attached means nothing to encode. Skipping here rather than
        // inside the encoder keeps the whole cost at one lock read while the
        // feature is armed but idle.
        guard running, link.isConnected else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let currentBitrate = lock.withLock { bitrate }
        guard encoder.prepare(width: width, height: height, bitrate: currentBitrate, frameRate: frameRate) else {
            return
        }

        let sizeChanged = lock.withLock { () -> Bool in
            let size = CGSize(width: width, height: height)
            guard announcedSize != size else { return false }
            announcedSize = size
            return true
        }
        if sizeChanged {
            sendHello(width: width, height: height)
        }

        let base = lock.withLock { startTimestamp }
        encoder.encode(
            pixelBuffer,
            presentationTime: CMTime(seconds: max(hostTime - base, 0), preferredTimescale: 90_000)
        )
    }

    // MARK: - Outbound

    private func dispatch(_ frame: GVBroadcastEncoder.EncodedFrame) {
        link.send(
            kind: .videoFrame,
            payload: frame.data,
            isKeyframe: frame.isKeyframe,
            timestampNanoseconds: Int64(frame.presentationTime.seconds * 1_000_000_000)
        )
        recordStats(bytes: frame.data.count)
    }

    private func publishFormat(_ format: GVBroadcastVideoFormat) {
        lock.withLock { latestFormat = format }
        guard let payload = try? JSONEncoder().encode(format) else { return }
        link.send(kind: .videoFormat, payload: payload)
    }

    private func sendHello(width: Int, height: Int) {
        let hello = GVBroadcastHello(
            deviceName: GVBroadcastEngine.deviceName,
            width: width,
            height: height,
            codec: encoder.codecFourCC
        )
        guard let payload = try? JSONEncoder().encode(hello) else { return }
        link.send(kind: .hello, payload: payload)
    }

    /// Replays the handshake for a peer that attached after it was first sent.
    private func resendHandshake() {
        let (size, format) = lock.withLock { (announcedSize, latestFormat) }
        if size != .zero {
            sendHello(width: Int(size.width), height: Int(size.height))
        }
        if let format, let payload = try? JSONEncoder().encode(format) {
            link.send(kind: .videoFormat, payload: payload)
        }
    }

    // MARK: - Stats

    private func recordStats(bytes: Int) {
        let now = CACurrentMediaTime()
        lock.withLock {
            windowFrames += 1
            windowBytes += bytes
            let elapsed = now - windowStart
            guard elapsed >= 1 else { return }
            publishedStats = GVBroadcastStats(
                framesPerSecond: Double(windowFrames) / elapsed,
                kilobitsPerSecond: Double(windowBytes) * 8 / elapsed / 1000,
                droppedFrames: link.droppedFrameCount,
                width: Int(announcedSize.width),
                height: Int(announcedSize.height),
                codec: encoder.codecFourCC
            )
            windowStart = now
            windowFrames = 0
            windowBytes = 0
        }
    }

    var stats: GVBroadcastStats {
        lock.withLock { publishedStats }
    }

    private static var deviceName: String {
        // `UIDevice.name` is privacy-gated and returns a generic model string
        // without an entitlement, so there is nothing to gain from importing
        // UIKit here. The operator names the link on the Mac anyway.
        ProcessInfo.processInfo.hostName
    }
}
