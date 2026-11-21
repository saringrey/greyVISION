import SwiftUI

/// One shelf in the effect browser.
///
/// The rail and the browser read the same list, so a category can never exist
/// in one and not the other — which is exactly how the developer and
/// experimental shelves went missing from the picker while the catalogue still
/// had their effects in it.
enum WorkspaceDockCategory: String, CaseIterable, Identifiable {
    case all
    /// Everything rendering right now, in pipeline order. The answer to
    /// "what is actually on" without hunting across the families.
    case active
    /// The operator's own shortlist, alongside the complete ALL shelf.
    case favorites
    /// The last handful the operator reached for.
    case recents
    /// Codec moshes, pixel sorts and digital damage: the picture as data
    /// that has gone wrong.
    case glitch
    /// Frame history: feedback, trails, echoes and time slicing.
    case time
    /// Tape, film and tube: VHS, Super 8, CRT, halation.
    case analog
    /// Grades and print processes: thermal, false colour, dither, ASCII.
    case look
    /// Light through glass: flares, diffraction, tilt-shift, leaks.
    case lens
    /// Space bent: kaleidoscopes, mirrors, polar and fluid warps.
    case warp
    /// Self-generating shader worlds that run over the frame.
    case generative
    /// Reacts to the microphone.
    case audio
    /// The real depth modes. These are not effects and are not luma
    /// approximations of depth: they read actual LiDAR from the capture
    /// pipeline, so they live behind the hardware's own capability gate.
    case spatial
    /// Capture modes, not effects. They live in the dock rather than here.
    case objects
    case blobs
    case lidar

    var id: String {
        rawValue
    }

    /// Clean display form for the rail. Identifiers and logic keep `rawValue`;
    /// the visible list uses title case for a calmer, professional read.
    var displayLabel: String {
        switch self {
        case .all: "All"
        case .active: "Active"
        case .favorites: "Favorites"
        case .recents: "Recent"
        case .glitch: "Glitch"
        case .time: "Time"
        case .analog: "Analog"
        case .look: "Look"
        case .lens: "Lens"
        case .warp: "Warp"
        case .generative: "Generative"
        case .audio: "Audio"
        case .spatial: "LiDAR"
        case .objects: "AR"
        case .blobs: "Tracking"
        case .lidar: "LiDAR"
        }
    }

    /// Glyphs for the scopes and modes, and the fallback a family card shows
    /// until its live preview has rendered.
    var symbol: String? {
        switch self {
        case .active: "power"
        case .favorites: "star.fill"
        case .recents: "clock.arrow.circlepath"
        case .glitch: "square.split.diagonal.2x2"
        case .time: "clock.arrow.2.circlepath"
        case .analog: "tv"
        case .look: "paintpalette"
        case .lens: "camera.aperture"
        case .warp: "circle.hexagongrid"
        case .generative: "sparkles"
        case .audio: "waveform"
        case .spatial: "sensor.tag.radiowaves.forward"
        case .blobs: "scope"
        case .objects: "cube.transparent"
        default: nil
        }
    }

    /// The shelves the browser owns. Objects, tracking and LiDAR are capture
    /// modes with their own decks in the dock, so they are not browsable here.
    ///
    /// Built once. This is a frozen filter over a frozen enum, and the browser
    /// body asked for it on every pass.
    static let browsable: [WorkspaceDockCategory] =
        allCases.filter { $0 != .objects && $0 != .blobs && $0 != .lidar }

    /// The browsable categories that are actual effect shelves, in order.
    ///
    /// The browser's category column is a `ForEach` over this, and the body
    /// used to re-filter `browsable` on every pass. The answer is fixed — the
    /// catalogue's shelves are static — so it is computed once here.
    static let shelfCategories: [WorkspaceDockCategory] = browsable.filter(\.isShelf)

    /// Whether this category is a shelf of effects rather than a saved list.
    /// `spatial` is excluded: it holds real depth modes, not catalogue
    /// effects, so it has no entry in `EffectCatalog.shelves`.
    var isShelf: Bool {
        self != .spatial && EffectCatalog.effects(in: rawValue).isEmpty == false
    }
}

/// The effect browser: a picture catalogue over the live picture.
///
/// Everything the operator chooses is a photograph of what the effect does,
/// rendered by the production shader over a frame tapped from the live
/// camera when the browser opened. Nothing has to be guessed from a name or
/// decoded from an abstract diagram.
///
/// The chrome is kept to what a choice needs: a title, one line of state, a
/// search field, the two ways a tap can behave, and a single shelf of
/// categories. The details — render cost, what an effect does, its variants,
/// whether it wants the microphone — are one touch away on the effect itself
/// rather than printed across every tile.
struct GVEffectBrowser: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var audioRuntime: AudioReactiveRuntime
    @EnvironmentObject private var preferences: GVPreferences
    @EnvironmentObject private var decay: GVDecayEngine
    @EnvironmentObject private var toasts: GVToastBox
    @StateObject private var thumbnails = GVEffectThumbnailStore.shared
    @ObservedObject var editor: EffectEditingSession
    /// The category the browser opens on. The dock passes whatever shelf the
    /// operator tapped, so the rail and the browser always agree.
    let initialCategory: WorkspaceDockCategory

    @State private var category: WorkspaceDockCategory
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private static let spacing: CGFloat = 8
    private static let panelRadius: CGFloat = 24
    private let surface = Color.white.opacity(0.045)

    init(editor: EffectEditingSession, initialCategory: WorkspaceDockCategory) {
        self.editor = editor
        self.initialCategory = initialCategory
        _category = State(initialValue: initialCategory)
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height * 1.15
            Group {
                if wide {
                    HStack(alignment: .top, spacing: 6) {
                        VStack(spacing: 6) {
                            header
                            searchRow
                            selectorPanel
                            Spacer(minLength: 0)
                        }
                        .frame(width: min(max(geometry.size.width * 0.36, 260), 340))
                        contentPanel
                    }
                } else {
                    VStack(spacing: 6) {
                        header
                        searchRow
                        unifiedPanel
                    }
                }
            }
            .padding(.horizontal, GVMetrics.screenInset)
            .padding(.top, 2)
            .padding(.bottom, 2)
        }
        .presentationBackground { backdrop }
        .preferredColorScheme(.dark)
        .onAppear { thumbnails.refreshFromLiveSource() }
        .onDisappear { editor.endPreview() }
        .sensoryFeedback(.selection, trigger: category)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.browser")
    }

    /// The live picture, frosted and dimmed: the dashboard reads as glass laid
    /// over the camera rather than a separate screen that replaced it.
    private var backdrop: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color(red: 0.08, green: 0.084, blue: 0.092).opacity(0.72)
        }
        .ignoresSafeArea()
    }

    // MARK: - Chrome

    /// A title and one line of state. The instrument used to print the open
    /// category next to the title as well as marking it on the chip, so the
    /// same fact appeared twice in the first row the eye met.
    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Effects")
                    .gvSystemFont(18, .semibold, maxScale: 1.1)
                    .foregroundStyle(GVTheme.bone)
                statusLine
            }
            Spacer(minLength: 4)
            closeButton
        }
    }

    /// What is on, what it costs, and whether the microphone is feeding the
    /// audio-reactive effects — as a sentence rather than an instrument
    /// cluster. The numbers are still here; they are just no longer shouting.
    private var statusLine: some View {
        let active = editor.activeEffects
        let load = active.reduce(0) { $0 + $1.gpuCost.rawValue }
        let micLive = audioRuntime.state == .running
        return HStack(spacing: 8) {
            Text("\(statusCount.count) \(statusCount.noun)")
                .gvSystemFont(12, .medium)
                .foregroundStyle(GVTheme.bone.opacity(0.6))
                .contentTransition(.numericText())
            // Nothing is on, so there is nothing to report but the microphone.
            // The rest arrives the moment an effect is applied.
            if !active.isEmpty {
                separator
                Text("\(active.count) on")
                    .font(GVTheme.mono(11, .semibold))
                    .foregroundStyle(GVTheme.bone.opacity(0.92))
                    .contentTransition(.numericText())
                loadMeter(load: load)
            }
            separator
            Image(systemName: micLive ? "waveform" : "mic.slash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(micLive ? Color.mint : GVTheme.bone.opacity(0.35))
                .symbolEffect(.variableColor.iterative, isActive: micLive && !reduceMotion)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(statusCount.count) \(statusCount.noun) in view, \(active.count) effects on, "
                            + "render load \(load), microphone \(micLive ? "live" : "off")")
        .accessibilityIdentifier("workspace.browser.readouts")
    }

    /// A hairline dot between the facts in the status line.
    private var separator: some View {
        Circle()
            .fill(GVTheme.bone.opacity(0.28))
            .frame(width: 2.5, height: 2.5)
            .accessibilityHidden(true)
    }

    /// The render-cost meter: six segments, one per point of load, lit from
    /// the left. It is the one part of the readout that cannot be said in
    /// words without losing its meaning.
    private func loadMeter(load: Int) -> some View {
        HStack(spacing: 3) {
            Text("Load")
                .font(GVTheme.mono(9, .medium))
                .foregroundStyle(GVTheme.bone.opacity(0.4))
            HStack(spacing: 2) {
                ForEach(0 ..< 6, id: \.self) { index in
                    Capsule()
                        .fill(index < load ? (load > 4 ? GVTheme.record : GVTheme.bone.opacity(0.85))
                                           : GVTheme.bone.opacity(0.16))
                        .frame(width: 3, height: 7)
                }
            }
        }
    }

    /// Search, and the one browser action that has no tile to hang off: what
    /// a tap does to the composition.
    private var searchRow: some View {
        HStack(spacing: 8) {
            searchField
            addModeControl
        }
    }

    /// Replace or Add, said in words.
    ///
    /// This used to be an unlabelled stack icon that silently changed the
    /// meaning of every tap in the grid. A control that changes what the
    /// whole screen does has to say so, and saying so takes one word.
    private var addModeControl: some View {
        HStack(spacing: 2) {
            modeSegment(
                "Replace",
                selected: !editor.isStackArmed,
                hint: "Choosing an effect replaces the ones you have on",
                identifier: "workspace.browser.replace"
            ) {
                editor.setStackArmed(false)
                decay.fire(.effectActivated)
            }
            modeSegment(
                "Add",
                selected: editor.isStackArmed,
                hint: "Choosing an effect adds it to your stack",
                identifier: "workspace.browser.add"
            ) {
                editor.setStackArmed(true)
                decay.fire(.effectActivated)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.75)
        )
        .fixedSize()
        .frame(height: 44)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tap behaviour")
    }

    private func modeSegment(_ label: String, selected: Bool, hint: String,
                             identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.black : GVTheme.bone.opacity(0.72))
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(GVTheme.bone)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        .accessibilityLabel(label)
        .accessibilityValue(selected ? "selected" : "")
        .accessibilityHint(hint)
        .accessibilityIdentifier(identifier)
    }

    private var searchField: some View {
        HStack(spacing: GVMetrics.gapTight) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GVTheme.bone.opacity(0.65))
            TextField(text: $query) {
                Text("Search effects").foregroundStyle(GVTheme.bone.opacity(0.5))
            }
            .textFieldStyle(.plain)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .focused($searchFocused)
            .onSubmit { searchFocused = false }
            .gvSystemFont(14)
            .foregroundStyle(GVTheme.bone)
            .tint(.white)
            .accessibilityLabel("Search all effects")
            .accessibilityIdentifier("workspace.search.field")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(GVTheme.bone.opacity(0.65))
                        .frame(width: 32, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(GVPressStyle())
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 11)
        .frame(height: 38)
        .background(Color.white.opacity(searchFocused ? 0.1 : 0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(searchFocused ? 0.32 : 0), lineWidth: 1)
        )
        .frame(minHeight: GVMetrics.touchTarget)
        .animation(GVMotion.resolved(GVMotion.normal, reduceMotion: reduceMotion), value: searchFocused)
    }

    private var selectorPanel: some View {
        selector
            .padding(10)
            .gvLiquidGlass(radius: Self.panelRadius)
    }

    private var selector: some View {
        GVEffectDashboardSelector(
            selected: category,
            readouts: shelfReadouts,
            onSelect: changeCategory
        )
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GVTheme.bone)
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.08), in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.75))
                .frame(width: GVMetrics.touchTarget, height: GVMetrics.touchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        .accessibilityLabel("Close effect browser")
        .accessibilityIdentifier("workspace.browser.close")
    }

    // MARK: - Content

    /// The portrait layout keeps the shelf of categories and the effects in
    /// one surface, with the categories pinned above the scrolling list. The
    /// navigation therefore stays exactly where it was left, instead of
    /// scrolling away behind the catalogue.
    private var unifiedPanel: some View {
        VStack(spacing: 0) {
            selector
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 8)
            GVRule().padding(.horizontal, 10)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 2)
        }
        .padding(.bottom, 10)
        .gvLiquidGlass(radius: Self.panelRadius)
    }

    private var contentPanel: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .gvLiquidGlass(radius: Self.panelRadius)
    }

    @ViewBuilder
    private var content: some View {
        if category == .spatial, trimmedQuery.isEmpty {
            depthPane
        } else if category == .blobs, trimmedQuery.isEmpty {
            GVTrackingPane(runtime: appModel.blobs, tileMinimum: 100, spacing: Self.spacing) { preset in
                appModel.deactivateDepthMode()
                appModel.deactivateObjectMode()
                editor.focus(nil)
                appModel.blobs.apply(preset)
                GVInteractionHaptics.select()
                dismiss()
            }
        } else if visibleSections.allSatisfy(\.items.isEmpty) {
            emptyState
        } else {
            GVEffectIndexList(
                sections: visibleSections.filter { !$0.items.isEmpty },
                thumbnails: thumbnails,
                audioRunning: audioRuntime.state == .running,
                onSelect: select,
                onToggleFavorite: { preferences.toggleFavorite($0.rawValue) },
                onOpenMicrophoneSettings: openMicrophoneSettings
            )
            .accessibilityIdentifier("workspace.effects.\(category.rawValue)")
        }
    }

    /// An empty shelf is a place to learn the interface, not a dead end.
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: emptySymbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(GVTheme.bone.opacity(0.55))
            Text(emptyTitle)
                .gvSystemFont(15, .semibold)
                .foregroundStyle(GVTheme.bone.opacity(0.85))
            Text(emptyMessage)
                .gvSystemFont(13)
                .foregroundStyle(GVTheme.bone.opacity(0.6))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
        .accessibilityIdentifier("workspace.effects.empty")
    }

    private var emptySymbol: String {
        if !trimmedQuery.isEmpty { return "magnifyingglass" }
        switch category {
        case .favorites: return "star"
        case .recents: return "clock.arrow.circlepath"
        case .active: return "power"
        default: return "sparkles"
        }
    }

    private var emptyTitle: String {
        if !trimmedQuery.isEmpty { return "No match" }
        switch category {
        case .favorites: return "No favorites yet"
        case .recents: return "Nothing here yet"
        case .active: return "Nothing on yet"
        default: return "Nothing in this shelf"
        }
    }

    private var emptyMessage: String {
        if !trimmedQuery.isEmpty {
            return "No effect matches “\(trimmedQuery)”. Try a family name — Glitch, Analog, Warp."
        }
        switch category {
        case .favorites:
            return "Touch and hold an effect to save it here."
        case .recents:
            return "The effects you use will collect here."
        case .active:
            return "Tap an effect to turn it on."
        default:
            return "Nothing in this shelf."
        }
    }

    private func indexItem(_ effect: WorkspaceAdjustableEffect) -> GVEffectIndexItem {
        let active = EffectCatalog.variants(for: effect).contains { editor.isEnabled($0) }
        return GVEffectIndexItem(
            effect: effect,
            name: displayName(effect),
            active: active,
            favorite: preferences.isFavorite(effect.rawValue),
            cost: effect.gpuCost.rawValue,
            needsAudio: effect.requiresAudioAnalysis,
            accessibilityValue: accessibilityState(for: effect, active: active)
        )
    }

    // MARK: - Depth

    /// The genuine depth modes. These read real LiDAR from the capture
    /// pipeline rather than approximating depth from luminance, so they are
    /// gated on the hardware's own capability and say why when unavailable.
    private var depthPane: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Self.spacing) {
                HStack(alignment: .firstTextBaseline) {
                    Text("LiDAR")
                        .gvSystemFont(15, .semibold)
                        .foregroundStyle(GVTheme.bone)
                    Spacer()
                    Text("\(DepthEffectMode.allCases.count)")
                        .font(GVTheme.mono(11, .medium))
                        .foregroundStyle(GVTheme.bone.opacity(0.45))
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 8)
                if !appModel.depth.capability.isSupported {
                    Text(appModel.depth.capability.reason)
                        .font(.system(size: 12))
                        .foregroundStyle(GVTheme.bone.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 130, maximum: 260), spacing: Self.spacing)],
                    spacing: Self.spacing
                ) {
                    ForEach(DepthEffectMode.allCases) { mode in
                        depthTile(mode)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .accessibilityIdentifier("workspace.depth.modes")
    }

    private func depthTile(_ mode: DepthEffectMode) -> some View {
        let available = appModel.depth.capability.isSupported
        let active = appModel.sourceMode == .lidar && appModel.depth.effect == mode && appModel.depth.isActive
        return Button {
            selectDepth(mode)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(mode.label.capitalized)
                            .gvSystemFont(13, active ? .semibold : .regular)
                            .foregroundStyle(GVTheme.bone)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if !available {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(GVTheme.record)
                        }
                    }
                    Text(mode.detail)
                        .gvSystemFont(11)
                        .foregroundStyle(GVTheme.bone.opacity(0.62))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(GVTheme.bone.opacity(active ? 0.55 : 0), lineWidth: 1)
            }
            .overlay(alignment: .topTrailing) {
                if active {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GVTheme.bone)
                        .frame(width: 26, height: 26)
                        .background(Color.black.opacity(0.7), in: Circle())
                        .padding(8)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        .opacity(available ? 1 : 0.6)
        .accessibilityLabel(mode.label)
        .accessibilityHint(mode.detail)
        .accessibilityValue(active ? "active" : "inactive")
        .accessibilityIdentifier("workspace.depth.\(mode.rawValue)")
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
        dismiss()
    }

    /// AR is a capture mode with its own studio deck, so choosing it leaves
    /// the browser rather than opening a shelf.
    private func enterAR() {
        guard appModel.objects.capability.isSupported else {
            toasts.show(appModel.objects.capability.reason)
            return
        }
        editor.disableAll()
        appModel.deactivateDepthMode()
        appModel.activateObjectMode()
        GVInteractionHaptics.select()
        dismiss()
    }

    private func changeCategory(_ item: WorkspaceDockCategory) {
        if item == .objects {
            enterAR()
            return
        }
        searchFocused = false
        withAnimation(GVMotion.resolved(GVMotion.normal, reduceMotion: reduceMotion)) {
            category = item
            query = ""
        }
    }

    // MARK: - Data

    /// Counts and live lights for every selector key, in one pass over the
    /// active set rather than one catalogue walk per key.
    private static let catalogueCount = EffectCatalog.canonicalEffects(EffectCatalog.shelves.flatMap(\.effects)).count

    private var shelfReadouts: [WorkspaceDockCategory: GVEffectShelfReadout] {
        let active = Set(editor.activeEffects)
        let isLive: (WorkspaceAdjustableEffect) -> Bool = { effect in
            EffectCatalog.variants(for: effect).contains(where: active.contains)
        }
        var readouts: [WorkspaceDockCategory: GVEffectShelfReadout] = [
            .all: .init(count: Self.catalogueCount, live: !active.isEmpty),
            .active: .init(count: active.count, live: !active.isEmpty),
            .favorites: .init(count: WorkspaceAdjustableEffect.allCases.count { preferences.isFavorite($0.rawValue) }, live: false),
            .recents: .init(count: preferences.recentEffects.count, live: false),
            .blobs: .init(count: GVTrackingPreset.all.count, live: appModel.blobs.isEnabled),
            .objects: .init(count: appModel.objects.objects.count, live: appModel.sourceMode == .objects),
            .spatial: .init(count: DepthEffectMode.allCases.count, live: appModel.sourceMode == .lidar && appModel.depth.isActive)
        ]
        for shelf in WorkspaceDockCategory.shelfCategories {
            let effects = EffectCatalog.effects(in: shelf.rawValue)
            readouts[shelf] = .init(count: effects.count, live: effects.contains(where: isLive))
        }
        return readouts
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What is on screen right now, in the words that fit it. The depth
    /// modes and the tracking presets are not effects, and calling them
    /// "0 effects" was a small lie the status line told on every visit.
    private var statusCount: (count: Int, noun: String) {
        if trimmedQuery.isEmpty {
            switch category {
            case .spatial: return (DepthEffectMode.allCases.count, "depth modes")
            case .blobs: return (GVTrackingPreset.all.count, "presets")
            default: break
            }
        }
        let count = visibleSections.reduce(0) { $0 + $1.items.count }
        return (count, count == 1 ? "effect" : "effects")
    }

    /// What the index shows. A search spans every shelf — the whole point of
    /// typing is not having to know which family an effect was filed under.
    private var visibleSections: [GVEffectIndexSection] {
        if !trimmedQuery.isEmpty {
            return [makeSection(id: "search", title: "Results", effects: EffectCatalog.search(trimmedQuery))]
        }
        switch category {
        case .spatial, .blobs:
            return []
        case .all:
            return EffectCatalog.shelves.map { shelf in
                makeSection(id: shelf.id, title: displayLabel(for: shelf.id), effects: shelf.effects)
            }
        case .active:
            return [makeSection(id: "active", title: "On now", effects: editor.activeEffects)]
        case .favorites:
            let effects = WorkspaceAdjustableEffect.allCases.filter { preferences.isFavorite($0.rawValue) }
            return [makeSection(id: "favorites", title: "Favorites", effects: effects)]
        case .recents:
            let effects = preferences.recentEffects.compactMap(WorkspaceAdjustableEffect.resolving)
            return [makeSection(id: "recents", title: "Recent", effects: effects)]
        default:
            return [makeSection(id: category.rawValue, title: category.displayLabel,
                                effects: EffectCatalog.effects(in: category.rawValue))]
        }
    }

    /// A shelf's name in the same voice as its chip. The catalogue stores
    /// them in capitals for the terminal; the browser speaks in title case.
    private func displayLabel(for shelfID: String) -> String {
        WorkspaceDockCategory(rawValue: shelfID)?.displayLabel
            ?? EffectCatalog.shelves.first { $0.id == shelfID }?.label
            ?? shelfID
    }

    private func makeSection(id: String, title: String, effects: [WorkspaceAdjustableEffect]) -> GVEffectIndexSection {
        GVEffectIndexSection(id: id, title: title, items: effects.map(indexItem))
    }

    private func displayName(_ effect: WorkspaceAdjustableEffect) -> String {
        switch effect {
        case .rgbSplit: return "RGB Split"
        case .liquidMosh: return "Liquid Mosh"
        case .heavyMosh: return "Heavy Mosh"
        case .cmykPress: return "CMYK Press"
        default: return effect.label.capitalized
        }
    }

    // MARK: - Selection

    /// Exclusive by default, additive while Add is on — exactly the contract
    /// `EffectEditingSession.selectFamily` already keeps for the rail, so
    /// nothing about stacking policy moves here.
    ///
    /// A tap applies the look and closes the browser: the menu covers most
    /// of the picture, so auditioning behind it showed too little to judge.
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
        dismiss()
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

    private func openMicrophoneSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// The spoken form of everything the tile encodes in dots and glyphs.
    private func accessibilityState(for effect: WorkspaceAdjustableEffect, active: Bool) -> String {
        var parts = [active ? "active" : "inactive"]
        if effect.gpuCost.rawValue > 0 {
            parts.append("render cost \(effect.gpuCost.rawValue) of 3")
        }
        let variants = EffectCatalog.variants(for: effect).count
        if variants > 1 {
            parts.append("\(variants) variants in this family")
        }
        if effect.requiresAudioAnalysis, audioRuntime.state != .running {
            parts.append("microphone off")
        }
        return parts.joined(separator: ", ")
    }
}
