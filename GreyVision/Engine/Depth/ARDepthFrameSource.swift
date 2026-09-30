@preconcurrency import ARKit
import CoreVideo
import Foundation

private struct ARDepthSourceState {
    let isRunning: Bool
    let usesSmoothedDepth: Bool
    let orientation: CapturedFrameOrientation
}

final class ARDepthFrameSource: NSObject, @unchecked Sendable {
    let sourceID = "arkit.scene-depth"
    let mailbox: LatestDepthFrameMailbox

    private let session = ARSession()
    private let sessionQueue = DispatchQueue(
        label: "com.saringrey.greyvision.depth.session",
        qos: .userInteractive
    )
    private let handlerLock = NSLock()
    private let stateLock = NSLock()

    private var eventHandler: (@Sendable (ARDepthSourceEvent) -> Void)?
    private var orientation = CapturedFrameOrientation.portrait
    private var isRunning = false
    private var usesSmoothedDepth = false
    private var frameSequence: UInt64 = 0
    private var lastMetadataTimestamp = -Double.infinity

    init(mailbox: LatestDepthFrameMailbox) {
        self.mailbox = mailbox
        super.init()
        session.delegate = self
        session.delegateQueue = sessionQueue
    }

    deinit {
        session.pause()
    }

    func setEventHandler(_ handler: (@Sendable (ARDepthSourceEvent) -> Void)?) {
        handlerLock.withLock {
            eventHandler = handler
        }
    }

    func updateOrientation(_ orientation: CapturedFrameOrientation) {
        stateLock.withLock {
            self.orientation = orientation
        }
    }

    func start(capability: DepthCapability) async throws -> Bool {
        guard capability.isSupported else {
            throw GVError.capabilityUnavailable(feature: "Scene Depth", reason: capability.reason)
        }
        let shouldUseSmoothed = capability.supportsSmoothedDepth
        return await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                mailbox.clear()
                let configuration = ARWorldTrackingConfiguration()
                configuration.worldAlignment = .gravity
                configuration.environmentTexturing = .none
                configuration.planeDetection = []
                configuration.providesAudioData = false
                configuration.frameSemantics = shouldUseSmoothed ? .smoothedSceneDepth : .sceneDepth

                stateLock.withLock {
                    usesSmoothedDepth = shouldUseSmoothed
                    isRunning = true
                    frameSequence = 0
                    lastMetadataTimestamp = -Double.infinity
                }
                session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
                GVLog.capture.notice(
                    "ARKit depth source started: \(shouldUseSmoothed ? "smoothed" : "raw", privacy: .public)"
                )
                continuation.resume(returning: shouldUseSmoothed)
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                stopOnSessionQueue()
                continuation.resume()
            }
        }
    }

    func stopSoon() {
        sessionQueue.async { [weak self] in
            self?.stopOnSessionQueue()
        }
    }

    private func stopOnSessionQueue() {
        stateLock.withLock {
            isRunning = false
            frameSequence = 0
            lastMetadataTimestamp = -Double.infinity
        }
        session.pause()
        mailbox.clear()
        GVLog.capture.notice("ARKit depth source stopped and detached")
    }

    private func emit(_ event: ARDepthSourceEvent) {
        let handler = handlerLock.withLock { eventHandler }
        handler?(event)
    }
}

extension ARDepthFrameSource: ARSessionDelegate {
    func session(_: ARSession, didUpdate frame: ARFrame) {
        let state = stateLock.withLock {
            ARDepthSourceState(
                isRunning: isRunning,
                usesSmoothedDepth: usesSmoothedDepth,
                orientation: orientation
            )
        }
        guard state.isRunning else { return }

        let actualSmoothed = state.usesSmoothedDepth && frame.smoothedSceneDepth != nil
        let depthData = state.usesSmoothedDepth
            ? frame.smoothedSceneDepth ?? frame.sceneDepth
            : frame.sceneDepth
        guard let depthData else { return }

        let image = frame.capturedImage
        let depthMap = depthData.depthMap
        let imageDimensions = CaptureDimensions(
            width: Int32(CVPixelBufferGetWidth(image)),
            height: Int32(CVPixelBufferGetHeight(image))
        )
        let packet = DepthFrame(
            capturedImage: image,
            depthMap: depthMap,
            confidenceMap: depthData.confidenceMap,
            intrinsics: frame.camera.intrinsics,
            cameraTransform: frame.camera.transform,
            imageDimensions: imageDimensions,
            orientation: state.orientation,
            timestamp: frame.timestamp
        )
        mailbox.publish(packet)

        let eventMetadata = stateLock.withLock { () -> DepthFrameMetadata? in
            frameSequence &+= 1
            guard frame.timestamp - lastMetadataTimestamp >= 0.20 || frameSequence == 1 else {
                return nil
            }
            lastMetadataTimestamp = frame.timestamp
            return DepthFrameMetadata(
                width: CVPixelBufferGetWidth(depthMap),
                height: CVPixelBufferGetHeight(depthMap),
                timestamp: frame.timestamp,
                sequence: frameSequence,
                hasConfidence: depthData.confidenceMap != nil,
                usesSmoothedDepth: actualSmoothed
            )
        }
        if let eventMetadata {
            emit(.frame(eventMetadata))
        }
    }

    func session(_: ARSession, didFailWithError error: Error) {
        stateLock.withLock {
            isRunning = false
        }
        emit(.failed(error.localizedDescription))
    }

    func sessionWasInterrupted(_: ARSession) {
        emit(.interrupted("ARKIT SESSION INTERRUPTED"))
    }

    func sessionInterruptionEnded(_: ARSession) {
        emit(.resumed)
    }
}
