import Foundation
import os.log

@MainActor
protocol CameraSourceAdapter: AnyObject {
    func start(configuration: CaptureConfiguration) async -> Bool
    func stop() async
    func stopSoon()
}

@MainActor
protocol DepthSourceAdapter: AnyObject {
    var isSupported: Bool { get }
    var selectedEffect: DepthEffectMode { get }
    func select(_ effect: DepthEffectMode)
    func start(effect: DepthEffectMode) async -> Bool
    func stop() async
    func stopSoon()
}

@MainActor
protocol ObjectSourceAdapter: AnyObject {
    var isSupported: Bool { get }
    func start() async -> Bool
    func stop() async
    func stopSoon()
}

extension CameraRuntime: CameraSourceAdapter {}

extension DepthRuntime: DepthSourceAdapter {
    var isSupported: Bool { capability.isSupported }
    var selectedEffect: DepthEffectMode { effect }
    func select(_ effect: DepthEffectMode) {
        setEffect(effect)
    }
}

extension ARObjectRuntime: ObjectSourceAdapter {
    var isSupported: Bool { capability.isSupported }
}

/// Owns the mutually-exclusive Camera / LiDAR / Objects transition.
///
/// Stop-before-start ordering, cancellation, and AVFoundation rollback live
/// here rather than in the app owner. The three runtimes are adapters; tests
/// can replace them without constructing camera or ARKit sessions.
///
/// The transition is the single source of truth for the active capture source.
/// AppModel observes `state` and must not maintain its own source-mode state.
@MainActor
final class CaptureSourceTransition {
    /// The authoritative state of the capture source.
    /// AppModel subscribes to `onStateChange` and reflects this state.
    struct State: Equatable, Sendable {
        enum Phase: Equatable, Sendable {
            case offline
            case stoppingPrevious
            case startingTarget
            case rollingBack
            case running
            case failed(TransitionFailure)
        }

        var mode: WorkspaceSourceMode
        var phase: Phase

        static let offline = State(mode: .camera, phase: .offline)

        var isTransitioning: Bool {
            switch phase {
            case .offline, .running, .failed: false
            case .stoppingPrevious, .startingTarget, .rollingBack: true
            }
        }

        /// Maps the internal phase to the app-facing runtime status.
        var runtimeStatus: RuntimeStatus {
            switch phase {
            case .offline: .offline
            // Stop-before-start is part of bringing the target up, not an
            // outage: reporting .offline here flashes the HUD through OFFLINE
            // on every engine start and source change.
            case .stoppingPrevious: .starting
            case .startingTarget, .rollingBack: .starting
            case .running: .running
            case .failed: .failed
            }
        }
    }

    /// Detailed failure information for diagnostics and testing.
    struct TransitionFailure: Equatable, Sendable {
        let failedMode: WorkspaceSourceMode
        let reason: String
        let rollbackAttempted: Bool
        let rollbackSucceeded: Bool
    }

    private let camera: any CameraSourceAdapter
    private let depth: any DepthSourceAdapter
    private let objects: any ObjectSourceAdapter

    /// Serializes transitions: only one transition operation runs at a time.
    private var transitionTask: Task<Void, Never>?
    /// Monotonically increasing generation counter to obsolete in-flight work.
    private var generation: UInt64 = 0
    /// The last known-good camera configuration for rollback.
    private var fallbackConfiguration = CaptureConfiguration.standard

    private(set) var state = State.offline {
        didSet {
            guard state != oldValue else { return }
            GVLog.capture.debug("Transition state: \(String(describing: self.state.phase), privacy: .public) mode: \(self.state.mode.rawValue, privacy: .public)")
            onStateChange?(state)
        }
    }

    var onStateChange: ((State) -> Void)?

    init(
        camera: any CameraSourceAdapter,
        depth: any DepthSourceAdapter,
        objects: any ObjectSourceAdapter
    ) {
        self.camera = camera
        self.depth = depth
        self.objects = objects
    }

    /// Activates the camera source with the given configuration.
    func activateCamera(configuration: CaptureConfiguration) {
        fallbackConfiguration = configuration
        beginTransition(to: .camera) { [camera, depth, objects] in
            await depth.stop()
            await objects.stop()
            return await camera.start(configuration: configuration)
        }
    }

    /// Activates the LiDAR depth source with the given effect.
    func activateDepth(effect: DepthEffectMode, fallback: CaptureConfiguration) {
        // Check support BEFORE any side effects (stop/start)
        guard depth.isSupported else {
            GVLog.capture.warning("LiDAR not supported; remaining on current source")
            return
        }

        // Select effect on the adapter (no I/O, just parameter change)
        depth.select(effect)
        fallbackConfiguration = fallback

        beginTransition(to: .lidar) { [camera, depth, objects] in
            await objects.stop()
            await camera.stop()
            let started = await depth.start(effect: effect)
            if !started {
                GVLog.capture.error("LiDAR start failed; rolling back to camera")
                return await self.rollbackToCamera(after: .lidar)
            }
            return true
        }
    }

    /// Activates the AR Objects world-tracking source.
    func activateObjects(fallback: CaptureConfiguration) {
        // Check support BEFORE any side effects
        guard objects.isSupported else {
            GVLog.capture.warning("AR Objects not supported; remaining on current source")
            return
        }

        fallbackConfiguration = fallback

        beginTransition(to: .objects) { [camera, depth, objects] in
            await depth.stop()
            await camera.stop()
            let started = await objects.start()
            if !started {
                GVLog.capture.error("AR Objects start failed; rolling back to camera")
                return await self.rollbackToCamera(after: .objects)
            }
            return true
        }
    }

    /// Restarts the current active source with a new configuration.
    /// Used for camera position flip, app foregrounding, etc.
    func restart(configuration: CaptureConfiguration) {
        fallbackConfiguration = configuration
        switch state.mode {
        case .camera:
            activateCamera(configuration: configuration)
        case .lidar:
            activateDepth(effect: depth.selectedEffect, fallback: configuration)
        case .objects:
            activateObjects(fallback: configuration)
        }
    }

    /// Stops all sources and resets to camera/offline.
    func stopSoon() {
        stopAll(preservingMode: false)
    }

    /// Suspends all sources but remembers the mode for quick resume.
    func suspendSoon() {
        stopAll(preservingMode: true)
    }

    /// Cancels any in-flight transition and stops all sources.
    private func stopAll(preservingMode: Bool) {
        let suspendedMode = state.mode
        generation &+= 1
        let stopGeneration = generation
        transitionTask?.cancel()
        transitionTask = nil

        // The adapters are main-actor bound. Stop them in sequence rather than
        // escaping their isolation through async-let child tasks.
        Task { [weak self] in
            guard let self else { return }
            await camera.stop()
            await depth.stop()
            await objects.stop()
            guard !Task.isCancelled, stopGeneration == generation else { return }
            state = State(
                mode: preservingMode ? suspendedMode : .camera,
                phase: .offline
            )
        }
    }

    /// Core transition orchestration: stop previous, start target, handle rollback.
    private func beginTransition(
        to targetMode: WorkspaceSourceMode,
        operation: @escaping @MainActor () async -> Bool
    ) {
        generation &+= 1
        let operationGeneration = generation
        let previousTask = transitionTask
        previousTask?.cancel()

        state = State(mode: targetMode, phase: .stoppingPrevious)

        transitionTask = Task { [weak self] in
            // Wait for previous transition to fully stop
            await previousTask?.value

            guard let self, !Task.isCancelled, operationGeneration == generation else { return }

            state = State(mode: targetMode, phase: .startingTarget)
            let success = await operation()

            guard !Task.isCancelled, operationGeneration == generation else { return }

            // Only update if we're still the active transition for this mode
            if self.state.mode == targetMode {
                self.state = State(
                    mode: targetMode,
                    phase: success ? .running : .failed(TransitionFailure(
                        failedMode: targetMode,
                        reason: "Start returned false",
                        rollbackAttempted: false,
                        rollbackSucceeded: false
                    ))
                )
            }
        }
    }

    /// Rolls back to the camera source after a failed activation.
    /// This is the critical failure path that must be bulletproof.
    private func rollbackToCamera(after failedMode: WorkspaceSourceMode) async -> Bool {
        guard !Task.isCancelled else {
            GVLog.capture.notice("Rollback cancelled before start")
            return false
        }

        state = State(mode: .camera, phase: .rollingBack)

        let restored = await camera.start(configuration: fallbackConfiguration)

        guard !Task.isCancelled else {
            GVLog.capture.notice("Rollback cancelled after camera start")
            return false
        }

        let failure = TransitionFailure(
            failedMode: failedMode,
            reason: "Activation failed, rolled back to camera",
            rollbackAttempted: true,
            rollbackSucceeded: restored
        )

        state = State(
            mode: .camera,
            phase: restored ? .running : .failed(failure)
        )

        if !restored {
            GVLog.capture.fault("AVFoundation rollback FAILED after \(failedMode.rawValue, privacy: .public) — NO ACTIVE SOURCE")
        } else {
            GVLog.capture.notice("Rollback to camera succeeded after \(failedMode.rawValue, privacy: .public)")
        }

        return restored
    }
}
