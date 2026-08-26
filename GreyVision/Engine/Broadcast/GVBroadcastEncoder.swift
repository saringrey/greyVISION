import CoreMedia
import Foundation
import VideoToolbox

/// Hardware video encoder for the live link.
///
/// Separate from `GVVideoRecorder` on purpose. Recording wants quality and
/// tolerates latency: it writes through `AVAssetWriter`, buffers, and reorders
/// freely. A live link wants the opposite — every frame out of the encoder as
/// soon as it exists, no B-frames, no reordering, and a bitrate that can be
/// retargeted mid-stream. Those are different property sets on the same
/// hardware, not one pipeline with a flag.
///
/// Thread-safe by lock rather than by actor: the renderer hands frames in from
/// a Metal command-buffer completion handler, which is not a place that can
/// `await`.
final class GVBroadcastEncoder: @unchecked Sendable {
    /// A finished access unit, ready to put on the wire.
    struct EncodedFrame: Sendable {
        var data: Data
        var isKeyframe: Bool
        var presentationTime: CMTime
    }

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var configuredWidth = 0
    private var configuredHeight = 0
    private var frameRate: Int32 = 30
    private var forceKeyframeOnNextEncode = false
    /// Retained so a format change mid-stream can be noticed and republished;
    /// the Mac cannot decode a frame whose parameter sets it has not seen.
    private var publishedFormatPointer: UnsafeRawPointer?

    /// Set once before the first encode. Called on VideoToolbox's own thread.
    private var frameHandler: (@Sendable (EncodedFrame) -> Void)?
    private var formatHandler: (@Sendable (GVBroadcastVideoFormat) -> Void)?

    private(set) var codec: CMVideoCodecType = kCMVideoCodecType_HEVC

    var codecFourCC: String {
        codec == kCMVideoCodecType_HEVC ? "hvc1" : "avc1"
    }

    func setHandlers(
        onFrame: @escaping @Sendable (EncodedFrame) -> Void,
        onFormat: @escaping @Sendable (GVBroadcastVideoFormat) -> Void
    ) {
        lock.withLock {
            frameHandler = onFrame
            formatHandler = onFormat
        }
    }

    // MARK: - Lifecycle

    /// Builds a session for this frame size, reusing the existing one when the
    /// size has not changed. Returns false when no encoder could be created at
    /// all, which is the caller's cue to stop rather than to retry per frame.
    @discardableResult
    func prepare(width: Int, height: Int, bitrate: Int, frameRate: Int) -> Bool {
        lock.withLock {
            if session != nil, configuredWidth == width, configuredHeight == height {
                return true
            }
            teardownLocked()

            // HEVC first: roughly half the bitrate of H.264 for the same
            // quality, which matters more here than anywhere else because the
            // link is the bottleneck. Falling back rather than failing keeps
            // older hardware working.
            guard let created = Self.makeSession(width: width, height: height, codec: kCMVideoCodecType_HEVC)
                ?? Self.makeSession(width: width, height: height, codec: kCMVideoCodecType_H264)
            else {
                GVLog.recording.error("Broadcast encoder unavailable for \(width)x\(height)")
                return false
            }

            session = created.session
            codec = created.codec
            configuredWidth = width
            configuredHeight = height
            self.frameRate = Int32(max(frameRate, 1))
            publishedFormatPointer = nil

            applyPropertiesLocked(bitrate: bitrate, frameRate: Int32(max(frameRate, 1)))
            VTCompressionSessionPrepareToEncodeFrames(created.session)
            GVLog.recording.notice(
                "Broadcast encoder ready: \(created.codec == kCMVideoCodecType_HEVC ? "HEVC" : "H.264") \(width)x\(height)"
            )
            return true
        }
    }

    func invalidate() {
        lock.withLock { teardownLocked() }
    }

    /// The next encoded frame will be a sync sample. Used when a receiver
    /// joins mid-stream, and whenever one says it has lost sync.
    func requestKeyframe() {
        lock.withLock { forceKeyframeOnNextEncode = true }
    }

    func setBitrate(_ bitrate: Int) {
        lock.withLock {
            guard let session else { return }
            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_AverageBitRate,
                value: NSNumber(value: bitrate)
            )
        }
    }

    // MARK: - Encoding

    /// Submits one frame. Safe to call from a Metal completion handler.
    ///
    /// Drops silently when no session exists — a link that is starting up or
    /// tearing down should cost the render loop nothing, and a log line per
    /// frame at 60fps is worse than the drop.
    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let (session, forceKeyframe) = lock.withLock { () -> (VTCompressionSession?, Bool) in
            let force = forceKeyframeOnNextEncode
            forceKeyframeOnNextEncode = false
            return (session, force)
        }
        guard let session else { return }

        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: CMTime(value: 1, timescale: frameRate),
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            self?.handleEncoded(sampleBuffer)
        }
    }

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else {
            return
        }

        // A sync sample has no attachment saying otherwise. Reading it this
        // way — absence of NotSync — is what CoreMedia actually guarantees;
        // there is no positive "this is a keyframe" flag.
        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
           CFArrayGetCount(attachments) > 0
        {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
            let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
            if let value = CFDictionaryGetValue(first as CFDictionary, key) {
                isKeyframe = !CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
            }
        }

        // Parameter sets travel separately, and only when they change. On a
        // steady stream that is once; on a resolution change it is once more.
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            publishFormatIfChanged(format)
        }

        var totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &pointer
        )
        guard status == kCMBlockBufferNoErr, let pointer, totalLength > 0 else { return }

        let handler = lock.withLock { frameHandler }
        handler?(
            EncodedFrame(
                data: Data(bytes: pointer, count: totalLength),
                isKeyframe: isKeyframe,
                presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            )
        )
    }

    /// Publishes parameter sets the first time they are seen and on any later
    /// change. Identity of the format description is the cheap check; it is
    /// stable for the life of a configuration.
    private func publishFormatIfChanged(_ format: CMFormatDescription) {
        let identity = Unmanaged.passUnretained(format).toOpaque()
        let (shouldPublish, handler) = lock.withLock { () -> (Bool, (@Sendable (GVBroadcastVideoFormat) -> Void)?) in
            guard publishedFormatPointer != UnsafeRawPointer(identity) else { return (false, nil) }
            publishedFormatPointer = UnsafeRawPointer(identity)
            return (true, formatHandler)
        }
        guard shouldPublish, let handler else { return }

        let isHEVC = codec == kCMVideoCodecType_HEVC
        var count = 0
        var nalHeaderLength: Int32 = 4
        let countStatus = isHEVC
            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalHeaderLength
            )
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalHeaderLength
            )
        guard countStatus == noErr, count > 0 else { return }

        var parameterSets: [Data] = []
        parameterSets.reserveCapacity(count)
        for index in 0 ..< count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = isHEVC
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
            guard status == noErr, let pointer, size > 0 else { return }
            parameterSets.append(Data(bytes: pointer, count: size))
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        handler(
            GVBroadcastVideoFormat(
                codec: codecFourCC,
                parameterSets: parameterSets,
                nalUnitHeaderLength: nalHeaderLength,
                width: Int(dimensions.width),
                height: Int(dimensions.height)
            )
        )
    }

    // MARK: - Session construction

    private static func makeSession(
        width: Int,
        height: Int,
        codec: CMVideoCodecType
    ) -> (session: VTCompressionSession, codec: CMVideoCodecType)? {
        // Low-latency rate control skips the encoder's lookahead buffer. It is
        // the single property that most separates a usable live link from one
        // that runs a third of a second behind the phone.
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue as Any
        ]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            // Must be nil to use the block-based encode entry point.
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else { return nil }
        return (session, codec)
    }

    private func applyPropertiesLocked(bitrate: Int, frameRate: Int32) {
        guard let session else { return }
        let isHEVC = codec == kCMVideoCodecType_HEVC
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            // No B-frames. Reordering trades latency for bitrate, and on a
            // live link latency is the product.
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (
                kVTCompressionPropertyKey_ProfileLevel,
                isHEVC
                    ? kVTProfileLevel_HEVC_Main_AutoLevel
                    : kVTProfileLevel_H264_High_AutoLevel
            ),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate)),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: frameRate)),
            // Two seconds between forced sync samples. Long enough not to cost
            // much bitrate, short enough that a receiver joining mid-stream
            // sees picture quickly even if its keyframe request is lost.
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: frameRate * 2)),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 2.0))
        ]
        for (key, value) in properties {
            VTSessionSetProperty(session, key: key, value: value)
        }
    }

    private func teardownLocked() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
        configuredWidth = 0
        configuredHeight = 0
        publishedFormatPointer = nil
    }

    deinit {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
    }
}
