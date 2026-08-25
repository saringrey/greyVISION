import SwiftUI

/// Compact single-rail parameter deck.
///
/// Every parameter sits on ONE horizontal slider rail under a single header
/// row, so the frame above stays visible while values are driven. Nothing was
/// removed from the old grouped inspector: power, favourite, stack arming,
/// hide-chrome, close, per-parameter drag, double-tap reset and section
/// grouping (now filter chips) all remain, and the rail adds RANDOMIZE,
/// COPY/PASTE, per-effect A/B snapshots and a FINE adjust mode on top.
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

    var body: some View {
        VStack(spacing: 6) {
            headerRow
            toolRow
            sliderRow
                .gvScrollProgressLine()
        }
        .gvCompactDeckPlate()
        .animation(GVMotion.micro, value: fineMode)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.parameters.\(effect.rawValue)")
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 5) {
            GVTerminalText(
                text: "FX.PARAM // \(effect.label)",
                size: GVMetrics.textSmall,
                weight: .black,
                tracking: 1.1,
                alignment: .leading,
                intensity: 1.15
            )

            Spacer(minLength: 6)

            GVDeckChip(label: "", symbol: "power", active: isEffectEnabled, tint: .white, id: "power") {
                toggleEffectEnabled()
            }
            GVDeckChip(
                label: "",
                symbol: isFavorite ? "star.fill" : "star",
                active: isFavorite,
                tint: .white,
                id: "favorite"
            ) {
                onFavoriteToggled()
            }
            // Was an ambiguous icon called STACK. The behaviour is arming
            // ADD-TO-STACK for the next selection, so it says that.
            GVDeckChip(label: isStackArmed ? "ADD\u{2713}" : "ADD", active: isStackArmed, tint: .white, id: "addmode") {
                onStackChanged(!isStackArmed)
            }
            GVDeckChip(label: "", symbol: "eye.slash", id: "hidechrome") {
                onHideChrome()
            }
            GVDeckChip(label: "", symbol: "xmark", id: "close") {
                onClose()
            }
        }
    }

    // MARK: - Tools

    private var toolRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(presentSections) { section in
                    GVDeckChip(
                        label: section == .all ? "ALL" : section.label,
                        active: sectionFilter == section,
                        id: "filter.\(section.rawValue)"
                    ) {
                        sectionFilter = section
                    }
                }

                divider

                GVDeckChip(label: "RST", id: "reset") {
                    reset()
                    toasts.show("FX // \(effect.label) RESET TO DEFAULTS")
                }
                GVDeckChip(label: "RAND", id: "random") {
                    randomize()
                    toasts.show("FX // \(effect.label) RANDOMIZED")
                }
                GVDeckChip(label: "CPY", id: "copy") {
                    copySettings()
                }
                GVDeckChip(label: "PST", dimmed: !EffectClipboard.hasContent, id: "paste") {
                    pasteSettings()
                }

                divider

                GVDeckChip(label: "ST.A", id: "storea") {
                    storeSnapshot(.a)
                    toasts.show("FX // STORED SLOT A")
                }
                GVDeckChip(label: "ST.B", id: "storeb") {
                    storeSnapshot(.b)
                    toasts.show("FX // STORED SLOT B")
                }
                GVDeckChip(
                    label: "A",
                    dimmed: !ABSlots.has(effect.rawValue, .a),
                    id: "recalla"
                ) {
                    recallSnapshot(.a)
                }
                GVDeckChip(
                    label: "B",
                    dimmed: !ABSlots.has(effect.rawValue, .b),
                    id: "recallb"
                ) {
                    recallSnapshot(.b)
                }

                divider

                GVDeckChip(label: "FINE", active: fineMode, id: "fine") {
                    fineMode.toggle()
                    toasts.show(fineMode ? "DRAG // FINE 0.25X" : "DRAG // COARSE")
                }
                .accessibilityValue(fineMode ? "on" : "off")
            }
            .padding(.vertical, 1)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .gvHorizontalEdgeFade()
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 14)
    }

    // MARK: - Sliders

    private var sliderRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(filteredSpecs) { spec in
                    GVRailSlider(
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
            .padding(.horizontal, 1)
            .padding(.bottom, 3)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .gvHorizontalEdgeFade()
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
