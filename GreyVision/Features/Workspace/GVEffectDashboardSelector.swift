import SwiftUI

/// What each selector chip shows besides its name. Plain values computed once
/// per browser pass, so the selector never walks the catalogue itself.
struct GVEffectShelfReadout: Equatable {
    var count: Int
    /// Something on this shelf is rendering right now.
    var live: Bool
}

/// The browser's navigation as a mini dock.
///
/// The browser used to open on a wall of fifteen chips in three rows — saved
/// lists, capture modes, and the eight families — before the operator had
/// seen a single effect. Now it opens on one slim row of three groups:
/// Library, Effects and Capture. Each group names what is open inside it, so
/// the dock alone answers "where am I". Tapping a group expands a tray of its
/// categories right under the dock; picking one closes the tray again, so the
/// previews get the screen back.
struct GVEffectDashboardSelector: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let selected: WorkspaceDockCategory
    let readouts: [WorkspaceDockCategory: GVEffectShelfReadout]
    let onSelect: (WorkspaceDockCategory) -> Void

    @State private var expanded: Group?

    static let scopes: [WorkspaceDockCategory] = [.all, .active, .favorites, .recents]
    static let families: [WorkspaceDockCategory] = WorkspaceDockCategory.shelfCategories
    static let modes: [WorkspaceDockCategory] = [.objects, .spatial, .blobs]

    enum Group: String, CaseIterable, Identifiable {
        case library, effects, capture

        var id: String { rawValue }

        var title: String {
            switch self {
            case .library: "Library"
            case .effects: "Effects"
            case .capture: "Capture"
            }
        }

        var symbol: String {
            switch self {
            case .library: "square.stack"
            case .effects: "sparkles"
            case .capture: "camera.aperture"
            }
        }

        var members: [WorkspaceDockCategory] {
            switch self {
            case .library: GVEffectDashboardSelector.scopes
            case .effects: GVEffectDashboardSelector.families
            case .capture: GVEffectDashboardSelector.modes
            }
        }

        static func containing(_ category: WorkspaceDockCategory) -> Group {
            allCases.first { $0.members.contains(category) } ?? .library
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            dock
            if let expanded {
                tray(for: expanded)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }
        }
        .animation(GVMotion.resolved(GVMotion.snap, reduceMotion: reduceMotion), value: expanded)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Dock

    private var dock: some View {
        HStack(spacing: 3) {
            ForEach(Group.allCases) { group in
                dockSegment(group)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.05), in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 0.75))
        .accessibilityIdentifier("workspace.browser.categories")
    }

    /// One group. The segment holding the open category is lit and names that
    /// category ("Glitch", "Favorites"); the others name their group.
    private func dockSegment(_ group: Group) -> some View {
        let owner = Group.containing(selected) == group
        let isOpen = expanded == group
        let live = group.members.contains { readouts[$0]?.live == true }
        let label = owner ? selected.displayLabel : group.title
        return Button {
            GVInteractionHaptics.select()
            expanded = isOpen ? nil : group
        } label: {
            HStack(spacing: 5) {
                Image(systemName: owner ? (selected.symbol ?? group.symbol) : group.symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 13, weight: owner ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if live, !owner {
                    Circle().fill(GVTheme.acid).frame(width: 5, height: 5)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .opacity(0.55)
            }
            .foregroundStyle(owner ? Color.black : GVTheme.bone.opacity(0.78))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background {
                if owner {
                    Capsule(style: .continuous).fill(GVTheme.bone)
                } else if isOpen {
                    Capsule(style: .continuous).fill(Color.white.opacity(0.1))
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(GVPressStyle())
        .frame(minHeight: GVMetrics.touchTarget - 4)
        .accessibilityLabel(group.title)
        .accessibilityValue(owner ? "\(selected.displayLabel), \(isOpen ? "expanded" : "collapsed")"
                                  : (isOpen ? "expanded" : "collapsed"))
        .accessibilityHint("Shows the \(group.title.lowercased()) categories")
        .accessibilityIdentifier("workspace.browser.group.\(group.rawValue)")
    }

    // MARK: - Tray

    private func tray(for group: Group) -> some View {
        GVFlowLayout(spacing: 5, lineSpacing: 5) {
            ForEach(group.members) { category in
                chip(category)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.75))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.browser.tray.\(group.rawValue)")
    }

    private func chip(_ category: WorkspaceDockCategory) -> some View {
        let isSelected = category == selected
        let readout = readouts[category] ?? GVEffectShelfReadout(count: 0, live: false)
        return Button {
            onSelect(category)
            expanded = nil
        } label: {
            HStack(spacing: 5) {
                if let symbol = category.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(isSelected ? 1 : 0.7)
                }
                Text(category.displayLabel)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                if readout.count > 0, Self.scopes.contains(category) {
                    Text("\(readout.count)")
                        .font(GVTheme.mono(10, .medium))
                        .monospacedDigit()
                        .opacity(0.55)
                }
                if readout.live {
                    Circle()
                        .fill(isSelected ? Color.black.opacity(0.55) : GVTheme.acid)
                        .frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(isSelected ? Color.black : GVTheme.bone.opacity(0.8))
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background {
                let shape = Capsule(style: .continuous)
                if isSelected {
                    shape.fill(GVTheme.bone)
                } else {
                    shape.fill(Color.white.opacity(0.06))
                        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.75))
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(GVPressStyle())
        .frame(minHeight: 40)
        .accessibilityLabel(category.displayLabel)
        .accessibilityValue(isSelected ? "selected" : "")
        .accessibilityHint("\(readout.count) \(Self.modes.contains(category) ? "options" : "effects")")
        .accessibilityIdentifier("workspace.browser.category.\(category.rawValue)")
    }
}

/// Lays chips out left to right, wrapping to a new line when the next one
/// would not fit. A real layout rather than a GeometryReader inside a scroll
/// view, which is what used to leave tall empty gaps in the browser.
struct GVFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * lineSpacing
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
