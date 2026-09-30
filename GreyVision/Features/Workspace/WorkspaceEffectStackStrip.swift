import SwiftUI

/// The render stack, as an editable strip.
///
/// `CameraEffectStackParameters` has carried ordered, individually identified
/// slots for a while — with `move`, `duplicate`, `remove` and per-slot enable
/// all implemented and tested. None of it had a caller. The operator could
/// turn effects on and off and nothing more: order was whatever
/// `defaultPlacementOrder` decided, a second instance of an effect was
/// unreachable, and the only way to see what was actually rendering was to
/// count lit cards across nineteen rails.
///
/// This is that model's control surface. One horizontal strip of slots in
/// render order, left to right, with the focused slot's operations underneath.
/// Two rows, no sheet, no navigation — it opens inside the parameter deck the
/// operator is already looking at.
struct WorkspaceEffectStackStrip: View {
    @ObservedObject var editor: EffectEditingSession
    /// The effect the parameter deck is currently editing, so its slot reads
    /// as the focused one without the strip owning a second source of truth.
    let editing: WorkspaceAdjustableEffect
    /// Owned by the deck, not by the strip: the deck edits whichever slot is
    /// focused, so focus has to outlive the strip being collapsed.
    let onSelect: (WorkspaceAdjustableEffect) -> Void

    @EnvironmentObject private var toasts: GVToastBox

    private var slots: [CameraEffectStackParameters.Slot] { editor.effectStack.orderedSlots }

    /// The slot the operations act on: whatever was last tapped, falling back
    /// to the first slot for the effect the deck is editing. Without the
    /// fallback the operations row would be inert until the operator tapped a
    /// chip, which reads as broken rather than as unfocused.
    private var activeSlot: CameraEffectStackParameters.Slot? {
        if let focusedSlot = editor.focusedSlot, let match = slots.first(where: { $0.id == focusedSlot }) {
            return match
        }
        return slots.first { $0.effect == editing }
    }

    var body: some View {
        VStack(spacing: 6) {
            if slots.isEmpty {
                Text("Stack empty · Enable an effect to begin")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(GVTheme.ash)
                    .frame(height: 30)
            } else {
                slotStrip
                operationsRow
            }
        }
        .accessibilityIdentifier("workspace.stack.strip")
    }

    // MARK: - Slots

    private var slotStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    slotChip(index: index, slot: slot)
                }
            }
            .padding(.horizontal, 1)
            .padding(.vertical, 1)
        }
        .gvHorizontalEdgeFade()
    }

    private func slotChip(index: Int, slot: CameraEffectStackParameters.Slot) -> some View {
        let focused = activeSlot?.id == slot.id
        let live = slot.parameters.isEnabled
        return Button {
            editor.focusedSlot = slot.id
            onSelect(slot.effect)
        } label: {
            HStack(spacing: 5) {
                // Render position, not effect index. This number is the whole
                // reason the strip exists: it is the answer to "what runs
                // before what", which nothing in the app said before.
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(focused ? Color.white : GVTheme.ash)
                Text(slot.effect.label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(live ? Color.white : GVTheme.bone.opacity(0.45))
                Circle()
                    .fill(live ? Color.white : Color(white: 0.28))
                    .frame(width: 4.5, height: 4.5)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
        }
        .buttonStyle(GVGlassSlotChipStyle(focused: focused, live: live))
        .frame(minHeight: GVMetrics.touchTarget)
        .contentShape(Rectangle())
        .accessibilityLabel("\(index + 1) \(slot.effect.label)")
        .accessibilityValue("\(live ? "on" : "off")\(focused ? ", focused" : "")")
        .accessibilityIdentifier("workspace.stack.slot.\(index + 1)")
    }

    private struct GVGlassSlotChipStyle: ButtonStyle {
        let focused: Bool
        let live: Bool

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .gvGlassChip(radius: 8, active: focused || configuration.isPressed, tint: .white)
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.98 : 1))
                .animation(GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion), value: configuration.isPressed)
        }
    }

    // MARK: - Operations

    private var operationsRow: some View {
        let slot = activeSlot
        let index = slot.flatMap { target in slots.firstIndex { $0.id == target.id } }
        return HStack(spacing: 5) {
            GVDeckChip(
                label: "",
                symbol: "chevron.left",
                accessibilityLabel: "Move effect earlier in stack",
                dimmed: index == nil || index == 0,
                id: "stackup"
            ) {
                move(by: -1)
            }
            GVDeckChip(
                label: "",
                symbol: "chevron.right",
                accessibilityLabel: "Move effect later in stack",
                dimmed: index == nil || index == slots.count - 1,
                id: "stackdown"
            ) {
                move(by: +1)
            }
            GVDeckChip(
                label: "",
                symbol: slot?.parameters.isEnabled == true ? "power" : "power.dotted",
                accessibilityLabel: slot?.parameters.isEnabled == true ? "Disable effect" : "Enable effect",
                active: slot?.parameters.isEnabled == true,
                dimmed: slot == nil,
                id: "stackpower"
            ) {
                toggleActive()
            }
            GVDeckChip(label: "Solo", symbol: "1.circle", dimmed: slot == nil, id: "stacksolo") {
                soloActive()
            }
            GVDeckChip(label: "Duplicate", symbol: "doc.on.doc", dimmed: slot == nil, id: "stackdup") {
                duplicateActive()
            }
            Spacer(minLength: 0)
            GVDeckChip(label: "", symbol: "trash", accessibilityLabel: "Remove effect from stack", dimmed: slot == nil, tint: GVTheme.record, id: "stackremove") {
                removeActive()
            }
        }
    }

    // MARK: - Actions

    private func move(by offset: Int) {
        guard let slot = activeSlot, let position = editor.moveFocused(by: offset) else { return }
        toasts.show("\(slot.effect.label) moved to position \(position)")
    }

    private func toggleActive() {
        editor.toggleFocused()
    }

    /// Powers everything else down without discarding it, so the operator can
    /// audition one node of a deep stack and get the rest back by re-powering
    /// rather than by rebuilding.
    private func soloActive() {
        guard let effect = editor.soloFocused() else { return }
        toasts.show("Soloing \(effect.label)")
    }

    private func removeActive() {
        guard let effect = editor.removeFocused() else { return }
        toasts.show("\(effect.label) removed")
    }

    private func duplicateActive() {
        guard let effect = editor.duplicateFocused() else { return }
        toasts.show("\(effect.label) duplicated")
    }
}
