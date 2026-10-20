@preconcurrency import AVFoundation
import CoreVideo
import Metal
import Photos
import UIKit

/// State of the recorder, surfaced to the HUD.
enum GVRecordingState: Equatable, Sendable {
    case idle
    case recording(startedAt: CFTimeInterval)
    case finishing
    case failed(String)

    var isRecording: Bool {
        if case .recording = self {
            return true
        }
        return false
    }
}

final class GVRecordingStateMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = GVRecordingState.idle

    var latest: GVRecordingState {
        lock.withLock { value }
    }

    func publish(_ state: GVRecordingState) {
        lock.withLock { value = state }
    }
}

/// Audited handoff: `finishWriting` retains the writer past the lock release.
/// The box is the sole owner across the @Sendable completion boundary.
private final class GVWriterBox: @unchecked Sendable {
    let writer: AVAssetWriter
    init(_ writer: AVAssetWriter) {
        self.writer = writer
    }
}

/// Writes processed frames to a QuickTime file.
///
/// Frames arrive already encoded to display-referred BGRA in a pixel buffer
/// drawn from the adaptor's own pool, so nothing is copied through the CPU.
///
/// Legacy, and video-only in fact as well as in code: the live recorder is
/// `GVRealtimeRecordingSession` (`Engine/AR/ARRecordingSession.swift`), which owns
/// the microphone handoff — `CameraRuntime` routes audio sample buffers into
/// `recordingMailbox.appendAudio` and the session writes them through its own
/// `AVAssetWriterInput`. This class is not on that path any more:
/// `GVProcessedFramesAdapter` still holds one, and `GVRecordingTransaction` still
/// selects that adapter for the camera's recording path, but the transaction stops
/// the camera through the mailbox before the adapter's recorder is ever asked to
/// start, and this writer's `configureWriter` / `nextTexture` / `appendFrame` have
/// no callers. Deleting it is a separate decision from correcting what it claims.
final class GVVideoRecorder: @unchecked Sendable {
    let stateMailbox = GVRecordingStateMailbox()

    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var textureCache: CVMetalTextureCache?
    /// The movie being written. It stays readable after `finish` so the caller can
    /// still address the take; see the note in `finish`.
    private(set) var outputURL: URL?
    private var startTime: CMTime?
    private var frameIndex: Int64 = 0
    private var frameDuration = CMTime(value: 1, timescale: 60)
    private var size = CGSize.zero
    /// Frames dropped due to encoder backpressure (not ready for more media data)
    private var droppedFrames: Int64 = 0
    /// Frames dropped due to pixel buffer pool exhaustion
    private var poolExhaustionFrames: Int64 = 0

    var isRecording: Bool {
        stateMailbox.latest.isRecording
    }

    /// Total frames successfully encoded.
    var encodedFrameCount: Int64 {
        lock.withLock { frameIndex }
    }

    /// Frames dropped due to encoder not ready.
    var droppedFrameCount: Int64 {
        lock.withLock { droppedFrames }
    }

    /// Frames dropped due to pixel buffer pool exhaustion.
    var poolExhaustionFrameCount: Int64 {
        lock.withLock { poolExhaustionFrames }
    }

    /// Total frames presented to recorder (encoded + dropped).
    var totalFramesPresented: Int64 {
        lock.withLock { frameIndex + droppedFrames + poolExhaustionFrames }
    }

    /// Prepares the writer. Returns false if the codec or destination is
    /// unavailable rather than failing silently later.
    @discardableResult
    func start(
        device: MTLDevice,
        width: Int,
        height: Int,
        framesPerSecond: Int,
        codec: CaptureSetupDraft.VideoCodec,
        videoOrientation _: CGImagePropertyOrientation = .up
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard writer == nil else { return false }

        // Encoders require even dimensions.
        let evenWidth = width - (width % 2)
        let evenHeight = height - (height % 2)
        guard evenWidth > 0, evenHeight > 0 else { return false }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gv-\(UUID().uuidString).mov")

        guard let assetWriter = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            stateMailbox.publish(.failed("WRITER UNAVAILABLE"))
            return false
        }

        guard let writerCodec = codec.assetWriterCodec else {
            stateMailbox.publish(.failed("\(codec.rawValue) UNAVAILABLE"))
            return false
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: writerCodec,
            AVVideoWidthKey: evenWidth,
            AVVideoHeightKey: evenHeight
        ]
        guard assetWriter.canApply(outputSettings: settings, forMediaType: .video) else {
            stateMailbox.publish(.failed("\(codec.rawValue) UNSUPPORTED"))
            return false
        }

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        writerInput.expectsMediaDataInRealTime = true

        // Orientation transform applied by the caller (CameraMetalSurface for main recording path)
        // Use identity transform since frames are already display-oriented

        let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: evenWidth,
                kCVPixelBufferHeightKey as String: evenHeight,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        )

        guard assetWriter.canAdd(writerInput) else {
            stateMailbox.publish(.failed("INPUT REJECTED"))
            return false
        }
        assetWriter.add(writerInput)

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache
        else {
            stateMailbox.publish(.failed("TEXTURE CACHE FAILED"))
            return false
        }

        guard assetWriter.startWriting() else {
            stateMailbox.publish(.failed(assetWriter.error?.localizedDescription.uppercased() ?? "START FAILED"))
            return false
        }
        assetWriter.startSession(atSourceTime: .zero)

        writer = assetWriter
        input = writerInput
        adaptor = pixelAdaptor
        textureCache = cache
        outputURL = url
        startTime = nil
        frameIndex = 0
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(framesPerSecond, 1)))
        size = CGSize(width: evenWidth, height: evenHeight)
        stateMailbox.publish(.recording(startedAt: CACurrentMediaTime()))
        GVLog.rendering.notice("Recording started at \(evenWidth)x\(evenHeight)")
        return true
    }

    /// Dimensions the renderer must encode into. Nil when not recording.
    var targetSize: CGSize? {
        lock.withLock { writer == nil ? nil : size }
    }

    /// Vends a pixel buffer plus a Metal texture view of it for this frame.
    func nextTexture() -> (CVPixelBuffer, MTLTexture)? {
        lock.lock()
        defer { lock.unlock() }
        guard let adaptor, let pool = adaptor.pixelBufferPool, let textureCache else { return nil }
        guard input?.isReadyForMoreMediaData == true else {
            droppedFrames &+= 1
            return nil
        }

        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer
        else {
            poolExhaustionFrames &+= 1
            return nil
        }

        var lease: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer),
            CVPixelBufferGetHeight(pixelBuffer),
            0,
            &lease
        )
        guard result == kCVReturnSuccess,
              let lease,
              let texture = CVMetalTextureGetTexture(lease)
        else {
            return nil
        }
        return (pixelBuffer, texture)
    }

    /// Appends a completed frame. Called from the GPU completion handler.
    func append(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let adaptor, input?.isReadyForMoreMediaData == true else {
            droppedFrames &+= 1
            return
        }
        let presentation = CMTimeMultiply(frameDuration, multiplier: Int32(truncatingIfNeeded: frameIndex))
        if adaptor.append(pixelBuffer, withPresentationTime: presentation) {
            frameIndex &+= 1
        }
    }

    /// Finishes the file and hands it to Photos.
    func finish(completion: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        guard let writer, let input, let url = outputURL else {
            lock.unlock()
            completion(false)
            return
        }
        self.writer = nil
        self.input = nil
        adaptor = nil
        textureCache = nil
        // `outputURL` deliberately survives the stop. The caller that saves to
        // Photos and the timeline scrub preview both have to address the file after
        // the writer is finished, and clearing it here made the coordinator's
        // success branch read nil and throw the path away.
        let wroteFrames = frameIndex > 0
        lock.unlock()

        stateMailbox.publish(.finishing)
        input.markAsFinished()
        let boxed = GVWriterBox(writer)
        boxed.writer.finishWriting { [stateMailbox, self] in
            guard wroteFrames, boxed.writer.status == .completed else {
                let message = boxed.writer.error?.localizedDescription.uppercased() ?? "NO FRAMES WRITTEN"
                stateMailbox.publish(.failed(message))
                try? FileManager.default.removeItem(at: url)
                discardOutputURL()
                completion(false)
                return
            }
            GVPhotoLibrary.saveVideo(at: url) { saved in
                stateMailbox.publish(.idle)
                if !saved {
                    try? FileManager.default.removeItem(at: url)
                    self.discardOutputURL()
                }
                completion(saved)
            }
        }
    }

    /// Retires the take's path together with the file. A URL for a movie that was
    /// just deleted is worse than no URL: whatever opens it gets nothing, which
    /// reads as a broken effect rather than as a take that never landed.
    private func discardOutputURL() {
        lock.withLock { outputURL = nil }
    }

    /// Hard stop used on teardown and interruption; discards the file.
    func abort() {
        lock.lock()
        let writer = self.writer
        let url = outputURL
        self.writer = nil
        input = nil
        adaptor = nil
        textureCache = nil
        outputURL = nil
        frameIndex = 0
        lock.unlock()

        writer?.cancelWriting()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        stateMailbox.publish(.idle)
    }
}

/// Photos access, isolated so the renderer never touches PhotoKit directly.
enum GVPhotoLibrary {
    static func saveVideo(at url: URL, completion: @escaping @Sendable (Bool) -> Void) {
        requestAddAccess { granted in
            guard granted else {
                completion(false)
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: url, options: nil)
            } completionHandler: { saved, error in
                if let error {
                    GVLog.rendering.error("Video save failed: \(error.localizedDescription, privacy: .public)")
                }
                completion(saved)
            }
        }
    }

    private static func requestAddAccess(_ completion: @escaping @Sendable (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            completion(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { granted in
                completion(granted == .authorized || granted == .limited)
            }
        default:
            completion(false)
        }
    }
}

extension CaptureSetupDraft.VideoCodec {
    /// Exact codec identifier. A professional format must never silently turn
    /// into HEVC; unsupported selections fail before a take begins.
    var assetWriterCodec: AVVideoCodecType? {
        avVideoCodecType
    }
}
