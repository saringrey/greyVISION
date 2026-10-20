import CoreHaptics
import SwiftUI
import UIKit
import os

/// Manages the boot-to-main interface transition with haptic feedback.
///
/// This component handles the final phase of the boot sequence, implementing:
/// - Fade-in to the main interface on `GVMotion.cinematic`
/// - Haptic feedback on completion
/// - State transition coordination
///
/// **Requirements:** 3.5 (Boot-to-main transition)
@MainActor
final class BootTransitionManager: ObservableObject {
    // MARK: - Published State

    @Published private(set) var isTransitioning: Bool = false
    @Published private(set) var mainInterfaceOpacity: CGFloat = 0.0

    // MARK: - Haptic Engine

    /// `deinit` is nonisolated and `CHHapticEngine` is not `Sendable`, so the
    /// reference is marked unsafe. It is written once on the main actor during
    /// setup, and the only cross-isolation use is `stop()`, which CoreHaptics
    /// documents as safe to call from any thread.
    private nonisolated(unsafe) var hapticEngine: CHHapticEngine?
    private var supportsHaptics: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    // MARK: - Initialization

    init() {
        setupHaptics()
    }

    // MARK: - Public Interface

    /// Begin the boot-to-main transition on the shared `cinematic` token.
    /// - Parameter onComplete: Callback when transition completes
    func beginTransition(onComplete: @escaping () -> Void) {
        guard !isTransitioning else { return }

        isTransitioning = true

        // The handoff into the instrument is a once-per-launch moment, so it
        // takes the shared `cinematic` token rather than a duration of its
        // own. `AppRootView` drives the real route change; keeping this on the
        // same vocabulary means the two cannot drift apart.
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        withAnimation(GVMotion.resolved(GVMotion.cinematic, reduceMotion: reduceMotion)) {
            mainInterfaceOpacity = 1.0
        }

        // Trigger haptic feedback on completion, waiting out the same travel.
        Task {
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.12 : 0.45))
            await triggerCompletionHaptic()
            onComplete()
            isTransitioning = false
        }
    }

    /// Reset transition state
    func reset() {
        isTransitioning = false
        mainInterfaceOpacity = 0.0
    }

    // MARK: - Haptic Feedback

    /// Setup haptic engine (Requirement 3.5)
    private func setupHaptics() {
        guard supportsHaptics else { return }

        do {
            hapticEngine = try CHHapticEngine()
            try hapticEngine?.start()
        } catch {
            GVLog.app.error("Failed to start haptic engine: \(error.localizedDescription)")
        }
    }

    /// Trigger haptic feedback on boot completion
    private func triggerCompletionHaptic() async {
        guard supportsHaptics, let engine = hapticEngine else {
            // Fallback to UIImpactFeedbackGenerator
            UIImpactFeedbackGenerator(style: .medium).preparedImpact()
            return
        }

        do {
            // Create a satisfying "completion" haptic pattern
            let sharpness = CHHapticEventParameter(
                parameterID: .hapticSharpness,
                value: 0.7
            )
            let intensity = CHHapticEventParameter(
                parameterID: .hapticIntensity,
                value: 0.8
            )

            // Double tap pattern for confirmation feel
            let events = [
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [sharpness, intensity],
                    relativeTime: 0
                ),
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6)
                    ],
                    relativeTime: 0.08
                )
            ]

            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)

        } catch {
            GVLog.app.error("Failed to play haptic pattern: \(error.localizedDescription)")
            // Fallback
            UIImpactFeedbackGenerator(style: .medium).preparedImpact()
        }
    }

    deinit {
        hapticEngine?.stop()
    }
}

// MARK: - Boot Fade Transition Modifier

/// ViewModifier for boot-to-main fade transition
struct BootFadeTransition: ViewModifier {
    let opacity: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            // Reduce Motion keeps the fade, which is what carries the state
            // change, and drops the travel.
            .scaleEffect(reduceMotion ? 1 : 0.95 + (opacity * 0.05))
    }
}

extension View {
    /// Apply boot-to-main fade transition
    func bootFadeTransition(opacity: CGFloat) -> some View {
        modifier(BootFadeTransition(opacity: opacity))
    }
}

// MARK: - Utility Extensions

extension UIImpactFeedbackGenerator {
    /// Warms the generator and fires it in one call.
    ///
    /// Deliberately *not* named `impactOccurred()`: an extension with that name
    /// shadows UIKit's own method, so the body would call itself forever.
    @MainActor
    func preparedImpact(intensity: CGFloat = 1.0) {
        prepare()
        impactOccurred(intensity: intensity)
    }
}
