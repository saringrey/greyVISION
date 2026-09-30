import AppKit
import CoreImage
import CoreMedia
import CryptoKit
import Foundation
import Network
import VideoToolbox

/// Owns the network side of the link: discovers the phone, completes the
/// TLS-PSK handshake, and pushes framed messages to the rest of the app.
///
/// Mirrors `GVBroadcastLink` on the phone side, but in reverse: the Mac is
/// the client and the phone is the listener. Same header, same payloads,
/// same drift-prevention rationale that lives in the iPhone protocol file.
///
/// Keeping the source, the remote control and the view as three separate
/// files is what lets each one be replaced in isolation — a different
/// transport, a different UI shell, a different decoder — without rebuilding
/// the others.
struct GVLinkHealth: Equatable, Sendable {
    var framesPerSecond: Double = 0
    var kilobitsPerSecond: Double = 0
    var receivedFrames: Int = 0
    var decoderStatus: String = "IDLE"
}

final class GVPhoneLink: @unchecked Sendable {
    enum LinkState: Equatable {
        case idle
        case searching
        case connecting(peer: String)
        case connected(peer: String)
        case failed(reason: String)
    }

    // MARK: - Output

    var onImage: ((NSImage) -> Void)?
    var onPixelBuffer: ((CVPixelBuffer, CMTime) -> Void)?
    var onStatus: ((String, Bool) -> Void)?
    var onVideoFormat: ((GVBroadcastVideoFormat) -> Void)?
    var onHello: ((GVBroadcastHello) -> Void)?
    var onHealth: ((GVLinkHealth) -> Void)?
    var onControlSurface: ((GVBroadcastControlSurface) -> Void)?
    var onControlState: ((GVBroadcastControlState) -> Void)?
    var onLinkState: ((LinkState) -> Void)?

    // MARK: - Internals

    private let queue = DispatchQueue(label: "greyvision.maccapture.link")
    private let decoder = GVVideoDecoder()
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var didConnect = false
    private var receivedFrameCount = 0
    private var healthWindowStart = CACurrentMediaTime()
    private var healthWindowFrames = 0
    private var healthWindowBytes = 0
    private var desiredBitrate: Int?
    private var requestedServiceName = ""
    private var lastLinkState: LinkState = .idle
    /// Passcode for the in-flight search, kept so the peer-to-peer fallback can
    /// rebuild identical TLS parameters without asking the caller again.
    private var passcodeForSearch = ""
    /// Whether the live browse is the peer-to-peer fallback.
    private var browseIncludesPeerToPeer = false
    /// Pending escalation to peer-to-peer discovery. Cancelled on connect and
    /// on stop so an abandoned search never fires.
    private var fallbackWork: DispatchWorkItem?
    /// How long the LAN-only browse runs before peer-to-peer is tried. Long
    /// enough that a phone already on the same Wi-Fi is found immediately,
    /// short enough that a user with no shared network is not left waiting.
    private static let peerToPeerFallbackDelay: TimeInterval = 3

    // MARK: - Lifecycle

    init() {
        decoder.onImage = { [weak self] image in
            guard let self else { return }
            self.onImage?(image)
            if self.receivedFrameCount == 0 {
                self.onStatus?("DECODING // FIRST FRAME ON SCREEN", false)
            }
        }
        decoder.onPixelBuffer = { [weak self] pixelBuffer, timestamp in
            self?.onPixelBuffer?(pixelBuffer, timestamp)
        }
    }

    deinit {
        browser?.cancel()
        connection?.cancel()
    }

    func start(passcode: String, bitrate: Int) {
        queue.async { [weak self] in self?.startOnQueue(passcode: passcode, bitrate: bitrate) }
    }

    func setBitrate(_ bitrate: Int) {
        queue.async { [weak self] in
            self?.desiredBitrate = bitrate
            self?.sendCommandOnQueue(.setBitrate(bitrate))
        }
    }

    func requestKeyframe() {
        queue.async { [weak self] in self?.sendCommandOnQueue(.requestKeyframe) }
    }

    /// Sends a control command up the link. The phone answers by publishing a
    /// fresh `GVBroadcastControlState`; the Mac never assumes a command landed
    /// until it sees the state come back.
    func send(_ command: GVBroadcastCommand) {
        queue.async { [weak self] in self?.sendCommandOnQueue(command) }
    }

    func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    // MARK: - Queue

    private func startOnQueue(passcode: String, bitrate: Int) {
        stopOnQueue()
        desiredBitrate = bitrate
        requestedServiceName = ""
        receivedFrameCount = 0
        healthWindowStart = CACurrentMediaTime()
        healthWindowFrames = 0
        healthWindowBytes = 0
        onHealth?(GVLinkHealth(decoderStatus: "SEARCHING"))
        publishLinkState(.searching)
        passcodeForSearch = passcode
        // Two phases. The first browse is LAN-only, which is the common case
        // and costs nothing: no AWDL interface, no peer-to-peer radio held
        // awake on a laptop that is otherwise idle. Only if that finds nothing
        // do we pay for the fallback, which is exactly the "no shared
        // network" situation that needs it.
        startBrowser(passcode: passcode, includePeerToPeer: false)
        status("Looking for a GreyVision device on the local network…")
    }

    private func startBrowser(passcode: String, includePeerToPeer: Bool) {
        browser?.cancel()
        browseIncludesPeerToPeer = includePeerToPeer
        let parameters = Self.makeParameters(passcode: passcode, includePeerToPeer: includePeerToPeer)
        let browser = NWBrowser(for: .bonjour(type: GVBroadcastProtocol.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, !self.didConnect else { return }
            guard let result = results.first(where: { self.matchesRequestedService($0.endpoint) }) else { return }
            self.connect(to: result.endpoint, passcode: passcode, using: parameters)
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case let .failed(error):
                self.publishLinkState(.failed(reason: error.localizedDescription))
                self.status("Browser failed: \(error.localizedDescription)", error: true)
            case .cancelled:
                if self.lastLinkState != .idle { self.publishLinkState(.idle) }
            default:
                break
            }
        }
        self.browser = browser
        browser.start(queue: queue)

        if !includePeerToPeer {
            // Nothing on the LAN: fall through to peer-to-peer discovery.
            fallbackWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.didConnect, self.browser != nil else { return }
                self.status("No device on this network — looking for a direct link…")
                self.startBrowser(passcode: passcode, includePeerToPeer: true)
            }
            fallbackWork = work
            queue.asyncAfter(deadline: .now() + Self.peerToPeerFallbackDelay, execute: work)
        }
    }

    private func connect(to endpoint: NWEndpoint, passcode _: String, using parameters: NWParameters) {
        didConnect = true
        // The search is over; a pending peer-to-peer escalation would only
        // replace a working link with a second browser.
        fallbackWork?.cancel()
        fallbackWork = nil
        let connection = NWConnection(to: endpoint, using: parameters)
        let peer = Self.describe(endpoint)
        publishLinkState(.connecting(peer: peer))
        status("Connecting to \(peer)…")
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.publishLinkState(.connected(peer: peer))
                self.status("Connected. Waiting for processed GreyVision frames…")
                if let bitrate = self.desiredBitrate { self.sendCommandOnQueue(.setBitrate(bitrate)) }
                // Catalogue and current composition first; without them the
                // desktop's buttons are blank until the next user-driven change.
                self.sendCommandOnQueue(.requestControlSurface)
                self.receiveHeader(on: connection)
            case let .failed(error):
                self.publishLinkState(.failed(reason: error.localizedDescription))
                self.status("Connection failed: \(error.localizedDescription)", error: true)
                self.stopOnQueue()
            case .cancelled:
                self.publishLinkState(.idle)
            default:
                break
            }
        }
        self.connection = connection
        connection.start(queue: queue)
    }

    private func stopOnQueue() {
        fallbackWork?.cancel()
        fallbackWork = nil
        browser?.cancel()
        browser = nil
        browseIncludesPeerToPeer = false
        connection?.cancel()
        connection = nil
        didConnect = false
        requestedServiceName = ""
        receivedFrameCount = 0
        decoder.reset()
        publishLinkState(.idle)
    }

    // MARK: - Receive loop

    private func receiveHeader(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: GVBroadcastProtocol.headerLength, maximumLength: GVBroadcastProtocol.headerLength) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let error {
                self.status("Stream error: \(error.localizedDescription)", error: true)
                self.stopOnQueue()
                return
            }
            if complete {
                self.status("iPhone closed the stream.")
                self.stopOnQueue()
                return
            }
            guard let data, let header = GVBroadcastProtocol.Header.decode(data) else {
                self.status("Stream header could not be parsed.", error: true)
                self.stopOnQueue()
                return
            }
            guard header.payloadLength > 0 else {
                self.receiveHeader(on: connection)
                return
            }
            self.receivePayload(on: connection, header: header)
        }
    }

    private func receivePayload(on connection: NWConnection, header: GVBroadcastProtocol.Header) {
        connection.receive(minimumIncompleteLength: header.payloadLength, maximumLength: header.payloadLength) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let error {
                self.status("Stream error: \(error.localizedDescription)", error: true)
                self.stopOnQueue()
                return
            }
            if complete {
                self.status("iPhone closed the stream.")
                self.stopOnQueue()
                return
            }
            guard let data else {
                self.status("Stream ended unexpectedly.", error: true)
                self.stopOnQueue()
                return
            }
            self.handle(header: header, payload: data)
            self.receiveHeader(on: connection)
        }
    }

    private func handle(header: GVBroadcastProtocol.Header, payload: Data) {
        switch header.kind {
        case .none:
            // A newer phone's message type. The payload has already been read,
            // so the stream stays framed — skipping is what keeps an older Mac
            // build usable against a phone that has grown a new message.
            break
        case .videoFrame:
            recordReceivedFrame(bytes: payload.count)
            let stamp = header.timestampNanoseconds
            queue.async { [weak self] in
                self?.decoder.decode(payload, timestampNanoseconds: stamp)
            }
        case .videoFormat:
            guard let format = try? JSONDecoder().decode(GVBroadcastVideoFormat.self, from: payload) else {
                status("Could not parse video format payload.", error: true)
                return
            }
            guard decoder.configure(format) else {
                status("Video format is not supported by this Mac.", error: true)
                return
            }
            onVideoFormat?(format)
        case .controlSurface:
            guard let surface = try? JSONDecoder().decode(GVBroadcastControlSurface.self, from: payload) else {
                status("Could not parse control surface.", error: true)
                return
            }
            onControlSurface?(surface)
        case .controlState:
            guard let state = try? JSONDecoder().decode(GVBroadcastControlState.self, from: payload) else {
                status("Could not parse control state.", error: true)
                return
            }
            onControlState?(state)
        case .hello:
            guard let hello = try? JSONDecoder().decode(GVBroadcastHello.self, from: payload) else {
                status("Could not parse camera profile.", error: true)
                return
            }
            onHello?(hello)
        case .command, .keepalive:
            // Command is a no-op response to a keyframe request. Keepalive is a no-op.
            break
        }
    }

    private func recordReceivedFrame(bytes: Int) {
        receivedFrameCount += 1
        healthWindowFrames += 1
        healthWindowBytes += bytes
        let elapsed = CACurrentMediaTime() - healthWindowStart
        guard elapsed >= 1 else { return }
        onHealth?(GVLinkHealth(
            framesPerSecond: Double(healthWindowFrames) / elapsed,
            kilobitsPerSecond: Double(healthWindowBytes) * 8 / elapsed / 1000,
            receivedFrames: receivedFrameCount,
            decoderStatus: "RECEIVING"
        ))
        healthWindowStart = CACurrentMediaTime()
        healthWindowFrames = 0
        healthWindowBytes = 0
    }

    // MARK: - Send

    private func sendCommandOnQueue(_ command: GVBroadcastCommand) {
        guard let connection, case .ready = connection.state else { return }
        guard let payload = try? JSONEncoder().encode(command) else { return }
        let header = GVBroadcastProtocol.Header(kind: .command, payloadLength: payload.count)
        var message = header.encoded
        message.append(payload)
        connection.send(content: message, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.status("Send failed: \(error.localizedDescription)", error: true)
            }
        })
    }

    // MARK: - Status / state

    private func status(_ text: String, error: Bool = false) {
        onStatus?(text, error)
    }

    private func publishLinkState(_ state: LinkState) {
        guard state != lastLinkState else { return }
        lastLinkState = state
        onLinkState?(state)
    }

    // MARK: - TLS-PSK

    private static func makeParameters(passcode _: String, includePeerToPeer: Bool) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        // Identical KDF to the phone so the two sides agree on key material.
        // Pairing is automatic for this personal local-network workflow.
        let salt = SymmetricKey(data: SHA256.hash(data: Data(GVBroadcastProtocol.serviceType.utf8)))
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(GVBroadcastProtocol.automaticPairingSecret.utf8)),
            salt: salt.withUnsafeBytes { Data($0) },
            info: Data("greyVISION.link.v1".utf8),
            outputByteCount: 32
        )
        let pskData = derived.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("greyVISION".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, pskData as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t.AES_128_GCM_SHA256)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = includePeerToPeer
        return parameters
    }

    private func matchesRequestedService(_ endpoint: NWEndpoint) -> Bool {
        guard !requestedServiceName.isEmpty else { return true }
        guard case let .service(name, _, _, _) = endpoint else { return true }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(requestedServiceName) == .orderedSame
    }

    private static func describe(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case let .hostPort(host, _): String(describing: host)
        case let .service(name, _, _, _): name
        default: String(describing: endpoint)
        }
    }
}

// MARK: - Decoder

/// VideoToolbox decode path. Same as before: build a format description from
/// the codec parameter sets, drop frames into the session, publish at most a
/// preview every 1/24 s so SwiftUI is not redrawn faster than the screen.
final class GVVideoDecoder: @unchecked Sendable {
    var onImage: ((NSImage) -> Void)?
    var onPixelBuffer: ((CVPixelBuffer, CMTime) -> Void)?
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let previewLock = NSLock()
    /// Rotation can deliver a new video format while asynchronous frames from
    /// the previous format are still draining. Keep all VideoToolbox state on
    /// one queue so reset/configure/decode cannot race during that transition.
    private let decodeQueue = DispatchQueue(label: "greyvision.maccapture.decoder", qos: .userInitiated)
    /// Keep rotation and link stalls from allowing VideoToolbox work to grow
    /// without bound. Dropping an intermediate frame is preferable to freezing
    /// the preview while the phone changes dimensions.
    private let decodeSlots = DispatchSemaphore(value: 3)
    private var lastPreviewTime: TimeInterval = 0
    private static let maximumPreviewDimension: CGFloat = 8192
    private static let previewInterval: TimeInterval = 1.0 / 60.0
    private let exposureFilter = CIFilter(name: "CIExposureAdjust")!

    @discardableResult
    func configure(_ format: GVBroadcastVideoFormat) -> Bool {
        decodeQueue.sync { configureLocked(format) }
    }

    private func configureLocked(_ format: GVBroadcastVideoFormat) -> Bool {
        resetLocked()
        var description: CMFormatDescription?
        let parameterSetData = format.parameterSets.map { $0 as NSData }
        let parameterSets = parameterSetData.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        let sizes = parameterSetData.map(\.length)
        let status: OSStatus = format.codec == "hvc1"
            ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: parameterSets.count, parameterSetPointers: parameterSets, parameterSetSizes: sizes, nalUnitHeaderLength: format.nalUnitHeaderLength, extensions: nil, formatDescriptionOut: &description)
            : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: parameterSets.count, parameterSetPointers: parameterSets, parameterSetSizes: sizes, nalUnitHeaderLength: format.nalUnitHeaderLength, formatDescriptionOut: &description)
        guard status == noErr, let description else { return false }
        formatDescription = description
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { reference, _, status, _, imageBuffer, _, _ in
                guard status == noErr, let reference, let imageBuffer else { return }
                Unmanaged<GVVideoDecoder>.fromOpaque(reference).takeUnretainedValue().emit(imageBuffer)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description, decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary, outputCallback: &callback, decompressionSessionOut: &session) == noErr else { return false }
        self.session = session
        return true
    }

    func decode(_ payload: Data, timestampNanoseconds: Int64) {
        // Never enqueue unlimited asynchronous decodes. Rotation can briefly
        // produce a format transition while old frames are still in flight.
        guard decodeSlots.wait(timeout: .now()) == .success else { return }
        decodeQueue.async { [weak self] in
            defer { self?.decodeSlots.signal() }
            self?.decodeLocked(payload, timestampNanoseconds: timestampNanoseconds)
        }
    }

    private func decodeLocked(_ payload: Data, timestampNanoseconds: Int64) {
        guard let session, let formatDescription else { return }
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: payload.count, flags: 0, blockBufferOut: &blockBuffer) == noErr, let blockBuffer else { return }
        payload.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: payload.count) }
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: timestampNanoseconds, timescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var size = payload.count
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: formatDescription, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer else { return }
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: ._EnableAsynchronousDecompression, frameRefcon: nil, infoFlagsOut: nil)
    }

    func reset() {
        decodeQueue.sync { resetLocked() }
    }

    private func resetLocked() {
        if let session {
            // All submitted decode calls are serialized on decodeQueue. Do not
            // synchronously wait for VideoToolbox callbacks here: during an
            // orientation change that wait can block the receiver indefinitely.
            VTDecompressionSessionFinishDelayedFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        previewLock.withLock { lastPreviewTime = 0 }
    }

    private func emit(_ imageBuffer: CVImageBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        let shouldPublish = previewLock.withLock { () -> Bool in
            guard now - lastPreviewTime >= Self.previewInterval else { return false }
            lastPreviewTime = now
            return true
        }
        guard shouldPublish else { return }

        let image = CIImage(cvImageBuffer: imageBuffer, options: [.colorSpace: sRGBColorSpace])
        // The phone preview is display-managed while the decoded Mac frame is
        // not. Apply Core Image's adaptive correction, then a conservative
        // lift so dark scenes match the phone without changing the wire data.
        var adjusted = image
        for filter in image.autoAdjustmentFilters(options: [:]) {
            filter.setValue(adjusted, forKey: kCIInputImageKey)
            adjusted = filter.outputImage ?? adjusted
        }
        exposureFilter.setValue(adjusted, forKey: kCIInputImageKey)
        exposureFilter.setValue(0.28, forKey: kCIInputEVKey)
        adjusted = exposureFilter.outputImage ?? adjusted
        let extent = adjusted.extent
        let scale = min(1, Self.maximumPreviewDimension / max(extent.width, extent.height))
        let preview = scale < 1 ? adjusted.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : adjusted
        guard let cgImage = context.createCGImage(
            preview,
            from: preview.extent,
            format: .RGBA8,
            colorSpace: sRGBColorSpace
        ) else { return }
        onPixelBuffer?(imageBuffer, CMClockGetTime(CMClockGetHostTimeClock()))
        onImage?(NSImage(cgImage: cgImage, size: NSSize(width: preview.extent.width, height: preview.extent.height)))
    }
}
