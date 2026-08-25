import SwiftUI
import UIKit

// MARK: - Tactile punctuation

/// Throttled haptics for parameter scrubbing.
///
/// A continuous drag can cross dozens of discrete steps per second. Firing the
/// generator on every one produces a constant buzz that reads as malfunction,
/// so ticks are rate-limited and detents are given a distinct, rarer feel.
@MainActor
enum GVParameterHaptics {
    private static var lastTick: TimeInterval = 0
    private static let tickInterval: TimeInterval = 0.045

    private static let tick = UIImpactFeedbackGenerator(style: .light)
    private static let detent = UIImpactFeedbackGenerator(style: .rigid)
    private static let selection = UISelectionFeedbackGenerator()

    static func prepare() {
        tick.prepare()
        detent.prepare()
        selection.prepare()
    }

    /// Discrete-step tick. Silently drops anything inside the throttle window.
    static func step() {
        let now = CACurrentMediaTime()
        guard now - lastTick >= tickInterval else { return }
        lastTick = now
        tick.impactOccurred(intensity: 0.32)
    }

    /// Crossing zero, or a major angle detent. Deliberately stronger than a tick.
    static func detentCrossed() {
        let now = CACurrentMediaTime()
        guard now - lastTick >= tickInterval else { return }
        lastTick = now
        detent.impactOccurred(intensity: 0.62)
    }

    static func select() {
        selection.selectionChanged()
    }
}

// MARK: - Control vocabulary

/// How a parameter's magnitude is drawn. `auto` infers from range and step so
/// existing call sites need no annotation.
enum GVParameterStyle: Equatable, Sendable {
    case auto
    /// Segmented block meter — use when relative magnitude matters.
    case meter
    /// Thin baseline with a position caret — use for simple scalar values.
    case plain
    /// Centred meter filling outward from zero, with a zero detent.
    case bipolar
    /// Technical angle scale with detents at -180/-90/0/90/180.
    case angle
    /// Discrete tick track for frame counts, repeats and block sizes.
    case integer

    fileprivate func resolved(range: ClosedRange<Double>, step: Double) -> GVParameterStyle {
        guard self == .auto else { return self }
        if range.lowerBound <= -90, range.upperBound >= 90 { return .angle }
        if range.lowerBound < 0, range.upperBound > 0 { return .bipolar }
        if step >= 1, (range.upperBound - range.lowerBound) / step <= 16 { return .integer }
        return .meter
    }
}

/// Sensitivity tiers for precision scrubbing. The finger's vertical distance
/// from the row selects the tier, matching the scrub behaviour of professional
/// compositing and NLE software.
private enum GVPrecision {
    static func factor(forVerticalOffset offset: CGFloat) -> Double {
        switch abs(offset) {
        case ..<30: 1.0
        case ..<70: 0.5
        case ..<120: 0.1
        default: 0.01
        }
    }

    static func label(_ factor: Double) -> String {
        switch factor {
        case 1.0: "1X"
        case 0.5: "0.5X"
        case 0.1: "0.1X"
        default: "0.01X"
        }
    }
}

// MARK: - Track rendering

/// The drawn magnitude track. One `Canvas` for every style keeps the parameter
/// deck to a single draw call per row rather than a stack of shape views.
private struct GVTerminalTrack: View {
    let style: GVParameterStyle
    let fraction: Double
    let tint: Color
    let isActive: Bool
    let segmentCount: Int

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            switch style {
            case .meter, .auto:
                drawSegments(context: context, size: size, fromCenter: false)
            case .bipolar:
                drawSegments(context: context, size: size, fromCenter: true)
            case .integer:
                drawTicks(context: context, size: size)
            case .angle:
                drawScale(context: context, size: size)
            case .plain:
                drawBaseline(context: context, size: size)
            }
        }
        .frame(height: 9)
        .animation(GVMotion.micro, value: isActive)
    }

    private var dim: Color { GVTheme.faint }

    private func drawSegments(context: GraphicsContext, size: CGSize, fromCenter: Bool) {
        let count = segmentCount
        let gap: CGFloat = 1.5
        let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
        guard width > 0.5 else { return }

        let clamped = min(max(fraction, 0), 1)
        for index in 0 ..< count {
            let rect = CGRect(
                x: CGFloat(index) * (width + gap),
                y: 0,
                width: width,
                height: size.height
            )
            let filled: Bool
            if fromCenter {
                let centre = Double(count) / 2
                let position = clamped * Double(count)
                filled = position >= centre
                    ? Double(index) >= centre - 0.001 && Double(index) < position
                    : Double(index) + 1 <= centre + 0.001 && Double(index) + 1 > position
            } else {
                filled = Double(index) < clamped * Double(count)
            }
            context.fill(
                Path(roundedRect: rect, cornerRadius: 0.6),
                with: .color(filled ? tint.opacity(isActive ? 1 : 0.88) : dim.opacity(0.55))
            )
        }

        if fromCenter {
            let centreX = size.width / 2
            context.fill(
                Path(CGRect(x: centreX - 0.5, y: -1, width: 1, height: size.height + 2)),
                with: .color(GVTheme.bone.opacity(0.55))
            )
        }
    }

    private func drawTicks(context: GraphicsContext, size: CGSize) {
        let count = max(2, segmentCount)
        let clamped = min(max(fraction, 0), 1)
        let baseline = size.height - 1
        context.fill(
            Path(CGRect(x: 0, y: baseline, width: size.width, height: 1)),
            with: .color(dim.opacity(0.5))
        )
        for index in 0 ..< count {
            let progress = count == 1 ? 0 : Double(index) / Double(count - 1)
            let x = CGFloat(progress) * (size.width - 1)
            let reached = progress <= clamped + 0.0001
            let height: CGFloat = reached ? size.height : size.height * 0.45
            context.fill(
                Path(CGRect(x: x, y: baseline - height, width: 1, height: height)),
                with: .color(reached ? tint.opacity(isActive ? 1 : 0.85) : dim.opacity(0.65))
            )
        }
    }

    private func drawScale(context: GraphicsContext, size: CGSize) {
        let baseline = size.height - 1
        context.fill(
            Path(CGRect(x: 0, y: baseline, width: size.width, height: 1)),
            with: .color(dim.opacity(0.6))
        )
        // Major detents at -180 / -90 / 0 / 90 / 180.
        for index in 0 ... 4 {
            let progress = Double(index) / 4
            let x = CGFloat(progress) * (size.width - 1)
            let isCentre = index == 2
            let height: CGFloat = isCentre ? size.height : size.height * 0.62
            context.fill(
                Path(CGRect(x: x, y: baseline - height, width: 1, height: height)),
                with: .color(GVTheme.bone.opacity(isCentre ? 0.6 : 0.34))
            )
        }
        drawCaret(context: context, size: size)
    }

    private func drawBaseline(context: GraphicsContext, size: CGSize) {
        let baseline = size.height - 1
        context.fill(
            Path(CGRect(x: 0, y: baseline, width: size.width, height: 1)),
            with: .color(dim.opacity(0.6))
        )
        let filledWidth = CGFloat(min(max(fraction, 0), 1)) * size.width
        context.fill(
            Path(CGRect(x: 0, y: baseline, width: filledWidth, height: 1)),
            with: .color(tint.opacity(isActive ? 1 : 0.8))
        )
        drawCaret(context: context, size: size)
    }

    private func drawCaret(context: GraphicsContext, size: CGSize) {
        let x = CGFloat(min(max(fraction, 0), 1)) * (size.width - 1)
        var caret = Path()
        caret.move(to: CGPoint(x: x - 2.4, y: 0))
        caret.addLine(to: CGPoint(x: x + 2.4, y: 0))
        caret.addLine(to: CGPoint(x: x, y: size.height - 2))
        caret.closeSubpath()
        context.fill(caret, with: .color(tint.opacity(isActive ? 1 : 0.9)))
    }
}

// MARK: - Universal terminal parameter row

/// A parameter control with no visible slider and no thumb to grab.
///
/// The entire row is the control: drag horizontally anywhere on it to change
/// the value, move the finger vertically away to reduce sensitivity, tap the
/// readout to type an exact value, double-tap to restore the default. The
/// external geometry deliberately matches the slider rows it replaces so the
/// surrounding deck layout is untouched.
struct GVTerminalParameterRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: String
    var style: GVParameterStyle = .auto
    var tint: Color = GVTheme.violet
    var fontSize: CGFloat = 6.5
    var tracking: CGFloat = 0.68
    var defaultValue: Double?
    var identifier: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isDragging = false
    @State private var lastTranslation: CGFloat = 0
    @State private var continuous: Double = 0
    @State private var precision: Double = 1
    @State private var delta: Double = 0
    @State private var trackWidth: CGFloat = 120
    @State private var isEditing = false
    @State private var entry = ""
    @State private var resetFlash: String?
    @FocusState private var entryFocused: Bool

    private var resolvedStyle: GVParameterStyle {
        style.resolved(range: range, step: step)
    }

    private var span: Double { max(range.upperBound - range.lowerBound, .ulpOfOne) }

    private var fraction: Double {
        (value - range.lowerBound) / span
    }

    private var segmentCount: Int {
        switch resolvedStyle {
        case .integer:
            min(max(Int((span / max(step, .ulpOfOne)).rounded()) + 1, 2), 16)
        default:
            14
        }
    }

    var body: some View {
        VStack(spacing: 1) {
            readoutLine
            trackLine
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        // The plate only exists while the row is being driven. A permanent
        // one put a box around every parameter, so a deck of six read as six
        // panels rather than as one instrument with six readings on it.
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.black.opacity(isDragging ? 0.34 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    tint.opacity(isDragging ? 0.55 : 0),
                    lineWidth: 1
                )
        )
        .animation(GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion), value: isDragging)
        .overlay(alignment: .top) { adjustTelemetry }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .gesture(scrubGesture, isEnabled: !isEditing)
        .onTapGesture(count: 2) { resetToDefault() }
        // Reported to assistive technology — and to XCUITest — as the slider
        // this behaves like, rather than as an anonymous adjustable container.
        // The visual stays the segmented terminal track; only the accessibility
        // tree is substituted. Writes route through `commit` so a VoiceOver
        // adjustment snaps and clamps exactly like a scrub does.
        .accessibilityRepresentation {
            Slider(
                value: Binding(get: { value }, set: { commit($0) }),
                in: range,
                step: step > 0 ? step : span / 20
            ) {
                Text(label)
            }
        }
        .accessibilityIdentifier(identifier ?? "workspace.parameter.\(slug)")
        .accessibilityLabel(label)
        .accessibilityValue(display)
    }

    // MARK: Readout

    private var readoutLine: some View {
        HStack(spacing: 3) {
            Text(label)
                .foregroundStyle(isDragging ? GVTheme.bone : GVTheme.ash)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 2)
            if isEditing {
                TextField("", text: $entry)
                    .keyboardType(step >= 1 ? .numbersAndPunctuation : .numbersAndPunctuation)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(tint)
                    .focused($entryFocused)
                    .frame(maxWidth: 54)
                    .onSubmit { commitEntry() }
                    .accessibilityIdentifier("\(identifier ?? "workspace.parameter.\(slug)").entry")
            } else {
                Text(isDragging ? "[\(display)]" : display)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    .onTapGesture { beginEditing() }
            }
        }
        .gvMono(fontSize, .bold)
        .tracking(tracking)
    }

    @ViewBuilder private var trackLine: some View {
        ZStack {
            if isEditing {
                HStack(spacing: 0) {
                    Text("MIN \(bound(range.lowerBound))")
                    Spacer(minLength: 2)
                    Text("MAX \(bound(range.upperBound))")
                }
                .gvMono(fontSize - 1.2, .bold)
                .tracking(0.4)
                .foregroundStyle(GVTheme.ash)
            } else if let resetFlash {
                Text(resetFlash)
                    .gvMono(fontSize - 1.0, .black)
                    .tracking(0.5)
                    .foregroundStyle(GVTheme.acid)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                GVTerminalTrack(
                    style: resolvedStyle,
                    fraction: fraction,
                    tint: tint,
                    isActive: isDragging,
                    segmentCount: segmentCount
                )
                .background(
                    GeometryReader { geometry in
                        Color.clear.onAppear { trackWidth = geometry.size.width }
                    }
                )
            }
        }
        .frame(height: 13)
        .frame(maxWidth: .infinity)
    }

    /// Transient scrub telemetry. Rendered as an overlay so it can never move
    /// the deck's layout, and torn down the moment the finger lifts.
    @ViewBuilder private var adjustTelemetry: some View {
        if isDragging {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(label) // ADJUST")
                Text("Δ \(signed(delta))  \(GVPrecision.label(precision))")
                    .foregroundStyle(precision < 1 ? GVTheme.acid : GVTheme.ash)
            }
            .gvMono(GVMetrics.textMicro, .black)
            .tracking(0.45)
            .foregroundStyle(GVTheme.ash)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(tint.opacity(0.42), lineWidth: 0.5)
            )
            .fixedSize()
            .offset(y: -26)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    // MARK: Scrubbing

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                if !isDragging {
                    isDragging = true
                    lastTranslation = gesture.translation.width
                    continuous = value
                    delta = 0
                    GVParameterHaptics.prepare()
                }
                let dx = gesture.translation.width - lastTranslation
                lastTranslation = gesture.translation.width
                precision = GVPrecision.factor(forVerticalOffset: gesture.translation.height)

                let width = max(trackWidth, 40)
                continuous += Double(dx) / Double(width) * span * precision
                continuous = min(max(continuous, range.lowerBound), range.upperBound)

                let candidate = snapped(continuous)
                if candidate != value {
                    let crossedDetent = didCrossDetent(from: value, to: candidate)
                    delta = candidate - value
                    value = candidate
                    if crossedDetent {
                        GVParameterHaptics.detentCrossed()
                    } else {
                        GVParameterHaptics.step()
                    }
                }
            }
            .onEnded { _ in
                isDragging = false
                precision = 1
                delta = 0
            }
    }

    /// Quantises to the parameter's step, then applies gentle magnetism at the
    /// detents that matter. Magnetism is intentionally narrow so precision
    /// scrubbing near zero stays usable rather than fighting the snap.
    private func snapped(_ raw: Double) -> Double {
        var result = raw
        if step > 0 {
            result = (raw / step).rounded() * step
        }
        let magnet = span * 0.012 * precision
        switch resolvedStyle {
        case .bipolar:
            if abs(result) < magnet { result = 0 }
        case .angle:
            for detent in [-180.0, -90.0, 0.0, 90.0, 180.0]
                where detent >= range.lowerBound && detent <= range.upperBound
            {
                if abs(result - detent) < magnet { result = detent }
            }
        default:
            break
        }
        return min(max(result, range.lowerBound), range.upperBound)
    }

    private func didCrossDetent(from old: Double, to new: Double) -> Bool {
        let detents: [Double]
        switch resolvedStyle {
        case .bipolar:
            detents = [0]
        case .angle:
            detents = [-180, -90, 0, 90, 180]
        case .meter, .plain, .integer, .auto:
            if let def = defaultValue {
                detents = [range.lowerBound, def, (range.lowerBound + range.upperBound) * 0.5, range.upperBound]
            } else {
                detents = [range.lowerBound, (range.lowerBound + range.upperBound) * 0.5, range.upperBound]
            }
        }
        return detents.contains { detent in
            (old < detent && new >= detent) || (old > detent && new <= detent)
        }
    }

    private func commit(_ raw: Double) {
        value = min(max(step > 0 ? (raw / step).rounded() * step : raw, range.lowerBound), range.upperBound)
    }

    // MARK: Exact entry

    private func beginEditing() {
        entry = step >= 1
            ? String(Int(value.rounded()))
            : String(format: "%.3f", value)
        isEditing = true
        entryFocused = true
        GVParameterHaptics.select()
    }

    private func commitEntry() {
        if let parsed = Double(entry.trimmingCharacters(in: .whitespaces)) {
            commit(parsed)
        }
        endEditing()
    }

    private func endEditing() {
        entryFocused = false
        isEditing = false
    }

    // MARK: Reset

    private func resetToDefault() {
        guard let defaultValue, defaultValue != value else { return }
        let previous = value
        commit(defaultValue)
        GVParameterHaptics.detentCrossed()
        resetFlash = "\(bound(previous)) → \(bound(value))"
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(GVMotion.normal) { resetFlash = nil }
        }
    }

    // MARK: Formatting

    private func bound(_ raw: Double) -> String {
        step >= 1 ? String(format: "%03d", Int(raw.rounded())) : String(format: "%.2f", raw)
    }

    private func signed(_ raw: Double) -> String {
        step >= 1 ? String(format: "%+d", Int(raw.rounded())) : String(format: "%+.3f", raw)
    }

    private var slug: String {
        label.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}

// MARK: - Boolean parameter row

/// A boolean with no sliding switch. The whole row is the target; the state is
/// stated as a word, because a word is unambiguous at 6pt where a 20pt toggle
/// would dominate the deck.
struct GVTerminalBooleanRow: View {
    let label: String
    @Binding var isOn: Bool
    var tint: Color = GVTheme.violet
    var fontSize: CGFloat = 6.5
    var identifier: String?

    @State private var flashing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            isOn.toggle()
            GVParameterHaptics.select()
            flashing = true
            Task {
                try? await Task.sleep(for: .milliseconds(140))
                withAnimation(GVMotion.micro) { flashing = false }
            }
        } label: {
            HStack(spacing: 3) {
                Text(label)
                    .foregroundStyle(isOn ? GVTheme.bone : GVTheme.ash)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                Text(flashing ? "[\(isOn ? "ON" : "OFF")]" : (isOn ? "ON" : "OFF"))
                    .foregroundStyle(isOn ? tint : GVTheme.faint)
                    .contentTransition(.opacity)
            }
            .gvMono(fontSize, .bold)
            .tracking(0.68)
            .padding(.horizontal, 6)
            // Matches the enlarged camera rows; 24pt was under the comfortable
            // tap target for a control used one-handed.
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.black.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(tint.opacity(isOn ? 0.5 : 0.14), lineWidth: 1)
            )
        }
        .buttonStyle(GVPressStyle(tint: tint))
        .accessibilityIdentifier(identifier ?? "workspace.parameter.\(label.lowercased())")
        .accessibilityValue(isOn ? "on" : "off")
    }
}

// MARK: - Enum parameter row

/// A mode selector that expands in place into a numbered terminal list and
/// collapses again the instant a choice is made. No confirmation step — the
/// selection is the confirmation.
struct GVTerminalEnumRow<Option: Hashable>: View {
    let label: String
    let options: [Option]
    let title: (Option) -> String
    @Binding var selection: Option
    var tint: Color = GVTheme.violet
    var fontSize: CGFloat = 6.5
    var identifier: String?

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 2) {
            Button {
                withAnimation(GVMotion.resolved(GVMotion.normal, reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
                GVParameterHaptics.select()
            } label: {
                HStack(spacing: 3) {
                    Text(isExpanded ? "\(label) //" : label)
                        .foregroundStyle(GVTheme.ash)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 2)
                    Text(title(selection))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .gvMono(fontSize, .bold)
                .tracking(0.68)
                .padding(.horizontal, 5)
                .frame(height: 22)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(GVPressStyle(tint: tint))

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.element) { index, option in
                        optionRow(index: index, option: option)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.black.opacity(0.16))
        )
        .accessibilityIdentifier(identifier ?? "workspace.parameter.\(label.lowercased())")
    }

    private func optionRow(index: Int, option: Option) -> some View {
        let selected = option == selection
        return Button {
            selection = option
            GVParameterHaptics.select()
            withAnimation(GVMotion.resolved(GVMotion.normal, reduceMotion: reduceMotion)) {
                isExpanded = false
            }
        } label: {
            HStack(spacing: 4) {
                Text(selected ? ">" : " ")
                    .foregroundStyle(tint)
                Text(String(format: "%02d", index + 1))
                    .foregroundStyle(GVTheme.faint)
                Text(title(option))
                    .foregroundStyle(selected ? GVTheme.bone : GVTheme.ash)
                Spacer(minLength: 0)
            }
            .gvMono(fontSize, selected ? .black : .bold)
            .tracking(0.6)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .frame(maxWidth: .infinity)
            .background(
                selected ? tint.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A numeric field that rolls between values instead of snapping.
///
/// Restored alongside the terminal controls: the HUD and telemetry views both
/// depend on it for readouts that must not jump as digits change.
struct GVNumericReadout: View {
    let value: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(value)
            .contentTransition(reduceMotion ? .opacity : .numericText())
            .animation(
                GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion),
                value: value
            )
    }
}
