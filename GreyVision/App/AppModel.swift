import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var route: AppRoute
    @Published private(set) var runtimeStatus: RuntimeStatus = .offline
    @Published var setup = CaptureSetupDraft()
    @Published private(set) var sourceMode = WorkspaceSourceMode.camera
    /// Non-nil while the workspace is still settling from the splash raster
    /// tear. Purely presentational; it never gates the capture session.
    @Published private(set) var entrySettleStart: Date?

    let bootTelemetry: BootTelemetry
    let camera: CameraRuntime
    let depth: DepthRuntime
    let objects: ARObjectRuntime
    let audio: AudioReactiveRuntime
    let blobs: BlobTrackingRuntime
    /// Live link that publishes the processed frame to the Mac virtual
    /// camera. Owned here so it outlives any one view and can keep streaming
    /// while the operator moves around the workspace.
    let broadcast = GVBroadcastRuntime()
    let preferences = GVPreferences()
    let isUITesting: Bool
    private var engineTask: Task<Void, Never>?

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        bootTelemetry: BootTelemetry? = nil
    ) {
        camera = CameraRuntime()
        depth = DepthRuntime()
        objects = ARObjectRuntime()
        audio = AudioReactiveRuntime()
        blobs = BlobTrackingRuntime()
        isUITesting = arguments.contains("--uitesting")
        self.bootTelemetry = bootTelemetry ?? .collect()

        if arguments.contains("--uitesting-workspace") || arguments.contains("--skip-boot") {
            route = .workspace
            runtimeStatus = .queued
        } else if isUITesting {
            // The gate is an entry ceremony, not a thing under test. `--uitesting`
            // lands on the boot screen so the format-dock suite can drive it;
            // without this it sat on the keypad and every assertion timed out.
            route = .boot
        } else {
            route = .gate
        }
    }

    /// Correct code entered. The only way out of `.gate`.
    ///
    /// With the startup ceremony enabled this hands over to the boot sequence;
    /// with it disabled the operator lands straight in the workspace — the
    /// camera pipeline starts through exactly the same path `startEngine`
    /// uses, so there is still one capture session.
    func unlockAccess() {
        guard route == .gate else { return }
        if preferences.startupAnimationEnabled {
            route = .boot
        } else {
            sourceMode = .camera
            runtimeStatus = .queued
            entrySettleStart = nil
            route = .workspace
            beginEngineStart()
        }
    }

    func startEngine() {
        guard route == .boot else { return }
        sourceMode = .camera
        runtimeStatus = .queued
        entrySettleStart = isUITesting ? nil : Date()
        route = .workspace
        beginEngineStart()
    }

    func finishEntrySettle() {
        entrySettleStart = nil
    }

    func returnToBoot() {
        engineTask?.cancel()
        engineTask = nil
        camera.stopSoon()
        depth.stopSoon()
        objects.stopSoon()
        blobs.stop(using: camera)
        audio.stop()
        sourceMode = .camera
        runtimeStatus = .offline
        entrySettleStart = nil
        route = .boot
    }

    func restartEngine() {
        guard route == .workspace else { return }
        if sourceMode == .lidar {
            beginDepthStart(effect: depth.effect)
        } else if sourceMode == .objects {
            beginObjectsStart()
        } else {
            beginEngineStart()
        }
    }

    func switchCameraPosition() {
        guard route == .workspace else { return }
        setup.cameraPosition = setup.cameraPosition == .rear ? .front : .rear
        beginEngineStart()
    }

    func activateDepthEffect(_ effect: DepthEffectMode) {
        guard route == .workspace else { return }
        if sourceMode == .lidar, depth.isActive {
            depth.setEffect(effect)
            return
        }
        beginDepthStart(effect: effect)
    }

    func deactivateDepthMode() {
        guard route == .workspace, sourceMode == .lidar else { return }
        beginEngineStart()
    }

    func activateObjectMode() {
        guard route == .workspace else { return }
        guard objects.capability.isSupported else {
            Task { @MainActor [objects] in
                _ = await objects.start()
            }
            return
        }
        if sourceMode == .objects, objects.isActive {
            return
        }
        beginObjectsStart()
    }

    func deactivateObjectMode() {
        guard route == .workspace, sourceMode == .objects else { return }
        beginEngineStart()
    }

    func cycleLens() {
        guard route == .workspace else { return }
        engineTask?.cancel()
        runtimeStatus = .starting
        engineTask = Task { [weak self] in
            guard let self else { return }
            let running = await camera.cycleLens()
            guard !Task.isCancelled else { return }
            runtimeStatus = running ? .running : .failed
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if route == .workspace, runtimeStatus == .offline || runtimeStatus == .queued {
                if sourceMode == .lidar {
                    beginDepthStart(effect: depth.effect)
                } else {
                    beginEngineStart()
                }
            } else {
                updateCaptureRotation()
            }
        case .inactive, .background:
            // Release the audio hardware regardless of route — the boot screen
            // uses sound too, and holding an active session while backgrounded
            // is exactly what makes other apps' audio duck for no reason.
            GVSoundEngine.shared.shutdown()
            guard route == .workspace else { return }
            engineTask?.cancel()
            engineTask = nil
            camera.stopSoon()
            depth.stopSoon()
            objects.stopSoon()
            blobs.stop(using: camera)
            audio.stop()
            runtimeStatus = .offline
        @unknown default:
            break
        }
    }

    func updateCaptureRotation() {
        camera.refreshVideoRotation()
        depth.refreshOrientation()
        objects.refreshOrientation()
    }

    func stopAll() {
        engineTask?.cancel()
        engineTask = nil
        camera.stopSoon()
        depth.stopSoon()
        objects.stopSoon()
        blobs.stop(using: camera)
        audio.stop()
        sourceMode = .camera
        runtimeStatus = .offline
    }

    func setRuntimeStatus(_ status: RuntimeStatus) {
        runtimeStatus = status
    }

    private func beginEngineStart() {
        engineTask?.cancel()
        let configuration = CaptureConfiguration(draft: setup)
        sourceMode = .camera
        runtimeStatus = .starting
        engineTask = Task { [weak self] in
            guard let self else { return }
            await depth.stop()
            let running = await camera.start(configuration: configuration)
            guard !Task.isCancelled else { return }
            runtimeStatus = running ? .running : .failed
        }
    }

    private func beginDepthStart(effect: DepthEffectMode) {
        guard depth.capability.isSupported else {
            depth.setEffect(effect)
            return
        }
        engineTask?.cancel()
        let fallbackConfiguration = CaptureConfiguration(draft: setup)
        sourceMode = .lidar
        runtimeStatus = .starting
        engineTask = Task { [weak self] in
            guard let self else { return }
            await camera.stop()
            let running = await depth.start(effect: effect)
            guard !Task.isCancelled else { return }
            if running {
                runtimeStatus = .running
                return
            }

            GVLog.capture.error("LiDAR start failed; restoring AVFoundation source")
            sourceMode = .camera
            let fallbackRunning = await camera.start(configuration: fallbackConfiguration)
            guard !Task.isCancelled else { return }
            runtimeStatus = fallbackRunning ? .running : .failed
        }
    }

    private func beginObjectsStart() {
        guard objects.capability.isSupported else {
            Task { @MainActor [objects] in
                _ = await objects.start()
            }
            return
        }
        engineTask?.cancel()
        let fallbackConfiguration = CaptureConfiguration(draft: setup)
        sourceMode = .objects
        runtimeStatus = .starting
        engineTask = Task { [weak self] in
            guard let self else { return }
            await camera.stop()
            let running = await objects.start()
            guard !Task.isCancelled else { return }
            if running {
                runtimeStatus = .running
                return
            }

            GVLog.capture.error("AR objects start failed; restoring AVFoundation source")
            sourceMode = .camera
            let fallbackRunning = await camera.start(configuration: fallbackConfiguration)
            guard !Task.isCancelled else { return }
            runtimeStatus = fallbackRunning ? .running : .failed
        }
    }
}

enum WorkspaceSourceMode: String, Sendable {
    case camera
    case lidar
    case objects
}
