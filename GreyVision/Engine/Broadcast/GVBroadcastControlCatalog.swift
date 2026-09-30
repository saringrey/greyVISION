import Foundation

/// Builds the desktop's catalogue from the phone's own effect vocabulary.
///
/// Lives on the iOS side because it is the only place that knows
/// `WorkspaceAdjustableEffect` exists. Everything it produces is plain
/// Foundation types from `GVBroadcastControlSurface`, which is what lets the
/// Mac render a control surface for effects it has never been compiled
/// against.
///
/// Built once per connection rather than cached in a static: the families are
/// arrays on the enum and the labels are switches over it, so this is a few
/// hundred string lookups, and doing it on connect means a debug build that
/// changed the vocabulary never serves a stale catalogue.
enum GVBroadcastControlCatalog {
    /// Families in the order the phone's dock lists them, so an operator
    /// looking at both screens sees the same shelf order.
    private static var families: [EffectCatalog.Shelf] { EffectCatalog.shelves }

    /// - Parameter isAudioAvailable: whether the microphone is armed. Audio
    ///   effects stay in the catalogue when it is not — they are still real
    ///   effects — but carry a reason so the desktop can say why the control
    ///   is inert rather than letting the operator turn a knob that does
    ///   nothing.
    static func makeSurface(isAudioAvailable: Bool) -> GVBroadcastControlSurface {
        // Every effect reachable from a family, plus RGB SPLIT, which the dock
        // presents on its own. Deduplicated because a handful of effects are
        // curated into more than one family on purpose.
        let descriptors = WorkspaceAdjustableEffect.allCases.map(descriptor(for:))

        var unavailable: [String: String] = [:]
        if !isAudioAvailable {
            for descriptor in descriptors where descriptor.requiresAudioAnalysis {
                unavailable[descriptor.id] = "MICROPHONE UNAVAILABLE"
            }
        }

        return GVBroadcastControlSurface(
            families: families.map {
                GVEffectFamily(
                    id: $0.id,
                    label: $0.label,
                    // Filter to what actually made it into `descriptors`, so a
                    // family never advertises an id the desktop cannot resolve.
                    effectIDs: $0.effects.map(\.rawValue)
                )
            },
            effects: descriptors,
            unavailable: unavailable
        )
    }

    private static func descriptor(for effect: WorkspaceAdjustableEffect) -> GVEffectDescriptor {
        let defaults = effect.defaultCameraParameters
        return GVEffectDescriptor(
            id: effect.rawValue,
            label: effect.label,
            parameterLabels: Array(EffectCatalog.controls(for: effect).prefix(3).map(\.label)),
            defaults: [defaults.primary, defaults.secondary, defaults.tertiary, defaults.blend],
            requiresAudioAnalysis: effect.requiresAudioAnalysis,
            isSpectrumOverlay: effect.isSpectrumOverlay
        )
    }

    // MARK: - Live state

    static func makeState(
        stack: CameraEffectStackParameters,
        rgbSplit: RGBSplitEffectParameters,
        isStackArmed: Bool,
        isRecording: Bool,
        isAudioAvailable: Bool
    ) -> GVBroadcastControlState {
        GVBroadcastControlState(
            slots: stack.orderedSlots.map { slot in
                GVBroadcastSlotState(
                    id: slot.id,
                    effect: slot.effect.rawValue,
                    isEnabled: slot.parameters.isEnabled,
                    primary: slot.parameters.primary,
                    secondary: slot.parameters.secondary,
                    tertiary: slot.parameters.tertiary,
                    blend: slot.parameters.blend,
                    overlayX: slot.parameters.overlayX,
                    overlayY: slot.parameters.overlayY
                )
            },
            isStackArmed: isStackArmed,
            rgbSplit: GVBroadcastRGBSplitState(
                isEnabled: rgbSplit.isEnabled,
                amount: rgbSplit.amount,
                angleDegrees: rgbSplit.angleDegrees,
                mix: rgbSplit.mix
            ),
            isRecording: isRecording,
            isAudioAvailable: isAudioAvailable
        )
    }
}
