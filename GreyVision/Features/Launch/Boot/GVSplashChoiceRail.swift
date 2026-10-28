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
    let enabled: Bool
    let apply: () -> Void
}

/// A compact signal console, not a second settings screen. The choices and
/// their availability come from the format model; the cards carry only names.
struct GVSplashChoiceRail: View {
    @State private var isSelecting = false
    @State private var selectionTask: Task<Void, Never>?

    let section: SplashDockSection
    let options: [GVSplashOption]
    let selectedID: String
    @Binding var scrollID: String?
    let onSelect: (GVSplashOption) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            optionScroller
        }
        .background { GVSplashPlate(active: true) }
        .clipShape(GVChamferedPlate(cut: 14))
        .overlay {
            GVChamferedPlate(cut: 14)
                .strokeBorder(GVSplashPalette.border, lineWidth: 0.75)
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
        .padding(.top, 12)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(GVTheme.bone.opacity(0.09)).frame(height: 1)
        }
    }

    private var optionScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(options) { option in card(option) }
            }
            .padding(.vertical, 10)
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
        let hint = option.enabled ? "Selects this format." : "Unavailable on this device."
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
            HStack(spacing: 6) {
                Text(option.label)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Image(systemName: !option.enabled ? "lock" : (selected ? "checkmark.circle.fill" : "circle"))
                    .font(.caption2)
                    .foregroundStyle(selected ? GVSplashPalette.glow : GVTheme.bone)
                    .opacity(selected ? 1 : 0.60)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(GVTheme.bone)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minWidth: 80, minHeight: 44)
            .background { GVSplashPlate(active: selected) }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .modifier(GVSplashBorder(active: selected))
            .gvDecay(selected && isSelecting)
            .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        .disabled(!option.enabled)
        .opacity(option.enabled ? 1 : 0.55)
        .accessibilityValue(selected ? "selected" : "not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(option.label)
        .accessibilityHint(hint)
        .accessibilityIdentifier(option.identifier)
        .id(option.id)
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
