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
    /// "what is actually on" without hunting across twelve families.
    case active
    /// The operator's own shortlist, alongside the complete ALL shelf.
    case favorites
    /// The last handful the operator reached for. Sits beside favourites
    /// because both answer "where was that one" — favourites for the effects
    /// they chose to keep, recents for the ones they are working with now.
    case recents
    case color
    /// Real codec moshing: VideoToolbox decode, drop the reference data,
    /// render the damage. Its own shelf because these genuinely need a
    /// decoder rather than a frame ring.
    case datamosh
    /// Pixel and line sorting by luma, radius, history or edge.
    case sort
    /// Frame history without a codec and without sorting: hold, drag,
    /// extrude, tunnel.
    case time
    case motion
    case decay
    case signal
    case optics
    case form
    /// Colorful interactive and audio-reactive Metal shaders.
    case shaders
    case audio
    /// Measurement instruments. Kept apart from AUDIO because a scope reports
    /// on the signal rather than changing it, and a rail that mixes the two
    /// stops answering either question.
    case scope
    /// Generative work still being tuned: touch-reactive, spectrum-reactive and
    /// the two whole-frame solvers.
    case experimental
    /// Research builds that read deep internal state — the sarin experiments,
    /// the predictive moshes and the corruption brush.
    case developer
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
        case .color: "Tonal"
        case .datamosh: "Datamosh"
        case .sort: "Sort"
        case .time: "History"
        case .motion: "Motion"
        case .decay: "Decay"
        case .signal: "Analog"
        case .optics: "Lens"
        case .form: "Geometry"
        case .shaders: "Generative"
        case .audio: "Spectrum"
        case .scope: "Instruments"
        case .experimental: "Solvers"
        case .developer: "Research"
        case .spatial: "Depth"
        case .objects: "Objects"
        case .blobs: "Tracking"
        case .lidar: "LiDAR"
        case .active: "Active"
        case .favorites: "Favorites"
        case .recents: "Recent"
        }
    }

    /// Favourites and recents are drawn as glyphs instead of words, so they
    /// read as shelves rather than as two more families among the others.
    var symbol: String? {
        switch self {
        case .active: "power"
        case .favorites: "star.fill"
        case .recents: "clock.arrow.circlepath"
        case .experimental: "flask"
        case .developer: "wrench.and.screwdriver"
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

/// The effect browser.
///
/// Replaces both the radial ring and the three-cards-per-category rail. The
/// problem with the rail was not its size, it was its shape: a horizontal
/// strip of 128-point cards showed three effects at a time, hid the rest
/// behind a scroll nobody could see, and gave a thumbnail 26 points of height
/// to say something with. 192 effects need a grid, a real category list and
/// images big enough to tell `astralPlasma` from `plasmaRipple`.
///
/// Families are named for what they contain, and the shelf list is derived
/// from the same catalogue the dock reads, so a family can never exist in one
/// place and not the other.
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

    @ScaledMetric(relativeTo: .caption) private var sidebarWidth: CGFloat = 112
    @ScaledMetric(relativeTo: .caption) private var tileMinimum: CGFloat = 112
    private static let spacing: CGFloat = 14
    private let canvas = Color(red: 0.075, green: 0.073, blue: 0.080)
    private let surface = Color(red: 0.115, green: 0.112, blue: 0.122)

    init(editor: EffectEditingSession, initialCategory: WorkspaceDockCategory) {
        self.editor = editor
        self.initialCategory = initialCategory
        _category = State(initialValue: initialCategory)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                categoryColumn
                Rectangle()
                    .fill(GVTheme.bone.opacity(0.06))
                    .frame(width: 1)
                content
            }
            selectionBar
        }
        .background(canvas)
        .preferredColorScheme(.dark)
        .onDisappear { editor.endPreview() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.browser")
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text("Effects")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(GVTheme.bone)
                Spacer(minLength: 8)
                addModeChip
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.medium))
                        .foregroundStyle(GVTheme.bone)
                        .frame(width: GVMetrics.touchTarget, height: GVMetrics.touchTarget)
                        .background(surface, in: Circle())
                }
                .buttonStyle(GVPressStyle())
                .accessibilityLabel("Close effect browser")
                .accessibilityIdentifier("workspace.browser.close")
            }
            searchField
        }
        .padding(.horizontal, GVMetrics.screenInset)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    /// Stacking is the one browser action that has no tile to hang off, so it
    /// lives in the header. Off, a tap is exclusive — the same rule the rail
    /// used, stated rather than implied.
    private var addModeChip: some View {
        Button {
            editor.setStackArmed(!editor.isStackArmed)
            decay.fire(.effectActivated)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: editor.isStackArmed ? "checkmark" : "plus")
                    .font(.caption.weight(.medium))
                Text(editor.isStackArmed ? "Stacking" : "Stack")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(editor.isStackArmed ? GVTheme.bone : GVTheme.bone.opacity(0.72))
            .padding(.horizontal, 11)
            .frame(minHeight: GVMetrics.touchTarget)
            .background(
                GVTheme.bone.opacity(editor.isStackArmed ? 0.13 : 0.04),
                in: Capsule()
            )
        }
        .buttonStyle(GVPressStyle())
        .accessibilityLabel(editor.isStackArmed ? "Stacking on, taps add effects" : "Add mode off, taps replace the effect")
        .accessibilityIdentifier("workspace.browser.add")
    }

    private var searchField: some View {
        HStack(spacing: GVMetrics.gapTight) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(GVTheme.bone.opacity(0.65))
            TextField(text: $query) {
                Text("Search effects").foregroundStyle(GVTheme.bone.opacity(0.60))
            }
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { searchFocused = false }
                .font(.subheadline)
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
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(GVPressStyle())
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, GVMetrics.stepRelated)
        .frame(minHeight: GVMetrics.touchTarget)
        .background(surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(searchFocused ? 0.18 : 0.06), lineWidth: GVMetrics.hairline)
        )
    }

    /// One aligned, scrollable column keeps every group directly reachable.
    /// Personal shelves and effect families are separated, not nested.
    private var categoryColumn: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach([WorkspaceDockCategory.all, .active, .favorites, .recents]) { item in
                    categoryRow(item)
                }
                Rectangle()
                    .fill(GVTheme.bone.opacity(0.08))
                    .frame(height: 1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                ForEach(WorkspaceDockCategory.shelfCategories) { item in
                    categoryRow(item)
                }
                // Real depth modes are listed last and are not effects, so they
                // sit behind their own rule rather than inside the families.
                Rectangle()
                    .fill(GVTheme.bone.opacity(0.08))
                    .frame(height: 1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                categoryRow(.spatial)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
        }
        .frame(width: min(sidebarWidth, 152))
        .background(surface.opacity(0.32))
        .accessibilityIdentifier("workspace.browser.categories")
    }

    private func categoryRow(_ item: WorkspaceDockCategory) -> some View {
        let selected = category == item && trimmedQuery.isEmpty
        return Button {
            changeCategory(item)
        } label: {
            HStack(spacing: 5) {
                Text(item.displayLabel)
                    .font(.caption.weight(selected ? .medium : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? GVTheme.bone : GVTheme.bone.opacity(0.68))
            .padding(.horizontal, 8)
            .frame(minHeight: GVMetrics.touchTarget)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(GVTheme.bone.opacity(selected ? 0.10 : 0))
            )
            .overlay(alignment: .trailing) {
                if selected {
                    Circle().fill(GVTheme.bone.opacity(0.7))
                        .frame(width: 3, height: 3)
                        .padding(.trailing, 7)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        .accessibilityIdentifier("workspace.browser.category.\(item.rawValue)")
        .accessibilityValue(selected ? "selected" : "")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if category == .spatial, trimmedQuery.isEmpty {
            depthPane
        } else if visibleEffects.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                HStack(alignment: .firstTextBaseline) {
                    Text(trimmedQuery.isEmpty ? category.displayLabel : "Results")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(GVTheme.bone)
                    Spacer()
                    Text("\(visibleEffects.count)")
                        .font(.caption)
                        .foregroundStyle(GVTheme.bone.opacity(0.60))
                }
                .padding(.horizontal, Self.spacing)
                .padding(.top, 4)
                .padding(.bottom, 6)
                LazyVGrid(
                    // Keep the image legible on narrow phones, with additional
                    // columns when landscape offers room.
                    columns: [GridItem(.adaptive(minimum: tileMinimum, maximum: 260), spacing: Self.spacing)],
                    spacing: Self.spacing
                ) {
                    ForEach(visibleEffects, id: \.rawValue) { effect in
                        tile(effect)
                    }
                }
                .padding(Self.spacing)
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
        let image = thumbnails.image(for: effect)
        return Button {
            select(effect)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                Color.clear
                    .aspectRatio(1.12, contentMode: .fit)
                    .overlay { thumbnailBody(effect, image: image) }
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
                                .background(canvas.opacity(0.88), in: Circle())
                                .padding(8)
                                .accessibilityHidden(true)
                        }
                    }
                Text(displayName(effect))
                    .font(.caption.weight(active ? .medium : .regular))
                    .foregroundStyle(GVTheme.bone)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
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
                dismiss()
            }
            Text(effect.detail.capitalized)
            Text("Render cost \(effect.gpuCost.rawValue) of 3")
            if effect.requiresAudioAnalysis, audioRuntime.state != .running {
                Button("Open Microphone Settings", action: openMicrophoneSettings)
            }
        }
    }

    @ViewBuilder
    private func thumbnailBody(_ effect: WorkspaceAdjustableEffect, image: UIImage?) -> some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            VStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.title3.weight(.light))
                Text(thumbnails.isUnavailable(effect) ? "Preview unavailable" : "Rendering preview")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(GVTheme.bone.opacity(0.65))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
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
                    columns: [GridItem(.adaptive(minimum: tileMinimum, maximum: 260), spacing: Self.spacing)],
                    spacing: Self.spacing
                ) {
                    ForEach(DepthEffectMode.allCases) { mode in
                        depthTile(mode)
                    }
                }
            }
            .padding(Self.spacing)
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
            .frame(maxWidth: .infinity, minHeight: tileMinimum * 0.86, alignment: .topLeading)
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
                        .background(canvas.opacity(0.88), in: Circle())
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
    }

    private func changeCategory(_ item: WorkspaceDockCategory) {
        searchFocused = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            category = item
            query = ""
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(editor.selectedEffect.map(displayName) ?? "Find your next look")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(GVTheme.bone)
                    .lineLimit(1)
                Text(selectionDetail)
                    .font(.caption)
                    .foregroundStyle(GVTheme.bone.opacity(0.65))
            }
            Spacer(minLength: 4)
            if editor.selectedEffect != nil {
                Button("Adjust") { dismiss() }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(GVTheme.bone)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(GVTheme.bone.opacity(0.09), in: Capsule())
                    .accessibilityIdentifier("workspace.browser.adjust")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(surface)
    }

    private var selectionDetail: String {
        guard let selected = editor.selectedEffect else { return "Effect previews · Sample scene" }
        return editor.isEnabled(selected) ? "Applied to your camera" : "Selected · Currently off"
    }

    // MARK: - Data

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
        case .spatial:
            return []
        case .all:
            return EffectCatalog.canonicalEffects(EffectCatalog.shelves.flatMap(\.effects))
        case .active:
            return editor.activeEffects
        case .favorites:
            return WorkspaceAdjustableEffect.allCases.filter { preferences.isFavorite($0.rawValue) }
        case .recents:
            return preferences.recentEffects.compactMap(WorkspaceAdjustableEffect.init(rawValue:))
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
    private func select(_ effect: WorkspaceAdjustableEffect) {
        appModel.deactivateDepthMode()
        appModel.deactivateObjectMode()
        armAudioIfNeeded(for: effect)
        let activated = editor.selectFamily(effect, preferExactVariant: true)
        if activated {
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
