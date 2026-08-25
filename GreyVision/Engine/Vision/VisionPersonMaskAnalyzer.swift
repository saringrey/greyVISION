import CoreVideo
import Foundation
import ImageIO
@preconcurrency import Vision

struct VisionPersonMaskFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let sequence: UInt64
}

private struct VisionPersonMaskInput: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let orientation: CGImagePropertyOrientation
}

final class VisionPersonMaskAnalyzer: @unchecked Sendable {
    private let analysisQueue = DispatchQueue(
        label: "com.saringrey.greyvision.vision.person-mask",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private let request: VNGeneratePersonSegmentationRequest
    private var isProcessing = false
    private var lastSubmissionTime: TimeInterval = 0
    private var latestFrame: VisionPersonMaskFrame?
    private var sequence: UInt64 = 0

    init() {
        request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    func submit(_ pixelBuffer: CVPixelBuffer, orientation: CapturedFrameOrientation) {
        let now = ProcessInfo.processInfo.systemUptime
        let accepted = stateLock.withLock {
            guard !isProcessing, now - lastSubmissionTime >= 1.0 / 10.0 else { return false }
            isProcessing = true
            lastSubmissionTime = now
            return true
        }
        guard accepted else { return }

        let input = VisionPersonMaskInput(
            pixelBuffer: pixelBuffer,
            orientation: Self.imageOrientation(for: orientation)
        )
        analysisQueue.async { [weak self] in
            guard let self else { return }
            defer {
                stateLock.withLock {
                    isProcessing = false
                }
            }
            do {
                let handler = VNImageRequestHandler(
                    cvPixelBuffer: input.pixelBuffer,
                    orientation: input.orientation
                )
                try handler.perform([request])
                guard let mask = request.results?.first?.pixelBuffer else { return }
                stateLock.withLock {
                    sequence &+= 1
                    latestFrame = VisionPersonMaskFrame(pixelBuffer: mask, sequence: sequence)
                }
            } catch {
                GVLog.rendering.error("Vision person mask failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func latestMask() -> VisionPersonMaskFrame? {
        stateLock.withLock { latestFrame }
    }

    func reset() {
        stateLock.withLock {
            latestFrame = nil
            lastSubmissionTime = 0
        }
    }

    private static func imageOrientation(
        for orientation: CapturedFrameOrientation
    ) -> CGImagePropertyOrientation {
        switch orientation {
        case .portrait:
            .right
        case .portraitUpsideDown:
            .left
        case .landscapeLeft:
            .up
        case .landscapeRight:
            .down
        }
    }
}
