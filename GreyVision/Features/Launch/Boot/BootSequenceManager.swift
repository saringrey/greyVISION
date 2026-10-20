import Combine
import Foundation
import SwiftUI
import UIKit

/// Manages the 4-phase boot sequence state machine for grey//VISION UI.
///
/// This is the spec-compliant implementation that drives the boot sequence
/// through distinct phases with precise timing and accessibility support.
///
/// **Phases:**
/// 1. **phosphorBloom** (1200ms) - Radial gradient expanding from center with CRT-style purple glow
/// 2. **crtScanline** (600ms) - Scanline reveal animation
/// 3. **systemStatus** (700ms) - System status display
/// 4. **mainInterfaceFadeIn** (400ms) - Fade-in to main interface
///
/// **Accessibility:**
/// - `reduceMotion` enabled: Fast path with 1500ms static display
/// - Touch input blocked during boot sequence
/// - Support for `userForceQuickBoot` environment variable
///
/// **Requirements:** 3.1, 3.2, 3.3, 3.6, 3.7
/// The boot sequence's phase vocabulary and its progress.
///
/// This used to live in `AppStateContainer.swift`, which was deleted along with
/// the rest of an unreachable parallel state graph. It is genuinely live —
/// `BootSequenceManager` advances through `BootSequenceState.Phase` — so it
/// moved here rather than going with the file.
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

@MainActor
final class BootSequenceManager: ObservableObject {
    // MARK: - Published State

    @Published private(set) var currentPhase: BootSequenceState.Phase = .idle
    @Published private(set) var phaseProgress: CGFloat = 0.0
    @Published private(set) var phaseStartTime: Date = .init()
    @Published private(set) var isTouchBlocked: Bool = true

    // MARK: - Phase Timing Configuration (Requirement 3.2)

    private enum PhaseTiming {
        static let phosphorBloom: TimeInterval = 1.2 // 1200ms
        static let crtScanline: TimeInterval = 0.6 // 600ms
        static let systemStatus: TimeInterval = 0.7 // 700ms
        static let mainInterfaceFadeIn: TimeInterval = 0.4 // 400ms

        /// Total sequence duration (normal mode)
        static let total = phosphorBloom + crtScanline + systemStatus + mainInterfaceFadeIn // 2900ms

        /// Fast path for reduceMotion (Requirement 3.7)
        static let reducedMotion: TimeInterval = 1.5 // 1500ms static
    }

    // MARK: - Private State

    private var sequenceTask: Task<Void, Never>?
    private var sequenceStartTime: Date = .init()
    private let forceQuickBoot: Bool

    // MARK: - Initialization

    init() {
        // Check for userForceQuickBoot environment variable (Requirement 3.6)
        self.forceQuickBoot = ProcessInfo.processInfo.environment["userForceQuickBoot"] != nil
    }

    // MARK: - Public Interface

    /// Start the boot sequence with optional accessibility overrides
    /// - Parameter reduceMotion: If true, uses fast path (1500ms static)
    func start(reduceMotion: Bool = false) {
        guard sequenceTask == nil else { return }

        sequenceStartTime = Date()
        isTouchBlocked = true

        // Quick boot bypasses animations (Requirement 3.6)
        if forceQuickBoot {
            applyQuickBoot()
            return
        }

        // Reduced motion fast path (Requirement 3.7)
        if reduceMotion {
            applyReducedMotionSequence()
            return
        }

        // Normal animated sequence (Requirement 3.1, 3.2)
        sequenceTask = Task { [weak self] in
            await self?.runSequence()
        }
    }

    /// Cancel the boot sequence
    func cancel() {
        sequenceTask?.cancel()
        sequenceTask = nil
        isTouchBlocked = false
    }

    /// Get current phase elapsed time
    func phaseElapsed() -> TimeInterval {
        Date().timeIntervalSince(phaseStartTime)
    }

    /// Get overall sequence elapsed time
    func sequenceElapsed() -> TimeInterval {
        Date().timeIntervalSince(sequenceStartTime)
    }

    /// Calculate phase progress normalized to [0, 1]
    func calculateProgress(duration: TimeInterval) -> CGFloat {
        let elapsed = phaseElapsed()
        return CGFloat(min(max(elapsed / duration, 0), 1))
    }

    // MARK: - Private Implementation

    /// Quick boot: skip directly to complete (Requirement 3.6)
    private func applyQuickBoot() {
        advanceTo(.complete)
        isTouchBlocked = false
    }

    /// Reduced motion sequence: 1500ms static display (Requirement 3.7)
    private func applyReducedMotionSequence() {
        advanceTo(.phosphorBloom)

        sequenceTask = Task { [weak self] in
            guard let self else { return }

            // Single 1500ms static phase
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }

            self.advanceTo(.complete)
            self.unblockTouch()
        }
    }

    /// Run the full animated boot sequence (Requirement 3.1, 3.2)
    private func runSequence() async {
        // PHASE 1: Phosphor Bloom (1200ms, ease-out)
        advanceTo(.phosphorBloom)
        guard await sleep(milliseconds: 1200) else { return }

        // PHASE 2: CRT Scanline (600ms, linear)
        advanceTo(.crtScanline)
        guard await sleep(milliseconds: 600) else { return }

        // PHASE 3: System Status (700ms)
        advanceTo(.systemStatus)
        guard await sleep(milliseconds: 700) else { return }

        // PHASE 4: Main Interface Fade-In (400ms)
        advanceTo(.mainInterfaceFadeIn)
        guard await sleep(milliseconds: 400) else { return }

        // Complete
        advanceTo(.complete)
        unblockTouch()
    }

    /// Advance to next phase
    private func advanceTo(_ phase: BootSequenceState.Phase) {
        currentPhase = phase
        phaseStartTime = Date()
        phaseProgress = 0.0
    }

    /// Unblock touch input (Requirement 3.3)
    private func unblockTouch() {
        isTouchBlocked = false
    }

    /// Sleep helper that respects cancellation
    private func sleep(milliseconds: Int) async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(milliseconds))
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    deinit {
        sequenceTask?.cancel()
    }
}

// MARK: - Boot Sequence Configuration

extension BootSequenceManager {
    /// Get timing duration for current phase
    var currentPhaseDuration: TimeInterval {
        switch currentPhase {
        case .idle:
            return 0
        case .phosphorBloom:
            return PhaseTiming.phosphorBloom
        case .crtScanline:
            return PhaseTiming.crtScanline
        case .systemStatus:
            return PhaseTiming.systemStatus
        case .mainInterfaceFadeIn:
            return PhaseTiming.mainInterfaceFadeIn
        case .complete:
            return 0
        }
    }

    /// Check if boot sequence is complete
    var isComplete: Bool {
        currentPhase == .complete
    }

    /// Check if main interface should be visible
    var isMainInterfaceVisible: Bool {
        currentPhase == .mainInterfaceFadeIn || currentPhase == .complete
    }
}
