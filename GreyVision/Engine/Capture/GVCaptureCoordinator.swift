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
    let burnHUD: Bool
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
    /// Set by the workspace before a take begins. The renderer reads this once
    /// at start so a take cannot change its burn-in policy midway through.
    var burnHUD = false

    private var activeAdapter: (any GVRecordingAdapter)?
    private var activePath: GVRecordingPath?
    private var pendingStartPath: GVRecordingPath?
    private var recordingStartTime: Date?
    fileprivate var currentConfiguration: GVRecordingConfiguration?

    // Adapters - created lazily, owned by the transaction
    private lazy var processedFramesAdapter = GVProcessedFramesAdapter()
    private lazy var objectsAdapter = GVObjectsAdapter()

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

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let adapter = try await self.prepareAdapter(for: path, cameraRuntime: cameraRuntime, objectsRuntime: objectsRuntime)
                self.activePath = path
                self.pendingStartPath = nil
                self.recordingStartTime = Date()

                let rawCapture = self.currentConfiguration?.videoCodec.isProResRAW == true
                let started: Bool
                if rawCapture {
                    guard let codec = self.currentConfiguration?.videoCodec.avVideoCodecType else {
                        throw GVRecordingTransactionError.startFailed(path, "PRORES RAW CODEC UNAVAILABLE")
                    }
                    self.activeAdapter = nil
                    started = await cameraRuntime.startNativeRAWRecording(codec: codec)
                } else {
                    self.activeAdapter = adapter
                    started = await adapter.start()
                }
                if !started {
                    throw GVRecordingTransactionError.startFailed(path, "ADAPTER REFUSED START")
                }

                if path == .processedFrames, !rawCapture {
                    guard let codec = self.currentConfiguration?.videoCodec.avVideoCodecType else {
                        throw GVRecordingTransactionError.startFailed(path, "VIDEO CODEC UNAVAILABLE")
                    }
                    cameraRuntime.recordingMailbox.requestStart(
                        codecRawValue: codec.rawValue,
                        fps: self.currentConfiguration?.framesPerSecond ?? 30,
                        burnHUD: self.currentConfiguration?.burnHUD ?? false
                    )
                }

                self.state = .recording(path: path, startedAt: self.recordingStartTime!)
                self.statusMessage = rawCapture
                    ? "REC // SENSOR PRORES RAW"
                    : "REC // \(path == .processedFrames ? "CLEAN RENDER" : "OBJECTS RENDER")"
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
            state = .finalizing(path: path)
            statusMessage = "REC // FINALIZING SENSOR RAW"
            Task { @MainActor [weak self] in
                guard let self else { return }
                let saved = await cameraRuntime.stopNativeRAWRecording()
                if saved {
                    // The sensor writes and saves its own movie, and the runtime
                    // records that take's URL as it lands, so the transaction has an
                    // outcome here and no path of its own. The `/dev/null` this used to
                    // invent travelled to the UI looking like a take that opens.
                    self.markSaved(path: path)
                } else {
                    await self.handleResult(
                        .failure(GVRecordingTransactionError.finalizeFailed(path, "RAW SAVE FAILED")),
                        path: path,
                        cameraRuntime: cameraRuntime
                    )
                }
            }
            return
        }

        // If we're only in pending-start, cancel it.
        if pendingStartPath != nil, activeAdapter == nil {
            cancelPendingStart(path: path, objectsRuntime: objectsRuntime)
            return
        }

        guard let adapter = activeAdapter, isPathLive(path, cameraRuntime: cameraRuntime, objectsRuntime: objectsRuntime) else {
            cleanup()
            return
        }

        if path == .processedFrames {
            let writerWasActive = cameraRuntime.isRecording
            cameraRuntime.recordingMailbox.requestStop()
            guard writerWasActive else {
                cleanup()
                return
            }
            state = .finalizing(path: path)
            statusMessage = "REC // FINALIZING"
            return
        }

        state = .finalizing(path: path)
        statusMessage = "REC // FINALIZING"

        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await adapter.stop()
            await self.handleResult(result, path: path, cameraRuntime: cameraRuntime)
        }
    }

    /// Cancel a pending start that hasn't fully begun.
    private func cancelPendingStart(path: GVRecordingPath, objectsRuntime: ARObjectRuntime) {
        if path == .objects {
            objectsRuntime.cancelRecordingStart()
        }
        // For processed frames, the mailbox handles it via CameraRuntime
        pendingStartPath = nil
        state = .idle
        statusMessage = nil
    }

    /// Prepare the appropriate adapter for the path.
    private func prepareAdapter(
        for path: GVRecordingPath,
        cameraRuntime: CameraRuntime,
        objectsRuntime _: ARObjectRuntime
    ) async throws -> any GVRecordingAdapter {
        let adapter: any GVRecordingAdapter
        let targetSize: CGSize?
        let fps = cameraRuntime.snapshot.framesPerSecond
        let codec = cameraRuntime.snapshot.requestedVideoCodec
        let burnHUD = self.burnHUD

        switch path {
        case .processedFrames:
            adapter = processedFramesAdapter
            // Size will be determined by the renderer on first frame
            targetSize = nil
        case .objects:
            adapter = objectsAdapter
            // AR objects rendering size comes from the surface
            targetSize = nil
        }

        let config = GVRecordingConfiguration(
            path: path,
            videoCodec: codec,
            framesPerSecond: fps,
            targetSize: targetSize,
            saveToPhotos: true,
            burnHUD: burnHUD,
            watermark: burnHUD ? "grey//VISION" : nil
        )
        self.currentConfiguration = config

        let prepared = await adapter.prepare(configuration: config)
        if !prepared {
            throw GVRecordingTransactionError.prepareFailed(path, "ADAPTER PREPARE RETURNED FALSE")
        }
        return adapter
    }

    /// Handle the result of a finished recording.
    private func handleResult(
        _ result: GVRecordingResult,
        path: GVRecordingPath,
        cameraRuntime: CameraRuntime
    ) async {
        switch result {
        case let .success(take):
            // Handing the file on is the point of the result. It used to be dropped
            // here, which left the session holding no address for a movie it had
            // just written — and nothing downstream could open one to look at.
            cameraRuntime.noteCompletedTake(take)
            markSaved(path: path)
        case let .failure(error):
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .failed(path: path, message: message)
            statusMessage = message
        case .cancelled:
            cleanup()
        }
    }

    /// The one saved-state transition. A take that landed in Photos gets the same
    /// notice and retires on the same beat whichever path produced it, because the
    /// sensor path, the adapters, and the renderer's own message all end up here.
    private func markSaved(path: GVRecordingPath) {
        state = .saved(path: path)
        statusMessage = "REC // SAVED TO CAMERA ROLL"
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
    func abort(cameraRuntime: CameraRuntime, objectsRuntime _: ARObjectRuntime) async {
        if currentConfiguration?.videoCodec.isProResRAW == true, cameraRuntime.isRecording {
            _ = await cameraRuntime.stopNativeRAWRecording()
        }
        if let adapter = activeAdapter {
            await adapter.abort()
        }
        // Also abort the camera runtime's writer
        cameraRuntime.recordingMailbox.requestStop()

        cleanup()
    }

    /// One screenshot entry point — CLEAN grabs the render target; HUD grabs the composed screen.
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
                statusMessage = "REC // \(path == .processedFrames ? "CLEAN RENDER" : "OBJECTS RENDER")"
            }
        } else {
            // Renderer has stopped the writer
            if case .recording = state {
                // Don't change state here - the transaction's stop() handles finalization
                // This is just a notification that the writer is no longer active
            }
        }
    }

    /// Called by the renderer when the writer could not start or the export failed.
    func handleRecordingMessage(_ message: String) {
        if message.contains("SAVED") {
            markSaved(path: activePath ?? .processedFrames)
            return
        }
        if message.contains("FAILED") || message.contains("ERROR") || message.contains("UNAVAILABLE") {
            // Extract path from current state
            let path = state.path
            state = .failed(path: path, message: message)
            statusMessage = message
            activeAdapter = nil
            activePath = nil
            pendingStartPath = nil
        }
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

// MARK: - Objects Adapter

@MainActor
final class GVObjectsAdapter: GVRecordingAdapter {
    private var recordingSession: GVRealtimeRecordingSession?
    private var startTime: Date?

    var isRecording: Bool { recordingSession != nil }
    var recordingState: GVAdapterRecordingState {
        if recordingSession == nil { return .idle }
        // The session doesn't expose state directly; infer from existence.
        return .recording(startedAt: startTime ?? Date())
    }

    func prepare(configuration _: GVRecordingConfiguration) async -> Bool {
        // Size comes from the surface at start time
        true
    }

    func start() async -> Bool {
        // Actual start happens when surface calls consumeStartRequest with size
        true
    }

    func stop() async -> GVRecordingResult {
        guard let session = recordingSession else {
            return .failure(GVRecordingTransactionError.finalizeFailed(.objects, "NO SESSION"))
        }
        recordingSession = nil
        return await withCheckedContinuation { continuation in
            session.finish { result in
                switch result {
                case let .success(url):
                    continuation.resume(returning: .success(url))
                case let .failure(error):
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    func abort() async {
        recordingSession?.finish { _ in } // Best effort
        recordingSession = nil
    }

    /// Called by ARObjectRuntime when the surface provides the drawable size.
    func consumeStartRequest(size: CGSize) {
        guard recordingSession == nil, size.width > 0, size.height > 0 else { return }
        let timestamp = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("greyvision-ar-\(timestamp).mp4")
        let session = GVRealtimeRecordingSession(outputURL: url, size: size, saveToPhotos: true)
        guard session.start() else { return }
        recordingSession = session
        startTime = Date()
    }

    /// Called by ARObjectRuntime each frame to append the rendered pixel buffer.
    func appendFrame(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        recordingSession?.append(pixelBuffer, timestamp: timestamp)
    }
}

// MARK: - Screen Capture (stills, not video)

/// Screen capture remains a static utility — it captures the composed window
/// including chrome, which the Metal render path cannot do.
enum GVRecordingTransactionScreenCapture {
    static func save(_ image: UIImage, message: @escaping @Sendable (String) -> Void) {
        guard let png = image.pngData() else {
            message("SCREENSHOT // ENCODE FAILED")
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("greyvision-ui-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
        } catch {
            message("SCREENSHOT // WRITE FAILED")
            return
        }
        requestAddAccess { granted in
            guard granted else {
                try? FileManager.default.removeItem(at: url)
                message("SCREENSHOT // PHOTOS ACCESS DENIED")
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            } completionHandler: { success, error in
                try? FileManager.default.removeItem(at: url)
                if success {
                    message("PHOTO // SAVED TO CAMERA ROLL")
                } else {
                    message("SCREENSHOT // SAVE FAILED")
                    GVLog.recording.error(
                        "UI screenshot save failed: \(error?.localizedDescription ?? "unknown")"
                    )
                }
            }
        }
    }

    private static func requestAddAccess(_ completion: @escaping @Sendable (Bool) -> Void) {
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

// MARK: - Singleton access for renderer callbacks (temporary bridge)

extension GVRecordingTransaction {
    /// Temporary singleton for renderer callbacks until dependency injection is wired.
    weak static var shared: GVRecordingTransaction?
}
