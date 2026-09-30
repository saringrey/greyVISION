import Foundation
import SwiftUI

/// UI-facing model for the bidirectional control channel.
///
/// One source of truth that the panel binds to, the source writes into, and
/// the link talks through. Deliberately small: any business logic about which
/// command is the right answer for a given UI gesture belongs in the view
/// (or in a `GVBroadcastCommand` case), not here.
///
/// Commands are *deltas*. The phone is the authority — the Mac publishes what
/// it asked for, then waits for the next `GVBroadcastControlState` to confirm
/// what actually happened. This avoids the class of bugs where a stale local
/// copy of the composition diverges from the phone because a parameter was
/// clamped, sanitised or rejected at the other end.
@MainActor
final class GVRemoteControl: ObservableObject {
    // MARK: - Published

    @Published private(set) var surface: GVBroadcastControlSurface?
    @Published private(set) var state: GVBroadcastControlState = .empty
    @Published private(set) var lastSent: GVBroadcastCommand?
    @Published private(set) var isAudioAvailable = true

    var hasSurface: Bool { surface != nil }

    func descriptor(for effectID: String) -> GVEffectDescriptor? {
        surface?.descriptor(for: effectID)
    }

    func isUnavailable(_ effectID: String) -> Bool {
        surface?.unavailable[effectID] != nil
    }

    func unavailabilityReason(_ effectID: String) -> String? {
        surface?.unavailable[effectID]
    }

    // MARK: - Wiring

    private weak var source: GVPhoneLink?

    func attach(to source: GVPhoneLink) {
        self.source = source
        source.onControlSurface = { [weak self] surface in
            Task { @MainActor in self?.applySurface(surface) }
        }
        source.onControlState = { [weak self] state in
            Task { @MainActor in self?.applyState(state) }
        }
    }

    // MARK: - Outbound

    /// Sends a command and remembers it locally so the UI can flash a pending
    /// state. The phone's echoed `GVBroadcastControlState` is the only thing
    /// that flips the published state; `lastSent` is purely for the UI.
    func send(_ command: GVBroadcastCommand) {
        lastSent = command
        source?.send(command)
    }

    // MARK: - Convenience

    func toggleStackArmed() {
        send(.setStackArmed(!state.isStackArmed))
    }

    func setRecording(_ recording: Bool) {
        send(.setRecording(recording))
    }

    func capturePhoto() {
        send(.capturePhoto)
    }

    func addEffect(_ effectID: String) {
        send(.addEffect(effect: effectID))
    }

    func removeSlot(_ id: UUID) {
        send(.removeSlot(slot: id))
    }

    func setSlotEnabled(_ id: UUID, enabled: Bool) {
        send(.setSlotEnabled(slot: id, enabled: enabled))
    }

    func setSlotParameter(_ id: UUID, channel: GVBroadcastParameterChannel, value: Double) {
        send(.setSlotParameter(slot: id, channel: channel, value: value))
    }

    func resetSlot(_ id: UUID) {
        send(.resetSlot(slot: id))
    }

    func clearEffects() {
        send(.clearEffects)
    }

    func setRGBSplit(enabled: Bool? = nil, amount: Double? = nil, angleDegrees: Double? = nil, mix: Double? = nil) {
        send(.setRGBSplit(enabled: enabled, amount: amount, angleDegrees: angleDegrees, mix: mix))
    }

    // MARK: - Inbound

    private func applySurface(_ surface: GVBroadcastControlSurface) {
        // Refuse unknown versions. The shape would otherwise render as a wall
        // of defaults that look correct but have no real meaning.
        guard surface.surfaceVersion == GVBroadcastControlSurface.currentVersion else {
            assertionFailure("Unknown control surface version: \(surface.surfaceVersion)")
            return
        }
        self.surface = surface
        // Audio availability is on the surface, not the state, so derive it.
        let anyAudioEffectIsUnavailable = surface.unavailable.values.contains { $0.contains("MICROPHONE") }
        self.isAudioAvailable = !anyAudioEffectIsUnavailable
    }

    private func applyState(_ state: GVBroadcastControlState) {
        self.state = state
        self.isAudioAvailable = state.isAudioAvailable
    }
}
