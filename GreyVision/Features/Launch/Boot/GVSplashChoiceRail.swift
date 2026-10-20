import SwiftUI

enum SplashDockSection: String, CaseIterable, Identifiable {
    case codec
    case frameRate = "fps"
    case resolution

    var id: String { rawValue }

    var label: String {
        switch self {
        case .codec: "CODEC"
        case .frameRate: "FPS"
        case .resolution: "RES"
        }
    }

    var title: String {
        switch self {
        case .codec: "Encoding"
        case .frameRate: "Frame rate"
        case .resolution: "Resolution"
        }
    }
}

struct GVSplashOption: Identifiable {
    let id: String
    let identifier: String
    let label: String
    let spec: String
    let note: String
    let meter: Int
    let chips: [GVSplashSpecChip]
    let enabled: Bool
    let apply: () -> Void
}

struct GVSplashSpecChip: Identifiable {
    let caption: String
    let value: String
    var meter: Int = 0
    var id: String { caption }
}

/// A compact signal console, not a second settings screen. The choices and
/// their availability are unchanged; all readouts come from the format model.
struct GVSplashChoiceRail: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var isSelecting = false
    @State private var selectionTask: Task<Void, Never>?

    let section: SplashDockSection
    let options: [GVSplashOption]
    let selectedID: String
    @Binding var scrollID: String?
    let onSelect: (GVSplashOption) -> Void

    private let surface = Color(white: 0.065)
    private var compact: Bool { verticalSizeClass == .compact }
    private var selected: GVSplashOption? { options.first { $0.id == selectedID } ?? options.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            optionScroller
            if let selected { readout(for: selected) }
        }
        .background(surface)
        .clipShape(GVChamferedPlate(cut: 14))
        .overlay {
            GVChamferedPlate(cut: 14)
                .strokeBorder(GVTheme.bone.opacity(0.18), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .overlay { GVSplashRegistration(color: GVTheme.bone.opacity(0.35), inset: 8) }
        .frame(maxWidth: .infinity)
        .onDisappear { selectionTask?.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("boot.format.panel")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(section.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(GVTheme.bone)
            Spacer()
            Text("\(options.count) FORMATS")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(GVTheme.bone.opacity(0.62))
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(GVTheme.bone.opacity(0.09)).frame(height: 1)
        }
    }

    private var optionScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(options) { option in card(option) }
            }
            .padding(.vertical, 14)
            .scrollTargetLayout()
        }
        .scrollPosition(id: $scrollID, anchor: .leading)
        .defaultScrollAnchor(.leading)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .gvHorizontalEdgeFade()
        .accessibilityIdentifier("boot.choices.\(section.rawValue)")
    }

    private func card(_ option: GVSplashOption) -> some View {
        let selected = option.id == selectedID
        let width: CGFloat = section == .codec ? 156 : 128
        let height: CGFloat = compact ? 72 : (section == .codec ? 100 : 82)
        let borderOpacity: Double = selected ? 0.5 : 0.10
        return Button {
            guard option.enabled else { return }
            selectionTask?.cancel()
            isSelecting = true
            GVInteractionHaptics.select()
            onSelect(option)
            selectionTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                isSelecting = false
            }
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text(cardTitle(option))
                        .font(.system(.subheadline, design: .monospaced).weight(.medium))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    Image(systemName: !option.enabled ? "lock" : (selected ? "checkmark" : "plus"))
                        .font(.caption)
                        .opacity(selected ? 1 : 0.60)
                }
                Spacer(minLength: 0)
                Text(option.spec)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(GVTheme.bone.opacity(0.70))
                    .lineLimit(2)
            }
            .foregroundStyle(GVTheme.bone)
            .padding(12)
            .frame(width: width, height: height)
            .background(Color.white.opacity(selected ? 0.10 : 0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(GVTheme.bone.opacity(borderOpacity), lineWidth: 0.75)
            }
            .gvDecay(selected && isSelecting, seed: Double(option.meter))
            .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        .disabled(!option.enabled)
        .opacity(option.enabled ? 1 : 0.55)
        .accessibilityValue(selected ? "selected" : "not selected")
        .accessibilityLabel(option.label)
        .accessibilityHint(option.enabled ? option.note : "Unavailable. \(option.note)")
        .accessibilityIdentifier(option.identifier)
        .id(option.id)
    }

    private func cardTitle(_ option: GVSplashOption) -> String {
        guard section == .codec else { return option.label }
        return option.label.replacingOccurrences(of: "PRORES ", with: "ProRes\n")
    }

    private func readout(for option: GVSplashOption) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(option.label)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(GVTheme.bone)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("SELECTED")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(GVTheme.bone.opacity(0.65))
            }
            Text(option.note)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(GVTheme.bone.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("boot.format.note")
            if section == .codec, !compact {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 12) {
                    ForEach(option.chips) { chip in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(chip.caption)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(GVTheme.bone.opacity(0.62))
                            Text(chip.value)
                                .font(.system(.caption2, design: .monospaced).weight(.medium))
                                .foregroundStyle(GVTheme.bone)
                                .lineLimit(1)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if !compact { GVSplashTickRule(height: 5) }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .background(Color.black.opacity(0.25))
        .contentTransition(.opacity)
        .animation(GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion), value: option.id)
    }
}

/// Registration ticks on the format instrument; static and low contrast.
struct GVSplashTickRule: View {
    var height: CGFloat = 6
    var spacing: CGFloat = 7
    var color: Color = .white

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var index = 0
            var x: CGFloat = 0
            while x <= size.width {
                let tick = index.isMultiple(of: 5) ? height : height * 0.45
                path.move(to: CGPoint(x: x, y: size.height - tick))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
                index += 1
            }
            context.stroke(path, with: .color(color.opacity(0.16)), lineWidth: 0.75)
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct GVSplashRegistration: View {
    var color: Color
    var inset: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                path.move(to: CGPoint(x: inset, y: geometry.size.height - inset))
                path.addLine(to: CGPoint(x: inset + 7, y: geometry.size.height - inset))
                path.move(to: CGPoint(x: geometry.size.width - inset - 7, y: inset))
                path.addLine(to: CGPoint(x: geometry.size.width - inset, y: inset))
            }
            .stroke(color, lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
