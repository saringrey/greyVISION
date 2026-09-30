import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Writes the decoded LINK stream locally without changing the iPhone stream.
/// Audio remains a separate future track; the current network contract carries
/// video and effect state only.
final class GVLocalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var firstTimestamp: CMTime?
    private var outputURL: URL?

    var isRecording: Bool { lock.withLock { writer != nil } }

    @discardableResult
    func start(width: Int, height: Int, frameRate: Int) -> URL? {
        lock.withLock {
            guard writer == nil else { return outputURL }
            let folder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let formatter = ISO8601DateFormatter()
            let name = "GreyVision-\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-"))\(UUID().uuidString.prefix(4)).mov"
            let url = folder.appendingPathComponent(name)
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoExpectedSourceFrameRateKey: max(frameRate, 1),
                    AVVideoAverageBitRateKey: 120_000_000,
                    AVVideoMaxKeyFrameIntervalKey: max(frameRate, 1) * 2
                ]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { return nil }
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height
                ]
            )
            writer.add(input)
            guard writer.startWriting() else { return nil }
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.outputURL = url
            firstTimestamp = nil
            return url
        }
    }

    func append(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        lock.withLock {
            guard let writer, let input, let adaptor, writer.status == .writing else { return }
            if firstTimestamp == nil {
                firstTimestamp = timestamp
                writer.startSession(atSourceTime: timestamp)
            }
            guard input.isReadyForMoreMediaData else { return }
            _ = adaptor.append(pixelBuffer, withPresentationTime: timestamp)
        }
    }

    func stop(completion: @escaping (URL?) -> Void) {
        let captured: (AVAssetWriter?, AVAssetWriterInput?, URL?) = lock.withLock {
            let value = (writer, input, outputURL)
            writer = nil
            input = nil
            adaptor = nil
            firstTimestamp = nil
            outputURL = nil
            return value
        }
        guard let writer = captured.0, let input = captured.1 else {
            completion(nil)
            return
        }
        input.markAsFinished()
        writer.finishWriting { completion(writer.status == .completed ? captured.2 : nil) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }; return body()
    }
}
