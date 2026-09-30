import Combine
import Foundation
import UIKit

/// Decides when the microphone is allowed to stay open.
///
/// Audio-reactive effects are inert without the analyser, so selecting one
/// arms the microphone. The inverse was never wired: nothing stopped it again,
/// which left a `.playAndRecord` session with a 5 ms input tap — roughly 200
/// FFT analyses a second — running after the last effect that needed it had
/// been switched off. That is both a battery cost and a privacy one, because
/// the system recording indicator stays lit.
///
/// The rule this enforces: the analyser runs while something the operator
/// armed still wants it, and for nothing else. A manual arm from the toolbar
/// is latched, so someone deliberately watching a scope is never left
/// wondering why it went quiet.
@MainActor
final class GVAudioArmPolicy: ObservableObject {
    /// The operator asked for audio from the toolbar rather than by selecting
    /// an effect. Latched so an unrelated stack edit does not undo it.
    @Published private(set) var isManuallyArmed = false
    /// True while at least one armed effect reads the spectrum.
    @Published private(set) var isRequiredByStack = false
    /// Whether the microphone should currently be open.
    var isMicrophoneNeeded: Bool { isManuallyArmed || isRequiredByStack }

    private var cancellables = Set<AnyCancellable>()
    private weak var audio: AudioReactiveRuntime?
    private weak var editor: EffectEditingSession?

    /// Starts watching the composition. Safe to call once per session.
    func attach(audio: AudioReactiveRuntime, editor: EffectEditingSession) {
        self.audio = audio
        self.editor = editor
        recompute()

        // Every path that can change the armed set: a slot's enabled flag, a
        // parameter write that re-enables one, the effect being swapped under a
        // focused slot, or rgbSplit itself. One debounced sink covers all of
        // them, and the scan is over a single-digit slot list.
        editor.$effectStack
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &cancellables)
        editor.$rgbSplitParameters
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &cancellables)
    }

    /// Recomputes the requirement from the editor and releases the microphone
    /// when nothing needs it.
    func reconcile() {
        recompute()
        guard !isMicrophoneNeeded, let audio, audio.isEnabled else { return }
        audio.stop()
    }

    /// The toolbar toggle. `true` means the operator wants audio regardless of
    /// what the stack says; `false` releases the latch, which may close the
    /// microphone outright or leave it open for a still-armed effect.
    func setManualArm(_ armed: Bool) {
        isManuallyArmed = armed
        if !armed { reconcile() }
    }

    private func recompute() {
        guard let editor else { return }
        isRequiredByStack = editor.activeEffects.contains { $0.requiresAudioAnalysis }
    }
}

/// Decides whether the app is allowed to hold the display awake.
///
/// `isIdleTimerDisabled` was set for the whole workspace, which meant a phone
/// left face-up on a desk with the workspace open never slept — no effect
/// armed, nothing recording, nothing to protect. The viewfinder only needs to
/// stay awake while a take could actually be lost, and once it does not the
/// system timeout is strictly better.
///
/// Two-state: hold while live, hand the screen back after an idle window, and
/// re-hold on the next interaction.
@MainActor
final class GVIdleTimerPolicy {
    /// How long the workspace may sit untouched, with nothing armed and
    /// nothing recording, before the display is handed back to the system.
    static let idleTimeout: TimeInterval = 60

    private var lastInteraction = Date.now
    /// Whether an armed effect or a live recording is protecting the session.
    private var isLive = false

    /// True when the display should be held awake right now.
    var shouldHoldScreen: Bool {
        isLive && Date.now.timeIntervalSince(lastInteraction) < Self.idleTimeout
    }

    /// Something the operator did. Postpones the release.
    func noteInteraction() {
        lastInteraction = .now
    }

    /// Recomputed by the caller on scene-phase and route changes.
    func setLive(_ live: Bool) {
        isLive = live
        if live { noteInteraction() }
    }
}
