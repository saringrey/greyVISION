import SwiftUI

/// Names and states for one visual effect control.
struct GVEffectIndexItem: Identifiable, Equatable {
    let effect: WorkspaceAdjustableEffect
    let name: String
    let active: Bool
    let favorite: Bool
    let cost: Int
    let needsAudio: Bool
    let accessibilityValue: String

    var id: String {
        effect.rawValue
    }
}

/// A named group of effects, rendered as a labelled section in the index.
struct GVEffectIndexSection: Identifiable, Equatable {
    let id: String
    let title: String
    let items: [GVEffectIndexItem]

    init(id: String, title: String, items: [GVEffectIndexItem]) {
        self.id = id
        self.title = title
        // Stack slots have independent identities, but discovery controls are
        // per effect. Keep the first occurrence and its render order.
        var seen = Set<String>()
        self.items = items.filter { seen.insert($0.id).inserted }
    }
}

/// The catalogue as a picture grid.
///
/// Every tile carries a real preview of the effect it stands for, rendered by
/// the production shader over a frame tapped from the live camera when the
/// browser opened. The grid is browsable at a glance because each tile looks
/// like the thing it does.
struct GVEffectIndexList: View {
    let sections: [GVEffectIndexSection]
    /// The preview source. Held as an observed object so a tile lights up the
    /// moment its render lands.
    @ObservedObject var thumbnails: GVEffectThumbnailStore
    let audioRunning: Bool
    let onSelect: (WorkspaceAdjustableEffect) -> Void
    let onToggleFavorite: (WorkspaceAdjustableEffect) -> Void
    let onOpenMicrophoneSettings: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Three across on a phone, more on a wide panel. Fixed rather than
    /// scaled: a preview grid that reflows when the type grows stops being
    /// comparable between one visit and the next.
    private let tileMinimum: CGFloat = 96
    private let tileSpacing: CGFloat = 10

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections) { section in
                    sectionHeader(section)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: tileMinimum), spacing: tileSpacing)],
                              spacing: 16) {
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                            tile(item)
                                .gvTileEntrance(index: index, reduceMotion: reduceMotion)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 18)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("workspace.effects.index")
    }

    /// The section's name and how much is in it. One line, no rules: the
    /// pictures below already say what the group is.
    private func sectionHeader(_ section: GVEffectIndexSection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(section.title)
                .gvSystemFont(15, .semibold)
                .foregroundStyle(GVTheme.bone)
                .lineLimit(1)
            Text("\(section.items.count)")
                .font(GVTheme.mono(11, .medium))
                .foregroundStyle(GVTheme.bone.opacity(0.45))
                .monospacedDigit()
                .contentTransition(.numericText())
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 9)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func tile(_ item: GVEffectIndexItem) -> some View {
        Button {
            onSelect(item.effect)
        } label: {
            GVEffectTileFace(model: GVEffectTileModel(
                name: item.name,
                image: thumbnails.image(for: item.effect),
                previewUnavailable: thumbnails.isUnavailable(item.effect),
                active: item.active,
                favorite: item.favorite,
                cost: item.cost,
                needsAudio: item.needsAudio
            ))
            .contentShape(Rectangle())
        }
        .buttonStyle(GVEffectTileStyle())
        .accessibilityLabel(item.name)
        .accessibilityValue(item.accessibilityValue)
        .accessibilityIdentifier("workspace.effect.\(item.effect.rawValue)")
        // Asked for the moment the tile appears. The store renders on a
        // utility queue and caches, so a tile that scrolls back into view
        // never waits for a second render.
        .onAppear { thumbnails.request(item.effect) }
        .contextMenu {
            Button {
                onToggleFavorite(item.effect)
            } label: {
                Label(item.favorite ? "Remove favorite" : "Save favorite", systemImage: "star")
            }
            Button("Adjust effect") {
                onSelect(item.effect)
            }
            Text(item.effect.detail.capitalized)
            Text("Render cost \(item.cost) of 3")
            if item.needsAudio, !audioRunning {
                Button("Open Microphone Settings", action: onOpenMicrophoneSettings)
            }
        }
    }
}
