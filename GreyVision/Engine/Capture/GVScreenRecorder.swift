@preconcurrency import AVFoundation
import ReplayKit
import UIKit

/// Records the app's own screen — the effected image *and* the interface over
/// it — into the take library, so a take looks exactly like what the operator
/// saw while making it.
///
/// ReplayKit's in-app capture hands back the composited screen, Metal layers
/// included, so nothing here touches the render loop. The movie is written
/// straight into the durable take library; filing and the Photos export are
/// the caller's job, through `GVTakeArchive.completeRecording`, which is the
/// one place a take is ever saved to Photos.
@MainActor
final class GVScreenRecorder {
    static var isAvailable: Bool {
        RPScreenRecorder.shared().isAvailable
    }

    private(set) var isActive = false
    private var sink: GVScreenRecordingSink?

    /// Starts capture. Returns false when ReplayKit refuses (permission
    /// declined, another capture running) or the library has no room.
    func start() async -> Bool {
        guard !isActive else { return true }
        let url: URL
        do {
            url = try GVTakeArchive.shared.makeRecordingURL()
        } catch {
            GVLog.recording.error("Screen recording has no writable take library")
            return false
        }
        let sink = GVScreenRecordingSink(url: url)
        let recorder = RPScreenRecorder.shared()
        recorder.isMicrophoneEnabled = true
        self.sink = sink
        isActive = true
        do {
            // The handler runs on ReplayKit's own queue. It must be explicitly
            // @Sendable, or Swift 6 infers main-actor isolation from this
            // context and traps the first time a frame arrives off-main.
            try await recorder.startCapture(handler: { @Sendable buffer, type, error in
                if let error {
                    GVLog.recording.error("Screen capture frame error: \(error.localizedDescription, privacy: .public)")
                    return
                }
                sink.append(buffer, type: type)
            })
            GVLog.recording.notice("Screen recording started")
            return true
        } catch {
            GVLog.recording.error("Screen recording refused: \(error.localizedDescription, privacy: .public)")
            isActive = false
            self.sink = nil
            sink.discard()
            return false
        }
    }

    /// Stops capture and finalises the movie. Returns its URL, or nil when no
    /// usable movie was produced (the partial file is removed).
    func stop() async -> URL? {
        guard isActive, let sink else { return nil }
        isActive = false
        self.sink = nil
        do {
            try await RPScreenRecorder.shared().stopCapture()
        } catch {
            GVLog.recording.error("Screen capture stop failed: \(error.localizedDescription, privacy: .public)")
        }
        return await sink.finish()
    }

    /// Abandons the take without filing anything.
    func cancel() async {
        guard isActive, let sink else { return }
        isActive = false
        self.sink = nil
        try? await RPScreenRecorder.shared().stopCapture()
        sink.discard()
    }
}

/// Owns the writer. ReplayKit delivers buffers serially on one queue, so a
/// lock around the writer state is all the coordination it needs.
final class GVScreenRecordingSink: @unchecked Sendable {
    let url: URL

    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var closed = false
    private var videoFrames = 0

    init(url: URL) {
        self.url = url
    }

    func append(_ buffer: CMSampleBuffer, type: RPSampleBufferType) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, CMSampleBufferDataIsReady(buffer) else { return }

        switch type {
        case .video:
            if writer == nil, !configure(firstFrame: buffer) {
                closed = true
                return
            }
            guard let writer, let videoInput else { return }
            if !sessionStarted {
                guard writer.startWriting() else {
                    GVLog.recording.error("Screen writer failed to start: \(writer.error?.localizedDescription ?? "unknown", privacy: .public)")
                    closed = true
                    return
                }
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buffer))
                sessionStarted = true
            }
            if videoInput.isReadyForMoreMediaData, videoInput.append(buffer) {
                videoFrames += 1
            }
        case .audioMic:
            guard sessionStarted, let audioInput, audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(buffer)
        default:
            break
        }
    }

    /// Builds the writer from the first frame, which is the only reliable
    /// source for the capture's real pixel size and orientation.
    private func configure(firstFrame buffer: CMSampleBuffer) -> Bool {
        guard let format = CMSampleBufferGetFormatDescription(buffer) else { return false }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let width = Int(dimensions.width)
        let height = Int(dimensions.height)
        guard width > 0, height > 0 else { return false }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            GVLog.recording.error("Screen writer could not be created: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(width * height * 10, 8_000_000),
                AVVideoExpectedSourceFrameRateKey: 60
            ]
        ])
        video.expectsMediaDataInRealTime = true
        video.transform = Self.transform(for: buffer)
        guard writer.canAdd(video) else { return false }
        writer.add(video)

        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ])
        audio.expectsMediaDataInRealTime = true
        if writer.canAdd(audio) {
            writer.add(audio)
            audioInput = audio
        }

        self.writer = writer
        videoInput = video
        return true
    }

    /// ReplayKit keeps the buffer in the panel's native orientation and tags
    /// how to turn it; the track transform carries that into the movie.
    private static func transform(for buffer: CMSampleBuffer) -> CGAffineTransform {
        guard let raw = CMGetAttachment(buffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: raw.uint32Value)
        else { return .identity }
        switch orientation {
        case .right: return CGAffineTransform(rotationAngle: .pi / 2)
        case .left: return CGAffineTransform(rotationAngle: -.pi / 2)
        case .down: return CGAffineTransform(rotationAngle: .pi)
        default: return .identity
        }
    }

    func finish() async -> URL? {
        let (writer, usable): (AVAssetWriter?, Bool) = lock.withLock {
            closed = true
            return (self.writer, sessionStarted && videoFrames > 0)
        }
        guard let writer, usable else {
            discard()
            return nil
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        let box = GVScreenWriterBox(writer)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            box.writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            GVLog.recording.error("Screen writer did not complete: \(writer.error?.localizedDescription ?? "unknown", privacy: .public)")
            discard()
            return nil
        }
        GVLog.recording.notice("Screen recording finalized: \(self.videoFrames, privacy: .public) frames")
        return url
    }

    func discard() {
        lock.withLock {
            closed = true
            if sessionStarted { writer?.cancelWriting() }
        }
        try? FileManager.default.removeItem(at: url)
    }
}

private final class GVScreenWriterBox: @unchecked Sendable {
    let writer: AVAssetWriter
    init(_ writer: AVAssetWriter) {
        self.writer = writer
    }
}
