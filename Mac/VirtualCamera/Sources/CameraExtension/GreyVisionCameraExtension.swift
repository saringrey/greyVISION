import AVFoundation
import CoreImage
import CoreMedia
import CoreMediaIO
import CoreVideo
import CryptoKit
import Foundation
import Network
import VideoToolbox

@available(macOS 13.0, *)
final class GVVirtualCameraProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private let deviceSource: GVVirtualCameraDeviceSource

    override init() {
        deviceSource = GVVirtualCameraDeviceSource()
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: DispatchQueue(label: "greyvision.virtualcamera.provider"))
        try? provider.addDevice(deviceSource.device)
    }

    var availableProperties: Set<CMIOExtensionProperty> { [] }

    func providerProperties(forProperties _: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        CMIOExtensionProviderProperties(dictionary: [:])
    }

    func setProviderProperties(_: CMIOExtensionProviderProperties) throws {}
    func connect(to _: CMIOExtensionClient) throws {}
    func disconnect(from _: CMIOExtensionClient) {}
}

@available(macOS 13.0, *)
final class GVVirtualCameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private(set) var streamSource: GVVirtualCameraStreamSource!
    private let receiver: GVPhoneReceiver
    private var activeClientCount = 0

    override init() {
        receiver = GVPhoneReceiver()
        super.init()
        // The device shows up in Photo Booth, OBS, FaceTime, QuickTime, and
        // every other camera client as "grey//visionCAM". Two slashes so the
        // name reads as a wordmark and not as an em-dash that the user has to
        // double-tap to confirm; "CAM" caps because it is the noun the client
        // is asking for ("grey vision's CAM" reads as a clean choice).
        device = CMIOExtensionDevice(
            localizedName: "grey//visionCAM",
            deviceID: UUID(),
            legacyDeviceID: nil,
            source: self
        )
        streamSource = GVVirtualCameraStreamSource(device: device)
        streamSource.deviceSource = self
        streamSource.onPresentationChange = { [weak self] width, height in
            self?.receiver.updatePresentation(width: width, height: height)
        }
        try? device.addStream(streamSource.stream)
        receiver.onSampleBuffer = { [weak streamSource] sampleBuffer, hostTime in
            streamSource?.send(sampleBuffer, hostTime: hostTime)
        }
        receiver.onStatus = { [weak self] status in
            self?.streamSource.status = status
        }
        receiver.onFormat = { [weak self] format in
            self?.streamSource.adopt(phoneFormat: format)
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceModel) {
            // Distinct from the device name so the model field describes
            // what's coming down the pipe (a processed iPhone feed through
            // grey//VISION's renderer) rather than repeating the user-facing
            // label.
            result.model = "grey//vision iPhone Feed"
        }
        return result
    }

    func setDeviceProperties(_: CMIOExtensionDeviceProperties) throws {}
    func authorizeClient(_: CMIOExtensionClient) throws -> Bool {
        true
    }

    func deauthorizeClient(_: CMIOExtensionClient) {}

    func startStreaming() {
        activeClientCount += 1
        guard activeClientCount == 1 else { return }
        let pairing = GVVirtualCameraConfiguration.load()
        guard pairing.isEnabled, GVBroadcastKeyMaterial.isValidCode(pairing.pairingCode) else {
            streamSource.status = "Open grey//visionCAM and paste the pairing code shown on the iPhone."
            return
        }
        receiver.start(serviceName: pairing.serviceName, pairingCode: pairing.pairingCode)
    }

    func stopStreaming() {
        activeClientCount = max(activeClientCount - 1, 0)
        guard activeClientCount == 0 else { return }
        receiver.stop()
        streamSource.status = "Waiting for a camera client (grey//visionCAM is idle)."
    }
}

@available(macOS 13.0, *)
final class GVVirtualCameraStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    /// The ladder the stream advertises. CoreMediaIO requires the format list
    /// to be fixed for the life of the stream, so the choice made here is what
    /// a client can ever ask for — everything after negotiation is a selection
    /// within it, not a new entry.
    private let streamFormats: [CMIOExtensionStreamFormat]
    /// Which rung of `streamFormats` is currently selected.
    private let formatLock = NSLock()
    private var activeFormatIndexValue = 0
    private var activeFrameDurationValue = CMTime(value: 1, timescale: 30)
    private let queue = DispatchQueue(label: "greyvision.virtualcamera.stream")
    weak var deviceSource: GVVirtualCameraDeviceSource?
    /// Set by the device source so a client-driven rung change can reach the
    /// decoder, which is what actually resizes the frames.
    var onPresentationChange: ((Int, Int) -> Void)?
    var status = "Waiting for a camera client (grey//visionCAM is idle)."
    /// What the phone is actually sending, once it has said so. Drives the
    /// default rung and the status line.
    private(set) var negotiatedSourceFormat: GVBroadcastVideoFormat?

    init(device _: CMIOExtensionDevice) {
        streamFormats = GVVirtualCameraStreamSource.ladder.map { entry in
            let description = GVVirtualCameraStreamSource.makeFormatDescription(
                width: entry.width,
                height: entry.height
            )
            let duration = CMTime(value: 1, timescale: Int32(entry.framesPerSecond))
            return CMIOExtensionStreamFormat(
                formatDescription: description,
                maxFrameDuration: duration,
                minFrameDuration: duration,
                validFrameDurations: nil
            )
        }
        super.init()
        stream = CMIOExtensionStream(
            localizedName: "grey//visionCAM",
            streamID: UUID(),
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    /// The rungs, smallest first so index 0 is the safe default that any
    /// client can open without negotiating anything.
    static let ladder: [(width: Int32, height: Int32, framesPerSecond: Int32)] = [
        (1280, 720, 30),
        (1920, 1080, 30),
        (1920, 1080, 60)
    ]

    var formats: [CMIOExtensionStreamFormat] { streamFormats }

    /// The geometry frames are currently being produced at.
    var activeFormat: (width: Int32, height: Int32, framesPerSecond: Int32) {
        formatLock.withLock {
            let index = min(max(activeFormatIndexValue, 0), streamFormats.count - 1)
            return GVVirtualCameraStreamSource.ladder[index]
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        let (index, duration) = formatLock.withLock { (activeFormatIndexValue, activeFrameDurationValue) }
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = index }
        if properties.contains(.streamFrameDuration) { result.frameDuration = duration }
        return result
    }

    /// A client asking for a different rung is a real request, not a probe.
    /// Honouring it is the difference between grey//visionCAM being a
    /// 720p-only camera in every capture app's list and being a camera with a
    /// resolution menu.
    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        guard let requested = streamProperties.activeFormatIndex else { return }
        let clamped = min(max(Int(requested), 0), streamFormats.count - 1)
        let duration = CMTime(value: 1, timescale: GVVirtualCameraStreamSource.ladder[clamped].framesPerSecond)
        let changed = formatLock.withLock { () -> Bool in
            guard activeFormatIndexValue != clamped else { return false }
            activeFormatIndexValue = clamped
            activeFrameDurationValue = duration
            return true
        }
        guard changed else { return }
        describeActiveFormat()
        publishPresentation()
    }

    /// Moves to the rung that best matches what the phone is sending, so the
    /// common case needs no user action: a 1080p60 phone gets 1080p60.
    func adopt(phoneFormat: GVBroadcastVideoFormat) {
        negotiatedSourceFormat = phoneFormat
        let sourceWidth = Int32(phoneFormat.width)
        let sourceHeight = Int32(phoneFormat.height)
        let sourceRate = phoneFormat.framesPerSecond.flatMap { $0 > 0 ? Int32($0) : nil } ?? 30
        // Exact geometry first, then the same geometry at a rate we can
        // actually hold, then the largest rung that does not upscale.
        let exact = GVVirtualCameraStreamSource.ladder.firstIndex {
            $0.width == sourceWidth && $0.height == sourceHeight && $0.framesPerSecond == sourceRate
        }
        let index = exact ?? GVVirtualCameraStreamSource.ladder.enumerated().reversed().first {
            Int64($0.element.width) * Int64($0.element.height) <= Int64(sourceWidth) * Int64(sourceHeight)
        }?.offset ?? 0
        let duration = CMTime(value: 1, timescale: GVVirtualCameraStreamSource.ladder[index].framesPerSecond)
        let changed = formatLock.withLock { () -> Bool in
            guard activeFormatIndexValue != index else { return false }
            activeFormatIndexValue = index
            activeFrameDurationValue = duration
            return true
        }
        describeActiveFormat()
        if changed { publishPresentation() }
    }

    private func publishPresentation() {
        let format = activeFormat
        onPresentationChange?(Int(format.width), Int(format.height))
    }

    private func describeActiveFormat() {
        let source = negotiatedSourceFormat
        let presenting = activeFormat
        let sourceText = source.map {
            "\($0.width)×\($0.height) @\($0.framesPerSecond ?? 30)"
        } ?? "unknown"
        status = "iPhone sending \(sourceText) · presenting \(presenting.width)×\(presenting.height) @\(presenting.framesPerSecond)"
    }

    func authorizedToStartStream(for _: CMIOExtensionClient) -> Bool {
        true
    }

    func startStream() throws {
        guard let deviceSource else {
            throw NSError(domain: "GreyVisionVirtualCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing virtual camera device source."])
        }
        deviceSource.startStreaming()
    }

    func stopStream() throws {
        deviceSource?.stopStreaming()
    }

    func send(_ sampleBuffer: CMSampleBuffer, hostTime: UInt64) {
        queue.async { [weak self] in
            self?.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: hostTime)
        }
    }

    private static func makeFormatDescription(width: Int32, height: Int32) -> CMFormatDescription {
        var formatDescription: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: width,
            height: height,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        precondition(status == noErr && formatDescription != nil)
        return formatDescription!
    }
}

@available(macOS 13.0, *)
final class GVPhoneReceiver: @unchecked Sendable {
    var onSampleBuffer: ((CMSampleBuffer, UInt64) -> Void)?
    var onStatus: ((String) -> Void)?
    /// The format the phone announced, so the stream can pick a presentation
    /// geometry that matches instead of hard-coding 720p.
    var onFormat: ((GVBroadcastVideoFormat) -> Void)?

    private let queue = DispatchQueue(label: "greyvision.virtualcamera.receiver")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var decoder = GVVideoDecoder()
    private var didConnect = false
    /// A camera client is attached, so the search should keep running even
    /// when the phone drops. Cleared by `stop`.
    private var wantsLink = false
    private var serviceNameForSearch = ""
    private var passcodeForSearch = ""
    /// Last time anything at all arrived on the socket. The peer can vanish
    /// without a FIN — screen off, app killed, out of AWDL range — and TCP
    /// will not notice for minutes.
    private var lastActivity = CACurrentMediaTime()
    private var silenceWatchdog: DispatchSourceTimer?

    /// How long the socket may be completely silent before the link is
    /// considered dead and the search restarts. A live stream produces a
    /// message every frame time, so ten seconds of nothing is unambiguous.
    private static let silenceTimeout: TimeInterval = 10

    func start(serviceName: String, pairingCode: String) {
        stop()
        wantsLink = true
        serviceNameForSearch = serviceName
        passcodeForSearch = pairingCode
        beginSearch()
    }

    private func beginSearch() {
        guard wantsLink else { return }
        onStatus?("Looking for \(serviceNameForSearch) on the local network…")
        // A malformed code is refused before the browse starts. Browsing under the
        // wrong key would find the phone and then fail the handshake, which
        // surfaces as a network fault rather than as the pairing mistake it is.
        guard let secret = GVBroadcastKeyMaterial.secret(forCode: passcodeForSearch) else {
            onStatus?("That pairing code is not one this app can use. Re-read it from the iPhone.")
            return
        }
        let parameters = GVBroadcastKeyMaterial.parameters(secret: secret, includePeerToPeer: true)
        let browser = NWBrowser(for: .bonjour(type: GVBroadcastProtocol.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, !self.didConnect else { return }
            guard let endpoint = results.first(where: { result in
                if case let .service(name, _, _, _) = result.endpoint { return name == self.serviceNameForSearch }
                return false
            })?.endpoint else { return }
            self.didConnect = true
            self.startSilenceWatchdog()
            self.connect(to: endpoint, parameters: parameters)
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state { self?.onStatus?("Network browse failed: \(error.localizedDescription)") }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    func stop() {
        wantsLink = false
        didConnect = false
        silenceWatchdog?.cancel()
        silenceWatchdog = nil
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        decoder.reset()
    }

    /// A client picked a different rung of the stream's format ladder, so the
    /// decoder has to start producing frames at that geometry.
    func updatePresentation(width: Int, height: Int) {
        decoder.updatePresentation(width: width, height: height)
    }

    /// Tearing the socket down is not the same as giving up: a client is
    /// still holding the device open, so the extension goes back to looking
    /// for the phone rather than going idle and needing the user to restart
    /// capture.
    private func startSilenceWatchdog() {
        silenceWatchdog?.cancel()
        lastActivity = CACurrentMediaTime()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.silenceTimeout, repeating: Self.silenceTimeout / 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.didConnect else { return }
            let silence = CACurrentMediaTime() - self.lastActivity
            guard silence > Self.silenceTimeout else { return }
            self.onStatus?("iPhone stopped sending (last frame \(Int(silence))s ago). Looking again…")
            self.didConnect = false
            self.silenceWatchdog?.cancel()
            self.silenceWatchdog = nil
            self.connection?.cancel()
            self.connection = nil
            self.decoder.reset()
            self.beginSearch()
        }
        silenceWatchdog = timer
        timer.resume()
    }

    private func connect(to endpoint: NWEndpoint, parameters: NWParameters) {
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onStatus?("Connected to iPhone. Waiting for grey//vision frames…")
                self.receiveHeader(on: connection)
            case let .failed(error):
                self.onStatus?("iPhone link failed: \(error.localizedDescription)")
                self.stop()
            case .cancelled:
                self.onStatus?("iPhone link disconnected.")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveHeader(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: GVBroadcastProtocol.headerLength, maximumLength: GVBroadcastProtocol.headerLength) { [weak self] data, _, complete, error in
            guard let self, error == nil, !complete, let data, let header = GVBroadcastProtocol.Header.decode(data) else {
                self?.stop()
                return
            }
            self.lastActivity = CACurrentMediaTime()
            guard header.payloadLength > 0 else {
                self.receiveHeader(on: connection)
                return
            }
            self.receivePayload(on: connection, header: header)
        }
    }

    private func receivePayload(on connection: NWConnection, header: GVBroadcastProtocol.Header) {
        connection.receive(minimumIncompleteLength: header.payloadLength, maximumLength: header.payloadLength) { [weak self] data, _, complete, error in
            guard let self, error == nil, !complete, let data else {
                self?.stop()
                return
            }
            self.lastActivity = CACurrentMediaTime()
            self.handle(header: header, payload: data)
            self.receiveHeader(on: connection)
        }
    }

    private func handle(header: GVBroadcastProtocol.Header, payload: Data) {
        // `kind` is optional in the shared protocol: a peer speaking a newer
        // vocabulary sends a raw value this build has no case for, and the
        // framing says exactly how many bytes to skip so the stream survives.
        switch header.kind {
        case .none:
            break
        case .hello:
            guard let hello = try? JSONDecoder().decode(GVBroadcastHello.self, from: payload), hello.version == GVBroadcastProtocol.version else {
                onStatus?("Incompatible grey//vision iPhone stream.")
                stop()
                return
            }
            onStatus?("Connected to \(hello.deviceName). Preparing \(hello.codec.uppercased()) video…")
        case .videoFormat:
            guard let format = try? JSONDecoder().decode(GVBroadcastVideoFormat.self, from: payload) else { return }
            // Announced before a single frame arrives, so the stream can move
            // to a matching presentation geometry before any client sees one.
            onFormat?(format)
            decoder.configure(format) { [weak self] sampleBuffer, hostTime in
                self?.onSampleBuffer?(sampleBuffer, hostTime)
            }
        case .videoFrame:
            decoder.decode(payload, timestampNanoseconds: header.timestampNanoseconds)
        case .command, .keepalive, .controlSurface, .controlState:
            // Desktop-driven messages. This extension is a passive sink for the
            // phone's picture, so there is nothing here to apply them to.
            break
        }
    }

    // `makeParameters` used to sit here and derive the key from the passcode
    // while the phone derived it from a literal, so the handshake could never
    // succeed. It is now `GVBroadcastKeyMaterial`, which this extension
    // compiles from the iOS tree exactly as the Mac app does.
}

@available(macOS 13.0, *)
final class GVVideoDecoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var onDecoded: ((CMSampleBuffer, UInt64) -> Void)?
    private var frameAdapter = GVFrameAdapter(width: 1280, height: 720)
    private let adapterLock = NSLock()
    private let timestampLock = NSLock()
    private var timestampOrigin: (incoming: CMTime, host: CMTime)?

    /// Resizes the frames the decoder emits. Called when the stream's active
    /// format changes, so a client that picks 1080p60 gets 1080p60 frames
    /// rather than an upscale of a 720p stream.
    func updatePresentation(width: Int, height: Int) {
        _ = adapterLock.withLock { () -> Bool in
            frameAdapter.retarget(width: width, height: height)
        }
    }

    func configure(_ format: GVBroadcastVideoFormat, onDecoded: @escaping (CMSampleBuffer, UInt64) -> Void) {
        reset()
        self.onDecoded = onDecoded
        guard let description = Self.makeFormatDescription(format) else { return }
        formatDescription = description
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var session: VTDecompressionSession?
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { reference, _, status, _, imageBuffer, presentationTimeStamp, _ in
                guard status == noErr, let reference, let imageBuffer else { return }
                let decoder = Unmanaged<GVVideoDecoder>.fromOpaque(reference).takeUnretainedValue()
                decoder.emit(imageBuffer: imageBuffer, timestamp: presentationTimeStamp)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        guard VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &session
        ) == noErr else { return }
        self.session = session
    }

    func decode(_ payload: Data, timestampNanoseconds: Int64) {
        guard let session, let formatDescription else { return }
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return }
        payload.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: payload.count)
        }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: timestampNanoseconds, timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var size = payload.count
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: ._EnableAsynchronousDecompression, frameRefcon: nil, infoFlagsOut: nil)
    }

    func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        formatDescription = nil
        timestampLock.withLock { timestampOrigin = nil }
    }

    private func emit(imageBuffer: CVImageBuffer, timestamp: CMTime) {
        let adapter = adapterLock.withLock { frameAdapter }
        guard let outputBuffer = adapter.adapt(imageBuffer) else { return }
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: outputBuffer, formatDescriptionOut: &description) == noErr,
              let description else { return }
        let hostTimestamp = rebasedTimestamp(timestamp)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: hostTimestamp, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: outputBuffer,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }
        let nanoseconds = CMTimeConvertScale(hostTimestamp, timescale: 1_000_000_000, method: .default)
        onDecoded?(sampleBuffer, UInt64(max(nanoseconds.value, 0)))
    }

    private func rebasedTimestamp(_ incoming: CMTime) -> CMTime {
        timestampLock.withLock {
            if let timestampOrigin {
                return CMTimeAdd(timestampOrigin.host, CMTimeSubtract(incoming, timestampOrigin.incoming))
            }
            let host = CMClockGetTime(CMClockGetHostTimeClock())
            timestampOrigin = (incoming, host)
            return host
        }
    }

    private static func makeFormatDescription(_ format: GVBroadcastVideoFormat) -> CMVideoFormatDescription? {
        guard !format.parameterSets.isEmpty, format.parameterSets.allSatisfy({ !$0.isEmpty }) else { return nil }

        let storage = format.parameterSets.map { data -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            data.copyBytes(to: pointer, count: data.count)
            return pointer
        }
        defer { storage.forEach { $0.deallocate() } }

        let parameterSets: [UnsafePointer<UInt8>] = storage.map { UnsafePointer($0) }
        let sizes = format.parameterSets.map(\.count)
        var description: CMFormatDescription?
        let status: OSStatus
        if format.codec == "hvc1" {
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: parameterSets.count,
                parameterSetPointers: parameterSets,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: format.nalUnitHeaderLength,
                extensions: nil,
                formatDescriptionOut: &description
            )
        } else {
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: parameterSets.count,
                parameterSetPointers: parameterSets,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: format.nalUnitHeaderLength,
                formatDescriptionOut: &description
            )
        }
        return status == noErr ? description : nil
    }
}

@available(macOS 13.0, *)
private final class GVFrameAdapter: @unchecked Sendable {
    private let lock = NSLock()
    private var width: Int
    private var height: Int
    private var pool: CVPixelBufferPool
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pool = Self.makePool(width: width, height: height)
    }

    /// Retargets the adapter when the client picks a different rung of the
    /// stream's format ladder. A no-op when the geometry already matches, so
    /// the common case never reallocates a pool.
    @discardableResult
    func retarget(width newWidth: Int, height newHeight: Int) -> Bool {
        lock.withLock { () -> Bool in
            guard newWidth != width || newHeight != height else { return false }
            width = newWidth
            height = newHeight
            pool = Self.makePool(width: newWidth, height: newHeight)
            return true
        }
    }

    private static func makePool(width: Int, height: Int) -> CVPixelBufferPool {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            attributes as CFDictionary,
            &pool
        )
        precondition(status == kCVReturnSuccess && pool != nil)
        return pool!
    }

    func adapt(_ input: CVImageBuffer) -> CVPixelBuffer? {
        let (pool, width, height) = lock.withLock { (self.pool, self.width, self.height) }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) == kCVReturnSuccess,
              let output else { return nil }

        let target = CGRect(x: 0, y: 0, width: width, height: height)
        let source = CIImage(cvImageBuffer: input)
        let scale = min(target.width / source.extent.width, target.height / source.extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let positioned = scaled.transformed(by: CGAffineTransform(
            translationX: target.midX - scaled.extent.midX,
            y: target.midY - scaled.extent.midY
        ))
        let background = CIImage(color: .black).cropped(to: target)
        context.render(
            positioned.composited(over: background),
            to: output,
            bounds: target,
            colorSpace: colorSpace
        )
        return output
    }
}
