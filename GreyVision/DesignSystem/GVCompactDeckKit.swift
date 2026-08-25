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
    private var dismissTask: Task<Void, Never>?

    /// A new message replaces the current one and restarts the timer. That is
    /// deliberately not a queue: notices here answer "what just happened", and
    /// a backlog of answers is noise.
    func show(_ text: String) {
        message = text
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}

struct GVToastCapsule: View {
    @Environment(\.colorSchemeContrast) private var contrast
    private var lift: Double { contrast == .increased ? 1.5 : 1 }

    let text: String?

    private var isError: Bool {
        guard let text else { return false }
        let upper = text.uppercased()
        return ["FAILED", "DENIED", "ERROR", "UNAVAILABLE", "LOCKED"].contains { upper.contains($0) }
    }

    var body: some View {
        if let text {
            HStack(spacing: 7) {
                Circle()
                    .fill(isError ? GVTheme.record : Color.white)
                    .frame(width: 5, height: 5)
                    .shadow(color: isError ? GVTheme.record.opacity(0.9) : .white.opacity(0.9), radius: 4)
                Text(text)
                    .gvMono(GVMetrics.textSmall, .bold)
                    .tracking(0.8)
                    .foregroundStyle(
                        isError
                            ? GVTheme.record.opacity(min(0.92 * lift, 1))
                            : Color.white.opacity(min(0.88 * lift, 1))
                    )
                    .shadow(color: isError ? GVTheme.record.opacity(0.4) : .white.opacity(0.28), radius: 4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(red: 0.135, green: 0.135, blue: 0.143).opacity(0.94))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(
                                isError ? GVTheme.record.opacity(0.6) : Color.white.opacity(0.14),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: .black.opacity(0.55), radius: 10, y: 4)
                    .shadow(
                        color: isError ? GVTheme.record.opacity(0.22) : .white.opacity(0.12),
                        radius: 12
                    )
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("workspace.toast")
        }
    }
}

// MARK: - Scroll progress line

private struct GVScrollProgressLine: ViewModifier {
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
                            .fill(Color.white.opacity(0.05))
                            .frame(width: geometry.size.width)
                        if contentWidth > visibleWidth + 8 {
                            Capsule()
                                .fill(Color.white.opacity(0.30))
                                .frame(width: fillWidth)
                                .offset(x: progress * (geometry.size.width - fillWidth))
                                .animation(GVMotion.micro, value: progress)
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
    /// The shared charcoal material for every bottom-sheet deck: gradient,
    /// top hairline, hairline stroke, depth shadow. One source so the effect,
    /// depth, AR and blob decks cannot drift apart again.
    func gvCompactDeckPlate() -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 8)
            .background(
                ZStack(alignment: .top) {
                    LinearGradient(
                        colors: [
                            Color(red: 0.135, green: 0.135, blue: 0.143),
                            Color(red: 0.078, green: 0.078, blue: 0.085)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 1 / UIScreen.main.scale)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.62), radius: 12, y: 6)
    }
}

// MARK: - Deck chip

/// The small labelled control used across deck headers and tool rows.
struct GVDeckChip: View {
    let label: String
    var symbol: String?
    var active = false
    var dimmed = false
    var tint: Color = .white
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: GVMetrics.textMicro + 1.5, weight: .black))
                }
                Text(label)
                    .gvMono(GVMetrics.textMicro, .black)
                    .tracking(0.7)
                    .lineLimit(1)
            }
            .foregroundStyle(active ? tint : GVTheme.bone.opacity(dimmed ? 0.32 : 0.78))
            .shadow(color: active ? tint.opacity(0.55) : .clear, radius: 3)
            .padding(.horizontal, symbol == nil ? 7 : 6)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(active ? tint.opacity(0.14) : Color(white: 0.155))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(
                                active ? tint.opacity(0.85) : Color.white.opacity(0.09),
                                lineWidth: active ? 1.1 : 0.8
                            )
                    )
                    .shadow(color: active ? tint.opacity(0.3) : .clear, radius: 4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle(scale: 0.92))
        .disabled(dimmed && !active)
        .accessibilityLabel(label)
        .accessibilityIdentifier("workspace.chip.\(id)")
        .accessibilityValue(active ? "on" : "off")
    }
}

// MARK: - Rail slider

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
            Text(label)
                .gvMono(GVMetrics.textMicro, .bold)
                .tracking(0.5)
                .foregroundStyle(isDragging ? Color.white : GVTheme.ash)
                .shadow(color: isDragging ? .white.opacity(0.5) : .clear, radius: 3)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

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
                            color: .white.opacity(isDragging ? 0.6 : 0.24),
                            radius: isDragging ? 5 : 2
                        )
                    Circle()
                        .fill(Color.white)
                        .frame(width: 11, height: 11)
                        .shadow(
                            color: .white.opacity(isDragging ? 0.95 : 0.45),
                            radius: isDragging ? 7 : 3
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
                .gvMono(GVMetrics.textSmall, .bold)
                .tracking(0.3)
                .foregroundStyle(isDragging ? Color.white : GVTheme.bone.opacity(0.82))
                .shadow(color: isDragging ? .white.opacity(0.45) : .clear, radius: 3)
        }
        .frame(width: 84)
        // Floating readout above the knob while the finger is down: the value
        // stays legible even when the finger covers the rail itself.
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
                    .offset(x: bubbleOffsetX, y: -21)
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

    /// Keeps the floating chip inside the slider's own footprint.
    private var bubbleOffsetX: CGFloat {
        let raw = (84 - 11) * CGFloat(fraction)
        return min(max(raw, -18), 84 - 40)
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
