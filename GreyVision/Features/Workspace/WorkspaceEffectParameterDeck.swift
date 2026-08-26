import SwiftUI

/// Parameter deck for one effect.
///
/// One flat register: a compact header row (power, favourite, stack arming,
/// hide-chrome, TOOLS, close) over a short list of full-width tuner rows.
/// An effect carries only a handful of parameters, so the old section tabs —
/// ALL / CORE / SPACE / ADV — were navigation for furniture and are gone.
///
/// The occasional actions (reset, randomize, clipboard, A/B store/recall,
/// fine mode) live behind TOOLS: one tap opens it, one tap fires an action
/// and the drawer closes itself, returning the operator straight to the rails.
///
/// STACK opens the render chain itself — see `WorkspaceEffectStackStrip`. The
/// model underneath has always been an ordered list of identified slots; until
/// that strip existed, none of the ordering, duplication or removal it
/// supports could be reached from the app.
struct WorkspaceEffectParameterDeck: View {
    let effect: WorkspaceAdjustableEffect
    @Binding var rgbSplitParameters: RGBSplitEffectParameters
    @Binding var effectStack: CameraEffectStackParameters
    let isStackArmed: Bool
    let onStackChanged: (Bool) -> Void
    let isFavorite: Bool
    let onFavoriteToggled: () -> Void
    let onHideChrome: () -> Void
    let onSelectEffect: (WorkspaceAdjustableEffect) -> Void
    let onClose: () -> Void

    @EnvironmentObject private var toasts: GVToastBox

    @State private var fineMode = false
    @State private var showTools = false
    @State private var showStack = false
    /// Which stack slot this deck is editing. Nil means "the first slot for
    /// this effect", which is what every call site meant before slots could
    /// be duplicated.
    @State private var focusedSlot: CameraEffectStackParameters.Slot.ID?

    var body: some View {
        VStack(spacing: 7) {
            headerRow

            if showStack {
                WorkspaceEffectStackStrip(
                    effectStack: $effectStack,
                    rgbSplitParameters: $rgbSplitParameters,
                    editing: effect,
                    focusedSlot: $focusedSlot,
                    onSelect: onSelectEffect
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if showTools {
                toolsPanel
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            sliderRow
        }
        .gvCompactDeckPlate()
        .animation(GVMotion.micro, value: fineMode)
        .animation(GVMotion.micro, value: showTools)
        .animation(GVMotion.panel, value: showStack)
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
        if let focusedSlot,
           let slot = effectStack.slot(focusedSlot),
           slot.effect == effect
        {
            return focusedSlot
        }
        return effectStack.firstSlotID(for: effect)
    }

    /// Where this effect sits in the render chain, or nil when it is not
    /// placed. Shown in the header because "which of these runs first" is the
    /// question a stacked chain raises immediately and nothing answered.
    private var renderPosition: Int? {
        editedSlot.flatMap { effectStack.renderPosition(of: $0) }
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            GVTerminalText(
                text: renderPosition.map { "FX.\(String(format: "%02d", $0)) // \(effect.label)" }
                    ?? "FX.PARAM // \(effect.label)",
                size: GVMetrics.textBody,
                weight: .black,
                tracking: 1.1,
                alignment: .leading,
                intensity: 1.15
            )

            Spacer(minLength: 8)

            GVDeckChip(label: "", symbol: "power", active: isEffectEnabled, tint: .white, height: 27, id: "power") {
                toggleEffectEnabled()
            }
            GVDeckChip(
                label: "",
                symbol: isFavorite ? "star.fill" : "star",
                active: isFavorite,
                tint: .white,
                height: 27,
                id: "favorite"
            ) {
                onFavoriteToggled()
            }
            // Was an ambiguous icon called STACK. The behaviour is arming
            // ADD-TO-STACK for the next selection, so it says that.
            GVDeckChip(label: isStackArmed ? "ADD\u{2713}" : "ADD", active: isStackArmed, tint: .white, height: 27, id: "addmode") {
                onStackChanged(!isStackArmed)
            }
            GVDeckChip(label: "", symbol: "eye.slash", height: 27, id: "hidechrome") {
                onHideChrome()
            }
            GVDeckChip(
                label: "",
                symbol: "square.3.layers.3d",
                active: showStack,
                tint: .white,
                height: 27,
                id: "stack"
            ) {
                withAnimation(GVMotion.panel) { showStack.toggle() }
            }
            .accessibilityLabel("Render stack")
            .accessibilityValue(showStack ? "open" : "closed")
            GVDeckChip(
                label: "TOOLS",
                symbol: "slider.horizontal.3",
                active: showTools,
                tint: .white,
                height: 27,
                id: "tools"
            ) {
                withAnimation(GVMotion.micro) { showTools.toggle() }
            }
            .accessibilityValue(showTools ? "open" : "closed")
            GVDeckChip(label: "", symbol: "xmark", height: 27, id: "close") {
                onClose()
            }
        }
    }

    // MARK: - Tools drawer

    private var toolsPanel: some View {
        VStack(spacing: 6) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
                spacing: 6
            ) {
                toolButton("RESET", id: "reset") {
                    reset()
                    toasts.show("FX // \(effect.label) RESET TO DEFAULTS")
                }
                toolButton("RANDOM", id: "random") {
                    randomize()
                    toasts.show("FX // \(effect.label) RANDOMIZED")
                }
                toolButton("COPY", id: "copy") {
                    copySettings()
                }
                toolButton("PASTE", id: "paste", dimmed: !EffectClipboard.hasContent) {
                    pasteSettings()
                }
                toolButton("ST.A", id: "storea") {
                    storeSnapshot(.a)
                    toasts.show("FX // STORED SLOT A")
                }
                toolButton("ST.B", id: "storeb") {
                    storeSnapshot(.b)
                    toasts.show("FX // STORED SLOT B")
                }
                toolButton("A", id: "recalla", dimmed: !ABSlots.has(effect.rawValue, .a)) {
                    recallSnapshot(.a)
                }
                toolButton("B", id: "recallb", dimmed: !ABSlots.has(effect.rawValue, .b)) {
                    recallSnapshot(.b)
                }
            }

            Button {
                fineMode.toggle()
                toasts.show(fineMode ? "DRAG // FINE 0.25X" : "DRAG // COARSE")
            } label: {
                HStack {
                    Text("FINE DRAG")
                        .gvMono(GVMetrics.textSmall, .black)
                        .tracking(1.0)
                    Spacer(minLength: 0)
                    Text(fineMode ? "0.25\u{00D7} ON" : "\u{00D7}1.00 OFF")
                        .gvMono(GVMetrics.textSmall, .bold)
                        .tracking(0.8)
                        .foregroundStyle(fineMode ? Color.white : GVTheme.bone.opacity(0.55))
                }
                .foregroundStyle(fineMode ? Color.white : GVTheme.bone.opacity(0.78))
                .shadow(color: fineMode ? .white.opacity(0.45) : .clear, radius: 3)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(fineMode ? Color.white.opacity(0.13) : Color(white: 0.135))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(
                                    fineMode ? Color.white.opacity(0.85) : Color.white.opacity(0.09),
                                    lineWidth: fineMode ? 1.1 : 0.8
                                )
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(GVPressStyle())
            .accessibilityIdentifier("workspace.chip.fine")
            .accessibilityValue(fineMode ? "on" : "off")
        }
        .padding(.top, 1)
    }

    /// Fires the action, then closes the drawer so the thumb lands back on
    /// the rails it came here to drive. FINE is the exception — it stays
    /// open because its state is the point.
    private func toolButton(_ label: String, id: String, dimmed: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            action()
            withAnimation(GVMotion.micro) { showTools = false }
        } label: {
            Text(label)
                .gvMono(GVMetrics.textSmall, .black)
                .tracking(0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(Color.white.opacity(dimmed ? 0.30 : 0.85))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.white.opacity(dimmed ? 0.04 : 0.12), lineWidth: 0.8)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        .disabled(dimmed)
        .accessibilityLabel(label)
        .accessibilityIdentifier("workspace.chip.\(id)")
    }

    // MARK: - Parameters

    /// One bank of dials on a single row: each parameter is its own column —
    /// value over knob over label. An effect never carries more than four
    /// parameters, so the whole bank fits across the deck and the popup stays
    /// two rows tall instead of unrolling into a list.
    private var sliderRow: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(allSpecs) { spec in
                GVParamRow(
                    label: spec.label,
                    value: spec.value,
                    defaultValue: spec.defaultValue,
                    range: spec.range,
                    format: spec.format,
                    fine: fineMode
                )
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("workspace.param.\(spec.id.lowercased())")
            }
        }
        .padding(.vertical, 2)
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
                value: $rgbSplitParameters.amount,
                defaultValue: RGBSplitEffectParameters.activeDefaults.amount,
                range: 0...0.08,
                format: { String(format: "%.1f%%", $0 * 100) }
            ))
            specs.append(ParamSpec(
                id: "ANGLE", label: "ANGLE",
                value: $rgbSplitParameters.angleDegrees,
                defaultValue: RGBSplitEffectParameters.activeDefaults.angleDegrees,
                range: -180...180,
                format: { "\(Int($0.rounded()))\u{00B0}" }
            ))
            specs.append(ParamSpec(
                id: "MIX", label: "MIX",
                value: $rgbSplitParameters.mix,
                defaultValue: RGBSplitEffectParameters.activeDefaults.mix,
                range: 0...1,
                format: percentage
            ))
        default:
            let labels = effect.parameterLabels
            let defaults = effect.defaultCameraParameters
            let channels: [(String, WritableKeyPath<CameraEffectParameters, Double>)] = [
                ("primary", \.primary),
                ("secondary", \.secondary),
                ("tertiary", \.tertiary)
            ]
            for (index, channel) in channels.enumerated() where index < labels.count {
                let label = labels[index]
                specs.append(ParamSpec(
                    id: label, label: label,
                    value: cameraParameterBinding(channel.1),
                    defaultValue: defaults[keyPath: channel.1],
                    range: 0...1,
                    format: percentage
                ))
            }
            specs.append(ParamSpec(
                id: "BLEND", label: "BLEND",
                value: cameraParameterBinding(\.blend),
                defaultValue: defaults.blend,
                range: 0...1,
                format: percentage
            ))
        }
        return specs
    }

    private var isEffectEnabled: Bool {
        switch effect {
        case .rgbSplit: return rgbSplitParameters.isEnabled
        default: return currentParameters.isEnabled
        }
    }

    private func toggleEffectEnabled() {
        setEnabled(!isEffectEnabled)
    }

    private func setEnabled(_ enabled: Bool) {
        switch effect {
        case .rgbSplit:
            rgbSplitParameters.isEnabled = enabled
        default:
            if let editedSlot, effectStack.slot(editedSlot) != nil {
                effectStack.setEnabled(enabled, slot: editedSlot)
            } else {
                effectStack.setEnabled(enabled, for: effect)
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
        if let editedSlot, let parameters = effectStack[slot: editedSlot] {
            return parameters
        }
        return effectStack[effect]
    }

    /// Writes to the focused slot when there is one, and falls back to the
    /// effect-keyed subscript when the effect has not been placed yet — that
    /// path is what creates the slot in the first place.
    private func write(_ parameters: CameraEffectParameters) {
        if let editedSlot, effectStack.slot(editedSlot) != nil {
            effectStack[slot: editedSlot] = parameters
        } else {
            effectStack[effect] = parameters
        }
    }

    private func percentage(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    // MARK: - Tools

    private func reset() {
        switch effect {
        case .rgbSplit:
            rgbSplitParameters = .activeDefaults
        default:
            if let editedSlot, effectStack.slot(editedSlot) != nil {
                effectStack.reset(slot: editedSlot)
            } else {
                effectStack.reset(effect)
            }
        }
    }

    private func randomize() {
        for spec in allSpecs {
            var lower = spec.range.lowerBound
            // Blend floors itself so a randomized effect cannot land at zero
            // presence and look like nothing happened.
            if spec.id == "BLEND" || spec.label == "MIX" {
                lower = max(lower, 0.3)
            }
            spec.value.wrappedValue = Double.random(in: lower...spec.range.upperBound)
        }
        setEnabled(true)
    }

    private func currentValues() -> [Double] {
        allSpecs.map { $0.value.wrappedValue }
    }

    private func applyValues(_ values: [Double]) {
        let specs = allSpecs
        for (index, spec) in specs.enumerated() where index < values.count {
            spec.value.wrappedValue = min(max(values[index], spec.range.lowerBound), spec.range.upperBound)
        }
        setEnabled(true)
    }

    private func copySettings() {
        EffectClipboard.store(values: currentValues(), source: effect.rawValue)
        toasts.show("COPIED // \(effect.label)")
    }

    private func pasteSettings() {
        guard let payload = EffectClipboard.payload else {
            toasts.show("CLIPBOARD EMPTY")
            return
        }
        applyValues(payload.values)
        toasts.show("PASTED // FROM \(payload.source.uppercased())")
    }

    private func storeSnapshot(_ slot: GVSnapshotSlot) {
        ABSlots.store(values: currentValues(), effect: effect.rawValue, slot: slot)
    }

    private func recallSnapshot(_ slot: GVSnapshotSlot) {
        guard let values = ABSlots.values(effect: effect.rawValue, slot: slot) else {
            toasts.show("SLOT \(slot == .a ? "A" : "B") EMPTY")
            return
        }
        applyValues(values)
        toasts.show("RECALLED \(slot == .a ? "A" : "B")")
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
private struct GVParamRow: View {
    let label: String
    @Binding var value: Double
    let defaultValue: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    var fine: Bool = false

    @State private var dragStart: Double?
    @State private var isDragging = false
    @State private var lastTickBucket: Int = -1
    @State private var wasAboveDefault: Bool?
    /// Live precision divisor, so the readout can say what the finger is
    /// currently buying without the caller having to recompute the curve.
    @State private var precision: Double = 1

    @MainActor private static let tickGenerator = UIImpactFeedbackGenerator(style: .soft)
    @MainActor private static let detentGenerator = UIImpactFeedbackGenerator(style: .rigid)

    /// Horizontal travel that carries the value across its whole range.
    private static let travel: CGFloat = 200

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
        VStack(spacing: 5) {
            Text(readout)
                .gvMono(GVMetrics.textSmall, .black)
                .tracking(0.3)
                .monospacedDigit()
                .foregroundStyle(isDragging ? Color.white : GVTheme.bone.opacity(0.72))
                .shadow(color: isDragging ? .white.opacity(0.4) : .clear, radius: 3)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            knob

            Text(label)
                .gvMono(GVMetrics.textMicro, .bold)
                .tracking(0.6)
                .foregroundStyle(isDragging ? Color.white.opacity(0.9) : GVTheme.ash)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .padding(.horizontal, 2)
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isDragging ? Color.white.opacity(0.05) : Color.clear)
        )
        .onTapGesture(count: 2) {
            value = defaultValue
        }
        .animation(GVMotion.micro, value: isDragging)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
        .accessibilityAddTraits(defaultValue == value ? [] : [.updatesFrequently])
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
                .frame(width: 1.2, height: 5)
                .offset(y: -20)
                .rotationEffect(.degrees(defaultDetentAngle))

            // Pointer.
            Rectangle()
                .fill(Color.white)
                .frame(width: 1.6, height: 11)
                .offset(y: -10)
                .rotationEffect(.degrees(pointerAngle))
                .shadow(color: .white.opacity(isDragging ? 0.6 : 0.25), radius: isDragging ? 3 : 1.5)
        }
        .frame(width: 44, height: 44)
        // The hit target extends well past the drawn dial so the thumb lands
        // on it without aiming.
        .frame(width: 64, height: 56)
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
                precision = divisor * (fine ? 4 : 1)
                let sensitivity = span / (Double(Self.travel) * precision)
                let moved = Double(gesture.translation.width) * sensitivity
                value = min(max(start + moved, range.lowerBound), range.upperBound)

                let bucket = Int(fraction * 10)
                if bucket != lastTickBucket {
                    lastTickBucket = bucket
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
                isDragging = false
                dragStart = nil
                lastTickBucket = -1
                wasAboveDefault = nil
                precision = 1
            }
    }
}

// MARK: - Session-wide clipboard and A/B storage

/// Clipboard survives effect switches — the whole point of COPY is carrying
/// settings onto another effect. MainActor-isolated because it is UI state.
@MainActor
private final class EffectClipboard {
    static var payload: (values: [Double], source: String)?

    static var hasContent: Bool { payload != nil }

    static func store(values: [Double], source: String) {
        payload = (values, source)
    }
}

/// Per-effect A/B snapshots, keyed by effect raw value so they persist while
/// the operator browses between effects mid-session.
@MainActor
final class ABSlots {
    static var slots: [String: (a: [Double]?, b: [Double]?)] = [:]

    static func has(_ effect: String, _ slot: GVSnapshotSlot) -> Bool {
        values(effect: effect, slot: slot) != nil
    }

    static func values(effect: String, slot: GVSnapshotSlot) -> [Double]? {
        let pair = slots[effect]
        switch slot {
        case .a: return pair?.a
        case .b: return pair?.b
        }
    }

    static func store(values: [Double], effect: String, slot: GVSnapshotSlot) {
        var pair = slots[effect] ?? (nil, nil)
        switch slot {
        case .a: pair.a = values
        case .b: pair.b = values
        }
        slots[effect] = pair
    }
}

/// Snapshot slot for A/B pairs. File-scope so future decks can share the same
/// snapshot machinery without re-declaring it.
enum GVSnapshotSlot {
    case a
    case b
}
