import Foundation

/// Applies desktop commands to the phone's composition, and publishes the
/// result back.
///
/// The one place the Mac is allowed to touch `EffectEditingSession`. Commands
/// arrive on the link's queue and are hopped to the main actor here, because
/// the editor is `@MainActor` and the effect stack is read by SwiftUI on every
/// frame it redraws.
///
/// ## Why the desktop is not trusted with placement
///
/// `addEffect` carries only an effect id. Where the slot lands is decided by
/// the phone's own `insertInPipelineOrder`, exactly as it would be for a tap
/// on the dock. A desktop that could choose an index would be able to build a
/// stack the phone's UI cannot represent, and the two screens would disagree
/// about what the composition is.
@MainActor
final class GVBroadcastControlBridge {
    /// Set by the workspace once its editor exists. Weak because the bridge
    /// outlives any particular presentation of the workspace, and a dangling
    /// strong reference here would keep a whole view's state alive after it
    /// went away.
    weak var editor: EffectEditingSession?

    /// Capture actions live in `GVRecordingTransaction`, which needs runtimes
    /// the bridge has no business holding. The workspace supplies closures
    /// instead, so this file stays a translator rather than a second capture
    /// controller.
    var onSetRecording: ((Bool) -> Void)?
    var onCapturePhoto: (() -> Void)?

    /// Pushes an encoded payload out over the link. Supplied by the runtime.
    var send: ((GVBroadcastProtocol.MessageKind, Data) -> Void)?

    private(set) var isAudioAvailable = true
    private var isRecording = false
    /// The last state actually put on the wire. Publishing is driven by
    /// SwiftUI change notifications, which fire more often than the
    /// composition actually changes; comparing here keeps a knob drag from
    /// becoming a message per frame.
    private var lastPublished: GVBroadcastControlState?

    // MARK: - Inbound

    /// Returns true when the command was a control-surface command and has
    /// been handled. Encoder commands (keyframe, bitrate) are not ours.
    func handle(_ command: GVBroadcastCommand) -> Bool {
        switch command {
        case .requestKeyframe, .setBitrate:
            return false

        case .requestControlSurface:
            publishSurface()
            publishState(force: true)

        case let .addEffect(effect):
            guard let effect = WorkspaceAdjustableEffect(rawValue: effect), let editor else { break }
            // Same path as a dock tap, so ADD mode and exclusive selection
            // mean the same thing from either screen.
            editor.select(effect)
            editor.recordHistory()

        case let .removeSlot(slot):
            editor?.effectStack.remove(slot)
            editor?.recordHistory()

        case let .duplicateSlot(slot):
            editor?.effectStack.duplicate(slot)
            editor?.recordHistory()

        case let .moveSlot(slot, toIndex):
            guard let editor,
                  let from = editor.effectStack.orderedSlots.firstIndex(where: { $0.id == slot })
            else { break }
            let clamped = min(max(toIndex, 0), editor.effectStack.orderedSlots.count - 1)
            guard clamped != from else { break }
            // `move(fromOffsets:toOffset:)` takes an insertion point, which is
            // one past the target when moving down the list.
            editor.effectStack.move(
                fromOffsets: IndexSet(integer: from),
                toOffset: clamped > from ? clamped + 1 : clamped
            )
            editor.recordHistory()

        case let .resetSlot(slot):
            editor?.effectStack.reset(slot: slot)
            editor?.recordHistory()

        case let .setSlotEnabled(slot, enabled):
            editor?.effectStack.setEnabled(enabled, slot: slot)
            editor?.recordHistory()

        case let .setSlotParameter(slot, channel, value):
            guard let editor, var parameters = editor.effectStack[slot: slot] else { break }
            let clamped = min(max(value, 0), 1)
            switch channel {
            case .primary: parameters.primary = clamped
            case .secondary: parameters.secondary = clamped
            case .tertiary: parameters.tertiary = clamped
            case .blend: parameters.blend = clamped
            case .overlayX: parameters.overlayX = clamped
            case .overlayY: parameters.overlayY = clamped
            }
            // The subscript sanitises, which is what keeps an overlay centre
            // out of the 0.05 margin regardless of what the desktop sent.
            editor.effectStack[slot: slot] = parameters
            // Deliberately no history entry per knob sample: a drag would
            // otherwise fill the undo stack with forty intermediate states.

        case let .setStackArmed(armed):
            editor?.setStackArmed(armed)

        case .clearEffects:
            editor?.disableAll()
            editor?.dismissSelection()
            editor?.recordHistory()

        case let .setRGBSplit(enabled, amount, angleDegrees, mix):
            guard let editor else { break }
            if let enabled { editor.rgbSplitParameters.isEnabled = enabled }
            if let amount { editor.rgbSplitParameters.amount = min(max(amount, 0), 0.08) }
            if let angleDegrees { editor.rgbSplitParameters.angleDegrees = min(max(angleDegrees, -180), 180) }
            if let mix { editor.rgbSplitParameters.mix = min(max(mix, 0), 1) }

        case let .setRecording(shouldRecord):
            guard shouldRecord != isRecording else { break }
            onSetRecording?(shouldRecord)

        case .capturePhoto:
            onCapturePhoto?()
        }

        publishState()
        return true
    }

    // MARK: - Outbound

    func setAudioAvailable(_ available: Bool) {
        guard available != isAudioAvailable else { return }
        isAudioAvailable = available
        // Availability is baked into the catalogue's `unavailable` map, so it
        // has to be resent rather than patched.
        publishSurface()
        publishState(force: true)
    }

    func setRecording(_ recording: Bool) {
        guard recording != isRecording else { return }
        isRecording = recording
        publishState()
    }

    /// Sent once per connection, and again whenever availability changes.
    func publishSurface() {
        let surface = GVBroadcastControlCatalog.makeSurface(isAudioAvailable: isAudioAvailable)
        guard let payload = try? JSONEncoder().encode(surface) else { return }
        send?(.controlSurface, payload)
    }

    /// Publishes the composition if it differs from what the desktop last saw.
    func publishState(force: Bool = false) {
        guard let editor else { return }
        let state = GVBroadcastControlCatalog.makeState(
            stack: editor.effectStack,
            rgbSplit: editor.rgbSplitParameters,
            isStackArmed: editor.isStackArmed,
            isRecording: isRecording,
            isAudioAvailable: isAudioAvailable
        )
        guard force || state != lastPublished else { return }
        lastPublished = state
        guard let payload = try? JSONEncoder().encode(state) else { return }
        send?(.controlState, payload)
    }

    /// A peer that just attached has seen nothing. Clearing the comparison
    /// baseline is what stops `publishState` from deciding the desktop is
    /// already up to date.
    func peerAttached() {
        lastPublished = nil
        publishSurface()
        publishState(force: true)
    }

    func peerDetached() {
        lastPublished = nil
    }
}
