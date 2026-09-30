import Combine
import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var route: AppRoute
    @Published private(set) var runtimeStatus: RuntimeStatus = .offline
    @Published var setup = CaptureSetupDraft()
    @Published private(set) var sourceMode = WorkspaceSourceMode.camera
    /// Non-nil while the workspace is still settling from the splash raster
    /// tear. Purely presentational; it never gates the capture session.
    @Published private(set) var entrySettleStart: Date?
    /// Whether something the operator built would actually be lost if the
    /// display went to sleep: a live recording, a broadcast to the Mac, or at
    /// least one armed effect.
    ///
    /// This is the single input to the idle-timer policy. The workspace owns
    /// the composition and the recording transaction, so it is the only place
    /// that can answer the question; everything above it just reads the answer.
    @Published private(set) var isTakeAtRisk = false

    /// Called by the workspace whenever the armed set or a take changes.
    func updateTakeRisk(isRecording: Bool, isBroadcasting: Bool, armedEffectCount: Int) {
        isTakeAtRisk = isRecording || isBroadcasting || armedEffectCount > 0
    }

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
    let preferences: GVPreferences
    let isUITesting: Bool
    private let sourceTransition: CaptureSourceTransition

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        bootTelemetry: BootTelemetry? = nil,
        preferences: GVPreferences? = nil
    ) {
        let camera = CameraRuntime()
        let depth = DepthRuntime()
        let objects = ARObjectRuntime()
        self.camera = camera
        self.depth = depth
        self.objects = objects
        sourceTransition = CaptureSourceTransition(
            camera: camera,
            depth: depth,
            objects: objects
        )
        audio = AudioReactiveRuntime()
        blobs = BlobTrackingRuntime()
        self.preferences = preferences ?? GVPreferences()
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

        sourceTransition.onStateChange = { [weak self] state in
            self?.sourceMode = state.mode
            self?.runtimeStatus = state.runtimeStatus
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
        sourceTransition.stopSoon()
        blobs.stop(using: camera)
        audio.stop()
        broadcast.stop()
        sourceMode = .camera
        runtimeStatus = .offline
        entrySettleStart = nil
        route = .boot
    }

    func restartEngine() {
        guard route == .workspace else { return }
        sourceTransition.restart(configuration: CaptureConfiguration(draft: setup))
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

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if route == .workspace, runtimeStatus == .offline || runtimeStatus == .queued {
                sourceTransition.restart(configuration: CaptureConfiguration(draft: setup))
            } else {
                updateCaptureRotation()
            }
        case .inactive:
            suspendWorkspace(stopBroadcast: false)
        case .background:
            suspendWorkspace(stopBroadcast: true)
        @unknown default:
            break
        }
    }

    func updateCaptureRotation(interfaceOrientation: UIInterfaceOrientation? = nil) {
        camera.refreshVideoRotation(interfaceOrientation)
        depth.refreshOrientation(interfaceOrientation)
        objects.refreshOrientation(interfaceOrientation)
    }

    func stopAll() {
        sourceTransition.stopSoon()
        blobs.stop(using: camera)
        audio.stop()
        broadcast.stop()
        sourceMode = .camera
        runtimeStatus = .offline
    }

    func setRuntimeStatus(_ status: RuntimeStatus) {
        runtimeStatus = status
    }

    private func suspendWorkspace(stopBroadcast: Bool) {
        // Release the audio hardware regardless of route: the boot screen uses
        // sound too, and holding it while inactive ducks other apps.
        GVSoundEngine.shared.shutdown()
        guard route == .workspace else { return }
        sourceTransition.suspendSoon()
        blobs.stop(using: camera)
        audio.stop()
        if stopBroadcast { broadcast.stop() }
        runtimeStatus = .offline
    }

    private func beginEngineStart() {
        let configuration = CaptureConfiguration(draft: setup)
        sourceTransition.activateCamera(configuration: configuration)
    }

    private func beginDepthStart(effect: DepthEffectMode) {
        let fallbackConfiguration = CaptureConfiguration(draft: setup)
        sourceTransition.activateDepth(effect: effect, fallback: fallbackConfiguration)
    }

    private func beginObjectsStart() {
        let fallbackConfiguration = CaptureConfiguration(draft: setup)
        sourceTransition.activateObjects(fallback: fallbackConfiguration)
    }
}

enum WorkspaceSourceMode: String, Sendable {
    case camera
    case lidar
    case objects
}
