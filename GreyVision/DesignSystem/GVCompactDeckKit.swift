import SwiftUI

// MARK: - Unified toast

//
/// One notice channel for the whole workspace. Replaces the three unrelated
/// surfaces notices used to surface from — red terminal text under the top
/// shell, a red line inside the dock, and inline flash text in the parameter
/// tool row — with a single charcoal capsule anchored just above the dock.
@MainActor
final class GVToastBox: ObservableObject {
    @Published var message: String?
    @Published private(set) var actionTitle: String?
    private var actionHandler: (() -> Void)?
    private var dismissTask: Task<Void, Never>?

    /// A new message replaces the current one and restarts the timer. That is
    /// deliberately not a queue: notices here answer "what just happened", and
    /// a backlog of answers is noise.
    func show(_ text: String) {
        show(text, action: nil)
    }

    /// A notice that offers a way out.
    ///
    /// A permission refusal is the case this exists for: telling the operator
    /// an effect needs the microphone and then dismissing the message two
    /// seconds later leaves them holding a control that does nothing, with no
    /// indication that the fix lives in Settings. The action stays up longer
    /// because it has to be reachable, not just readable.
    func show(_ text: String, action: ToastAction?) {
        message = text
        actionTitle = action?.title
        actionHandler = action?.handler
        dismissTask?.cancel()
        let duration = action == nil ? 2.4 : 6.0
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// Runs the pending action and clears the notice. Exposed so the capsule
    /// can invoke it without holding the handler itself.
    func performAction() {
        let handler = actionHandler
        dismiss()
        handler?()
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        message = nil
        actionTitle = nil
        actionHandler = nil
    }

    struct ToastAction {
        let title: String
        let handler: () -> Void
    }
}

struct GVToastCapsule: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var lift: Double { contrast == .increased ? 1.5 : 1 }

    let text: String?
    /// Optional way out, for a notice the operator can actually resolve.
    let actionTitle: String?
    let onAction: (() -> Void)?

    private var isError: Bool {
        guard let text else { return false }
        let upper = text.uppercased()
        return ["FAILED", "DENIED", "ERROR", "UNAVAILABLE", "LOCKED"].contains { upper.contains($0) }
    }

    var body: some View {
        if let text {
            HStack(spacing: 7) {
                Circle()
                    .fill(isError ? GVTheme.record : GVTheme.bone.opacity(0.7))
                    .frame(width: 5, height: 5)
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(
                        isError
                            ? GVTheme.record.opacity(min(0.92 * lift, 1))
                            : GVTheme.bone.opacity(min(0.9 * lift, 1))
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let actionTitle, let onAction {
                    Button(action: onAction) {
                        Text(actionTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                    }
                    .buttonStyle(GVPressStyle())
                    .accessibilityIdentifier("workspace.toast.action")
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .gvNoticeCapsule(
                tint: isError ? GVTheme.record.opacity(0.18) : nil,
                critical: isError
            )
            .transition(
                reduceMotion
                    ? .opacity
                    : .move(edge: .bottom).combined(with: .opacity)
            )
            .accessibilityIdentifier("workspace.toast")
        }
    }
}

// MARK: - Scroll progress line

private struct GVScrollProgressLine: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offsetX: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var visibleWidth: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                GeometryReader { geometry in
                    let scrollable = contentWidth - visibleWidth
                    let progress = scrollable > 1 ? min(max(offsetX / scrollable, 0), 1) : 0
                    let fillWidth = visibleWidth > 0 && contentWidth > 0
                        ? max(geometry.size.width * (visibleWidth / contentWidth), 26)
                        : 0
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.04))
                            .frame(width: geometry.size.width)
                        if contentWidth > visibleWidth + 8 {
                            Capsule()
                                .fill(Color.white.opacity(0.16))
                                .frame(width: fillWidth)
                                .offset(x: progress * (geometry.size.width - fillWidth))
                                .animation(
                                    GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion),
                                    value: progress
                                )
                        }
                    }
                    .frame(height: 2)
                }
                .frame(height: 2)
                .padding(.top, 2)
                .allowsHitTesting(false)
            }
            .onScrollGeometryChange(for: ScrollGeometry.self) { geometry in
                geometry
            } action: { _, newValue in
                offsetX = newValue.contentOffset.x
                contentWidth = newValue.contentSize.width
                visibleWidth = newValue.containerSize.width
                    - newValue.contentInsets.leading
                    - newValue.contentInsets.trailing
            }
    }
}

extension View {
    /// A 2pt position line under a horizontal scroller, so clipped cards read
    /// as "more over here" with a sense of where you are in it.
    func gvScrollProgressLine() -> some View {
        modifier(GVScrollProgressLine())
    }
}

// MARK: - Compact deck plate

extension View {
    /// Native Liquid Glass grouping on iOS 26+, with a no-op container on
    /// earlier systems. Grouping adjacent glass elements lets SwiftUI render
    /// and merge them as one optical system instead of stacking independent
    /// blur layers.
    @ViewBuilder
    func gvLiquidGlassContainer(spacing: CGFloat = 12) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                self
            }
        } else {
            self
        }
    }

    /// A dark, frosted Liquid Glass surface. Interactive response is reserved
    /// for controls; passive rails and deck plates leave it disabled.
    func gvLiquidGlass(
        radius: CGFloat,
        tint: Color = Color.black.opacity(0.34),
        interactive: Bool = false
    ) -> some View {
        gvMaterial(
            .deck,
            shape: .rounded(radius: radius),
            tint: tint,
            interactive: interactive
        )
    }

    /// Associates a glass surface with a stable identity when its hierarchy
    /// changes, enabling native morphing on iOS 26 without affecting fallback
    /// layouts.
    @ViewBuilder
    func gvLiquidGlassID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    /// The shared charcoal material for every bottom-sheet deck: gradient,
    /// top hairline, hairline stroke, depth shadow. One source so the effect,
    /// depth, AR and blob decks cannot drift apart again.
    func gvCompactDeckPlate() -> some View {
        modifier(GVCompactDeckPlateModifier())
    }
}

private struct GVCompactDeckPlateModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, GVMetrics.stepRelated)
            .padding(.top, GVMetrics.gap)
            .padding(.bottom, GVMetrics.gap)
            .gvMaterial(.deck, shape: .rounded(radius: GVMetrics.radiusPanel))
    }
}

// MARK: - Deck chip

/// The small labelled control used across deck headers and tool rows.
struct GVDeckChip: View {
    let label: String
    var symbol: String?
    /// Icon-only chips must name their action independently of their visual
    /// label; an empty `label` used to erase the SF Symbol's VoiceOver name.
    var accessibilityLabel: String?
    var active = false
    var dimmed = false
    var tint: Color = .white
    /// Drawn height. The button always receives a 44pt interaction frame even
    /// when dense deck chrome is rendered smaller.
    var height: CGFloat = 24
    let id: String
    let action: () -> Void

    private var spokenLabel: String {
        if let accessibilityLabel, !accessibilityLabel.isEmpty {
            return accessibilityLabel
        }
        if !label.isEmpty { return label }
        switch symbol {
        case "xmark": return "Close"
        case "power", "power.dotted": return "Toggle effect"
        case "star", "star.fill": return "Toggle favorite"
        case "chevron.left": return "Move earlier"
        case "chevron.right": return "Move later"
        case "trash": return "Remove"
        default: return "Control"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? tint : GVTheme.bone.opacity(dimmed ? 0.35 : 0.75))
            .padding(.horizontal, symbol == nil ? 10 : 8)
            .frame(height: height)
        }
        .buttonStyle(GVGlassChipStyle(active: active, dimmed: dimmed, tint: tint, height: height))
        .frame(minHeight: GVMetrics.touchTarget)
        .contentShape(Rectangle())
        .disabled(dimmed && !active)
        .accessibilityLabel(spokenLabel)
        .accessibilityIdentifier("workspace.chip.\(id)")
        .accessibilityValue(active ? "on" : "off")
    }
}

private struct GVGlassChipStyle: ButtonStyle {
    let active: Bool
    let dimmed: Bool
    let tint: Color
    let height: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .gvGlassChip(radius: 8, active: active || configuration.isPressed, tint: tint)
            .frame(height: height)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
            .animation(
                GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
            .opacity(dimmed && !active ? 0.55 : 1)
    }
}

// MARK: - Rail slider

/// Compact pagination for parameter decks. It deliberately replaces horizontal
/// parameter scrolling: every page is a complete, legible set of controls.
struct GVParameterPager: View {
    @Binding var page: Int
    let pageCount: Int

    var body: some View {
        guard pageCount > 1 else { return AnyView(EmptyView()) }
        return AnyView(
            HStack(spacing: 8) {
                Button {
                    page = max(0, page - 1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(GVPressStyle(scale: 0.9))
                .disabled(page == 0)
                .accessibilityLabel("Previous parameter page")
                .accessibilityHint("Shows parameter page \(max(page, 1)) of \(pageCount)")

                Text("Page \(page + 1) of \(pageCount)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(GVTheme.ash)
                    .monospacedDigit()

                Button {
                    page = min(pageCount - 1, page + 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(GVPressStyle(scale: 0.9))
                .disabled(page == pageCount - 1)
                .accessibilityLabel("Next parameter page")
                .accessibilityHint("Shows parameter page \(min(page + 2, pageCount)) of \(pageCount)")
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(GVTheme.bone)
            .frame(height: 24)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Parameter page \(page + 1) of \(pageCount)")
        )
    }
}

/// One parameter as a compact vertical unit: label, drag track with a default
/// detent notch, live value — plus a floating value bubble and soft haptic
/// ticks while dragging.
///
/// Dragging is relative to where the gesture started rather than absolute
/// positioning, and FINE scales the travel down to a quarter so small ranges
/// stay drivable. Double-tap returns the parameter to its default, which is
/// exactly where the notch sits.
@MainActor
struct GVRailSlider: View {
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

    private var defaultFraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((defaultValue - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(label.capitalized)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(isDragging ? Color.white.opacity(0.92) : GVTheme.ash)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color(white: 0.13))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8)
                        )

                    // Default detent: shows where double-tap lands BEFORE
                    // you discover reset by accident.
                    Rectangle()
                        .fill(abs(value - defaultValue) < (range.upperBound - range.lowerBound) * 0.004
                            ? Color.white.opacity(0.95)
                            : Color.white.opacity(0.28))
                        .frame(width: 1.4, height: 7)
                        .offset(x: 6 + (width - 14) * defaultFraction)

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
                            color: .white.opacity(isDragging ? 0.32 : 0.14),
                            radius: isDragging ? 3 : 1
                        )
                    Circle()
                        .fill(Color.white)
                        .frame(width: 11, height: 11)
                        .shadow(
                            color: .white.opacity(isDragging ? 0.45 : 0.20),
                            radius: isDragging ? 4 : 2
                        )
                        .offset(x: (width - 11) * fraction)
                }
                .frame(height: 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(dragGesture(width: width))
            }
            .frame(height: 16)

            Text(format(value))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(isDragging ? Color.white.opacity(0.92) : GVTheme.bone.opacity(0.82))
        }
        .frame(width: 84)
        // Floating readout above the knob while the finger is down: the value
        // stays legible even when the finger covers the rail itself.
        .overlay(alignment: .top) {
            if isDragging {
                Text(format(value))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(white: 0.11).opacity(0.96))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                            )
                            .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                    )
                    .fixedSize()
                    .offset(x: bubbleOffsetX, y: -21)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                    .allowsHitTesting(false)
            }
        }
        .onTapGesture(count: 2) {
            value = defaultValue
        }
        .animation(GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion), value: isDragging)
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

    /// Keeps the floating chip inside the slider's own footprint.
    private var bubbleOffsetX: CGFloat {
        let raw = (84 - 11) * CGFloat(fraction)
        return min(max(raw, -18), 84 - 40)
    }

    private func dragGesture(width _: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if !isDragging {
                    Self.tickGenerator.prepare()
                }
                isDragging = true
                let start = dragStart ?? value
                if dragStart == nil { dragStart = value }
                let span = range.upperBound - range.lowerBound
                let sensitivity = span / 170.0 * (fine ? 0.25 : 1)
                let moved = Double(gesture.translation.width) * sensitivity
                value = min(max(start + moved, range.lowerBound), range.upperBound)

                // One tick per 10% of travel crossed. Cheap, and it turns a
                // blind drag into something the thumb can count.
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

// MARK: - Hugging deck list

private struct GVDeckContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A capped vertical list that takes the height of what it holds.
///
/// A `ScrollView` has no intrinsic height — it takes every point it is offered
/// — so a plate that only caps its list reserves the whole cap whatever the
/// list contains. One starred recipe then sat in a plate three quarters empty,
/// because the plate was sized by its ceiling rather than its content.
struct GVDeckList<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: Content

    @State private var measured: CGFloat = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: GVDeckContentHeightKey.self, value: proxy.size.height)
                    }
                }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .frame(height: min(max(measured, 0), maxHeight))
        .onPreferenceChange(GVDeckContentHeightKey.self) { height in
            if abs(measured - height) > 0.5 { measured = height }
        }
    }
}
