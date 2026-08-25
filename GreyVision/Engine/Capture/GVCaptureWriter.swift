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

/// A one-shot request for a processed still.
final class GVStillRequestMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var isRequested = false
    private var handler: (@Sendable (CGImage?) -> Void)?

    func request(_ handler: @escaping @Sendable (CGImage?) -> Void) {
        lock.withLock {
            isRequested = true
            self.handler = handler
        }
    }

    /// Consuming clears the flag so a single tap captures exactly one frame.
    func consume() -> Bool {
        lock.withLock {
            let requested = isRequested
            isRequested = false
            return requested
        }
    }

    func deliver(_ image: CGImage?) {
        let handler = lock.withLock {
            let stored = self.handler
            self.handler = nil
            return stored
        }
        handler?(image)
    }

    func cancel() {
        lock.withLock {
            isRequested = false
            handler = nil
        }
    }
}

/// Writes processed frames to a QuickTime file.
///
/// Frames arrive already encoded to display-referred BGRA in a pixel buffer
/// drawn from the adaptor's own pool, so nothing is copied through the CPU.
/// Video only — the microphone is owned by the audio-reactive analyser and
/// sharing it with a recording session is not wired up.
final class GVVideoRecorder: @unchecked Sendable {
    let stateMailbox = GVRecordingStateMailbox()

    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var textureCache: CVMetalTextureCache?
    private var outputURL: URL?
    private var startTime: CMTime?
    private var frameIndex: Int64 = 0
    private var frameDuration = CMTime(value: 1, timescale: 60)
    private var size = CGSize.zero

    var isRecording: Bool {
        stateMailbox.latest.isRecording
    }

    /// Prepares the writer. Returns false if the codec or destination is
    /// unavailable rather than failing silently later.
    @discardableResult
    func start(
        device: MTLDevice,
        width: Int,
        height: Int,
        framesPerSecond: Int,
        codec: CaptureSetupDraft.VideoCodec
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

        let settings: [String: Any] = [
            AVVideoCodecKey: codec.assetWriterCodec,
            AVVideoWidthKey: evenWidth,
            AVVideoHeightKey: evenHeight
        ]
        guard assetWriter.canApply(outputSettings: settings, forMediaType: .video) else {
            stateMailbox.publish(.failed("\(codec.rawValue) UNSUPPORTED"))
            return false
        }

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        writerInput.expectsMediaDataInRealTime = true

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
        guard input?.isReadyForMoreMediaData == true else { return nil }

        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer
        else {
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
        guard let adaptor, input?.isReadyForMoreMediaData == true else { return }
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
        outputURL = nil
        let wroteFrames = frameIndex > 0
        lock.unlock()

        stateMailbox.publish(.finishing)
        input.markAsFinished()
        writer.finishWriting { [stateMailbox] in
            guard wroteFrames, writer.status == .completed else {
                let message = writer.error?.localizedDescription.uppercased() ?? "NO FRAMES WRITTEN"
                stateMailbox.publish(.failed(message))
                try? FileManager.default.removeItem(at: url)
                completion(false)
                return
            }
            GVPhotoLibrary.saveVideo(at: url) { saved in
                stateMailbox.publish(.idle)
                if !saved {
                    try? FileManager.default.removeItem(at: url)
                }
                completion(saved)
            }
        }
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
    static func saveImage(_ image: CGImage, completion: @escaping @Sendable (Bool) -> Void) {
        requestAddAccess { granted in
            guard granted else {
                completion(false)
                return
            }
            let data = UIImage(cgImage: image).pngData()
            guard let data else {
                completion(false)
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { saved, error in
                if let error {
                    GVLog.rendering.error("Still save failed: \(error.localizedDescription, privacy: .public)")
                }
                completion(saved)
            }
        }
    }

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
    /// Codec identifier the asset writer understands. ProRes variants fall back
    /// to HEVC where the platform does not offer them.
    var assetWriterCodec: AVVideoCodecType {
        switch rawValue.uppercased() {
        case let value where value.contains("H.264") || value.contains("H264"):
            .h264
        case let value where value.contains("PRORES 422"):
            .proRes422
        case let value where value.contains("PRORES 4444"):
            .proRes4444
        default:
            .hevc
        }
    }
}
