import SwiftUI

/// Parameter deck for one effect.
///
/// One flat register: a compact header row (power, favourite, stack arming,
/// render stack, random, close) over a short list of full-width
/// tuner rows. An effect carries only a handful of parameters, so the old
/// section tabs — ALL / CORE / SPACE / ADV — were navigation for furniture
/// and are gone.
///
/// RANDOM is the one operation that earns a permanent chip on the header:
/// re-roll the parameters to a fresh starting point, then keep tuning. The
/// rest of what used to live behind TOOLS (reset, clipboard, A/B, fine
/// mode) was six buttons competing for a thumb — most of it is reachable
/// from the deck's own gestures (double-tap a parameter to reset, hold for
/// fine), and the rest is in the stack strip.
///
/// STACK opens the render chain itself — see `WorkspaceEffectStackStrip`. The
/// model underneath has always been an ordered list of identified slots; until
/// that strip existed, none of the ordering or removal it supports could be
/// reached from the app.
struct WorkspaceEffectParameterDeck: View {
    let effect: WorkspaceAdjustableEffect
    @ObservedObject var editor: EffectEditingSession
    let isFavorite: Bool
    let onFavoriteToggled: () -> Void
    let onSelectEffect: (WorkspaceAdjustableEffect) -> Void
    let onClose: () -> Void

    @EnvironmentObject private var toasts: GVToastBox
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showStack = false
    /// Which stack slot this deck is editing. Nil means "the first slot for
    /// this effect", which is what every call site meant before slots could
    /// be duplicated.
    var body: some View {
        VStack(spacing: GVMetrics.gap) {
            headerRow
            sliderRow
            utilityFooter

            if showStack {
                WorkspaceEffectStackStrip(
                    editor: editor,
                    editing: effect,
                    onSelect: onSelectEffect
                )
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .gvCompactDeckPlate()
        .animation(GVMotion.resolved(GVMotion.panel, reduceMotion: reduceMotion), value: showStack)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.parameters.\(effect.rawValue)")
    }

    // MARK: - Header

    /// The slot this deck edits: the one focused in the strip when it carries
    /// this effect, otherwise the first slot placed for it.
    ///
    /// Everything below goes through this rather than through the effect-keyed
    /// subscript, which always resolves to slot one — so a duplicated node
    /// would otherwise be un-editable and DUP would produce a copy nothing
    /// could tell apart.
    private var editedSlot: CameraEffectStackParameters.Slot.ID? {
        if let focusedSlot = editor.focusedSlot,
           let slot = editor.effectStack.slot(focusedSlot),
           slot.effect == effect
        {
            return focusedSlot
        }
        return editor.effectStack.firstSlotID(for: effect)
    }

    /// Where this effect sits in the render chain, or nil when it is not
    /// placed. Shown in the header because "which of these runs first" is the
    /// question a stacked chain raises immediately and nothing answered.
    private var renderPosition: Int? {
        editedSlot.flatMap { editor.effectStack.renderPosition(of: $0) }
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            if EffectCatalog.variants(for: effect).count > 1 {
                Menu {
                    ForEach(EffectCatalog.variants(for: effect)) { variant in
                        Button {
                            editor.changeVariant(to: variant)
                        } label: {
                            Label(variant.label, systemImage: variant == effect ? "checkmark" : "circle")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        effectTitle
                        Image(systemName: "chevron.down")
                            .font(.system(size: GVMetrics.textMicro, weight: .bold))
                    }
                    .foregroundStyle(GVTheme.bone)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("\(EffectCatalog.canonical(effect).label) variant")
                .accessibilityValue(effect.label)
                .accessibilityIdentifier("workspace.effect.variant")
            } else {
                effectTitle
            }

            Spacer(minLength: 8)

            GVDeckChip(label: "", symbol: "power", accessibilityLabel: isEffectEnabled ? "Disable effect" : "Enable effect", active: isEffectEnabled, tint: .white, height: 27, id: "power") {
                toggleEffectEnabled()
            }
            GVDeckChip(label: "", symbol: "xmark", accessibilityLabel: "Close effect parameters", height: 27, id: "close") {
                onClose()
            }
        }
    }

    private var effectTitle: some View {
        HStack(spacing: 6) {
            Text(effect.label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(GVTheme.bone)
                .lineLimit(1)
            if let position = renderPosition {
                Text("· Effect \(position)")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(GVTheme.ash)
            }
        }
    }

    // MARK: - Parameters

    /// Every adjustable value stays in this single, compact pane. Effects have
    /// no more than four parameters, so paging would hide a control the
    /// operator needs while tuning.
    private var sliderRow: some View {
        HStack(alignment: .top, spacing: 2) {
            ForEach(allSpecs) { spec in
                GVParamRow(
                    label: spec.label,
                    value: spec.value,
                    defaultValue: spec.defaultValue,
                    range: spec.range,
                    format: spec.format,
                    onEditingChanged: { editing in
                        if editing {
                            editor.beginContinuousEdit()
                        } else {
                            editor.endContinuousEdit()
                        }
                    }
                )
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 2)
    }

    private var utilityFooter: some View {
        VStack(spacing: 3) {
            if effect.isSpectrumOverlay {
                Text("Drag preview to place · Pinch to resize")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(GVTheme.ash)
                    .accessibilityLabel("Drag preview to place spectrum overlay. Pinch preview to resize.")
            }
            HStack(spacing: 6) {
                GVDeckChip(
                    label: "",
                    symbol: isFavorite ? "star.fill" : "star",
                    accessibilityLabel: isFavorite ? "Remove from favorites" : "Add to favorites",
                    active: isFavorite,
                    tint: .white,
                    height: 27,
                    id: "favorite"
                ) { onFavoriteToggled() }
                GVDeckChip(label: editor.isStackArmed ? "Add ✓" : "Add", active: editor.isStackArmed, tint: .white, height: 27, id: "addmode") {
                    editor.setStackArmed(!editor.isStackArmed)
                }
                GVDeckChip(label: "Stack", symbol: "square.3.layers.3d", active: showStack, tint: .white, height: 27, id: "stack") {
                    withAnimation(GVMotion.resolved(GVMotion.panel, reduceMotion: reduceMotion)) {
                        showStack.toggle()
                    }
                }
                GVDeckChip(label: "Shuffle", symbol: "die.face.5", tint: .white, height: 27, id: "random") {
                    randomize()
                    toasts.show("\(effect.label) randomized")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Parameter model

    private struct ParamSpec: Identifiable {
        let id: String
        let label: String
        let value: Binding<Double>
        let defaultValue: Double
        let range: ClosedRange<Double>
        let format: (Double) -> String
    }

    private var allSpecs: [ParamSpec] {
        var specs: [ParamSpec] = []
        switch effect {
        case .rgbSplit:
            specs.append(ParamSpec(
                id: "OFFSET", label: "OFFSET",
                value: Binding(
                    get: { editor.rgbSplitParameters.amount },
                    set: { editor.rgbSplitParameters.amount = $0 }
                ),
                defaultValue: RGBSplitEffectParameters.activeDefaults.amount,
                range: 0 ... 0.08,
                format: { String(format: "%.1f%%", $0 * 100) }
            ))
            specs.append(ParamSpec(
                id: "ANGLE", label: "ANGLE",
                value: Binding(
                    get: { editor.rgbSplitParameters.angleDegrees },
                    set: { editor.rgbSplitParameters.angleDegrees = $0 }
                ),
                defaultValue: RGBSplitEffectParameters.activeDefaults.angleDegrees,
                range: -180 ... 180,
                format: { "\(Int($0.rounded()))\u{00B0}" }
            ))
            specs.append(ParamSpec(
                id: "MIX", label: "MIX",
                value: Binding(
                    get: { editor.rgbSplitParameters.mix },
                    set: { editor.rgbSplitParameters.mix = $0 }
                ),
                defaultValue: RGBSplitEffectParameters.activeDefaults.mix,
                range: 0 ... 1,
                format: percentage
            ))
        default:
            for control in EffectCatalog.controls(for: effect) {
                specs.append(ParamSpec(
                    id: control.label, label: control.label,
                    value: cameraParameterBinding(control.keyPath),
                    defaultValue: control.defaultValue,
                    range: control.range,
                    format: percentage
                ))
            }
        }
        return specs
    }

    private var isEffectEnabled: Bool {
        switch effect {
        case .rgbSplit: return editor.rgbSplitParameters.isEnabled
        default: return currentParameters.isEnabled
        }
    }

    private func toggleEffectEnabled() {
        setEnabled(!isEffectEnabled)
    }

    private func setEnabled(_ enabled: Bool) {
        switch effect {
        case .rgbSplit:
            editor.rgbSplitParameters.isEnabled = enabled
        default:
            if let editedSlot, editor.effectStack.slot(editedSlot) != nil {
                editor.effectStack.setEnabled(enabled, slot: editedSlot)
            } else {
                editor.effectStack.setEnabled(enabled, for: effect)
            }
        }
    }

    private func cameraParameterBinding(_ keyPath: WritableKeyPath<CameraEffectParameters, Double>) -> Binding<Double> {
        Binding(
            get: { currentParameters[keyPath: keyPath] },
            set: { newValue in
                var parameters = currentParameters
                parameters[keyPath: keyPath] = newValue
                write(parameters)
            }
        )
    }

    private var currentParameters: CameraEffectParameters {
        if let editedSlot, let parameters = editor.effectStack[slot: editedSlot] {
            return parameters
        }
        return editor.effectStack[effect]
    }

    /// Writes to the focused slot when there is one, and falls back to the
    /// effect-keyed subscript when the effect has not been placed yet — that
    /// path is what creates the slot in the first place.
    private func write(_ parameters: CameraEffectParameters) {
        if let editedSlot, editor.effectStack.slot(editedSlot) != nil {
            editor.effectStack[slot: editedSlot] = parameters
        } else {
            editor.effectStack[effect] = parameters
        }
    }

    private func percentage(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    // MARK: - Random

    private func randomize() {
        for spec in allSpecs {
            var lower = spec.range.lowerBound
            // Blend floors itself so a randomized effect cannot land at zero
            // presence and look like nothing happened.
            if spec.id == "BLEND" || spec.label == "MIX" {
                lower = max(lower, 0.3)
            }
            spec.value.wrappedValue = Double.random(in: lower ... spec.range.upperBound)
        }
        setEnabled(true)
    }
}

// MARK: - Session-wide clipboard and A/B storage

/// One parameter as a single dial column: live value on top in fixed-width
/// digits, the knob beneath it, its name under that. Columns share one row,
/// so four parameters cost the height of one.
///
/// The gesture is relative, not positional — touch the dial (a generous hit
/// target around the 46pt circle), hold, and slide the finger left or right.
/// Where the finger lands does not matter; travel is what drives the value.
/// FINE quarter-speed, default detent notch, double-tap reset and haptic
/// ticks per 10% all carry over from the row sliders this replaced.
struct GVParamRow: View {
    let label: String
    @Binding var value: Double
    let defaultValue: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    /// Fires once when a drag starts and once when it ends, so the caller can
    /// bracket the whole scrub as a single undo step instead of recording one
    /// per frame.
    var onEditingChanged: ((Bool) -> Void)?

    @State private var dragStart: Double?
    @State private var isDragging = false
    @State private var lastTickBucket: Int = -1
    @State private var wasAboveDefault: Bool?
    /// Distance the finger has travelled since the last tick. Haptics are
    /// driven by this rather than by value buckets, so a long-range dial
    /// no longer fires ten times for a nudge and a small-range dial is not
    /// silent.
    @State private var distanceSinceLastTick: CGFloat = 0
    @State private var tickInstant: Date?
    @State private var lastDragTranslation: CGFloat = 0
    /// Live precision divisor, so the readout can say what the finger is
    /// currently buying without the caller having to recompute the curve.
    @State private var precision: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @MainActor private static let tickGenerator = UIImpactFeedbackGenerator(style: .soft)
    @MainActor private static let detentGenerator = UIImpactFeedbackGenerator(style: .rigid)

    /// Horizontal travel that carries the value across its whole range.
    private static let travel: CGFloat = 200

    /// Finger travel, in points, that earns one tick.
    ///
    /// Small enough to feel continuous on a normal drag, large enough that a
    /// jittery finger does not produce a buzz.
    private static let tickTravelPoints: CGFloat = 14
    /// Floor on the gap between two ticks, in seconds.
    private static let tickInterval: TimeInterval = 0.028

    /// Vertical distance, in points, that buys one further step of precision.
    ///
    /// Pulling away from the dial while dragging is the hardware convention
    /// for a fine adjust, and it is continuous — the operator does not have to
    /// decide up front whether this edit needs the FINE toggle, which is the
    /// one thing a mode switch always gets wrong.
    private static let precisionSpan: CGFloat = 70

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    /// The value, or the value and the precision divisor once the finger has
    /// pulled far enough away for it to matter. Showing it is what makes the
    /// gesture discoverable — otherwise a drag that suddenly moves less reads
    /// as a dropped touch.
    private var readout: String {
        guard isDragging, precision >= 1.6 else { return format(value) }
        return "\(format(value)) \u{00F7}\(Int(precision.rounded()))"
    }

    private var isAtDefault: Bool {
        abs(value - defaultValue) < (range.upperBound - range.lowerBound) * 0.004
    }

    /// The dial reads from 135° (7 o'clock) clockwise through 405° — a 270°
    /// sweep with open mouths at the bottom, like every hardware knob.
    private var pointerAngle: Double {
        -135 + fraction * 270
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(readout)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(isDragging ? Color.white : GVTheme.bone.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            knob

            Text(label.capitalized)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(isDragging ? Color.white.opacity(0.9) : GVTheme.ash)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 2)
        }
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isDragging ? Color.white.opacity(0.05) : Color.clear)
        )
        .onTapGesture(count: 2) {
            value = defaultValue
            GVInteractionHaptics.commit()
        }
        .animation(GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion), value: isDragging)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
        .accessibilityAddTraits(isAtDefault ? [] : [.updatesFrequently])
        .accessibilityAction(named: "Reset to default") {
            value = defaultValue
            GVInteractionHaptics.commit()
        }
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) * 0.05
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
        }
    }

    // MARK: - Dial

    private var knob: some View {
        ZStack {
            // Body.
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(white: isDragging ? 0.24 : 0.18), Color(white: 0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(Circle().strokeBorder(Color.white.opacity(isDragging ? 0.38 : 0.14), lineWidth: 1))

            // Level arc, sweeping clockwise from the 135° origin.
            Circle()
                .trim(from: 0, to: max(fraction * 0.75, fraction > 0 ? 0.005 : 0))
                .stroke(
                    Color.white.opacity(0.92),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
                )
                .rotationEffect(.degrees(135))

            // Default detent notch, at the angle double-tap restores.
            Rectangle()
                .fill(Color.white.opacity(isAtDefault ? 0.85 : 0.22))
                .frame(width: 1.2, height: 4)
                .offset(y: -16)
                .rotationEffect(.degrees(defaultDetentAngle))

            // Pointer.
            Rectangle()
                .fill(Color.white)
                .frame(width: 1.5, height: 9)
                .offset(y: -8)
                .rotationEffect(.degrees(pointerAngle))
                .shadow(color: .white.opacity(isDragging ? 0.6 : 0.25), radius: isDragging ? 3 : 1.5)
        }
        .frame(width: 36, height: 36)
        // The hit target extends well past the drawn dial so the thumb lands
        // on it without aiming.
        .frame(width: 54, height: 46)
        .contentShape(Rectangle())
        .gesture(dragGesture)
    }

    private var defaultDetentAngle: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return -135 }
        let defaultFraction = min(max((defaultValue - range.lowerBound) / span, 0), 1)
        return -135 + defaultFraction * 270
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if !isDragging {
                    Self.tickGenerator.prepare()
                    Self.detentGenerator.prepare()
                    wasAboveDefault = value >= defaultValue
                    distanceSinceLastTick = 0
                    tickInstant = .now
                    onEditingChanged?(true)
                }
                isDragging = true
                let start = dragStart ?? value
                if dragStart == nil { dragStart = value }
                let span = range.upperBound - range.lowerBound

                // Vertical distance from the dial divides the travel. Capped
                // at sixteen so a stray flick down the screen cannot make the
                // control feel dead.
                let pulled = abs(gesture.translation.height)
                let divisor = min(1 + Double(pulled / Self.precisionSpan) * 3, 16)
                precision = divisor
                let sensitivity = span / (Double(Self.travel) * precision)
                let moved = Double(gesture.translation.width) * sensitivity
                value = min(max(start + moved, range.lowerBound), range.upperBound)

                // Ticks are driven by how far the finger has actually moved
                // since the last one, and rate-limited in time.
                //
                // The old test was a value bucket — one impact per tenth of
                // the range — so a nudge across a 0…1 dial produced ten
                // haptics and a small-range dial produced a different
                // number again, neither of which matched the finger. Travel
                // distance is what the hand feels, and the interval floor
                // keeps a fast drag from buzzing.
                distanceSinceLastTick += abs(gesture.translation.width - lastDragTranslation)
                lastDragTranslation = gesture.translation.width
                let now = Date.now
                let elapsed = tickInstant.map { now.timeIntervalSince($0) } ?? 0
                if distanceSinceLastTick >= Self.tickTravelPoints, elapsed >= Self.tickInterval {
                    distanceSinceLastTick = 0
                    tickInstant = now
                    lastTickBucket = Int(fraction * 10)
                    Self.tickGenerator.impactOccurred(intensity: 0.32)
                }
                // A firmer tick exactly on the default, so the detent drawn on
                // the dial can be found without looking at it.
                let above = value >= defaultValue
                if let previous = wasAboveDefault, previous != above {
                    Self.detentGenerator.impactOccurred(intensity: 0.62)
                }
                wasAboveDefault = above
            }
            .onEnded { _ in
                guard isDragging else { return }
                isDragging = false
                dragStart = nil
                lastTickBucket = -1
                wasAboveDefault = nil
                precision = 1
                distanceSinceLastTick = 0
                lastDragTranslation = 0
                tickInstant = nil
                onEditingChanged?(false)
            }
    }
}

// MARK: - Session-wide clipboard and A/B storage

//
// The clipboard and A/B stores were part of the old TOOLS drawer. Removed
// alongside the drawer; the gestures they served (copy/paste/store/recall)
// have no surface in the streamlined deck and only the clipboard/snapshot
// symbols remain for any future restoration.
