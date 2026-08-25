import Combine
import Foundation
import QuartzCore
import SwiftUI

/// Drives stills and recording from the interface.
///
/// Owns the writer and the still request, and translates their results into
/// the short notices the workspace already uses. The renderer does the pixel
/// work; this type only decides when and reports what happened.
@MainActor
final class GVCaptureController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var isCapturingStill = false
    @Published private(set) var notice: String?

    let recorder = GVVideoRecorder()
    let stillMailbox = GVStillRequestMailbox()

    private var tickTimer: Timer?
    private var noticeTask: Task<Void, Never>?

    /// `REC 00:01:42` for the HUD.
    var timecode: String {
        let total = Int(elapsed)
        return String(format: "REC %02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    func captureStill() {
        guard !isCapturingStill else { return }
        isCapturingStill = true
        GVInteractionHaptics.commit()

        stillMailbox.request { [weak self] image in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let image else {
                    isCapturingStill = false
                    show("SCREENSHOT // CAPTURE FAILED")
                    return
                }
                GVPhotoLibrary.saveImage(image) { saved in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        isCapturingStill = false
                        show(saved ? "SCREENSHOT // SAVED TO PHOTOS" : "SCREENSHOT // PHOTOS ACCESS DENIED")
                    }
                }
            }
        }
    }

    func toggleRecording(device: MTLDevice?, snapshot: CameraRuntimeSnapshot, drawableSize: CGSize) {
        if isRecording {
            stopRecording()
        } else {
            startRecording(device: device, snapshot: snapshot, drawableSize: drawableSize)
        }
    }

    private func startRecording(device: MTLDevice?, snapshot: CameraRuntimeSnapshot, drawableSize: CGSize) {
        guard let device else {
            show("RECORD // NO METAL DEVICE")
            return
        }
        guard snapshot.state == .running else {
            show("RECORD // CAMERA NOT RUNNING")
            return
        }

        let width = max(Int(drawableSize.width.rounded()), 2)
        let height = max(Int(drawableSize.height.rounded()), 2)
        let started = recorder.start(
            device: device,
            width: width,
            height: height,
            framesPerSecond: snapshot.framesPerSecond,
            codec: snapshot.requestedVideoCodec
        )

        guard started else {
            if case let .failed(reason) = recorder.stateMailbox.latest {
                show("RECORD // \(reason)")
            } else {
                show("RECORD // COULD NOT START")
            }
            return
        }

        isRecording = true
        elapsed = 0
        GVInteractionHaptics.commit()
        show("RECORD // ARMED")
        startTicking()
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        stopTicking()
        GVInteractionHaptics.commit()
        show("RECORD // WRITING")

        recorder.finish { saved in
            Task { @MainActor [weak self] in
                self?.show(saved ? "RECORD // SAVED TO PHOTOS" : "RECORD // SAVE FAILED")
                self?.elapsed = 0
            }
        }
    }

    /// Interruption, backgrounding or teardown. Discards the partial file.
    func abort() {
        stopTicking()
        stillMailbox.cancel()
        guard isRecording else { return }
        isRecording = false
        elapsed = 0
        recorder.abort()
        show("RECORD // INTERRUPTED")
    }

    private func startTicking() {
        stopTicking()
        let started = CACurrentMediaTime()
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.elapsed = CACurrentMediaTime() - started
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
