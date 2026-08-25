import Combine
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Gesture State Models

enum FractureMode: Equatable {
    case inactive
    case recognizing
    case fracturing(scale: CGFloat)
    case fullyFractured(scale: CGFloat)
    case returning
}

enum TimeScrubMode: Equatable {
    case inactive
    case waiting(duration: TimeInterval)
    case active(seekTime: TimeInterval, playbackRate: Double)
    case ended
}

enum DamageMode: Equatable {
    case inactive
    case active(intensity: CGFloat)
    case fadingOut(intensity: CGFloat)
}

// MARK: - Camera Viewport State

struct CameraViewportState: Equatable {
    var isActive: Bool = false
    var cornerBrackets: CornerBracketConfig = .default
    var telemetry: CameraTelemetryData = .default
    var accessibility: AccessibilitySettings = .default
}

struct CornerBracketConfig: Equatable {
    var color: Color = .white
    var thickness: CGFloat = 2.0
    var length: CGFloat = 20.0
    var offset: CGFloat = 8.0
    var opacity: CGFloat = 1.0

    static let `default` = CornerBracketConfig()
}

struct CameraTelemetryData: Equatable {
    var isRecording: Bool = false
    var resolution: CGSize = .zero
    var frameRate: Double = 0.0
    var zoomLevel: CGFloat = 1.0
    var exposureCompensation: CGFloat = 0.0
    var iso: Double = 0.0
    var shutterSpeed: Double = 0.0
    var lensPosition: CGFloat = 0.0

    static let `default` = CameraTelemetryData()
}

struct SystemTelemetryData: Equatable {
    var gpuUtilization: CGFloat = 0.0
    var cpuUtilization: CGFloat = 0.0
    var memoryUsage: CGFloat = 0.0
    var frameDrops: Int = 0
}

struct AccessibilitySettings: Equatable {
    var reduceMotion: Bool = false
    var preferCrossFadeTransitions: Bool = false
    var displayZoom: CGFloat = 1.0
    var fontSizeScale: CGFloat = 1.0

    static let `default` = AccessibilitySettings()
}

// MARK: - Layout Models

struct PanelLayout: Codable, Equatable, Identifiable {
    var id: String
    var frame: CGRect
    var zOrder: Int
    var isDocked: Bool
    var isHidden: Bool
}

struct LayoutPreset: Codable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var panels: [PanelLayout]
    var viewportArea: CGRect

    static let defaultAsymmetrical = LayoutPreset(
        name: "Default Asymmetrical",
        panels: [],
        viewportArea: .zero
    )

    static let cinematicFocus = LayoutPreset(
        name: "Cinematic Focus",
        panels: [],
        viewportArea: .zero
    )

    static let controlCentric = LayoutPreset(
        name: "Control-Centric",
        panels: [],
        viewportArea: .zero
    )
}

// MARK: - Rendering State

struct RenderingState: Equatable {
    var activeEffects: Set<String> = []
    var gpuBudget: TimeInterval = 8.0 / 60.0
    var cpuBudget: TimeInterval = 8.0 / 60.0
    var currentFrameTime: TimeInterval = 0.0
}

// MARK: - Boot Sequence State

struct BootSequenceState: Equatable {
    enum Phase: Equatable {
        case idle
        case phosphorBloom
        case crtScanline
        case systemStatus
        case mainInterfaceFadeIn
        case complete
    }

    var currentPhase: Phase = .idle
    var progress: CGFloat = 0.0
    var forceQuickBoot: Bool = false
}

struct BootSequenceConfig {
    var durationRange: ClosedRange<TimeInterval> = 2.5 ... 4.0
    var phosphorBloomDuration: TimeInterval = 1.2
    var scanlineDuration: TimeInterval = 0.6
    var statusDuration: TimeInterval = 0.7
    var fadeDuration: TimeInterval = 0.4
    var forceQuickBoot: Bool = false
}

// MARK: - AppStateContainer

@MainActor
final class AppStateContainer: ObservableObject {
    // MARK: - Camera Viewport State

    @Published var cameraViewport: CameraViewportState = .init()
    @Published var cameraTelemetry: CameraTelemetryData = .default
    @Published var systemTelemetry: SystemTelemetryData = .init()

    // MARK: - Boot Sequence State

    @Published var bootSequence: BootSequenceState = .init()

    // MARK: - Gesture State Registry

    let gestureRegistry = GestureStateRegistry()

    // MARK: - Gesture States

    @Published var fractureMode: FractureMode = .inactive
    @Published var timeScrubMode: TimeScrubMode = .inactive
    @Published var damageMode: DamageMode = .inactive

    // MARK: - Rendering State

    @Published var renderingState: RenderingState = .init()

    // MARK: - Layout State

    @Published var activeLayout: LayoutPreset = .defaultAsymmetrical
    @Published var availableLayouts: [LayoutPreset] = [
        .defaultAsymmetrical,
        .cinematicFocus,
        .controlCentric
    ]

    // MARK: - Terminal Controls

    @Published var activeParameter: String?
    @Published var parameterValues: [String: Double] = [:]

    // MARK: - Audio State

    @Published var audioPeak: Float = 0.0

    // MARK: - Accessibility

    @Published var accessibility: AccessibilitySettings = .default

    // MARK: - Accessibility Observer

    private var accessibilityObserver: AccessibilityObserver?

    // MARK: - Initialization

    init() {
        // Initialize with system accessibility settings
        updateAccessibilitySettings()

        // Set up accessibility observer
        setupAccessibilityObserver()
    }

    private func setupAccessibilityObserver() {
        accessibilityObserver = AccessibilityObserver(appState: self)
    }

    // MARK: - State Update Methods

    func updateCameraTelemetry(_ telemetry: CameraTelemetryData) {
        cameraTelemetry = telemetry
        cameraViewport.telemetry = telemetry
    }

    func updateSystemTelemetry(_ telemetry: SystemTelemetryData) {
        systemTelemetry = telemetry
    }

    func enterFractureMode(scale: CGFloat) {
        // Request activation through gesture registry (Requirement 4.1)
        guard gestureRegistry.requestActivation(for: .signalFracture, touchCount: 2) else {
            return // Blocked by higher priority gesture
        }

        if scale > 1.0 {
            // Activate if transitioning from recognizing
            if case .recognizing = fractureMode {
                gestureRegistry.activateGesture(.signalFracture)
            } else if case .inactive = fractureMode {
                gestureRegistry.requestActivation(for: .signalFracture, touchCount: 2)
                gestureRegistry.activateGesture(.signalFracture)
            }
        }

        if scale >= 2.0 {
            fractureMode = .fullyFractured(scale: scale)
        } else if scale > 1.0 {
            fractureMode = .fracturing(scale: scale)
        } else {
            fractureMode = .recognizing
        }

        // Update activity to reset timeout (Requirement 4.6)
        if gestureRegistry.isActive(.signalFracture) {
            gestureRegistry.updateActivity(for: .signalFracture)
        }
    }

    func exitFractureMode() {
        switch fractureMode {
        case .inactive:
            break
        case .recognizing, .fracturing, .fullyFractured:
            fractureMode = .returning
            gestureRegistry.completeGesture(.signalFracture)
        case .returning:
            fractureMode = .inactive
        }
    }

    func completeFractureReturn() {
        fractureMode = .inactive
        gestureRegistry.resetGesture(.signalFracture)
    }

    func beginTimeScrub() {
        // Request activation through gesture registry (Requirement 5.1)
        guard gestureRegistry.requestActivation(for: .timeScrub, touchCount: 1) else {
            return // Blocked by higher priority gesture
        }
        timeScrubMode = .waiting(duration: 0.0)
    }

    func activateTimeScrub(seekTime: TimeInterval, playbackRate: Double = 1.0) {
        // Activate gesture after 250ms hold (Requirement 5.1)
        gestureRegistry.activateGesture(.timeScrub)
        timeScrubMode = .active(seekTime: seekTime, playbackRate: playbackRate)

        // Update activity to reset timeout
        gestureRegistry.updateActivity(for: .timeScrub)
    }

    func endTimeScrub() {
        timeScrubMode = .ended
        gestureRegistry.completeGesture(.timeScrub)

        // Return to inactive after a brief delay (Requirement 5.7)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            if case .ended = timeScrubMode {
                timeScrubMode = .inactive
            }
        }
    }

    func applyDamage(intensity: CGFloat) {
        let clampedIntensity = max(0.0, min(1.0, intensity))
        if clampedIntensity > 0.0 {
            damageMode = .active(intensity: clampedIntensity)
        } else {
            beginDamageFadeOut()
        }
    }

    func beginDamageFadeOut() {
        if case let .active(intensity) = damageMode {
            damageMode = .fadingOut(intensity: intensity)
        }
    }

    func completeDamageFadeOut() {
        damageMode = .inactive
    }

    func updateLayout(_ layout: LayoutPreset) {
        activeLayout = layout
    }

    func updateParameterValue(_ value: Double, for parameter: String) {
        parameterValues[parameter] = value
    }

    func setActiveParameter(_ parameter: String?) {
        activeParameter = parameter
    }

    func updateAudioPeak(_ peak: Float) {
        audioPeak = peak
    }

    func updateAccessibilitySettings() {
        #if os(iOS)
            accessibility = AccessibilitySettings(
                reduceMotion: UIAccessibility.isReduceMotionEnabled,
                preferCrossFadeTransitions: false,
                displayZoom: UIScreen.main.scale,
                fontSizeScale: 1.0
            )
            cameraViewport.accessibility = accessibility
        #endif
    }

    func updateBootSequencePhase(_ phase: BootSequenceState.Phase, progress: CGFloat = 0.0) {
        bootSequence.currentPhase = phase
        bootSequence.progress = progress
    }

    func completeBootSequence() {
        bootSequence.currentPhase = .complete
        bootSequence.progress = 1.0
    }

    func activateCameraViewport() {
        cameraViewport.isActive = true
    }

    func deactivateCameraViewport() {
        cameraViewport.isActive = false
    }

    func updateCornerBrackets(_ config: CornerBracketConfig) {
        cameraViewport.cornerBrackets = config
    }

    func addRenderingEffect(_ effectID: String) {
        renderingState.activeEffects.insert(effectID)
    }

    func removeRenderingEffect(_ effectID: String) {
        renderingState.activeEffects.remove(effectID)
    }

    func updateFrameTime(_ time: TimeInterval) {
        renderingState.currentFrameTime = time
    }

    func resetState() {
        cameraViewport = CameraViewportState()
        cameraTelemetry = .default
        systemTelemetry = SystemTelemetryData()
        bootSequence = BootSequenceState()
        fractureMode = .inactive
        timeScrubMode = .inactive
        damageMode = .inactive
        renderingState = RenderingState()
        activeLayout = .defaultAsymmetrical
        activeParameter = nil
        audioPeak = 0.0
        gestureRegistry.resetAll()
        updateAccessibilitySettings()
    }

    // MARK: - Modulation Orbit Gesture Methods

    /// Begin modulation orbit gesture (Requirement 7.1)
    func beginModulationOrbit() -> Bool {
        // Request activation through gesture registry
        guard gestureRegistry.requestActivation(for: .modulationOrbit, touchCount: 1) else {
            return false // Blocked by higher priority gesture
        }
        return true
    }

    /// Activate modulation orbit after circular gesture detected
    func activateModulationOrbit() {
        gestureRegistry.activateGesture(.modulationOrbit)
    }

    /// Update modulation orbit activity (resets timeout)
    func updateModulationOrbitActivity() {
        gestureRegistry.updateActivity(for: .modulationOrbit)
    }

    /// Complete modulation orbit gesture
    func completeModulationOrbit() {
        gestureRegistry.completeGesture(.modulationOrbit)
    }

    /// Cancel modulation orbit gesture
    func cancelModulationOrbit() {
        gestureRegistry.cancelGesture(.modulationOrbit)
    }
}
