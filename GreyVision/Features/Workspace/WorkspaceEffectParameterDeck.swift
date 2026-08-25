import SwiftUI

/// Parameter deck for one effect.
///
/// The deck keeps every capability the old dense version had — power,
/// favourite, stack arming, hide-chrome, close, per-parameter drag, double-tap
/// reset, section filtering, RANDOMIZE, COPY/PASTE, per-effect A/B snapshots
/// and FINE adjust — but splits it into two visual registers:
///
///  • The always-visible spine: header, section tabs and the slider rail.
///    These are the controls every adjustment touches, so they are large.
///  • A TOOLS drawer holding the occasional actions (reset, randomize,
///    clipboard, A/B store/recall, fine mode). One tap opens it, one tap
///    fires an action and the drawer closes itself, returning the operator
///    straight to the rails.
struct WorkspaceEffectParameterDeck: View {
    let effect: WorkspaceAdjustableEffect
    @Binding var rgbSplitParameters: RGBSplitEffectParameters
    @Binding var effectStack: CameraEffectStackParameters
    let isStackArmed: Bool
    let onStackChanged: (Bool) -> Void
    let isFavorite: Bool
    let onFavoriteToggled: () -> Void
    let onHideChrome: () -> Void
    let onClose: () -> Void

    @EnvironmentObject private var toasts: GVToastBox

    @State private var sectionFilter: ParamSection = .all
    @State private var fineMode = false
    @State private var showTools = false

    var body: some View {
        VStack(spacing: 7) {
            headerRow
            filterRow

            if showTools {
                toolsPanel
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            sliderRow
        }
        .gvCompactDeckPlate()
        .animation(GVMotion.micro, value: fineMode)
        .animation(GVMotion.micro, value: showTools)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.parameters.\(effect.rawValue)")
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 6) {
            GVTerminalText(
                text: "FX.PARAM // \(effect.label)",
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
            GVDeckChip(label: "", symbol: "xmark", height: 27, id: "close") {
                onClose()
            }
        }
    }

    // MARK: - Section tabs + tools toggle

    /// Sections are the only always-visible navigation, so they get real
    /// tabs rather than another row of micro-chips. The rare actions live
    /// behind TOOLS instead of competing with them for space.
    private var filterRow: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(presentSections) { section in
                        sectionTab(section)
                    }
                }
                .padding(.vertical, 1)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .gvHorizontalEdgeFade()

            GVDeckChip(
                label: "TOOLS",
                symbol: "slider.horizontal.3",
                active: showTools,
                tint: .white,
                height: 30,
                id: "tools"
            ) {
                withAnimation(GVMotion.micro) { showTools.toggle() }
            }
            .accessibilityValue(showTools ? "open" : "closed")
        }
    }

    private func sectionTab(_ section: ParamSection) -> some View {
        let selected = sectionFilter == section
        return Button {
            withAnimation(GVMotion.scan) { sectionFilter = section }
        } label: {
            Text(section == .all ? "ALL" : section.label)
                .gvMono(GVMetrics.textSmall, .black)
                .tracking(0.9)
                .foregroundStyle(selected ? Color.white : GVTheme.bone.opacity(0.72))
                .shadow(color: selected ? .white.opacity(0.45) : .clear, radius: 3)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.white.opacity(0.15) : Color(white: 0.155))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(
                                    selected ? Color.white.opacity(0.85) : Color.white.opacity(0.09),
                                    lineWidth: selected ? 1.1 : 0.8
                                )
                        )
                        .shadow(color: selected ? .white.opacity(0.25) : .clear, radius: 5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        .accessibilityIdentifier("workspace.chip.filter.\(section.rawValue)")
        .accessibilityValue(selected ? "on" : "off")
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

    /// Full-width tuner rows instead of a cramped rail of mini sliders: every
    /// parameter gets the whole line, so labels are legible and drags have
    /// travel. The list scrolls vertically; sections filter it above.
    private var sliderRow: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(filteredSpecs) { spec in
                    GVParamRow(
                        label: spec.label,
                        value: spec.value,
                        defaultValue: spec.defaultValue,
                        range: spec.range,
                        format: spec.format,
                        fine: fineMode
                    )
                    .accessibilityIdentifier("workspace.param.\(spec.id.lowercased())")
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: min(CGFloat(filteredSpecs.count) * 46 + 6, 232))
        .animation(GVMotion.scan, value: sectionFilter)
    }

    // MARK: - Parameter model

    private enum ParamSection: String, CaseIterable, Identifiable {
        case all
        case core
        case motion
        case space
        case decay
        case colorTexture = "coltex"
        case advanced

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: "ALL"
            case .core: "CORE"
            case .motion: "MOTION"
            case .space: "SPACE"
            case .decay: "DECAY"
            case .colorTexture: "COLOR"
            case .advanced: "ADV"
            }
        }

        init(name: String) {
            switch name {
            case "Motion": self = .motion
            case "Space": self = .space
            case "Decay / Feedback": self = .decay
            case "Color / Texture": self = .colorTexture
            case "Advanced": self = .advanced
            default: self = .core
            }
        }
    }

    private struct ParamSpec: Identifiable {
        let id: String
        let label: String
        let section: ParamSection
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
                id: "OFFSET", label: "OFFSET", section: .core,
                value: $rgbSplitParameters.amount,
                defaultValue: RGBSplitEffectParameters.activeDefaults.amount,
                range: 0...0.08,
                format: { String(format: "%.1f%%", $0 * 100) }
            ))
            specs.append(ParamSpec(
                id: "ANGLE", label: "ANGLE", section: .motion,
                value: $rgbSplitParameters.angleDegrees,
                defaultValue: RGBSplitEffectParameters.activeDefaults.angleDegrees,
                range: -180...180,
                format: { "\(Int($0.rounded()))\u{00B0}" }
            ))
            specs.append(ParamSpec(
                id: "MIX", label: "MIX", section: .advanced,
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
                    section: ParamSection(name: sectionFor(label: label)),
                    value: cameraParameterBinding(channel.1),
                    defaultValue: defaults[keyPath: channel.1],
                    range: 0...1,
                    format: percentage
                ))
            }
            specs.append(ParamSpec(
                id: "BLEND", label: "BLEND", section: .advanced,
                value: cameraParameterBinding(\.blend),
                defaultValue: defaults.blend,
                range: 0...1,
                format: percentage
            ))
        }
        return specs
    }

    private var filteredSpecs: [ParamSpec] {
        allSpecs.filter { spec in
            sectionFilter == .all || spec.section == sectionFilter
        }
    }

    private var presentSections: [ParamSection] {
        var seen: Set<ParamSection> = []
        let ordered: [ParamSection] = [.all] + allSpecs.map(\.section).filter { $0 != .all }
        return ordered.filter { seen.insert($0).inserted }
    }

    private var isEffectEnabled: Bool {
        switch effect {
        case .rgbSplit: return rgbSplitParameters.isEnabled
        default: return effectStack[effect].isEnabled
        }
    }

    private func toggleEffectEnabled() {
        let enabled = !isEffectEnabled
        switch effect {
        case .rgbSplit: rgbSplitParameters.isEnabled = enabled
        default: effectStack.setEnabled(enabled, for: effect)
        }
    }

    private func setEnabled(_ enabled: Bool) {
        switch effect {
        case .rgbSplit: rgbSplitParameters.isEnabled = enabled
        default: effectStack.setEnabled(enabled, for: effect)
        }
    }

    private func cameraParameterBinding(_ keyPath: WritableKeyPath<CameraEffectParameters, Double>) -> Binding<Double> {
        Binding(
            get: { effectStack[effect][keyPath: keyPath] },
            set: { newValue in
                var parameters = effectStack[effect]
                parameters[keyPath: keyPath] = newValue
                effectStack[effect] = parameters
            }
        )
    }

    private func percentage(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    /// Same classifier the old grouped inspector used, so no parameter moves
    /// families in the switch to filter chips.
    private func sectionFor(label: String) -> String {
        let lower = label.lowercased()
        if lower.contains("speed") || lower.contains("flow") || lower.contains("drift") || lower.contains("roll")
            || lower.contains("spin") || lower.contains("motion") || lower.contains("angle")
            || lower.contains("rotation") || lower.contains("vx") || lower.contains("vy") {
            return "Motion"
        }
        if lower.contains("space") || lower.contains("size") || lower.contains("radius") || lower.contains("width")
            || lower.contains("height") || lower.contains("inset") || lower.contains("length")
            || lower.contains("span") || lower.contains("distance") || lower.contains("offset")
            || lower.contains("scale") || lower.contains("density") || lower.contains("frequency") {
            return "Space"
        }
        if lower.contains("decay") || lower.contains("feedback") || lower.contains("hold")
            || lower.contains("history") || lower.contains("trail") {
            return "Decay / Feedback"
        }
        if lower.contains("color") || lower.contains("texture") || lower.contains("noise")
            || lower.contains("grain") || lower.contains("hue") || lower.contains("sat")
            || lower.contains("luma") {
            return "Color / Texture"
        }
        if lower.contains("mix") || lower.contains("blend") || lower.contains("opacity")
            || lower.contains("gate") || lower.contains("thresh") || lower.contains("bias")
            || lower.contains("ref") {
            return "Advanced"
        }
        return "Core"
    }

    // MARK: - Tools

    private func reset() {
        switch effect {
        case .rgbSplit:
            rgbSplitParameters = .activeDefaults
        default:
            effectStack.reset(effect)
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

/// One parameter as a full-width row: label and live value on the reading
/// line, a wide drag track beneath. Same interaction contract as the old rail
/// sliders — relative dragging, FINE quarter-speed, default detent notch,
/// double-tap reset, haptic ticks per 10% — with room to actually aim.
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @MainActor private static let tickGenerator = UIImpactFeedbackGenerator(style: .soft)

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    private var isAtDefault: Bool {
        abs(value - defaultValue) < (range.upperBound - range.lowerBound) * 0.004
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text(label)
                    .gvMono(GVMetrics.textSmall, .bold)
                    .tracking(0.9)
                    .foregroundStyle(isDragging ? Color.white : GVTheme.bone.opacity(0.85))
                    .shadow(color: isDragging ? .white.opacity(0.5) : .clear, radius: 3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Spacer(minLength: 8)

                Text(format(value))
                    .gvMono(GVMetrics.textSmall, .black)
                    .tracking(0.5)
                    .foregroundStyle(isDragging ? Color.white : GVTheme.bone.opacity(0.62))
                    .shadow(color: isDragging ? .white.opacity(0.45) : .clear, radius: 3)
            }

            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color(white: 0.13))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8)
                        )

                    // Default detent: shows where double-tap lands.
                    Rectangle()
                        .fill(isAtDefault ? Color.white.opacity(0.95) : Color.white.opacity(0.28))
                        .frame(width: 1.4, height: 9)
                        .offset(x: 6 + (width - 14) * fractionForDefault)

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.95), Color.white.opacity(0.55)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(6, width * fraction))
                        .shadow(
                            color: .white.opacity(isDragging ? 0.6 : 0.22),
                            radius: isDragging ? 5 : 2
                        )

                    Circle()
                        .fill(Color.white)
                        .frame(width: 13, height: 13)
                        .shadow(
                            color: .white.opacity(isDragging ? 0.95 : 0.42),
                            radius: isDragging ? 7 : 3
                        )
                        .offset(x: (width - 13) * fraction)
                }
                .frame(height: 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(dragGesture(width: width))
            }
            .frame(height: 18)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isDragging ? Color.white.opacity(0.05) : Color.clear)
        )
        // Floating readout above the knob while the finger is down.
        .overlay(alignment: .top) {
            if isDragging {
                Text(format(value))
                    .gvMono(GVMetrics.textMicro, .black)
                    .tracking(0.4)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(white: 0.11).opacity(0.96))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.8)
                            )
                            .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                            .shadow(color: .white.opacity(0.22), radius: 6)
                    )
                    .fixedSize()
                    .offset(y: -24)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                    .allowsHitTesting(false)
            }
        }
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

    private var fractionForDefault: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((defaultValue - range.lowerBound) / span, 0), 1)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if !isDragging {
                    Self.tickGenerator.prepare()
                }
                isDragging = true
                let start = dragStart ?? value
                if dragStart == nil { dragStart = value }
                let span = range.upperBound - range.lowerBound
                let sensitivity = span / (width * (fine ? 4 : 1))
                let moved = Double(gesture.translation.width) * sensitivity
                value = min(max(start + moved, range.lowerBound), range.upperBound)

                let bucket = Int(fraction * 10)
                if bucket != lastTickBucket {
                    lastTickBucket = bucket
                    Self.tickGenerator.impactOccurred(intensity: 0.32)
                }
            }
            .onEnded { _ in
                isDragging = false
                dragStart = nil
                lastTickBucket = -1
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
