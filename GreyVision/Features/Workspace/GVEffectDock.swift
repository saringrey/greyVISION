import SwiftUI

/// The effect picker as a dock that grows up out of the Effects button.
///
/// The first tap shows five labelled groups (Saved, Glitch, Film, Warp,
/// Capture) directly above the button. A group raises a row of its specific
/// shelves as small text pills, and the first shelf's live previews rise
/// above that, so everything builds bottom up and the picture stays visible.
/// The full catalogue with search lives under Saved → All effects.
struct GVEffectDock: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var audioRuntime: AudioReactiveRuntime
    @EnvironmentObject private var preferences: GVPreferences
    @EnvironmentObject private var decay: GVDecayEngine
    @EnvironmentObject private var toasts: GVToastBox
    @StateObject private var thumbnails = GVEffectThumbnailStore.shared
    @ObservedObject var editor: EffectEditingSession
    /// Opens the full-screen catalogue (search and every shelf).
    let onOpenCatalogue: () -> Void
    let onClose: () -> Void

    private static let library: [WorkspaceDockCategory] = [.active, .favorites, .recents]
    private static let families: [WorkspaceDockCategory] = WorkspaceDockCategory.shelfCategories

    @State private var group: DockGroup?
    @State private var category: WorkspaceDockCategory?

    /// Five groups instead of twenty glyphs: the row a newcomer meets reads
    /// in words, and the specifics live one level down.
    enum DockGroup: String, CaseIterable, Identifiable {
        case saved, glitch, film, warp, capture

        var id: String { rawValue }

        var title: String {
            switch self {
            case .saved: "Saved"
            case .glitch: "Glitch"
            case .film: "Film"
            case .warp: "Warp"
            case .capture: "Capture"
            }
        }

        var symbol: String {
            switch self {
            case .saved: "star"
            case .glitch: "square.split.diagonal.2x2"
            case .film: "film"
            case .warp: "circle.hexagongrid"
            case .capture: "camera.aperture"
            }
        }

        var members: [WorkspaceDockCategory] {
            switch self {
            case .saved: [.active, .favorites, .recents]
            case .glitch: [.glitch, .time]
            case .film: [.analog, .look, .lens]
            case .warp: [.warp, .generative, .audio]
            case .capture: [.objects, .spatial, .blobs]
            }
        }
    }

    var body: some View {
        // Spaced for the tracker tags that hang off each plate's corner.
        VStack(spacing: 18) {
            if let category {
                strip(for: category)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(category)
            }
            if let group {
                subRow(for: group)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            mainRow
        }
        .animation(GVMotion.resolved(GVMotion.snap, reduceMotion: reduceMotion), value: category)
        .animation(GVMotion.resolved(GVMotion.snap, reduceMotion: reduceMotion), value: group)
        .onAppear { thumbnails.refreshFromLiveSource() }
        .onDisappear { editor.endPreview() }
        .sensoryFeedback(.selection, trigger: category)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.browser")
    }

    // MARK: - Main row

    private var mainRow: some View {
        // Two rows of three: the five groups plus the full catalogue, big
        // enough to read at a glance and hit without looking.
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(DockGroup.allCases) { item in
                groupButton(item)
            }
            catalogueButton
        }
        .padding(5)
        .gvChromePlate(RoundedRectangle(cornerRadius: GVSplashDock.radius, style: .continuous))
        .accessibilityIdentifier("workspace.browser.categories")
    }

    private func groupButton(_ item: DockGroup) -> some View {
        let isOpen = group == item
        let live = item.members.contains(where: isLive)
        return Button {
            GVInteractionHaptics.select()
            if isOpen {
                group = nil
                category = nil
            } else {
                group = item
                // Open the first real shelf straight away so one tap already
                // shows pictures; capture modes wait for an explicit pick.
                category = item == .capture ? nil : item.members.first { !effects(in: $0).isEmpty } ?? item.members.first
            }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: item.symbol)
                    .font(.system(size: 19, weight: .medium))
                Text(item.title)
                    .font(.system(size: 11.5, weight: isOpen ? .semibold : .medium))
                    .tracking(0.2)
                    .lineLimit(1)
            }
            .foregroundStyle(isOpen ? Color.black : GVTheme.bone.opacity(0.88))
            .frame(maxWidth: .infinity, minHeight: 58)
            .background {
                let tile = RoundedRectangle(cornerRadius: 5, style: .continuous)
                if isOpen {
                    tile.fill(GVTheme.accent)
                } else {
                    tile.fill(Color.white.opacity(0.05))
                        .overlay(tile.fill(GVTheme.accent.opacity(0.10)))
                }
            }
            .overlay(alignment: .topTrailing) {
                if live, !isOpen {
                    Circle().fill(GVTheme.acid).frame(width: 5, height: 5).padding(7)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        .accessibilityLabel(item.title)
        .accessibilityValue(isOpen ? "expanded" : (live ? "has active effects" : "collapsed"))
        .accessibilityIdentifier("workspace.browser.group.\(item.rawValue)")
    }

    private var catalogueButton: some View {
        Button {
            GVInteractionHaptics.select()
            onOpenCatalogue()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 19, weight: .medium))
                Text("All")
                    .font(.system(size: 11.5, weight: .medium))
                    .tracking(0.2)
            }
            .foregroundStyle(GVTheme.bone.opacity(0.88))
            .frame(maxWidth: .infinity, minHeight: 58)
            .background {
                let tile = RoundedRectangle(cornerRadius: 5, style: .continuous)
                tile.fill(Color.white.opacity(0.05)).overlay(tile.fill(GVTheme.accent.opacity(0.10)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        .accessibilityLabel("All effects")
        .accessibilityIdentifier("workspace.browser.search")
    }

    // MARK: - Sub row

    /// The specifics of one group as small text pills, plus — under Saved —
    /// the door to the full catalogue.
    private func subRow(for item: DockGroup) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(item.members) { member in
                    subChip(member)
                }
                if let category, category != .spatial, category != .blobs, item.members.contains(category) {
                    stackToggle
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func subChip(_ item: WorkspaceDockCategory) -> some View {
        let isOpen = category == item
        let live = isLive(item)
        return Button {
            choose(item)
        } label: {
            HStack(spacing: 5) {
                Text(item.displayLabel)
                    .font(.system(size: 12, weight: isOpen ? .semibold : .medium))
                    .lineLimit(1)
                if live {
                    Circle().fill(isOpen ? Color.black.opacity(0.5) : GVTheme.acid).frame(width: 4, height: 4)
                }
            }
            .foregroundStyle(isOpen ? Color.black : GVTheme.bone.opacity(0.85))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background {
                let shape = Capsule(style: .continuous)
                if isOpen { shape.fill(GVTheme.bone) } else { shape.fill(.ultraThinMaterial).overlay(shape.fill(Color.black.opacity(0.35))).overlay(shape.fill(GVTheme.accent.opacity(0.14))) }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(GVPressStyle())
        .accessibilityLabel(item.displayLabel)
        .accessibilityValue(isOpen ? "selected" : "")
        .accessibilityIdentifier("workspace.browser.category.\(item.rawValue)")
    }

    private func choose(_ item: WorkspaceDockCategory) {
        if item == .objects {
            enterAR()
            return
        }
        GVInteractionHaptics.select()
        category = category == item ? nil : item
    }

    // MARK: - Strip

    @ViewBuilder
    private func strip(for item: WorkspaceDockCategory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch item {
            case .spatial: depthStrip
            case .blobs: trackingStrip
            default: effectStrip(effects(in: item), category: item)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
        .gvChromePlate(RoundedRectangle(cornerRadius: GVSplashDock.radius, style: .continuous))
    }

    /// Replace or stack, as one small switch on the strip it governs.
    private var stackToggle: some View {
        Button {
            editor.setStackArmed(!editor.isStackArmed)
            decay.fire(.effectActivated)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: editor.isStackArmed ? "square.stack.3d.up.fill" : "square")
                    .font(.system(size: 10, weight: .semibold))
                Text(editor.isStackArmed ? "Stack" : "Single")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(editor.isStackArmed ? Color.black : GVTheme.bone.opacity(0.7))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                Capsule(style: .continuous).fill(editor.isStackArmed ? GVTheme.bone : Color.white.opacity(0.07))
            )
        }
        .buttonStyle(GVPressStyle())
        .accessibilityLabel("Stack effects")
        .accessibilityValue(editor.isStackArmed ? "on" : "off")
        .accessibilityIdentifier("workspace.browser.add")
    }

    private func effectStrip(_ effects: [WorkspaceAdjustableEffect], category item: WorkspaceDockCategory) -> some View {
        Group {
            if effects.isEmpty {
                Text(emptyMessage(for: item))
                    .font(.system(size: 12))
                    .foregroundStyle(GVTheme.bone.opacity(0.55))
                    .frame(maxWidth: .infinity, minHeight: 84)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(effects, id: \.self) { effect in
                            effectTile(effect)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(height: 88)
            }
        }
        .accessibilityIdentifier("workspace.effects.\(item.rawValue)")
    }

    private func effectTile(_ effect: WorkspaceAdjustableEffect) -> some View {
        let active = EffectCatalog.variants(for: effect).contains { editor.isEnabled($0) }
        let favorite = preferences.isFavorite(effect.rawValue)
        return Button {
            select(effect)
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                    if let image = thumbnails.image(for: effect) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14))
                            .foregroundStyle(GVTheme.bone.opacity(0.3))
                    }
                }
                .frame(width: 66, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(active ? GVTheme.accent : Color.white.opacity(0.08), lineWidth: active ? 2 : 0.75)
                }
                .overlay {
                    // A live effect is a tracked object, as on the splash.
                    if active {
                        GVTrackerBrackets(arm: 9)
                            .stroke(GVSplashDock.lime, style: StrokeStyle(lineWidth: 1, lineCap: .square))
                            .padding(-2)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if favorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(GVTheme.bone)
                            .padding(4)
                    }
                }
                Text(EffectNaming.display(effect))
                    .font(.system(size: 10, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? GVTheme.bone : GVTheme.bone.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 70)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        .onAppear { thumbnails.request(effect) }
        .contextMenu {
            Button {
                preferences.toggleFavorite(effect.rawValue)
            } label: {
                Label(favorite ? "Remove favorite" : "Favorite", systemImage: favorite ? "star.slash" : "star")
            }
        }
        .accessibilityLabel(EffectNaming.display(effect))
        .accessibilityValue(active ? "active" : "inactive")
        .accessibilityIdentifier("workspace.browser.effect.\(effect.rawValue)")
    }

    private var depthStrip: some View {
        chipStrip(
            DepthEffectMode.allCases.map { mode in
                (id: "\(mode.rawValue)", label: mode.label.capitalized, symbol: "sensor.tag.radiowaves.forward",
                 active: appModel.sourceMode == .lidar && appModel.depth.effect == mode && appModel.depth.isActive,
                 action: { selectDepth(mode) })
            },
            unavailable: appModel.depth.capability.isSupported ? nil : appModel.depth.capability.reason
        )
        .accessibilityIdentifier("workspace.depth.modes")
    }

    private var trackingStrip: some View {
        chipStrip(
            GVTrackingPreset.all.map { preset in
                (id: preset.id, label: preset.name, symbol: preset.symbol,
                 active: appModel.blobs.isEnabled && GVTrackingPreset.matching(appModel.blobs.parameters)?.id == preset.id,
                 action: {
                     appModel.deactivateDepthMode()
                     appModel.deactivateObjectMode()
                     editor.focus(nil)
                     appModel.blobs.apply(preset)
                     GVInteractionHaptics.select()
                 })
            },
            unavailable: nil
        )
        .accessibilityIdentifier("workspace.tracking.presets")
    }

    private func chipStrip(
        _ items: [(id: String, label: String, symbol: String, active: Bool, action: () -> Void)],
        unavailable: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let unavailable {
                Text(unavailable)
                    .font(.system(size: 11))
                    .foregroundStyle(GVTheme.bone.opacity(0.6))
                    .padding(.horizontal, 12)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items, id: \.id) { item in
                        Button(action: item.action) {
                            HStack(spacing: 5) {
                                Image(systemName: item.symbol).font(.system(size: 10, weight: .semibold))
                                Text(item.label).font(.system(size: 12, weight: item.active ? .semibold : .medium))
                            }
                            .foregroundStyle(item.active ? Color.black : GVTheme.bone.opacity(0.8))
                            .padding(.horizontal, 11)
                            .frame(height: 34)
                            .background(Capsule(style: .continuous).fill(item.active ? GVTheme.bone : Color.white.opacity(0.07)))
                        }
                        .buttonStyle(GVPressStyle())
                        .accessibilityValue(item.active ? "active" : "inactive")
                    }
                }
                .padding(.horizontal, 10)
            }
        }
    }

    // MARK: - Data

    private func effects(in item: WorkspaceDockCategory) -> [WorkspaceAdjustableEffect] {
        switch item {
        case .active: editor.activeEffects
        case .favorites: WorkspaceAdjustableEffect.allCases.filter { preferences.isFavorite($0.rawValue) }
        case .recents: preferences.recentEffects.compactMap(WorkspaceAdjustableEffect.resolving)
        case .spatial, .blobs, .objects, .lidar: []
        default: EffectCatalog.effects(in: item.rawValue)
        }
    }

    private func isLive(_ item: WorkspaceDockCategory) -> Bool {
        switch item {
        case .objects: appModel.sourceMode == .objects
        case .spatial: appModel.sourceMode == .lidar && appModel.depth.isActive
        case .blobs: appModel.blobs.isEnabled
        case .active, .favorites, .recents: false
        default:
            effects(in: item).contains { effect in
                EffectCatalog.variants(for: effect).contains { editor.isEnabled($0) }
            }
        }
    }

    private func emptyMessage(for item: WorkspaceDockCategory) -> String {
        switch item {
        case .favorites: "Touch and hold an effect to favorite it."
        case .recents: "Effects you use collect here."
        default: "Nothing here yet."
        }
    }

    // MARK: - Actions

    /// Applies and keeps the dock open: the picture is still on screen above
    /// it, so the next tap can compare straight away.
    private func select(_ effect: WorkspaceAdjustableEffect) {
        appModel.deactivateDepthMode()
        appModel.deactivateObjectMode()
        armAudioIfNeeded(for: effect)
        editor.applyFromBrowser(effect)
        if editor.selectedEffect != nil {
            preferences.noteEffectUsed((editor.selectedEffect ?? effect).rawValue)
            decay.fire(.effectActivated)
        }
        GVInteractionHaptics.select()
    }

    private func selectDepth(_ mode: DepthEffectMode) {
        guard appModel.depth.capability.isSupported else {
            toasts.show("\(mode.label): \(appModel.depth.capability.reason)")
            return
        }
        editor.disableAll()
        appModel.deactivateObjectMode()
        appModel.activateDepthEffect(mode)
        GVInteractionHaptics.select()
    }

    private func enterAR() {
        guard appModel.objects.capability.isSupported else {
            toasts.show(appModel.objects.capability.reason)
            return
        }
        editor.disableAll()
        appModel.deactivateDepthMode()
        appModel.activateObjectMode()
        GVInteractionHaptics.select()
        onClose()
    }

    private func armAudioIfNeeded(for effect: WorkspaceAdjustableEffect) {
        guard effect.requiresAudioAnalysis, !audioRuntime.isEnabled else { return }
        switch audioRuntime.state {
        case .denied:
            toasts.show("\(effect.label) needs microphone access")
        case .failed:
            toasts.show("\(effect.label): audio engine unavailable")
        default:
            Task { @MainActor in
                await audioRuntime.start()
                if audioRuntime.state == .denied {
                    toasts.show("\(effect.label) needs microphone access")
                }
            }
        }
    }
}

/// Display names shared by the dock and the catalogue.
enum EffectNaming {
    static func display(_ effect: WorkspaceAdjustableEffect) -> String {
        switch effect {
        case .rgbSplit: "RGB Split"
        case .liquidMosh: "Liquid Mosh"
        case .heavyMosh: "Heavy Mosh"
        case .cmykPress: "CMYK Press"
        default: effect.label.capitalized
        }
    }
}
