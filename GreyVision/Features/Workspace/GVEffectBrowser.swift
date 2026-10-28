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
        case .spatial: "Depth"
        case .objects: "Objects"
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

/// The effect browser: a glass dashboard over the live picture.
///
/// It replaced a full-screen sheet that was one long vertical grid under a
/// horizontal shelf rail — 190 effects at two big tiles a row meant most of
/// a session in the browser was spent scrolling. The dashboard puts every
/// shelf on screen at once as a keypad, and pages the chosen shelf sideways
/// in grids solved to fit the panel, so nothing is ever half off an edge.
///
/// The live camera stays visible through the glass, and every preview is the
/// effect rendered over a frame tapped from that camera when the browser
/// opened (`GVEffectThumbnailStore`), not over a stock test card.
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

    @ScaledMetric(relativeTo: .caption) private var tileMinimum: CGFloat = 78
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
                    HStack(alignment: .top, spacing: 10) {
                        VStack(spacing: 10) {
                            header
                            controlRow
                            selectorPanel
                            Spacer(minLength: 0)
                        }
                        .frame(width: min(max(geometry.size.width * 0.4, 300), 380))
                        contentPanel
                    }
                } else {
                    VStack(spacing: 10) {
                        header
                        controlRow
                        selectorPanel
                        contentPanel
                    }
                }
            }
            .padding(.horizontal, GVMetrics.screenInset)
            .padding(.top, 6)
            .padding(.bottom, 4)
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
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.35), .black.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("EFFECTS")
                    .font(GVTheme.mono(19, .semibold))
                    .foregroundStyle(GVTheme.bone)
                Text("// \(trimmedQuery.isEmpty ? category.displayLabel.uppercased() : "SEARCH")")
                    .font(GVTheme.mono(12, .medium))
                    .foregroundStyle(GVTheme.bone.opacity(0.5))
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .animation(GVMotion.resolved(GVMotion.normal, reduceMotion: reduceMotion), value: category)
            Spacer(minLength: 6)
            captureModes
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
    }

    /// Search, the stacking switch and the live readouts on one row: the
    /// dashboard's instrument strip.
    private var controlRow: some View {
        HStack(spacing: 6) {
            searchField
            addModeChip
            readouts
        }
    }

    /// Stacking is the one browser action that has no tile to hang off, so it
    /// lives in the header. Off, a tap is exclusive — the same rule the rail
    /// used, stated rather than implied.
    private var addModeChip: some View {
        Button {
            editor.setStackArmed(!editor.isStackArmed)
            decay.fire(.effectActivated)
        } label: {
            Image(systemName: editor.isStackArmed ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(editor.isStackArmed ? Color.black : GVTheme.bone.opacity(0.8))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 38)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(editor.isStackArmed ? GVTheme.bone : Color.white.opacity(0.06))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        .frame(minHeight: GVMetrics.touchTarget)
        .accessibilityLabel(editor.isStackArmed ? "Stacking on, taps add effects" : "Add mode off, taps replace the effect")
        .accessibilityIdentifier("workspace.browser.add")
    }

    /// What is on and what it costs, at a glance: active count over a load
    /// meter summed from the active effects' render-cost tiers, and whether
    /// the microphone is feeding the audio-reactive effects.
    private var readouts: some View {
        let active = editor.activeEffects
        let load = active.reduce(0) { $0 + $1.gpuCost.rawValue }
        let micLive = audioRuntime.state == .running
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(active.count) ON")
                    .font(GVTheme.mono(10, .semibold))
                    .foregroundStyle(active.isEmpty ? GVTheme.bone.opacity(0.5) : GVTheme.bone)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                HStack(spacing: 4) {
                    Text("LOAD")
                        .font(GVTheme.mono(8.5, .medium))
                        .foregroundStyle(GVTheme.bone.opacity(0.45))
                    HStack(spacing: 2) {
                        ForEach(0 ..< 6, id: \.self) { index in
                            Capsule()
                                .fill(index < load ? (load > 4 ? GVTheme.record : GVTheme.bone) : GVTheme.bone.opacity(0.18))
                                .frame(width: 3, height: 7)
                        }
                    }
                }
            }
            Image(systemName: micLive ? "waveform" : "mic.slash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(micLive ? Color.mint : GVTheme.bone.opacity(0.4))
                .symbolEffect(.variableColor.iterative, isActive: micLive && !reduceMotion)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(active.count) effects on, render load \(load), microphone \(micLive ? "live" : "off")")
        .accessibilityIdentifier("workspace.browser.readouts")
    }

    private var searchField: some View {
        HStack(spacing: GVMetrics.gapTight) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GVTheme.bone.opacity(0.65))
            TextField(text: $query) {
                Text("Search").foregroundStyle(GVTheme.bone.opacity(0.5))
            }
            .textFieldStyle(.plain)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .focused($searchFocused)
            .onSubmit { searchFocused = false }
            .font(GVTheme.mono(13, .regular))
            .foregroundStyle(GVTheme.bone)
            .tint(.white)
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
        GVEffectDashboardSelector(
            selected: category,
            readouts: shelfReadouts,
            preview: { family in EffectCatalog.hero(of: family.rawValue).flatMap(thumbnails.image(for:)) },
            onAppearFamily: { family in
                if let hero = EffectCatalog.hero(of: family.rawValue) { thumbnails.request(hero) }
            },
            onSelect: changeCategory
        )
            .padding(10)
            .gvLiquidGlass(radius: Self.panelRadius)
    }

    private var captureModes: some View {
        Menu {
            Button {
                guard appModel.objects.capability.isSupported else {
                    toasts.show(appModel.objects.capability.reason)
                    return
                }
                editor.commitPreview()
                editor.disableAll()
                appModel.deactivateDepthMode()
                appModel.activateObjectMode()
                dismiss()
            } label: { Label("AR Objects", systemImage: "cube.transparent") }
            Button { changeCategory(.blobs) } label: {
                Label("Tracking", systemImage: "scope")
            }
            Button { changeCategory(.spatial) } label: {
                Label("LiDAR", systemImage: "sensor.tag.radiowaves.forward")
            }
        } label: {
            Image(systemName: "camera.aperture")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GVTheme.bone)
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.08), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.75))
                .frame(width: GVMetrics.touchTarget, height: GVMetrics.touchTarget)
        }
        .accessibilityLabel("Capture modes")
        .accessibilityIdentifier("workspace.capture.modes")
    }

    // MARK: - Content

    private var contentPanel: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .gvLiquidGlass(radius: Self.panelRadius)
            .overlay(alignment: .bottom) {
                if editor.isPreviewing {
                    auditionBar
                }
            }
            .animation(GVMotion.resolved(GVMotion.normal, reduceMotion: reduceMotion), value: editor.isPreviewing)
    }

    /// The verdict on an audition: the composition is live behind the glass,
    /// but it is not the operator's edit yet. Keep commits it as one undo
    /// step and leaves; Revert restores the stash and browsing continues.
    private var auditionBar: some View {
        HStack(spacing: 8) {
            Text("AUDITION")
                .font(GVTheme.mono(9, .semibold))
                .foregroundStyle(GVTheme.bone.opacity(0.55))
            Text(editor.selectedEffect.map { displayName($0).uppercased() } ?? "COMPOSITION")
                .font(GVTheme.mono(11, .semibold))
                .foregroundStyle(GVTheme.bone)
                .lineLimit(1)
                .contentTransition(.opacity)
            Spacer(minLength: 10)
            Button("Revert") {
                editor.endPreview()
            }
            .font(GVTheme.mono(12, .semibold))
            .foregroundStyle(GVTheme.bone.opacity(0.75))
            .padding(.horizontal, 6)
            .buttonStyle(GVPressStyle())
            .accessibilityIdentifier("workspace.browser.audition.revert")
            Button("Keep") {
                editor.commitPreview()
                dismiss()
            }
            .font(GVTheme.mono(12, .bold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(GVTheme.bone, in: Capsule())
            .buttonStyle(GVPressStyle())
            .accessibilityIdentifier("workspace.browser.audition.keep")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: 44)
        .background(Color.black.opacity(0.62), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75))
        .padding(10)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Auditioning \(auditionName)")
        .accessibilityIdentifier("workspace.browser.audition")
    }

    /// The auditioning look, for both the bar's caption and VoiceOver.
    private var auditionName: String {
        editor.selectedEffect.map(\.label) ?? "a composition"
    }

    @ViewBuilder
    private var content: some View {
        if category == .spatial, trimmedQuery.isEmpty {
            depthPane
        } else if category == .blobs, trimmedQuery.isEmpty {
            GVTrackingPane(runtime: appModel.blobs, tileMinimum: 100, spacing: Self.spacing) { preset in
                appModel.deactivateDepthMode()
                appModel.deactivateObjectMode()
                editor.commitPreview()
                editor.focus(nil)
                appModel.blobs.apply(preset)
                GVInteractionHaptics.select()
                dismiss()
            }
        } else if visibleEffects.isEmpty {
            emptyState
        } else {
            GVEffectPager(items: visibleEffects, resetKey: trimmedQuery.isEmpty ? category.rawValue : "search:\(trimmedQuery)",
                          minimumTile: tileMinimum, spacing: Self.spacing)
            { effect, index in
                tile(effect)
                    .gvTileEntrance(index: index, reduceMotion: reduceMotion)
            }
            .accessibilityIdentifier("workspace.effects.\(category.rawValue)")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.title2.weight(.light))
                .foregroundStyle(GVTheme.bone.opacity(0.65))
            Text(emptyMessage)
                .font(.subheadline)
                .foregroundStyle(GVTheme.bone.opacity(0.65))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
    }

    private var emptyMessage: String {
        if !trimmedQuery.isEmpty {
            return "No effect matches “\(trimmedQuery)”"
        }
        switch category {
        case .favorites:
            return "Keep your favorites here. Touch and hold an effect to save it."
        case .recents:
            return "No recent effects · Your picks will appear here"
        case .active:
            return "Nothing active · Enable an effect to see it here"
        default:
            return "Nothing in this shelf"
        }
    }

    private func tile(_ effect: WorkspaceAdjustableEffect) -> some View {
        let active = EffectCatalog.variants(for: effect).contains { editor.isEnabled($0) }
        let model = GVEffectTileModel(
            name: displayName(effect),
            image: thumbnails.image(for: effect),
            previewUnavailable: thumbnails.isUnavailable(effect),
            active: active,
            favorite: preferences.isFavorite(effect.rawValue),
            cost: effect.gpuCost.rawValue,
            needsAudio: effect.requiresAudioAnalysis
        )
        return Button {
            select(effect)
        } label: {
            GVEffectTileFace(model: model)
                .animation(GVMotion.resolved(GVMotion.normal, reduceMotion: reduceMotion), value: model)
                .contentShape(Rectangle())
        }
        .buttonStyle(GVEffectTileStyle())
        .accessibilityLabel(effect.label)
        .accessibilityHint(effect.detail)
        .accessibilityValue(accessibilityState(for: effect, active: active))
        .accessibilityIdentifier("workspace.effect.\(effect.rawValue)")
        .accessibilityAction(named: "Open Microphone Settings") { openMicrophoneSettings() }
        .onAppear { thumbnails.request(effect) }
        .contextMenu {
            Button {
                preferences.toggleFavorite(effect.rawValue)
            } label: {
                Label(preferences.isFavorite(effect.rawValue) ? "Remove favorite" : "Save favorite", systemImage: "star")
            }
            Button("Adjust effect") {
                select(effect)
                editor.commitPreview()
                dismiss()
            }
            Text(effect.detail.capitalized)
            Text("Render cost \(effect.gpuCost.rawValue) of 3")
            if effect.requiresAudioAnalysis, audioRuntime.state != .running {
                Button("Open Microphone Settings", action: openMicrophoneSettings)
            }
        }
    }

    // MARK: - Depth

    /// The genuine depth modes. These read real LiDAR from the capture
    /// pipeline rather than approximating depth from luminance, so they are
    /// gated on the hardware's own capability and say why when unavailable.
    private var depthPane: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Self.spacing) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Depth")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(GVTheme.bone)
                    Spacer()
                    Text("\(DepthEffectMode.allCases.count)")
                        .font(.caption)
                        .foregroundStyle(GVTheme.bone.opacity(0.60))
                }
                if !appModel.depth.capability.isSupported {
                    Text(appModel.depth.capability.reason)
                        .font(.caption)
                        .foregroundStyle(GVTheme.bone.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 130, maximum: 260), spacing: Self.spacing)],
                    spacing: Self.spacing
                ) {
                    ForEach(DepthEffectMode.allCases) { mode in
                        depthTile(mode)
                    }
                }
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
                            .font(.caption.weight(active ? .medium : .regular))
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
                        .font(.system(.caption2, design: .monospaced))
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
        editor.commitPreview()
        editor.disableAll()
        appModel.deactivateObjectMode()
        appModel.activateDepthEffect(mode)
        GVInteractionHaptics.select()
        dismiss()
    }

    private func changeCategory(_ item: WorkspaceDockCategory) {
        searchFocused = false
        withAnimation(GVMotion.resolved(.spring(response: 0.38, dampingFraction: 0.82), reduceMotion: reduceMotion)) {
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
            .spatial: .init(count: DepthEffectMode.allCases.count, live: appModel.sourceMode == .lidar && appModel.depth.isActive),
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

    /// What the grid shows. A search spans every shelf — the whole point of
    /// typing is not having to know which family an effect was filed under.
    private var visibleEffects: [WorkspaceAdjustableEffect] {
        if !trimmedQuery.isEmpty {
            return EffectCatalog.search(trimmedQuery)
        }
        switch category {
        case .spatial, .blobs:
            return []
        case .all:
            return EffectCatalog.canonicalEffects(EffectCatalog.shelves.flatMap(\.effects))
        case .active:
            return editor.activeEffects
        case .favorites:
            return WorkspaceAdjustableEffect.allCases.filter { preferences.isFavorite($0.rawValue) }
        case .recents:
            return preferences.recentEffects.compactMap(WorkspaceAdjustableEffect.resolving)
        default:
            return EffectCatalog.effects(in: category.rawValue)
        }
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

    /// Exclusive by default, additive while the header's Add chip is on —
    /// exactly the contract `EffectEditingSession.selectFamily` already keeps
    /// for the rail, so nothing about stacking policy moves here.
    ///
    /// A tap *auditions*: the look renders behind the glass and the browser
    /// stays open, and it only becomes the operator's edit through the
    /// verdict bar's Keep (or an Adjust from the context menu). Closing any
    /// other way restores the stash through `endPreview`.
    private func select(_ effect: WorkspaceAdjustableEffect) {
        appModel.deactivateDepthMode()
        appModel.deactivateObjectMode()
        armAudioIfNeeded(for: effect)
        editor.auditionFromBrowser(effect)
        if editor.selectedEffect != nil {
            preferences.noteEffectUsed((editor.selectedEffect ?? effect).rawValue)
            decay.fire(.effectActivated)
        }
        GVInteractionHaptics.select()
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
