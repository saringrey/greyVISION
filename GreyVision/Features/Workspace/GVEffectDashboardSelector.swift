import SwiftUI

/// What each selector card shows besides its name. Plain values computed once
/// per browser pass, so the selector never walks the catalogue itself.
struct GVEffectShelfReadout: Equatable {
    var count: Int
    /// Something on this shelf is rendering right now.
    var live: Bool
}

/// The browser's selector panel: a scope segment, the effect families as
/// picture cards, and the two capture modes.
///
/// The families used to be a 4×4 keypad of words, which read as a wall of
/// text. Each family is now a card showing the live camera frame through its
/// signature effect, so the operator picks a family by how it looks; the
/// name is a caption, not the content.
struct GVEffectDashboardSelector: View {
    let selected: WorkspaceDockCategory
    let readouts: [WorkspaceDockCategory: GVEffectShelfReadout]
    /// The live-frame preview of a family's signature effect, once rendered.
    let preview: (WorkspaceDockCategory) -> UIImage?
    let onAppearFamily: (WorkspaceDockCategory) -> Void
    let onSelect: (WorkspaceDockCategory) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection

    static let scopes: [WorkspaceDockCategory] = [.all, .active, .favorites, .recents]
    static let families: [WorkspaceDockCategory] = WorkspaceDockCategory.shelfCategories
    static let modes: [WorkspaceDockCategory] = [.objects, .spatial, .blobs]
    private static let rowHeight: CGFloat = 32

    var body: some View {
        VStack(spacing: 8) {
            scopeSegment
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(Self.families) { family in
                    card(family)
                }
            }
            HStack(spacing: 6) {
                ForEach(Self.modes) { mode in
                    modeButton(mode)
                }
            }
        }
        .animation(GVMotion.resolved(.spring(response: 0.34, dampingFraction: 0.8), reduceMotion: reduceMotion), value: selected)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.browser.categories")
    }

    private var scopeSegment: some View {
        HStack(spacing: 4) {
            ForEach(Self.scopes) { scope in
                let isSelected = scope == selected
                Button { onSelect(scope) } label: {
                    HStack(spacing: 5) {
                        if let symbol = scope.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 10, weight: .semibold))
                                .symbolEffect(.bounce, value: isSelected)
                        }
                        Text(scope.displayLabel.uppercased())
                            .font(GVTheme.mono(10.5, isSelected ? .semibold : .medium))
                            .lineLimit(1)
                        Text("\(readouts[scope]?.count ?? 0)")
                            .font(GVTheme.mono(9.5, .regular))
                            .monospacedDigit()
                            .opacity(0.6)
                            .contentTransition(.numericText())
                    }
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(isSelected ? Color.black : GVTheme.bone.opacity(0.7))
                    .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
                    .background { plate(selected: isSelected) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(GVPressStyle(scale: 0.94))
                .accessibilityLabel(scope.displayLabel)
                .accessibilityIdentifier("workspace.browser.category.\(scope.rawValue)")
                .accessibilityValue(isSelected ? "selected" : "")
            }
        }
        .padding(3)
        .background(Color.black.opacity(0.28), in: Capsule())
    }

    /// A family as a picture: the live frame through the family's signature
    /// effect, the name and count set over a scrim, a light when one of its
    /// effects is on, and a bone frame when selected.
    private func card(_ family: WorkspaceDockCategory) -> some View {
        let isSelected = family == selected
        let readout = readouts[family] ?? GVEffectShelfReadout(count: 0, live: false)
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return Button { onSelect(family) } label: {
            Color.clear
                .aspectRatio(1.35, contentMode: .fit)
                .overlay {
                    if let image = preview(family) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    } else if let symbol = family.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 16, weight: .light))
                            .foregroundStyle(GVTheme.bone.opacity(0.5))
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(family.displayLabel.uppercased())
                            .font(GVTheme.mono(9, .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: 0)
                        Text("\(readout.count)")
                            .font(GVTheme.mono(8.5, .medium))
                            .monospacedDigit()
                            .opacity(0.7)
                    }
                    .foregroundStyle(GVTheme.bone)
                    .padding(.horizontal, 6)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                    .background {
                        LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if readout.live {
                        Circle()
                            .fill(Color.mint)
                            .frame(width: 5, height: 5)
                            .shadow(color: .mint.opacity(0.9), radius: 3)
                            .padding(5)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .background(Color.white.opacity(0.05))
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(isSelected ? GVTheme.bone : Color.white.opacity(0.1), lineWidth: isSelected ? 1.5 : 0.75)
                }
                .shadow(color: .white.opacity(isSelected ? 0.22 : 0), radius: 8)
                .saturation(isSelected || selected.isShelf == false ? 1 : 0.55)
                .opacity(isSelected || selected.isShelf == false ? 1 : 0.85)
                .contentShape(shape)
        }
        .buttonStyle(GVPressStyle(scale: 0.95))
        .onAppear { onAppearFamily(family) }
        .accessibilityLabel(family.displayLabel)
        .accessibilityValue([isSelected ? "selected" : nil, readout.live ? "has an active effect" : nil,
                             "\(readout.count) effects"].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("workspace.browser.category.\(family.rawValue)")
    }

    private func modeButton(_ mode: WorkspaceDockCategory) -> some View {
        GVSpecialModeButton(
            mode: mode,
            selected: mode == selected,
            readout: readouts[mode] ?? GVEffectShelfReadout(count: 0, live: false),
            action: { onSelect(mode) }
        )
    }

    /// One sliding bone plate marks the selection across the segment and the
    /// mode row, so the eye follows a single object.
    @ViewBuilder
    private func plate(selected isSelected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        if isSelected {
            shape
                .fill(GVTheme.bone)
                .shadow(color: .white.opacity(0.25), radius: 8)
                .matchedGeometryEffect(id: "selection", in: selection)
        } else {
            shape
                .fill(Color.white.opacity(0.04))
                .overlay(shape.strokeBorder(Color.white.opacity(0.07), lineWidth: 0.75))
        }
    }
}

/// Tracking, LiDAR and AR are capture modes, not effects — the heavy
/// hitters. They share one size and say what they are quietly: each carries
/// its own colour in its glyph, a thin coloured edge and a faint tint, and a
/// live dot when running. Selected, they take the same white plate as every
/// other selector key, with the glyph keeping its colour.
private struct GVSpecialModeButton: View {
    let mode: WorkspaceDockCategory
    let selected: Bool
    let readout: GVEffectShelfReadout
    let action: () -> Void

    /// Acid for tracking (the instrument's "armed"), scanner blue for LiDAR,
    /// violet for AR — distinct, and never louder than the white type.
    private var accent: Color {
        switch mode {
        case .blobs: GVTheme.acid
        case .spatial: Color(red: 0.32, green: 0.78, blue: 1.0)
        default: Color(red: 0.76, green: 0.52, blue: 1.0)
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: mode.symbol ?? "circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? accent.mix(with: .black, by: 0.35) : accent)
                Text(mode.displayLabel.uppercased())
                    .font(GVTheme.mono(10.5, selected ? .bold : .semibold))
                    .tracking(0.8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(selected ? Color.black : GVTheme.bone.opacity(0.85))
                if readout.live {
                    Circle()
                        .fill(accent)
                        .frame(width: 5, height: 5)
                        .shadow(color: accent.opacity(0.8), radius: 3)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background {
                if selected {
                    shape.fill(GVTheme.bone).shadow(color: .white.opacity(0.25), radius: 8)
                } else {
                    shape.fill(accent.opacity(0.07))
                }
            }
            .overlay {
                shape.strokeBorder(accent.opacity(selected ? 0 : 0.42), lineWidth: 0.9)
            }
            .contentShape(shape)
        }
        .buttonStyle(GVPressStyle(scale: 0.95))
        .accessibilityLabel(mode.displayLabel)
        .accessibilityValue([selected ? "selected" : nil, readout.live ? "live" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("workspace.browser.category.\(mode.rawValue)")
    }
}
