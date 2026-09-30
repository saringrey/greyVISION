import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Photos

extension CGImagePropertyOrientation {
    /// Returns the preferred transform for a given orientation and natural size.
    func transform(for naturalSize: CGSize) -> CGAffineTransform {
        var transform = CGAffineTransform.identity
        switch self {
        case .up:
            transform = .identity
        case .upMirrored:
            transform = CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -naturalSize.width, y: 0)
        case .down:
            transform = CGAffineTransform(rotationAngle: .pi).translatedBy(x: -naturalSize.width, y: -naturalSize.height)
        case .downMirrored:
            transform = CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: 0, y: -naturalSize.height).rotated(by: .pi)
        case .left:
            transform = CGAffineTransform(rotationAngle: .pi / 2).translatedBy(x: 0, y: -naturalSize.width)
        case .leftMirrored:
            transform = CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -naturalSize.height, y: 0).rotated(by: .pi / 2)
        case .right:
            transform = CGAffineTransform(rotationAngle: -.pi / 2).translatedBy(x: -naturalSize.height, y: 0)
        case .rightMirrored:
            transform = CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: 0, y: -naturalSize.width).rotated(by: -.pi / 2)
        @unknown default:
            transform = .identity
        }
        return transform
    }
}

enum GVRecordingError: LocalizedError, Sendable {
    case writerSetupFailed
    case finishFailed(String)
    case saveFailed
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .writerSetupFailed:
            return "RECORDING // WRITER SETUP FAILED"
        case let .finishFailed(message):
            return "RECORDING // FINALIZE FAILED \(message)"
        case .saveFailed:
            return "RECORDING // PHOTO LIBRARY SAVE FAILED"
        case .accessDenied:
            return "RECORDING // PHOTOS ACCESS DENIED"
        }
    }
}

/// Writes the AR objects render output to an H.264 movie and exports it to the
/// photo library on stop. The GPU blits each finished frame straight into a
/// pixel buffer from the writer's pool (no CPU round-trip), and frames are
/// appended from the command-buffer completion handler so the encoder can never
/// stall the live preview.
/// Non-Sendable AVFoundation objects wrapped for safe capture in @Sendable closures.
private final class WriterBox: @unchecked Sendable {
    let writer: AVAssetWriter

    init(_ writer: AVAssetWriter) {
        self.writer = writer
    }
}

private final class MediaBox: @unchecked Sendable {
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let pixelBuffer: CVPixelBuffer

    init(adaptor: AVAssetWriterInputPixelBufferAdaptor, pixelBuffer: CVPixelBuffer) {
        self.adaptor = adaptor
        self.pixelBuffer = pixelBuffer
    }
}

/// Audited handoff for the audio path: the serial `writerQueue` is the sole
/// owner of writer inputs once handed off. The box retains the input and the
/// rewritten sample buffer across the async boundary so neither the capture
/// callback nor the writer queue can observe a half-moved value.
private final class AudioBox: @unchecked Sendable {
    let audioInput: AVAssetWriterInput
    let sampleBuffer: CMSampleBuffer

    init(audioInput: AVAssetWriterInput, sampleBuffer: CMSampleBuffer) {
        self.audioInput = audioInput
        self.sampleBuffer = sampleBuffer
    }
}

final class GVRealtimeRecordingSession: @unchecked Sendable {
    let outputURL: URL
    let size: CGSize
    let saveToPhotos: Bool
    let burnHUD: Bool

    private let lock = NSLock()
    private let writerQueue = DispatchQueue(
        label: "com.saringrey.greyvision.ar.record",
        qos: .userInitiated
    )
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: TimeInterval?
    private var pendingBuffers = 0
    private var isFinished = false
    private let codec: AVVideoCodecType
    /// Frames dropped due to encoder backpressure (pendingBuffers >= 4)
    private var droppedFrames: Int64 = 0
    /// Frames dropped due to pixel buffer pool exhaustion
    private var poolExhaustionFrames: Int64 = 0
    /// Frames successfully encoded
    private var encodedFrames: Int64 = 0

    var pixelFormat: OSType {
        isHighPrecisionProRes ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA
    }

    /// Total frames successfully encoded.
    var encodedFrameCount: Int64 {
        lock.withLock { encodedFrames }
    }

    /// Frames dropped due to encoder not ready (backpressure).
    var droppedFrameCount: Int64 {
        lock.withLock { droppedFrames }
    }

    /// Frames dropped due to pixel buffer pool exhaustion.
    var poolExhaustionFrameCount: Int64 {
        lock.withLock { poolExhaustionFrames }
    }

    /// Total frames presented to recorder (encoded + dropped).
    var totalFramesPresented: Int64 {
        lock.withLock { encodedFrames + droppedFrames + poolExhaustionFrames }
    }

    private var isHighPrecisionProRes: Bool {
        [.proRes422Proxy, .proRes422LT, .proRes422, .proRes422HQ, .proRes4444]
            .contains(codec) || codec.rawValue == "ap4x"
    }

    /// Video orientation for the output file. Set before start().
    var videoOrientation: CGImagePropertyOrientation = .up

    init(
        outputURL: URL,
        size: CGSize,
        saveToPhotos: Bool,
        codec: AVVideoCodecType = .hevc,
        burnHUD: Bool = false
    ) {
        self.outputURL = outputURL
        self.size = size
        self.saveToPhotos = saveToPhotos
        self.codec = codec
        self.burnHUD = burnHUD
    }

    func start(withAudio: Bool = false) -> Bool {
        writerQueue.sync { () -> Bool in
            guard writer == nil else { return false }
            let width = max(16, Int(size.width.rounded() / 2) * 2)
            let height = max(16, Int(size.height.rounded() / 2) * 2)
            do {
                let assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
                var outputSettings: [String: Any] = [
                    AVVideoCodecKey: codec,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height
                ]
                if isHighPrecisionProRes {
                    // The Metal graph works in RGBA16Float linear light. Keep
                    // that precision through the ProRes encoder and identify
                    // the transfer correctly instead of quantizing to 8-bit
                    // BGRA while merely changing the codec label.
                    outputSettings[AVVideoColorPropertiesKey] = [
                        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                        AVVideoTransferFunctionKey: AVVideoTransferFunction_Linear,
                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                    ]
                }
                guard assetWriter.canApply(outputSettings: outputSettings, forMediaType: .video) else {
                    return false
                }
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
                input.expectsMediaDataInRealTime = true
                let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: input,
                    sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                        kCVPixelBufferWidthKey as String: width,
                        kCVPixelBufferHeightKey as String: height,
                        kCVPixelBufferMetalCompatibilityKey as String: true,
                        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
                    ]
                )
                guard assetWriter.canAdd(input) else {
                    return false
                }
                assetWriter.add(input)

                var audioInput: AVAssetWriterInput?
                if withAudio {
                    let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVNumberOfChannelsKey: 2,
                        AVSampleRateKey: 44100.0,
                        AVEncoderBitRateKey: 128000
                    ])
                    aInput.expectsMediaDataInRealTime = true
                    if assetWriter.canAdd(aInput) {
                        assetWriter.add(aInput)
                        audioInput = aInput
                    }
                }

                guard assetWriter.startWriting() else {
                    return false
                }
                assetWriter.startSession(atSourceTime: .zero)
                writer = assetWriter
                writerInput = input
                audioWriterInput = audioInput
                adaptor = pixelBufferAdaptor
                isFinished = false
                startTime = nil
                pendingBuffers = 0
                return true
            } catch {
                return false
            }
        }
    }

    /// Hands out a writable pixel buffer from the writer's pool. Bounded to a
    /// few outstanding buffers; when the encoder falls behind, frames are
    /// skipped rather than queuing without limit.
    func nextPixelBuffer() -> CVPixelBuffer? {
        lock.lock()
        guard writer != nil, !isFinished, pendingBuffers < 4,
              let pool = adaptor?.pixelBufferPool
        else {
            droppedFrames += 1
            lock.unlock()
            return nil
        }
        pendingBuffers += 1
        lock.unlock()

        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        if result != kCVReturnSuccess || pixelBuffer == nil {
            lock.withLock {
                pendingBuffers = max(pendingBuffers - 1, 0)
                poolExhaustionFrames += 1
            }
            return nil
        }
        return pixelBuffer
    }

    let overlayRenderer = RecordingOverlayRenderer()

    /// Safe to call from any thread once the GPU has finished writing into the
    /// pixel buffer (command-buffer completion handler).
    func append(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        lock.lock()
        let adaptor = self.adaptor
        let finished = isFinished
        if startTime == nil {
            startTime = timestamp
        }
        let baseTime = startTime ?? timestamp
        lock.unlock()

        guard !finished, let adaptor else {
            lock.withLock { pendingBuffers = max(pendingBuffers - 1, 0) }
            return
        }
        let presentationTime = CMTime(
            seconds: max(timestamp - baseTime, 0),
            preferredTimescale: 600
        )
        // AVAssetWriterInputPixelBufferAdaptor and CVPixelBuffer are
        // non-Sendable; box them so the queue closure holds safe captures.
        let box = MediaBox(adaptor: adaptor, pixelBuffer: pixelBuffer)
        writerQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.withLock { self.pendingBuffers = max(self.pendingBuffers - 1, 0) }
            }
            // The completion handler is on the live render path. Burn the
            // recording-only overlay on the bounded writer queue instead, so
            // text rasterisation can never delay preview presentation.
            if self.burnHUD {
                self.overlayRenderer.composite(into: box.pixelBuffer, timestamp: max(timestamp - baseTime, 0))
            }
            if box.adaptor.assetWriterInput.isReadyForMoreMediaData {
                box.adaptor.append(box.pixelBuffer, withPresentationTime: presentationTime)
                self.lock.withLock { self.encodedFrames += 1 }
            } else {
                self.lock.withLock { self.droppedFrames += 1 }
            }
        }
    }

    func appendAudio(sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let finished = isFinished
        let audioInput = self.audioWriterInput
        let audioPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        if startTime == nil {
            // The first audio buffer sets the session's epoch. The video path
            // does the same with the first video frame, and the two epochs are
            // both "time since boot", so whichever lands first anchors the
            // writer.
            startTime = audioPTS
        }
        let baseTime = startTime ?? audioPTS
        lock.unlock()

        guard !finished, let audioInput else { return }

        // The audio sample's PTS is in the capture clock (time since boot). The
        // writer was started at .zero and expects PTS in that same epoch
        // starting at 0, which is what the video path produces. The raw audio
        // buffer carries the original capture-time PTS - leaving it unchanged
        // puts audio at e.g. +12 000 s while video sits at 0, the writer drops
        // the buffers, and the file ends up silent.
        //
        // Rewriting the presentation time on a copy keeps the source buffer
        // untouched (the camera session owns it) and lets the writer align
        // audio with the video it is paired with.
        let sessionTime = max(audioPTS - baseTime, 0)
        var sourceDuration = CMSampleBufferGetDuration(sampleBuffer)
        if !sourceDuration.isValid {
            // Audio from AVCaptureAudioDataOutput typically carries no per-
            // buffer duration; the encoder derives frame timing from the PTS
            // series. A single sample's duration is irrelevant in that case,
            // so we leave the new buffer's duration invalid.
            sourceDuration = .invalid
        }
        var timing = CMSampleTimingInfo(
            duration: sourceDuration,
            presentationTimeStamp: CMTime(seconds: sessionTime, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var rewritten: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &rewritten
        )
        guard status == noErr, let audioBuffer = rewritten else {
            return
        }

        // Hand off to the serial writerQueue owner via an audited box.
        let box = AudioBox(audioInput: audioInput, sampleBuffer: audioBuffer)
        writerQueue.async { [weak self] in
            guard let _ = self else { return }
            if box.audioInput.isReadyForMoreMediaData {
                box.audioInput.append(box.sampleBuffer)
            }
        }
    }

    func finish(completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        writerQueue.async {
            self.lock.withLock { self.isFinished = true }
            guard let writer = self.writer, let writerInput = self.writerInput else {
                completion(.failure(GVRecordingError.writerSetupFailed))
                return
            }
            writerInput.markAsFinished()
            self.audioWriterInput?.markAsFinished()
            let url = self.outputURL
            let saveToPhotos = self.saveToPhotos
            // AVAssetWriter is non-Sendable; box it so the @Sendable completion
            // can inspect status without an unsafe capture.
            let boxed = WriterBox(writer)
            boxed.writer.finishWriting {
                if boxed.writer.status == .completed {
                    if saveToPhotos {
                        self.saveToPhotoLibrary(url, completion: completion)
                    } else {
                        completion(.success(url))
                    }
                } else {
                    let message = boxed.writer.error?.localizedDescription ?? "UNKNOWN WRITER ERROR"
                    try? FileManager.default.removeItem(at: url)
                    completion(.failure(GVRecordingError.finishFailed(message)))
                }
            }
        }
    }

    private func saveToPhotoLibrary(
        _ url: URL,
        completion: @escaping @Sendable (Result<URL, Error>) -> Void
    ) {
        Self.requestPhotoLibraryAccess { granted in
            guard granted else {
                try? FileManager.default.removeItem(at: url)
                completion(.failure(GVRecordingError.accessDenied))
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: url, options: nil)
            } completionHandler: { success, error in
                if success {
                    GVLog.recording.notice("Video successfully saved to Photos")
                    completion(.success(url))
                } else {
                    try? FileManager.default.removeItem(at: url)
                    GVLog.recording.error("Photo library video save error: \(error?.localizedDescription ?? "unknown")")
                    completion(.failure(error ?? GVRecordingError.saveFailed))
                }
            }
        }
    }

    private static func requestPhotoLibraryAccess(_ completion: @escaping @Sendable (Bool) -> Void) {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            completion(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                completion(status == .authorized || status == .limited)
            }
        default:
            completion(false)
        }
    }
}
