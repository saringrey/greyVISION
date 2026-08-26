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
    @Binding var effectStack: CameraEffectStackParameters
    @Binding var rgbSplitParameters: RGBSplitEffectParameters
    /// The effect the parameter deck is currently editing, so its slot reads
    /// as the focused one without the strip owning a second source of truth.
    let editing: WorkspaceAdjustableEffect
    /// Owned by the deck, not by the strip: the deck edits whichever slot is
    /// focused, so focus has to outlive the strip being collapsed.
    @Binding var focusedSlot: CameraEffectStackParameters.Slot.ID?
    let onSelect: (WorkspaceAdjustableEffect) -> Void

    @EnvironmentObject private var toasts: GVToastBox

    private var slots: [CameraEffectStackParameters.Slot] { effectStack.orderedSlots }

    /// The slot the operations act on: whatever was last tapped, falling back
    /// to the first slot for the effect the deck is editing. Without the
    /// fallback the operations row would be inert until the operator tapped a
    /// chip, which reads as broken rather than as unfocused.
    private var activeSlot: CameraEffectStackParameters.Slot? {
        if let focusedSlot, let match = slots.first(where: { $0.id == focusedSlot }) {
            return match
        }
        return slots.first { $0.effect == editing }
    }

    var body: some View {
        VStack(spacing: 6) {
            if slots.isEmpty {
                GVTerminalText(
                    text: "STACK EMPTY // POWER AN EFFECT ON",
                    size: GVMetrics.textMicro,
                    weight: .bold,
                    tracking: 0.8,
                    baseColor: GVTheme.ash,
                    intensity: 0.6
                )
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
            focusedSlot = slot.id
            onSelect(slot.effect)
        } label: {
            HStack(spacing: 5) {
                // Render position, not effect index. This number is the whole
                // reason the strip exists: it is the answer to "what runs
                // before what", which nothing in the app said before.
                Text(String(format: "%02d", index + 1))
                    .gvMono(GVMetrics.textMicro, .black)
                    .foregroundStyle(focused ? Color.white : GVTheme.ash)
                Text(slot.effect.label)
                    .gvMono(GVMetrics.textMicro, .black)
                    .tracking(0.7)
                    .lineLimit(1)
                    .foregroundStyle(live ? Color.white : GVTheme.bone.opacity(0.45))
                Circle()
                    .fill(live ? Color.white : Color(white: 0.28))
                    .frame(width: 4.5, height: 4.5)
                    .shadow(color: live ? .white.opacity(0.9) : .clear, radius: 3)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(focused ? Color.white.opacity(0.13) : Color(white: 0.145))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(
                                focused ? Color.white.opacity(0.9) : Color.white.opacity(0.08),
                                lineWidth: focused ? 1.1 : 0.8
                            )
                    )
                    .shadow(color: focused ? .white.opacity(0.35) : .clear, radius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle(scale: 0.94))
        .accessibilityLabel("\(index + 1) \(slot.effect.label)")
        .accessibilityValue(live ? "on" : "off")
        .accessibilityIdentifier("workspace.stack.slot.\(index + 1)")
    }

    // MARK: - Operations

    private var operationsRow: some View {
        let slot = activeSlot
        let index = slot.flatMap { target in slots.firstIndex { $0.id == target.id } }
        return HStack(spacing: 5) {
            GVDeckChip(
                label: "",
                symbol: "chevron.left",
                dimmed: index == nil || index == 0,
                id: "stackup"
            ) {
                move(by: -1)
            }
            GVDeckChip(
                label: "",
                symbol: "chevron.right",
                dimmed: index == nil || index == slots.count - 1,
                id: "stackdown"
            ) {
                move(by: 1)
            }
            GVDeckChip(
                label: "",
                symbol: slot?.parameters.isEnabled == true ? "power" : "power.dotted",
                active: slot?.parameters.isEnabled == true,
                dimmed: slot == nil,
                id: "stackpower"
            ) {
                toggleActive()
            }
            // Duplicating is the operation slots were built for: the same
            // effect twice with different parameters, which the old
            // effect-keyed dictionary could not represent at all.
            GVDeckChip(label: "DUP", symbol: "plus.square.on.square", dimmed: slot == nil, id: "stackdup") {
                duplicateActive()
            }
            GVDeckChip(label: "SOLO", symbol: "1.circle", dimmed: slot == nil, id: "stacksolo") {
                soloActive()
            }
            Spacer(minLength: 0)
            GVDeckChip(label: "", symbol: "trash", dimmed: slot == nil, tint: GVTheme.record, id: "stackremove") {
                removeActive()
            }
        }
    }

    // MARK: - Actions

    private func move(by offset: Int) {
        guard let slot = activeSlot,
              let index = slots.firstIndex(where: { $0.id == slot.id })
        else { return }
        let target = index + offset
        guard slots.indices.contains(target) else { return }
        // SwiftUI's move takes an insertion point rather than a destination
        // index, so moving later needs one extra step to land past the element
        // being displaced.
        effectStack.move(fromOffsets: IndexSet(integer: index), toOffset: offset > 0 ? target + 1 : target)
        focusedSlot = slot.id
        toasts.show("STACK // \(slot.effect.label) -> \(String(format: "%02d", target + 1))")
    }

    private func toggleActive() {
        guard let slot = activeSlot else { return }
        effectStack.setEnabled(!slot.parameters.isEnabled, slot: slot.id)
    }

    private func duplicateActive() {
        guard let slot = activeSlot, let copy = effectStack.duplicate(slot.id) else { return }
        focusedSlot = copy
        toasts.show("STACK // \(slot.effect.label) DUPLICATED")
    }

    /// Powers everything else down without discarding it, so the operator can
    /// audition one node of a deep stack and get the rest back by re-powering
    /// rather than by rebuilding.
    private func soloActive() {
        guard let slot = activeSlot else { return }
        for other in slots {
            effectStack.setEnabled(other.id == slot.id, slot: other.id)
        }
        rgbSplitParameters.isEnabled = false
        toasts.show("STACK // SOLO \(slot.effect.label)")
    }

    private func removeActive() {
        guard let slot = activeSlot else { return }
        effectStack.remove(slot.id)
        focusedSlot = nil
        toasts.show("STACK // \(slot.effect.label) REMOVED")
    }
}
