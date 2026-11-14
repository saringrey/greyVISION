import SwiftUI

/// What each selector chip shows besides its name. Plain values computed once
/// per browser pass, so the selector never walks the catalogue itself.
struct GVEffectShelfReadout: Equatable {
    var count: Int
    /// Something on this shelf is rendering right now.
    var live: Bool
}

/// The browser's navigation: the four saved lists, and the shelves.
///
/// Two rows, one vocabulary. The saved lists sit in a fixed row because they
/// are where a creator goes back to — Active, Favorites, Recent — and they
/// must never be scrolled away. The shelves sit in a scrolling row because
/// there are eight of them and they are browsed by eye: each one carries a
/// preview of its signature effect, so a family is chosen by how it looks
/// rather than by remembering what "Generative" meant.
///
/// The capture modes close the scrolling row behind a rule. They are capture
/// sources rather than effects, and they used to live in a third row with a
/// third shape of control; folding them into the same row as everything else
/// is what makes the whole strip read as one shelf of choices.
struct GVEffectDashboardSelector: View {
    let selected: WorkspaceDockCategory
    let readouts: [WorkspaceDockCategory: GVEffectShelfReadout]
    /// The live-frame preview of a family's signature effect, once rendered.
    let preview: (WorkspaceDockCategory) -> UIImage?
    let onAppearCategory: (WorkspaceDockCategory) -> Void
    let onSelect: (WorkspaceDockCategory) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let scopes: [WorkspaceDockCategory] = [.all, .active, .favorites, .recents]
    static let families: [WorkspaceDockCategory] = WorkspaceDockCategory.shelfCategories
    static let modes: [WorkspaceDockCategory] = [.objects, .spatial, .blobs]

    var body: some View {
        VStack(spacing: 8) {
            scopeRow
            browseRow
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Saved lists

    /// The four lists a creator keeps coming back to. Words, not icons: the
    /// labels are short enough to read, and an icon beside a word says the
    /// same thing twice.
    private var scopeRow: some View {
        HStack(spacing: 6) {
            ForEach(Self.scopes) { scope in
                scopeChip(scope)
            }
        }
    }

    private func scopeChip(_ scope: WorkspaceDockCategory) -> some View {
        let isSelected = scope == selected
        let count = readouts[scope]?.count ?? 0
        return Button { onSelect(scope) } label: {
            HStack(spacing: 5) {
                Text(scope.displayLabel)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                // An empty list says nothing a glance would not, and the row
                // has to survive the narrower column a sideways workspace
                // gives it.
                if count > 0 || scope == .all {
                    Text("\(count)")
                        .font(GVTheme.mono(10, .medium))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .opacity(isSelected ? 0.7 : 0.5)
                        .layoutPriority(-1)
                }
            }
            .foregroundStyle(isSelected ? Color.black : GVTheme.bone.opacity(0.72))
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .background { chipPlate(isSelected) }
            .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        .frame(minHeight: GVMetrics.touchTarget)
        .accessibilityLabel(scope.displayLabel)
        .accessibilityValue(isSelected ? "selected" : "")
        .accessibilityHint("\(count) effects")
        .accessibilityIdentifier("workspace.browser.category.\(scope.rawValue)")
    }

    // MARK: - Shelves

    /// The effect families and the capture modes, in one scrolling row.
    private var browseRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.families) { family in
                        familyChip(family)
                    }
                    Rectangle()
                        .fill(GVTheme.separator)
                        .frame(width: 1, height: 22)
                    ForEach(Self.modes) { mode in
                        modeChip(mode)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onChange(of: selected) { _, item in
                withAnimation(GVMotion.resolved(GVMotion.panel, reduceMotion: reduceMotion)) {
                    proxy.scrollTo(item, anchor: .center)
                }
            }
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
            .accessibilityIdentifier("workspace.browser.categories")
        }
    }

    /// A family as a picture: the live frame through the family's signature
    /// effect, its name, and a light when one of its effects is running.
    ///
    /// The preview is the point. The family rail used to draw a small
    /// procedural diagram per family, which made eight little abstract
    /// squiggles that a first-time user had to learn before the rail meant
    /// anything. A picture of what the family does needs no key.
    private func familyChip(_ family: WorkspaceDockCategory) -> some View {
        let isSelected = family == selected
        let readout = readouts[family] ?? GVEffectShelfReadout(count: 0, live: false)
        return Button { onSelect(family) } label: {
            HStack(spacing: 6) {
                familyThumbnail(family, isSelected: isSelected)
                Text(family.displayLabel)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.black : GVTheme.bone.opacity(0.78))
                    .lineLimit(1)
                if readout.live {
                    Circle()
                        .fill(isSelected ? Color.black.opacity(0.55) : GVTheme.acid)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .frame(minHeight: 36)
            .background { chipPlate(isSelected) }
            .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        .frame(minHeight: GVMetrics.touchTarget)
        .onAppear { onAppearCategory(family) }
        .accessibilityLabel(family.displayLabel)
        .accessibilityValue(isSelected ? "selected" : "")
        .accessibilityHint("\(readout.count) effects")
        .accessibilityIdentifier("workspace.browser.category.\(family.rawValue)")
    }

    @ViewBuilder
    private func familyThumbnail(_ family: WorkspaceDockCategory, isSelected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        ZStack {
            shape.fill(Color.white.opacity(isSelected ? 0.16 : 0.08))
            if let image = preview(family) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(shape)
            } else if let symbol = family.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? Color.black.opacity(0.55) : GVTheme.bone.opacity(0.5))
            }
        }
        .frame(width: 26, height: 26)
        .overlay(shape.strokeBorder(Color.white.opacity(isSelected ? 0.30 : 0.14), lineWidth: 0.5))
    }

    /// AR, LiDAR and Tracking: capture sources and capture modes, not
    /// effects. They keep their own glyphs because they are a different kind
    /// of thing, and a light when the source is running.
    private func modeChip(_ mode: WorkspaceDockCategory) -> some View {
        let isSelected = mode == selected
        let readout = readouts[mode] ?? GVEffectShelfReadout(count: 0, live: false)
        return Button { onSelect(mode) } label: {
            HStack(spacing: 5) {
                Image(systemName: mode.symbol ?? "circle")
                    .font(.system(size: 11, weight: .semibold))
                Text(mode.displayLabel)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                if readout.live {
                    Circle()
                        .fill(isSelected ? Color.black.opacity(0.55) : GVTheme.acid)
                        .frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(isSelected ? Color.black : GVTheme.bone.opacity(0.78))
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .background { chipPlate(isSelected) }
            .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        .frame(minHeight: GVMetrics.touchTarget)
        .accessibilityLabel(mode.displayLabel)
        .accessibilityValue(isSelected ? "selected" : "")
        .accessibilityHint("\(readout.count) options")
        .accessibilityIdentifier("workspace.browser.category.\(mode.rawValue)")
    }

    /// One plate for every chip in the strip: a bone fill when the chip is
    /// the one that is open, and a quiet outline when it is not. The
    /// instrument used to mark selection three different ways in three
    /// different rows — a bone plate, a ring and a capsule — which meant
    /// learning a new symbol for "you are here" every time the eye moved.
    @ViewBuilder
    private func chipPlate(_ isSelected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if isSelected {
            shape.fill(GVTheme.bone)
        } else {
            shape
                .fill(Color.white.opacity(0.055))
                .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.75))
        }
    }
}
