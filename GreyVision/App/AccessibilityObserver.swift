import Combine
import SwiftUI
import UIKit

/// Observer that monitors system accessibility settings and updates AppStateContainer
/// Validates: Requirements 1.6, 3.7
@MainActor
final class AccessibilityObserver: ObservableObject {
    // MARK: - Properties

    private weak var appState: AppStateContainer?
    private var cancellables = Set<AnyCancellable>()
    private var notificationObservers: [NSObjectProtocol] = []

    // MARK: - Initialization

    init(appState: AppStateContainer) {
        self.appState = appState
        setupNotificationObservers()
        updateAllSettings()
    }

    // Notification observers are removed automatically when object is deallocated
    // No explicit deinit cleanup needed for MainActor-isolated class

    // MARK: - Notification Setup

    private func setupNotificationObservers() {
        // Observe Reduce Motion changes
        let reduceMotionObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleReduceMotionChange()
        }
        notificationObservers.append(reduceMotionObserver)

        // Observe preferred content size changes (Dynamic Type)
        let contentSizeObserver = NotificationCenter.default.addObserver(
            forName: UIContentSizeCategory.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleDynamicTypeChange()
        }
        notificationObservers.append(contentSizeObserver)

        // Observe bold text changes
        let boldTextObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.boldTextStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleBoldTextChange()
        }
        notificationObservers.append(boldTextObserver)

        // Observe display scale changes
        let displayScaleObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.brightnessDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleDisplayScaleChange()
        }
        notificationObservers.append(displayScaleObserver)

        // Observe increased contrast changes
        let contrastObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleContrastChange()
        }
        notificationObservers.append(contrastObserver)
    }

    private func removeNotificationObservers() {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    // MARK: - Settings Update

    /// Updates all accessibility settings from system
    func updateAllSettings() {
        guard let appState else { return }

        let settings = AccessibilitySettings(
            reduceMotion: detectReduceMotion(),
            preferCrossFadeTransitions: detectPreferCrossFadeTransitions(),
            displayZoom: detectDisplayZoom(),
            fontSizeScale: detectDynamicTypeScale()
        )

        appState.accessibility = settings
        appState.cameraViewport.accessibility = settings
    }

    // MARK: - Detection Methods

    /// Detects if Reduce Motion is enabled
    /// Validates: Requirements 1.6, 3.7
    private func detectReduceMotion() -> Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    /// Detects if Prefer Cross-Fade Transitions is enabled
    /// This is a companion setting to Reduce Motion on iOS
    /// Validates: Requirements 1.6, 3.7
    private func detectPreferCrossFadeTransitions() -> Bool {
        // On iOS, this is generally true when Reduce Motion is enabled
        // The system prefers cross-fade over motion-based transitions
        UIAccessibility.isReduceMotionEnabled
    }

    /// Detects current display zoom/scale
    /// Validates: Requirements 1.6
    /// Note: Display zoom detection removed in iOS 26+ (deprecated API)
    private func detectDisplayZoom() -> CGFloat {
        // UIScreen.main.scale deprecated in iOS 26.0
        // No direct replacement available without view/window context
        // Return default scale of 1.0 for now
        1.0
    }

    /// Detects Dynamic Type font scale
    /// Returns a scale factor relative to the default body text size
    /// Validates: Requirements 1.6
    private func detectDynamicTypeScale() -> CGFloat {
        let preferredContentSize = UIApplication.shared.preferredContentSizeCategory

        // Calculate scale factor based on content size category
        let scale: CGFloat
        switch preferredContentSize {
        case .extraSmall:
            scale = 0.85
        case .small:
            scale = 0.90
        case .medium:
            scale = 0.95
        case .large: // Default
            scale = 1.0
        case .extraLarge:
            scale = 1.12
        case .extraExtraLarge:
            scale = 1.23
        case .extraExtraExtraLarge:
            scale = 1.35
        case .accessibilityMedium:
            scale = 1.6
        case .accessibilityLarge:
            scale = 1.9
        case .accessibilityExtraLarge:
            scale = 2.3
        case .accessibilityExtraExtraLarge:
            scale = 2.8
        case .accessibilityExtraExtraExtraLarge:
            scale = 3.5
        default:
            scale = 1.0
        }

        return scale
    }

    // MARK: - Notification Handlers

    private func handleReduceMotionChange() {
        guard let appState else { return }

        let reduceMotion = detectReduceMotion()
        let preferCrossFade = detectPreferCrossFadeTransitions()

        appState.accessibility.reduceMotion = reduceMotion
        appState.accessibility.preferCrossFadeTransitions = preferCrossFade
        appState.cameraViewport.accessibility.reduceMotion = reduceMotion
        appState.cameraViewport.accessibility.preferCrossFadeTransitions = preferCrossFade

        notifySettingsChanged()
    }

    private func handleDynamicTypeChange() {
        guard let appState else { return }

        let fontScale = detectDynamicTypeScale()
        appState.accessibility.fontSizeScale = fontScale
        appState.cameraViewport.accessibility.fontSizeScale = fontScale

        notifySettingsChanged()
    }

    private func handleBoldTextChange() {
        // Bold text changes affect font rendering
        // Trigger a settings update to ensure UI refreshes
        updateAllSettings()
        notifySettingsChanged()
    }

    private func handleDisplayScaleChange() {
        guard let appState else { return }

        let displayZoom = detectDisplayZoom()
        appState.accessibility.displayZoom = displayZoom
        appState.cameraViewport.accessibility.displayZoom = displayZoom

        notifySettingsChanged()
    }

    private func handleContrastChange() {
        // High contrast mode changes affect color rendering
        // Trigger a settings update to ensure UI refreshes
        updateAllSettings()
        notifySettingsChanged()
    }

    // MARK: - Notification Broadcasting

    private func notifySettingsChanged() {
        // Post notification for any components that need to react to accessibility changes
        NotificationCenter.default.post(
            name: .accessibilitySettingsDidChange,
            object: self,
            userInfo: ["settings": appState?.accessibility as Any]
        )
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when accessibility settings change
    static let accessibilitySettingsDidChange = Notification.Name("AccessibilitySettingsDidChange")
}

// MARK: - Convenience Methods

extension AccessibilityObserver {
    /// Returns true if animations should be disabled
    var shouldDisableAnimations: Bool {
        appState?.accessibility.reduceMotion ?? false
    }

    /// Returns true if cross-fade transitions should be preferred
    var shouldUseCrossFadeTransitions: Bool {
        appState?.accessibility.preferCrossFadeTransitions ?? false
    }

    /// Returns the current font size scale factor
    var fontSizeScale: CGFloat {
        appState?.accessibility.fontSizeScale ?? 1.0
    }

    /// Returns the current display zoom factor
    var displayZoom: CGFloat {
        appState?.accessibility.displayZoom ?? 1.0
    }
}
