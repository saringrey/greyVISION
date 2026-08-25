import SwiftUI

/// Integration example showing how to use the new BootSequenceManager
/// with the existing BootView implementation.
///
/// This file demonstrates the integration pattern but is not meant to replace
/// the existing BootView. Instead, it shows how to layer the new 4-phase
/// boot sequence components on top of or alongside the existing implementation.
///
/// **Integration Strategy:**
///
/// Option A: Side-by-side (Recommended for Testing)
/// - Keep existing GVBootSequence for current functionality
/// - Add BootSequenceManager as parallel implementation
/// - Use feature flag or environment variable to switch
///
/// Option B: Replace existing implementation
/// - Fully migrate from GVBootSequence to BootSequenceManager
/// - Update BootView to use new components
/// - Requires more extensive refactoring
///
/// **Components:**
/// - BootSequenceManager: State machine for 4 phases
/// - PhosphorBloomEffect: Phase 1 visual effect
/// - CRTScanlineOverlay: Phase 2 scanline reveal
/// - BootTransitionManager: Phase 4 fade-in with haptics

// MARK: - Example: New Boot Sequence View

/// Example implementation using the new boot sequence components.
/// This can be used as reference for integration or as a standalone boot view.
struct NewBootSequenceView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var sequenceManager = BootSequenceManager()
    @StateObject private var transitionManager = BootTransitionManager()

    /// Callback when boot completes
    var onBootComplete: () -> Void

    var body: some View {
        ZStack {
            // Base background
            Color.black.ignoresSafeArea()

            // Phase 1: Phosphor Bloom (1200ms ease-out)
            if sequenceManager.currentPhase == .phosphorBloom {
                TimelineView(.animation(minimumInterval: 1 / 60, paused: false)) { _ in
                    let progress = sequenceManager.calculateProgress(
                        duration: sequenceManager.currentPhaseDuration
                    )

                    PhosphorBloomEffect(
                        progress: progress,
                        isActive: true
                    )
                }
            }

            // Phase 2: CRT Scanline (600ms linear)
            if sequenceManager.currentPhase == .crtScanline {
                TimelineView(.animation(minimumInterval: 1 / 60, paused: false)) { _ in
                    let progress = sequenceManager.calculateProgress(
                        duration: sequenceManager.currentPhaseDuration
                    )

                    CRTScanlineOverlay(
                        progress: progress,
                        isActive: true
                    )
                }
            }

            // Phase 3: System Status (700ms)
            // (Content from existing BootView can be shown here)
            if sequenceManager.currentPhase == .systemStatus {
                systemStatusContent
            }

            // Phase 4: Main Interface Fade-In (400ms)
            if sequenceManager.isMainInterfaceVisible {
                mainInterfaceContent
                    .bootFadeTransition(opacity: transitionManager.mainInterfaceOpacity)
            }

            // Touch blocking overlay during boot
            if sequenceManager.isTouchBlocked {
                Color.clear
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)
                    .accessibilityHidden(true)
            }
        }
        .onAppear {
            startBootSequence()
        }
    }

    // MARK: - Content Phases

    private var systemStatusContent: some View {
        VStack(spacing: 20) {
            Text("SYSTEM ONLINE")
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .foregroundColor(.white)

            Text("INITIALIZING CAMERA...")
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundColor(.gray)

            Text("grey//VISION v3")
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundColor(.gray.opacity(0.7))
        }
        .transition(.opacity)
    }

    private var mainInterfaceContent: some View {
        VStack {
            Text("CAMERA READY")
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(.green)

            Text("TAP TO BEGIN")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .padding(.top, 8)
        }
        .onTapGesture {
            if sequenceManager.isComplete {
                onBootComplete()
            }
        }
    }

    // MARK: - Boot Sequence Control

    private func startBootSequence() {
        sequenceManager.start(reduceMotion: reduceMotion)

        // Monitor for main interface phase
        Task {
            // Wait until main interface phase
            while !sequenceManager.isMainInterfaceVisible {
                try? await Task.sleep(for: .milliseconds(100))
            }

            // Begin transition with haptic feedback
            transitionManager.beginTransition {
                // Boot complete
                print("✅ Boot sequence complete")
            }
        }
    }
}

// MARK: - Integration with Existing BootView

/// Extension showing how to integrate BootSequenceManager with existing BootView.
///
/// **Usage in BootView:**
/// ```swift
/// @StateObject private var newBootManager = BootSequenceManager()
///
/// // In body:
/// .overlay {
///     if useNewBootSequence {
///         NewBootSequenceOverlay(manager: newBootManager)
///     }
/// }
/// .onAppear {
///     if useNewBootSequence {
///         newBootManager.start(reduceMotion: reduceMotion)
///     } else {
///         // Existing GVBootSequence logic
///         sequence.start(lineCount: ..., reduceMotion: ...)
///     }
/// }
/// ```
struct NewBootSequenceOverlay: View {
    @ObservedObject var manager: BootSequenceManager

    var body: some View {
        ZStack {
            // Phase 1: Phosphor Bloom
            if manager.currentPhase == .phosphorBloom {
                TimelineView(.animation(minimumInterval: 1 / 60, paused: false)) { _ in
                    let progress = manager.calculateProgress(
                        duration: manager.currentPhaseDuration
                    )
                    PhosphorBloomEffect(progress: progress, isActive: true)
                }
            }

            // Phase 2: CRT Scanline
            if manager.currentPhase == .crtScanline {
                TimelineView(.animation(minimumInterval: 1 / 60, paused: false)) { _ in
                    let progress = manager.calculateProgress(
                        duration: manager.currentPhaseDuration
                    )
                    CRTScanlineOverlay(progress: progress, isActive: true)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Environment Flag for Feature Toggle

extension EnvironmentValues {
    /// Feature flag for using new boot sequence
    var useNewBootSequence: Bool {
        get { self[UseNewBootSequenceKey.self] }
        set { self[UseNewBootSequenceKey.self] = newValue }
    }
}

private struct UseNewBootSequenceKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

// MARK: - Preview

#Preview("New Boot Sequence") {
    NewBootSequenceView {
        print("Boot complete!")
    }
}

#Preview("Boot Sequence Overlay") {
    @Previewable @StateObject var manager = BootSequenceManager()

    return ZStack {
        Color.black.ignoresSafeArea()

        Text("EXISTING CONTENT")
            .font(.system(size: 32, weight: .bold, design: .monospaced))
            .foregroundColor(.white)

        NewBootSequenceOverlay(manager: manager)
    }
    .onAppear {
        manager.start(reduceMotion: false)
    }
}
