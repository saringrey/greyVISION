import AVFoundation
import CoreVideo
import Foundation
import Photos

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

final class GVRealtimeRecordingSession: @unchecked Sendable {
    let outputURL: URL
    let size: CGSize
    let saveToPhotos: Bool

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

    init(outputURL: URL, size: CGSize, saveToPhotos: Bool, codec: AVVideoCodecType = .hevc) {
        self.outputURL = outputURL
        self.size = size
        self.saveToPhotos = saveToPhotos
        self.codec = codec
    }

    func start(withAudio: Bool = false) -> Bool {
        writerQueue.sync {
            guard writer == nil else { return false }
            let width = max(16, Int(size.width.rounded() / 2) * 2)
            let height = max(16, Int(size.height.rounded() / 2) * 2)
            do {
                let assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: codec,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height
                ])
                input.expectsMediaDataInRealTime = true
                let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: input,
                    sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
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
            lock.unlock()
            return nil
        }
        pendingBuffers += 1
        lock.unlock()

        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        if result != kCVReturnSuccess || pixelBuffer == nil {
            lock.withLock { pendingBuffers = max(pendingBuffers - 1, 0) }
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

        overlayRenderer.composite(into: pixelBuffer, timestamp: max(timestamp - baseTime, 0))

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
            if box.adaptor.assetWriterInput.isReadyForMoreMediaData {
                box.adaptor.append(box.pixelBuffer, withPresentationTime: presentationTime)
            }
        }
    }

    func appendAudio(sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let finished = isFinished
        let audioInput = self.audioWriterInput
        if startTime == nil {
            startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        }
        lock.unlock()

        guard !finished, let audioInput else { return }
        
        writerQueue.async { [weak self] in
            guard let _ = self else { return }
            if audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
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
