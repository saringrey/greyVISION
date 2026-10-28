import SwiftUI

/// What each selector key shows besides its name. Plain values computed once
/// per browser pass, so the keypad never walks the catalogue itself.
struct GVEffectShelfReadout: Equatable {
    var count: Int
    /// Something on this shelf is rendering right now.
    var live: Bool
}

/// The browser's selector panel: a scope segment over a family keypad.
///
/// Every shelf is on screen at once. The old horizontal rail hid two thirds
/// of the families behind a scroll and gave no hint which of them held the
/// effect that was on; here each key carries its count and lights when one
/// of its effects is rendering.
struct GVEffectDashboardSelector: View {
    let selected: WorkspaceDockCategory
    let readouts: [WorkspaceDockCategory: GVEffectShelfReadout]
    let onSelect: (WorkspaceDockCategory) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection

    static let scopes: [WorkspaceDockCategory] = [.all, .active, .favorites, .recents]
    static let families: [WorkspaceDockCategory] = WorkspaceDockCategory.shelfCategories + [.blobs, .spatial]
    /// Dense by design: every shelf on screen at once is the point. Keys are
    /// ~85pt wide, so the hit area stays generous along the axis that matters.
    private static let keyHeight: CGFloat = 34

    var body: some View {
        VStack(spacing: 8) {
            scopeSegment
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(Self.families) { family in
                    key(family)
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
                    .frame(maxWidth: .infinity, minHeight: Self.keyHeight)
                    .background { plate(selected: isSelected, live: false) }
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

    private func key(_ family: WorkspaceDockCategory) -> some View {
        let isSelected = family == selected
        let readout = readouts[family] ?? GVEffectShelfReadout(count: 0, live: false)
        return Button { onSelect(family) } label: {
            HStack(spacing: 0) {
                Text(family.displayLabel.uppercased())
                    .font(GVTheme.mono(10, isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                Text("\(readout.count)")
                    .font(GVTheme.mono(9, .regular))
                    .monospacedDigit()
                    .opacity(0.55)
            }
            .padding(.horizontal, 8)
            .foregroundStyle(isSelected ? Color.black : GVTheme.bone.opacity(0.74))
            .frame(maxWidth: .infinity, minHeight: Self.keyHeight)
            .background { plate(selected: isSelected, live: readout.live) }
            .overlay(alignment: .topLeading) {
                if readout.live {
                    Circle()
                        .fill(isSelected ? Color.black : Color.mint)
                        .frame(width: 4, height: 4)
                        .shadow(color: .mint.opacity(isSelected ? 0 : 0.9), radius: 3)
                        .padding(4)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle(scale: 0.94))
        .accessibilityLabel(family.displayLabel)
        .accessibilityValue([isSelected ? "selected" : nil, readout.live ? "has an active effect" : nil,
                             "\(readout.count) items"].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("workspace.browser.category.\(family.rawValue)")
    }

    /// One sliding bone plate marks the selection across both the segment and
    /// the keypad, so the eye follows a single object rather than two states.
    @ViewBuilder
    private func plate(selected isSelected: Bool, live: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        if isSelected {
            shape
                .fill(GVTheme.bone)
                .shadow(color: .white.opacity(0.25), radius: 8)
                .matchedGeometryEffect(id: "selection", in: selection)
        } else {
            shape
                .fill(Color.white.opacity(live ? 0.075 : 0.04))
                .overlay(shape.strokeBorder(Color.white.opacity(live ? 0.16 : 0.07), lineWidth: 0.75))
        }
    }
}
