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
    /// Audited handoff: the serial `encodeQueue` is the sole owner of the
    /// frame once handed off. The box retains the IOSurface-backed buffer
    /// across the async boundary so the render thread and encoder never
    /// observe a half-moved value.
    private final class FrameBox: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let hostTime: CFTimeInterval
        init(_ pixelBuffer: CVPixelBuffer, hostTime: CFTimeInterval) {
            self.pixelBuffer = pixelBuffer
            self.hostTime = hostTime
        }
    }

    private let encoder = GVBroadcastEncoder()
    private let link = GVBroadcastLink()
    private let lock = NSLock()
    /// VideoToolbox can occasionally block while its hardware queue drains.
    /// Never call it from Metal's command-buffer completion handler.
    private let encodeQueue = DispatchQueue(label: "greyVISION.broadcast.encode", qos: .userInitiated)
    private var queuedEncodes = 0
    private static let maximumQueuedEncodes = 2

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
    private var frameRate: Int
    private var requestedCodec = "hevc"

    var onStateChange: (@Sendable (GVBroadcastLinkState) -> Void)?
    /// Commands the encoder cannot satisfy on its own — everything that
    /// drives the composition. Forwarded verbatim; the engine deliberately
    /// knows nothing about effects.
    var onControlCommand: (@Sendable (GVBroadcastCommand) -> Void)?

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
                let clamped = min(max(value, 1_000_000), 120_000_000)
                self.lock.withLock { self.bitrate = clamped }
                self.encoder.setBitrate(clamped)
            default:
                // Composition commands. Handed up rather than interpreted
                // here: the effect stack lives on the main actor and this
                // closure runs on the link's queue.
                self.onControlCommand?(command)
            }
        }
    }

    var isConnected: Bool { link.isConnected }

    // MARK: - Lifecycle

    func configureProfile(frameRate: Int, requestedCodec: String) {
        lock.withLock {
            self.frameRate = min(max(frameRate, 1), 120)
            self.requestedCodec = requestedCodec
        }
    }

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
            queuedEncodes = 0
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
        // The Metal command-buffer completion handler only schedules work. A
        // bounded queue drops excess frames instead of letting encoder pressure
        // accumulate and freezing the camera UI.
        let shouldQueue = lock.withLock { () -> Bool in
            guard isRunning, link.isConnected, queuedEncodes < Self.maximumQueuedEncodes else { return false }
            queuedEncodes += 1
            return true
        }
        guard shouldQueue else { return }

        let box = FrameBox(pixelBuffer, hostTime: hostTime)
        encodeQueue.async { [weak self] in
            guard let self else { return }
            defer { self.lock.withLock { self.queuedEncodes = max(0, self.queuedEncodes - 1) } }
            guard self.lock.withLock({ self.isRunning }), self.link.isConnected else { return }

            let pixelBuffer = box.pixelBuffer
            let hostTime = box.hostTime
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let profile = self.lock.withLock { (self.bitrate, self.frameRate, self.requestedCodec) }
            guard self.encoder.prepare(
                width: width,
                height: height,
                bitrate: profile.0,
                frameRate: profile.1,
                requestedCodec: profile.2
            ) else { return }

            let sizeChanged = self.lock.withLock { () -> Bool in
                let size = CGSize(width: width, height: height)
                guard self.announcedSize != size else { return false }
                self.announcedSize = size
                return true
            }
            if sizeChanged {
                self.sendHello(width: width, height: height)
            }

            let base = self.lock.withLock { self.startTimestamp }
            self.encoder.encode(
                pixelBuffer,
                presentationTime: CMTime(seconds: max(hostTime - base, 0), preferredTimescale: 90_000)
            )
        }
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

    /// Puts a control-surface payload on the wire.
    ///
    /// Separate from `dispatch` because these are never dropped: a control
    /// message the desktop misses leaves its UI describing a composition the
    /// phone is not rendering, which is worse than a late frame.
    func sendControl(kind: GVBroadcastProtocol.MessageKind, payload: Data) {
        link.send(kind: kind, payload: payload)
    }

    private func sendHello(width: Int, height: Int) {
        let hello = GVBroadcastHello(
            deviceName: GVBroadcastEngine.deviceName,
            width: width,
            height: height,
            codec: encoder.codecFourCC,
            requestedCodec: lock.withLock { requestedCodec },
            frameRate: lock.withLock { frameRate }
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
