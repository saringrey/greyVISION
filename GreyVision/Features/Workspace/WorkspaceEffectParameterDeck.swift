import SwiftUI

/// Effect-specific dials with power and close immediately available.
/// Secondary actions live in the tools menu so the preview keeps its space.
struct WorkspaceEffectParameterDeck: View {
    let effect: WorkspaceAdjustableEffect
    @ObservedObject var editor: EffectEditingSession
    let isFavorite: Bool
    let onFavoriteToggled: () -> Void
    let onClose: () -> Void

    @EnvironmentObject private var toasts: GVToastBox
    @EnvironmentObject private var cameraRuntime: CameraRuntime
    @GestureState private var pressingDatamosh = false
    @State private var showDatamoshMotion = false

    var body: some View {
        VStack(spacing: GVMetrics.gap) {
            headerRow
            sliderRow
            if effect == .datamosh { datamoshControls }
            if effect.isSpectrumOverlay {
                Text("Drag preview to place · Pinch to resize")
                    .font(.caption2)
                    .foregroundStyle(GVTheme.ash)
            }
        }
        .gvCompactDeckPlate()
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
            toolsMenu
            GVDeckChip(label: "", symbol: "xmark", accessibilityLabel: "Close effect parameters", height: 27, id: "close") {
                onClose()
            }
        }
    }

    private var effectTitle: some View {
        HStack(spacing: 6) {
            Text(effect.label.uppercased())
                .font(GVTheme.mono(13, .semibold))
                .tracking(0.8)
                .foregroundStyle(GVTheme.bone)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let position = renderPosition {
                Text("FX \(position)")
                    .font(GVTheme.mono(10, .medium))
                    .foregroundStyle(GVTheme.ash)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75))
                    .accessibilityLabel("Effect \(position) in the chain")
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

    private var toolsMenu: some View {
        Menu {
            Button(action: onFavoriteToggled) {
                Label(isFavorite ? "Remove favorite" : "Save favorite", systemImage: isFavorite ? "star.fill" : "star")
            }
            Button {
                editor.setStackArmed(!editor.isStackArmed)
            } label: {
                Label(editor.isStackArmed ? "Replace effects" : "Add effects to stack", systemImage: "plus")
            }
            Button {
                randomize()
                toasts.show("\(effect.label) randomized")
            } label: { Label("Shuffle parameters", systemImage: "shuffle") }
        } label: {
            // Drawn as a deck chip so the header's three actions read as one set.
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(GVTheme.bone.opacity(0.78))
                .frame(width: 31, height: 27)
                .background(Capsule(style: .continuous).fill(Color.white.opacity(0.05)))
                .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Effect tools")
        .accessibilityIdentifier("workspace.effect.tools")
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
                    format: effect == .datamosh ? { value in
                        control.label == "DIRECTION" ? "\(Int((value * 360 - 180).rounded()))°" : String(format: "%.2f%%", value * 100)
                    } : percentage
                ))
            }
        }
        return specs
    }

    private var datamoshControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(cameraRuntime.datamoshTransport.mode.rawValue.uppercased())
                    .font(GVTheme.mono(10, .semibold))
                    .foregroundStyle(GVTheme.ash)
                    .accessibilityIdentifier("datamosh.state")
                Spacer(minLength: 0)
                Text("HOLD")
                    .font(GVTheme.mono(12, .semibold))
                    .foregroundStyle(GVTheme.bone)
                    .frame(minWidth: 56, minHeight: 44)
                    .background(Capsule().fill(Color.white.opacity(cameraRuntime.datamoshTransport.mode == .hold ? 0.2 : 0.06)))
                    .gesture(DragGesture(minimumDistance: 0).updating($pressingDatamosh) { _, held, _ in held = true })
                    .onChange(of: pressingDatamosh) { _, held in
                        if held { cameraRuntime.sendDatamosh(.hold) }
                        else if cameraRuntime.datamoshTransport.mode == .hold { cameraRuntime.sendDatamosh(.release) }
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Hold datamosh source")
                    .accessibilityHint("Locks source pixels while the distortion keeps moving. Use Release to return to live input.")
                    .accessibilityAction { cameraRuntime.sendDatamosh(.hold) }
                    .accessibilityIdentifier("datamosh.hold")
                GVDeckChip(label: "RELEASE", height: 32, id: "datamosh.release") { cameraRuntime.sendDatamosh(.release) }
                GVDeckChip(label: "FREEZE", active: cameraRuntime.datamoshTransport.mode == .freeze, height: 32, id: "datamosh.freeze") { cameraRuntime.sendDatamosh(.freeze) }
                GVDeckChip(label: "RESET", height: 32, id: "datamosh.reset") { cameraRuntime.sendDatamosh(.reset) }
            }
            DisclosureGroup("Block motion", isExpanded: $showDatamoshMotion) {
                VStack(spacing: 8) {
                    Picker("Macroblock size", selection: Binding(
                        get: { currentParameters.datamoshBlockSize },
                        set: { size in var p = currentParameters; p.datamoshBlockSize = size; write(p) }
                    )) {
                        ForEach([8, 16, 32], id: \.self) { size in Text("\(size) × \(size)").tag(size) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("datamosh.blocks")
                    HStack {
                        GVParamRow(label: "DECAY", value: cameraParameterBinding(\.datamoshVelocityDecay),
                                   defaultValue: 0.18, range: 0 ... 1, format: percentage)
                        GVParamRow(label: "RESIDUAL", value: cameraParameterBinding(\.datamoshResidual),
                                   defaultValue: 0.0015, range: 0 ... 0.05,
                                   format: { String(format: "%.2f%%", $0 * 100) })
                    }
                }.padding(.top, 8)
            }
            .font(GVTheme.mono(11, .medium))
            .foregroundStyle(GVTheme.ash)
        }
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

            Text(label.uppercased())
                .font(GVTheme.mono(9.5, .medium))
                .tracking(0.6)
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
