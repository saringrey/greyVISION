import Combine
import Foundation
import Photos
import UIKit

/// The recording path determines which pixel pipeline receives the take.
enum GVRecordingPath: String, Sendable {
    case processedFrames
    case objects
}

/// Unified recording state visible to the operator and tests.
enum GVRecordingTransactionState: Equatable, Sendable {
    case idle
    case preparing(path: GVRecordingPath)
    case recording(path: GVRecordingPath, startedAt: Date)
    case finalizing(path: GVRecordingPath)
    case failed(path: GVRecordingPath?, message: String)
    case saved(path: GVRecordingPath)

    var isActive: Bool {
        if case .recording = self { return true }
        if case .preparing = self { return true }
        if case .finalizing = self { return true }
        return false
    }

    var path: GVRecordingPath? {
        switch self {
        case .idle: return nil
        case let .preparing(path): return path
        case let .recording(path, _): return path
        case let .finalizing(path): return path
        case let .failed(path, _): return path
        case let .saved(path): return path
        }
    }
}

/// Adapter protocol — each pixel pipeline implements this.
/// The transaction owns lifecycle; adapters only produce pixels and finish files.
@MainActor
protocol GVRecordingAdapter: AnyObject {
    var isRecording: Bool { get }
    var recordingState: GVAdapterRecordingState { get }
    func prepare(configuration: GVRecordingConfiguration) async -> Bool
    func start() async -> Bool
    func stop() async -> GVRecordingResult
    func abort() async
}

/// Configuration passed to adapters at prepare time.
struct GVRecordingConfiguration: Sendable {
    let path: GVRecordingPath
    let videoCodec: CaptureSetupDraft.VideoCodec
    let framesPerSecond: Int
    let targetSize: CGSize?
    let saveToPhotos: Bool
    let watermark: String?
}

/// Result of a finished recording. `success` carries the movie file, which is the
/// only handle anything downstream has on the take it just watched being written.
enum GVRecordingResult: Sendable {
    case success(URL)
    case failure(Error)
    case cancelled
}

/// Common recording state surfaced by adapters.
enum GVAdapterRecordingState: Equatable, Sendable {
    case idle
    case preparing
    case recording(startedAt: Date)
    case finalizing
    case failed(String)
    case saved

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

/// Errors that can occur during the recording transaction.
enum GVRecordingTransactionError: LocalizedError, Sendable {
    case adapterUnavailable(GVRecordingPath)
    case prepareFailed(GVRecordingPath, String)
    case startFailed(GVRecordingPath, String)
    case finalizeFailed(GVRecordingPath, String)
    case photosAccessDenied
    case interrupted(String)

    var errorDescription: String? {
        switch self {
        case let .adapterUnavailable(path):
            return "RECORDING // \(path.rawValue.uppercased()) ADAPTER UNAVAILABLE"
        case let .prepareFailed(path, msg):
            return "RECORDING // \(path.rawValue.uppercased()) PREPARE FAILED \(msg)"
        case let .startFailed(path, msg):
            return "RECORDING // \(path.rawValue.uppercased()) START FAILED \(msg)"
        case let .finalizeFailed(path, msg):
            return "RECORDING // \(path.rawValue.uppercased()) FINALIZE FAILED \(msg)"
        case .photosAccessDenied:
            return "RECORDING // PHOTOS ACCESS DENIED"
        case let .interrupted(reason):
            return "RECORDING // INTERRUPTED \(reason)"
        }
    }
}

/// The single operator-visible recording transaction.
///
/// Owns the complete lifecycle: prepare → start → record → finalize → save.
/// Adapters (processed frames, AR objects) are rendering delegates only.
/// This module decides source choice, start/stop intent, pending-start truth,
/// operator notices, finalization policy, and save behavior.
@MainActor
final class GVRecordingTransaction: ObservableObject {
    @Published private(set) var state: GVRecordingTransactionState = .idle
    @Published var statusMessage: String?

    private var activeAdapter: (any GVRecordingAdapter)?
    private var activePath: GVRecordingPath?
    private var pendingStartPath: GVRecordingPath?
    private var recordingStartTime: Date?
    private var startTask: Task<Void, Never>?
    fileprivate var currentConfiguration: GVRecordingConfiguration?

    // Adapters - created lazily, owned by the transaction
    private lazy var processedFramesAdapter = GVProcessedFramesAdapter()

    /// Current recording path based on source mode.
    private func recordingPath(for sourceMode: WorkspaceSourceMode) -> GVRecordingPath {
        sourceMode == .objects ? .objects : .processedFrames
    }

    /// Whether a take is currently live (recording or pending start).
    func isTakeLive(
        cameraRuntime: CameraRuntime,
        objectsRuntime: ARObjectRuntime,
        sourceMode: WorkspaceSourceMode
    ) -> Bool {
        let path = activePath ?? pendingStartPath ?? recordingPath(for: sourceMode)
        return isPathLive(path, cameraRuntime: cameraRuntime, objectsRuntime: objectsRuntime)
    }

    /// Check if a specific path is live.
    private func isPathLive(
        _ path: GVRecordingPath,
        cameraRuntime: CameraRuntime,
        objectsRuntime: ARObjectRuntime
    ) -> Bool {
        switch path {
        case .processedFrames:
            return cameraRuntime.isRecording || cameraRuntime.recordingMailbox.isStartPending
        case .objects:
            return objectsRuntime.isRecording || objectsRuntime.startRequested
        }
    }

    /// Toggle recording — the single operator entry point.
    func toggleRecording(
        cameraRuntime: CameraRuntime,
        objectsRuntime: ARObjectRuntime,
        sourceMode: WorkspaceSourceMode
    ) {
        if isTakeLive(
            cameraRuntime: cameraRuntime,
            objectsRuntime: objectsRuntime,
            sourceMode: sourceMode
        ) {
            stop(cameraRuntime: cameraRuntime, objectsRuntime: objectsRuntime, sourceMode: sourceMode)
        } else {
            start(cameraRuntime: cameraRuntime, objectsRuntime: objectsRuntime, sourceMode: sourceMode)
        }
    }

    /// Start a recording take.
    func start(
        cameraRuntime: CameraRuntime,
        objectsRuntime: ARObjectRuntime,
        sourceMode: WorkspaceSourceMode
    ) {
        // Already recording? Surface notice and return.
        if isTakeLive(
            cameraRuntime: cameraRuntime,
            objectsRuntime: objectsRuntime,
            sourceMode: sourceMode
        ) {
            statusMessage = "CAPTURE // ALREADY RECORDING"
            return
        }

        let path = recordingPath(for: sourceMode)
        pendingStartPath = path
        state = .preparing(path: path)
        statusMessage = "REC // PREPARING \(path.rawValue.uppercased())"

        let configuration = GVRecordingConfiguration(
            path: path,
            videoCodec: cameraRuntime.snapshot.requestedVideoCodec,
            framesPerSecond: cameraRuntime.snapshot.framesPerSecond,
            targetSize: nil,
            // The take library is written first and Photos is attempted after,
            // so a refusal cannot destroy footage.
            saveToPhotos: true,
            // Every take carries the HUD. There is no clean-record option.
            watermark: "grey//VISION"
        )
        currentConfiguration = configuration
        let rawCapture = configuration.videoCodec.isProResRAW

        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let started: Bool
                if rawCapture {
                    guard let codec = configuration.videoCodec.avVideoCodecType else {
                        throw GVRecordingTransactionError.startFailed(path, "PRORES RAW CODEC UNAVAILABLE")
                    }
                    self.activeAdapter = nil
                    started = await cameraRuntime.startNativeRAWRecording(codec: codec)
                } else if path == .objects {
                    // The objects runtime owns its own writer; the AR surface
                    // vends the drawable size on its next update. A second,
                    // disconnected session here would have recorded nothing.
                    self.activeAdapter = nil
                    started = objectsRuntime.requestStartRecording()
                } else {
                    let adapter = self.processedFramesAdapter
                    guard await adapter.prepare(configuration: configuration) else {
                        throw GVRecordingTransactionError.prepareFailed(path, "ADAPTER PREPARE RETURNED FALSE")
                    }
                    self.activeAdapter = adapter
                    started = await adapter.start()
                }

                // Stop may have landed while this was awaiting. Releasing
                // whatever just came up and abandoning the start is the only
                // safe answer: continuing would arm a writer the operator has
                // already asked to stop, and the button would read idle over a
                // recording take.
                if Task.isCancelled {
                    switch path {
                    case .objects:
                        if started { objectsRuntime.cancelRecordingStart() }
                    case .processedFrames:
                        if started, !rawCapture { cameraRuntime.recordingMailbox.requestStop() }
                        else if started { _ = await cameraRuntime.stopNativeRAWRecording() }
                    }
                    return
                }

                guard started else {
                    throw GVRecordingTransactionError.startFailed(path, "ADAPTER REFUSED START")
                }

                self.activePath = path
                self.pendingStartPath = nil
                self.recordingStartTime = Date()

                if path == .processedFrames, !rawCapture {
                    guard let codec = configuration.videoCodec.avVideoCodecType else {
                        throw GVRecordingTransactionError.startFailed(path, "VIDEO CODEC UNAVAILABLE")
                    }
                    cameraRuntime.recordingMailbox.requestStart(
                        codecRawValue: codec.rawValue,
                        fps: configuration.framesPerSecond
                    )
                }

                self.state = .recording(path: path, startedAt: self.recordingStartTime!)
                self.statusMessage = rawCapture
                    ? "REC // SENSOR PRORES RAW"
                    : "REC // \(path == .processedFrames ? "EFFECTS + HUD" : "AR OBJECTS + HUD")"
            } catch {
                self.handleError(error, path: path)
            }
        }
    }

    /// Stop the current recording take.
    func stop(
        cameraRuntime: CameraRuntime,
        objectsRuntime: ARObjectRuntime,
        sourceMode: WorkspaceSourceMode
    ) {
        let path = activePath ?? pendingStartPath ?? recordingPath(for: sourceMode)

        if currentConfiguration?.videoCodec.isProResRAW == true {
            startTask?.cancel()
            startTask = nil
            state = .finalizing(path: path)
            statusMessage = "REC // FINALIZING SENSOR RAW"
            Task { @MainActor [weak self] in
                guard let self else { return }
                let filed = await cameraRuntime.stopNativeRAWRecording()
                // The runtime files the take and reports the outcome through
                // `handleTakeResult`; only reach in when that never arrived.
                if !filed, case .finalizing = self.state {
                    self.state = .failed(path: path, message: "RECORDING // RAW TAKE NOT FILED")
                    self.statusMessage = "RECORDING // RAW TAKE NOT FILED"
                }
            }
            return
        }

        // If we're only in pending-start, cancel it.
        if pendingStartPath != nil, activeAdapter == nil, !objectsRuntime.isRecording {
            cancelPendingStart(path: path, cameraRuntime: cameraRuntime, objectsRuntime: objectsRuntime)
            return
        }

        guard isPathLive(path, cameraRuntime: cameraRuntime, objectsRuntime: objectsRuntime) else {
            cleanup()
            return
        }

        switch path {
        case .processedFrames:
            let writerWasActive = cameraRuntime.isRecording
            cameraRuntime.recordingMailbox.requestStop()
            guard writerWasActive else {
                cleanup()
                return
            }
            state = .finalizing(path: path)
            statusMessage = "REC // FINALIZING"
        case .objects:
            // A request the AR surface never consumed must be withdrawn, or the
            // next frame after "stop" starts recording anyway.
            objectsRuntime.cancelRecordingStart()
            guard objectsRuntime.isRecording else {
                cleanup()
                return
            }
            state = .finalizing(path: path)
            statusMessage = "REC // FINALIZING"
            // The runtime finalizes and files the movie; the outcome comes back
            // through handleTakeResult rather than an adapter that never owned
            // the session.
            objectsRuntime.stopRecording()
        }
    }

    /// Cancel a pending start that hasn't fully begun.
    private func cancelPendingStart(
        path: GVRecordingPath,
        cameraRuntime: CameraRuntime,
        objectsRuntime: ARObjectRuntime
    ) {
        startTask?.cancel()
        startTask = nil
        switch path {
        case .objects:
            objectsRuntime.cancelRecordingStart()
        case .processedFrames:
            cameraRuntime.recordingMailbox.requestStop()
        }
        activeAdapter = nil
        pendingStartPath = nil
        state = .idle
        statusMessage = nil
    }

    /// Install the transaction as the listener for finished takes. Both writers
    /// file their movie in the take library before Photos is attempted, and the
    /// verdict has to reach the operator-visible state from there rather than
    /// through a message string: two identical outcomes in a row are not a
    /// change, and the second take would look like it never happened.
    func bindTakeOutcomes(cameraRuntime: CameraRuntime, objectsRuntime: ARObjectRuntime) {
        cameraRuntime.takeOutcomeHandler = { [weak self] result in
            self?.handleTakeResult(result)
        }
        objectsRuntime.takeOutcomeHandler = { [weak self] result in
            self?.handleTakeResult(result)
        }
    }

    /// Handle the outcome of a filed take.
    func handleTakeResult(_ result: Result<GVTake, any Error>) {
        switch result {
        case let .success(take):
            let path: GVRecordingPath = take.source == .objects ? .objects : .processedFrames
            state = .saved(path: path)
            statusMessage = take.photosStatus == .saved
                ? "REC // SAVED TO PHOTOS"
                : "REC // KEPT IN LIBRARY · PHOTOS NOT SAVED"
            scheduleSavedCleanup()
        case let .failure(error):
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .failed(path: state.path, message: message)
            statusMessage = message
            activeAdapter = nil
            activePath = nil
            pendingStartPath = nil
        }
    }

    private func scheduleSavedCleanup() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, case .saved = self.state else { return }
            self.cleanup()
        }
    }

    /// Centralized error handling.
    private func handleError(_ error: Error, path: GVRecordingPath) {
        let message: String
        if let txError = error as? GVRecordingTransactionError {
            message = txError.errorDescription ?? "RECORDING // UNKNOWN ERROR"
        } else {
            message = "RECORDING // \(error.localizedDescription.uppercased())"
        }
        state = .failed(path: path, message: message)
        statusMessage = message
        activeAdapter = nil
        activePath = nil
        pendingStartPath = nil
    }

    /// Clean up after a completed or cancelled take.
    private func cleanup() {
        activeAdapter = nil
        activePath = nil
        pendingStartPath = nil
        recordingStartTime = nil
        currentConfiguration = nil
        state = .idle
        statusMessage = nil
    }

    /// Abort any in-progress recording immediately (used on app background/interruption).
    func abort(cameraRuntime: CameraRuntime, objectsRuntime: ARObjectRuntime) async {
        startTask?.cancel()
        startTask = nil
        if currentConfiguration?.videoCodec.isProResRAW == true, cameraRuntime.isRecording {
            _ = await cameraRuntime.stopNativeRAWRecording()
        }
        if let adapter = activeAdapter {
            await adapter.abort()
        }
        // Also abort the camera runtime's writer
        cameraRuntime.recordingMailbox.requestStop()
        // An objects take has its writer inside the AR runtime; leaving it armed
        // means the surface starts recording again on the next frame.
        objectsRuntime.cancelRecordingStart()

        cleanup()
    }

    /// One capture entry point: saves a photograph of the effect stack at sensor
    /// resolution.
    ///
    /// This used to snapshot the window, which produced a screen-sized image of
    /// the instrument rather than a picture of it. The window-snapshot path was
    /// removed with its caller rather than left behind unreferenced.
    func takeScreenshot(cameraRuntime: CameraRuntime) {
        cameraRuntime.takeScreenshot()
    }

    /// Request Photos access proactively so the first save doesn't block.
    func ensurePhotosAccess() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { granted in
                    continuation.resume(returning: granted == .authorized || granted == .limited)
                }
            }
        default:
            return false
        }
    }

    /// Current recording duration if active.
    var recordingDuration: TimeInterval? {
        guard case let .recording(_, startedAt) = state else { return nil }
        return Date().timeIntervalSince(startedAt)
    }

    /// Recording start time for HUD/timecode display.
    var recordingStartedAt: Date? {
        guard case let .recording(_, startedAt) = state else { return nil }
        return startedAt
    }

    /// Called by the renderer when the writer actually comes online / finishes.
    func handleRecordingStateChange(_ active: Bool) {
        if active {
            // Renderer has started the writer - update state if we're in preparing
            if case let .preparing(path) = state {
                state = .recording(path: path, startedAt: Date())
                statusMessage = "REC // \(path == .processedFrames ? "EFFECTS + HUD" : "AR OBJECTS + HUD")"
            }
        } else {
            // Renderer has stopped the writer
            if case .recording = state {
                // Don't change state here - the transaction's stop() handles finalization
                // This is just a notification that the writer is no longer active
            }
        }
    }

    /// Called by the renderer when the writer could not start or finalize. A
    /// take that *did* finish reports through `handleTakeResult`, which carries
    /// whether Photos accepted it; nothing arriving here may be read as a save,
    /// because "SAVED TO CAMERA ROLL" over a movie nobody filed is worse than
    /// silence.
    func handleRecordingMessage(_ message: String) {
        guard message.contains("FAILED") || message.contains("ERROR") || message.contains("UNAVAILABLE") else { return }
        let path = state.path
        state = .failed(path: path, message: message)
        statusMessage = message
        activeAdapter = nil
        activePath = nil
        pendingStartPath = nil
    }

    /// Called by the renderer when a screenshot is saved or failed.
    func handleScreenshotMessage(_ message: String) {
        statusMessage = message
    }
}

// MARK: - Processed Frames Adapter

@MainActor
final class GVProcessedFramesAdapter: GVRecordingAdapter {
    private let recorder = GVVideoRecorder()
    private var pendingSize: CGSize?

    var isRecording: Bool { recorder.isRecording }
    var recordingState: GVAdapterRecordingState {
        switch recorder.stateMailbox.latest {
        case .idle: return .idle
        case let .recording(startedAt): return .recording(startedAt: Date(timeIntervalSinceReferenceDate: startedAt))
        case .finishing: return .finalizing
        case let .failed(msg): return .failed(msg)
        }
    }

    func prepare(configuration _: GVRecordingConfiguration) async -> Bool {
        // Size is determined at render time; we just stash config.
        true
    }

    func start() async -> Bool {
        // The actual writer starts when the renderer calls setRecordingActive
        // and provides the real effect size via recordingMailbox.
        true
    }

    func stop() async -> GVRecordingResult {
        await withCheckedContinuation { continuation in
            // `saved` means the movie reached Photos, and `outputURL` still names the
            // file it was written from — the recorder holds the path across the stop
            // for exactly this read.
            recorder.finish { saved in
                if saved, let url = self.recorder.outputURL {
                    continuation.resume(returning: .success(url))
                } else {
                    let message = self.recorder.stateMailbox.latest
                    continuation.resume(returning: .failure(GVRecordingTransactionError.finalizeFailed(.processedFrames, "\(message)")))
                }
            }
        }
    }

    func abort() async {
        recorder.abort()
    }

    /// Called by the renderer when it knows the actual render size.
    func configureWriter(device: MTLDevice, width: Int, height: Int) -> Bool {
        guard let config = GVRecordingTransaction.shared?.currentConfiguration else { return false }
        return recorder.start(
            device: device,
            width: width,
            height: height,
            framesPerSecond: config.framesPerSecond,
            codec: config.videoCodec
        )
    }

    /// Called by the renderer to get a pixel buffer + texture for this frame.
    func nextTexture() -> (CVPixelBuffer, MTLTexture)? {
        recorder.nextTexture()
    }

    /// Called by the renderer to append a completed frame.
    func appendFrame(_ pixelBuffer: CVPixelBuffer) {
        recorder.append(pixelBuffer)
    }

    /// Notify adapter that recording is now active (renderer has configured writer).
    func setRecordingActive(_: Bool) {}
}

// Global reference for renderer callbacks - will be replaced by dependency injection
extension GVProcessedFramesAdapter {
    weak static var shared: GVProcessedFramesAdapter?
}

// MARK: - Screen Capture (stills, not video)

// MARK: - Singleton access for renderer callbacks (temporary bridge)

extension GVRecordingTransaction {
    /// Temporary singleton for renderer callbacks until dependency injection is wired.
    weak static var shared: GVRecordingTransaction?
}
