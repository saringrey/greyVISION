// swiftlint:disable file_length
import SwiftUI

// swiftlint:disable:next type_body_length
struct WorkspaceDockView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var cameraRuntime: CameraRuntime
    @EnvironmentObject private var depthRuntime: DepthRuntime
    @EnvironmentObject private var objectsRuntime: ARObjectRuntime
    @EnvironmentObject private var audioRuntime: AudioReactiveRuntime
    @EnvironmentObject private var blobRuntime: BlobTrackingRuntime
    @EnvironmentObject private var preferences: GVPreferences
    @EnvironmentObject private var decay: GVDecayEngine
    @EnvironmentObject private var toasts: GVToastBox
    /// #20. On-demand thumbnails for the effect cards. A card asks for one
    /// when it appears; nothing is rendered speculatively and nothing touches
    /// the camera.
    @StateObject private var thumbnails = GVEffectThumbnailStore.shared

    @ObservedObject var editor: EffectEditingSession
    @ObservedObject var recording: GVRecordingTransaction
    @Binding var dismissSelectionSignal: Int
    /// Read only so the parameter decks can plate themselves against a bright
    /// frame. The rails stay unplated — they are short labels with a scrim
    /// under them; the decks carry numbers.
    let statsMailbox: CameraRenderStatsMailbox
    /// Prevents the dock from claiming more height than a short landscape
    /// viewport can spare. The category rail remains pinned below the scrollable
    /// controls, so an expanded deck never makes navigation unreachable.
    var maximumHeight: CGFloat?

    @State private var selectedCategory: WorkspaceDockCategory?
    @State private var selectedDepthEffect: DepthEffectMode?
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var categoriesPresented = false
    @FocusState private var searchFocused: Bool
    /// Natural height of the browser's content, measured so the scroll view
    /// can size to it instead of filling the cap. See `dockControls`.
    @State private var contentHeight: CGFloat = 0
    /// #12. The effect currently being previewed under a held card, if any.
    @State private var previewHeldEffect: WorkspaceAdjustableEffect?
    @State private var railPositions: [WorkspaceDockCategory: String] = [:]
    @Namespace private var glassNamespace

    // MARK: - Charcoal / Black palette

    private var dockCharcoalElevated: Color { Color(red: 0.175, green: 0.175, blue: 0.183) }
    private var dockDeep: Color { Color(red: 0.078, green: 0.078, blue: 0.085) }

    private var selectedEffect: WorkspaceAdjustableEffect? {
        get { editor.selectedEffect }
        nonmutating set { editor.focus(newValue) }
    }

    private var isStackArmed: Bool {
        get { editor.isStackArmed }
        nonmutating set { editor.setStackArmed(newValue) }
    }

    private var rgbSplitParameters: RGBSplitEffectParameters { editor.rgbSplitParameters }
    private var effectStack: CameraEffectStackParameters { editor.effectStack }

    var body: some View {
        VStack(spacing: 5) {
            // One lit rule terminating the bottom chrome, matching the top.
            GVEdgeRule()
                .padding(.horizontal, 14)
                .padding(.bottom, 1)

            dockControls

            categoryRail
        }
        // No `.frame(maxHeight:)` here.
        //
        // That modifier is greedy: it makes the view expand to fill whatever
        // the parent offers, up to the maximum. So the dock claimed the full
        // 292pt cap no matter how little it held, the rail sat at the bottom
        // of that block because of the `.bottom` alignment, and the capture
        // pair rode on top of ~230pt of empty space — the gap that kept
        // putting photo/FX/record in the middle of the viewfinder.
        //
        // The cap still exists, on the scroll view inside `dockControls`,
        // where it bounds the browser without making the whole dock greedy.
        .padding(.top, 6)
        .padding(.bottom, 7)
        .padding(.horizontal, 4)
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .onChange(of: dismissSelectionSignal) { _, _ in
            // A preview tap closes an editor only. Capture-source transitions
            // are explicit actions; treating a dismiss tap as an AR exit made
            // placement and focus gestures unexpectedly tear down a session.
            selectedEffect = nil
            selectedDepthEffect = nil
        }
    }

    @ViewBuilder
    private var dockControls: some View {
        if let maximumHeight {
            ScrollView(.vertical, showsIndicators: false) {
                controlContent
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: DockContentHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            // A ScrollView has no intrinsic height — it takes every point it
            // is offered. Inside the dock's `maxHeight` that meant the browser
            // always claimed the full 292pt whatever it actually held, so a
            // dock with one short rail in it reserved a third of the screen of
            // empty black and pushed the capture row into the middle of the
            // viewfinder. Measuring the content and sizing to it, capped, is
            // what makes the dock hug what it contains.
            .frame(height: min(max(contentHeight, 0), maximumHeight))
            .onPreferenceChange(DockContentHeightKey.self) { height in
                if abs(contentHeight - height) > 0.5 { contentHeight = height }
            }
        } else {
            controlContent
        }
    }

    @ViewBuilder
    private var controlContent: some View {
        VStack(spacing: 5) {
            if let selectedDepthEffect {
                DepthEffectParameterDeck(
                    effect: selectedDepthEffect,
                    parameters: $depthRuntime.parameters,
                    onClose: { self.selectedDepthEffect = nil },
                    onExitDepth: appModel.deactivateDepthMode
                )
                .transition(deckTransition)
            } else if let selectedEffect {
                WorkspaceEffectParameterDeck(
                    effect: selectedEffect,
                    editor: editor,
                    isFavorite: preferences.isFavorite(selectedEffect.rawValue),
                    onFavoriteToggled: { preferences.toggleFavorite(selectedEffect.rawValue) },
                    onSelectEffect: { self.selectedEffect = $0 },
                    onClose: { self.selectedEffect = nil }
                )
                .transition(deckTransition)
            } else if selectedCategory == .objects, appModel.sourceMode == .objects {
                ARObjectsParameterDeck(
                    parameters: $objectsRuntime.parameters,
                    objectCount: objectsRuntime.objects.count,
                    isRecording: objectsRuntime.isRecording,
                    onRecordToggle: {
                        recording.toggleRecording(
                            cameraRuntime: cameraRuntime,
                            objectsRuntime: objectsRuntime,
                            sourceMode: appModel.sourceMode
                        )
                    },
                    onClear: { objectsRuntime.clearObjects() },
                    onExit: appModel.deactivateObjectMode,
                    onClose: { self.selectedCategory = nil }
                )
                .transition(deckTransition)
            } else if selectedCategory == .blobs, blobRuntime.isEnabled {
                BlobTrackingParameterDeck(
                    parameters: $blobRuntime.parameters,
                    isEnabled: blobRuntime.isEnabled,
                    status: blobRuntime.status,
                    onParametersChanged: { blobRuntime.setParameters($0) },
                    onToggle: toggleBlobs,
                    onClose: { self.selectedCategory = nil }
                )
                .transition(deckTransition)
            }

            // Search was built — field, matcher, result rail, accessibility
            // identifiers — and then never placed in the body. Across ten
            // families plus system shelves, "find the one I mean" is the only
            // navigation that scales, so it is mounted here and takes the
            // rail slot while it is open.
            if isSearching {
                searchField
                searchRail
                    .transition(deckTransition)
            } else if let selectedCategory {
                actionRail(for: selectedCategory)
                    .transition(deckTransition)
            }
        }
        .animation(GVMotion.resolved(GVMotion.panel, reduceMotion: reduceMotion), value: selectedCategory)
        .animation(GVMotion.resolved(GVMotion.panel, reduceMotion: reduceMotion), value: selectedEffect != nil)
        .animation(GVMotion.resolved(GVMotion.panel, reduceMotion: reduceMotion), value: selectedDepthEffect != nil)
        .animation(GVMotion.resolved(GVMotion.panel, reduceMotion: reduceMotion), value: isSearching)
    }

    private var deckTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    /// All shipped families stay discoverable, including hardware-only modes.
    private var visibleCategories: [WorkspaceDockCategory] {
        WorkspaceDockCategory.allCases
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every effect whose name or one-line description contains the query.
    ///
    private var searchMatches: [WorkspaceAdjustableEffect] {
        EffectCatalog.search(trimmedSearch)
    }

    private var searchField: some View {
        HStack(spacing: GVMetrics.gapTight) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GVTheme.ash)
            TextField("Search effects", text: $searchText)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { searchFocused = false }
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(GVTheme.bone)
                .tint(.white)
                .accessibilityIdentifier("workspace.search.field")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: GVMetrics.textBody, weight: .bold))
                        .foregroundStyle(GVTheme.ash)
                        .frame(width: GVMetrics.touchTarget, height: GVMetrics.controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("workspace.search.clear")
            }
        }
        .padding(.horizontal, GVMetrics.stepRelated)
        .frame(height: GVMetrics.controlHeight)
        .gvGlassField(radius: 10)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(searchFocused ? Color.white.opacity(0.18) : Color.white.opacity(0.06), lineWidth: GVMetrics.hairline)
        )
        .gvLiquidGlassID("effects-search-field", in: glassNamespace)
        .padding(.horizontal, GVMetrics.screenInset)
    }

    private var searchRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 6) {
                if trimmedSearch.isEmpty {
                    emptyRailNotice("Type to find an effect")
                } else if searchMatches.isEmpty {
                    emptyRailNotice("No matches for “\(trimmedSearch)”")
                } else {
                    effectCards(searchMatches, preserveVariants: true)
                }
            }
            .padding(4)
            .scrollTargetLayout()
            .gvLiquidGlassContainer(spacing: 6)
        }
        .scrollTargetBehavior(.viewAligned)
        .gvHorizontalEdgeFade()
        .gvGlassRail(radius: 14, tint: dockDeep.opacity(0.38))
        .gvLiquidGlassID("effects-search-rail", in: glassNamespace)
        .accessibilityIdentifier("workspace.effects.search")
    }

    private var categoryRail: some View {
        HStack(spacing: 4) {
            Button { categoriesPresented.toggle() } label: {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black, in: RoundedRectangle(cornerRadius: 9))
            }
            .accessibilityLabel("All effect categories")
            .accessibilityIdentifier("workspace.categories.all")
            .popover(isPresented: $categoriesPresented) {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(visibleCategories) { category in
                            Button {
                                categoriesPresented = false
                                selectCategory(category)
                            } label: {
                                Text(category.displayLabel)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("workspace.categoryPicker.\(category.rawValue)")
                        }
                    }
                    .padding(10)
                }
                .frame(width: 280, height: 414)
                .accessibilityIdentifier("workspace.categoryPicker.scroll")
                .presentationBackground(.black)
                .presentationCompactAdaptation(.popover)
            }
            categoryScrollRail
        }
    }

    private var categoryScrollRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                searchButton
                categoryButton(.all)
                categoryButton(.favorites, populated: hasContent(.favorites))
                ForEach(visibleCategories.filter { $0 != .all && $0 != .active && $0 != .favorites && $0 != .recents && $0 != .lidar }) { category in
                    categoryButton(category, populated: hasContent(category))
                }
                categoryButton(.active, populated: hasContent(.active))
                categoryButton(.recents, populated: hasContent(.recents))
                categoryButton(.lidar)
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .scrollTargetLayout()
            .gvLiquidGlassContainer(spacing: 6)
        }
        .gvScrollProgressLine()
        .contentMargins(.horizontal, 2, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        // Clipped pills should read as "more over here", not layout overflow.
        .gvHorizontalEdgeFade()
        .gvGlassRail(radius: 14, tint: dockDeep.opacity(0.32))
        // The variant rail is gone for effect families, so the primary family
        // strip can sit closer to the glass and return that height to preview.
        .offset(y: 3)
        .accessibilityIdentifier("workspace.categories")
    }

    /// Opens search in the rail slot. Deliberately styled as a category pill
    /// rather than as a field: the field only appears once search is on, so
    /// the collapsed state costs one glyph of rail instead of a whole row.
    private var searchButton: some View {
        Button {
            decay.fire(.effectActivated)
            withAnimation(GVMotion.panel) {
                isSearching.toggle()
                if isSearching {
                    selectedCategory = nil
                } else {
                    searchText = ""
                }
            }
            searchFocused = isSearching
        } label: {
            Image(systemName: isSearching ? "xmark" : "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSearching ? GVTheme.bone : GVTheme.bone.opacity(0.72))
                .padding(.horizontal, 11)
                .frame(height: GVMetrics.controlHeight)
        }
        .buttonStyle(GVGlassChipButtonStyle(active: isSearching, tint: .white))
        .frame(minHeight: GVMetrics.touchTarget)
        .contentShape(Rectangle())
        .gvLiquidGlassID("effects-search", in: glassNamespace)
        .accessibilityLabel("Search effects")
        .accessibilityValue(isSearching ? "open" : "closed")
        .accessibilityIdentifier("workspace.search.toggle")
    }

    private struct GVGlassChipButtonStyle: ButtonStyle {
        let active: Bool
        let tint: Color

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .gvGlassChip(radius: 9, active: active || configuration.isPressed, tint: tint)
                .frame(height: GVMetrics.controlHeight)
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.98 : 1))
                .brightness(configuration.isPressed ? 0.025 : 0)
                .animation(GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion), value: configuration.isPressed)
        }
    }

    private func categoryButton(_ category: WorkspaceDockCategory, populated: Bool = true) -> some View {
        let selected = selectedCategory == category
        return Button {
            selectCategory(category)
        } label: {
            categoryLabel(category, selected: selected, populated: populated)
                .padding(.horizontal, 10)
                .frame(height: GVMetrics.controlHeight)
        }
        .buttonStyle(GVGlassChipButtonStyle(active: selected, tint: .white))
        .frame(minHeight: GVMetrics.touchTarget)
        .contentShape(Rectangle())
        .gvLiquidGlassID("effects-category-\(category.rawValue)", in: glassNamespace)
        .accessibilityIdentifier("workspace.category.\(category.rawValue)")
        .accessibilityValue(selected ? "expanded" : "collapsed")
        .accessibilityHint("Double tap to browse effects")
    }

    private func selectCategory(_ category: WorkspaceDockCategory) {
        let selected = selectedCategory == category
        decay.fire(.effectActivated)
        // Leaving STACK armed makes every later effect tap additive, which
        // is indistinguishable from "effects stack by default". Changing
        // category always returns to exclusive selection.
        isStackArmed = false
        withAnimation(GVMotion.panel) {
            if !EffectCatalog.effects(in: category.rawValue).isEmpty {
                isSearching = false
                selectedDepthEffect = nil
                selectedEffect = nil
                selectedCategory = selected ? nil : category
            } else if selected {
                // Closing a system rail only collapses the browser. The
                // previous build disabled the whole composition and exited
                // depth mode here, so a second tap on All/Active/Favorites/
                // Recents/Objects/Tracking/LiDAR wiped the live look.
                selectedCategory = nil
                selectedEffect = nil
                selectedDepthEffect = nil
            } else {
                isSearching = false
                selectedCategory = category
                if category != .favorites {
                    selectedEffect = nil
                }
                if category != .lidar {
                    selectedDepthEffect = nil
                }
                if category != .objects, appModel.sourceMode == .objects {
                    appModel.deactivateObjectMode()
                }
            }
        }
    }

    private func actionRail(for category: WorkspaceDockCategory) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 6) {
                actionCards(for: category)
            }
            .padding(4)
            .scrollTargetLayout()
            .gvLiquidGlassContainer(spacing: 6)
        }
        .scrollTargetBehavior(.viewAligned)
        .gvHorizontalEdgeFade()
        .gvScrollProgressLine()
        .scrollPosition(id: Binding<String?>(
            get: { railPositions[category] },
            set: { if let id = $0 { railPositions[category] = id } }
        ))
        .gvGlassRail(radius: 14, tint: dockDeep.opacity(0.38))
        .gvLiquidGlassID("effects-action-rail", in: glassNamespace)
        .transition(.opacity)
        .accessibilityIdentifier("workspace.effects.\(category.rawValue)")
    }

    @ViewBuilder
    // swiftlint:disable:next cyclomatic_complexity
    private func actionCards(for category: WorkspaceDockCategory) -> some View {
        switch category {
        case .all:
            effectCards(WorkspaceAdjustableEffect.allCases, preserveVariants: true)
        case .active:
            if activeEffectList.isEmpty {
                emptyRailNotice("Nothing active · Enable an effect to see it here")
            } else {
                effectCards(activeEffectList, preserveVariants: true)
            }
        case .favorites:
            favoriteCards
        case .recents:
            recentCards
        case .color:
            effectCards(EffectCatalog.effects(in: "color"))
        case .time:
            effectCards(EffectCatalog.effects(in: "time"))
        case .motion:
            effectCards(EffectCatalog.effects(in: "motion"))
        case .decay:
            effectCards(EffectCatalog.effects(in: "decay"))
        case .signal:
            effectCards(EffectCatalog.effects(in: "signal"))
        case .optics:
            effectCards(EffectCatalog.effects(in: "optics"))
        case .form:
            effectCards(EffectCatalog.effects(in: "form"))
        case .shaders:
            shaderCards
        case .audio:
            audioCards
        case .scope:
            scopeCards
        case .lidar:
            lidarCards
        case .objects:
            objectsCards
        case .blobs:
            blobCards
        }
    }

    private var objectsCards: some View {
        let active = appModel.sourceMode == .objects && objectsRuntime.isActive
        return actionCard(
            1,
            "AR Objects",
            objectsRuntime.capability.isSupported ? "Placed 3D geometry" : objectsRuntime.capability.reason,
            active: active,
            selected: selectedCategory == .objects,
            available: objectsRuntime.capability.isSupported
        ) {
            if active {
                appModel.deactivateObjectMode()
            } else {
                appModel.activateObjectMode()
            }
        }
    }

    private var blobCards: some View {
        actionCard(
            1,
            "Blob Tracking",
            "Color field analyzer",
            active: blobRuntime.isEnabled
        ) {
            toggleBlobs()
        }
    }

    private func toggleBlobs() {
        if blobRuntime.isEnabled {
            blobRuntime.stop(using: cameraRuntime)
        } else {
            blobRuntime.start(using: cameraRuntime)
        }
    }

    private var audioCards: some View {
        effectCards(EffectCatalog.effects(in: "audio"))
    }

    private var scopeCards: some View {
        effectCards(EffectCatalog.effects(in: "scope"))
    }

    /// Every effect currently contributing pixels: RGB split plus each live
    /// stack slot, in the order the renderer applies them.
    private var activeEffectList: [WorkspaceAdjustableEffect] {
        editor.activeEffects
    }

    /// Starred effects, in canonical order rather than the order they were
    /// starred, so the shelf stays where the operator last saw it.
    private var favoriteEffects: [WorkspaceAdjustableEffect] {
        WorkspaceAdjustableEffect.allCases.filter { preferences.isFavorite($0.rawValue) }
    }

    /// Recents keep their own order — most recent first — because unlike
    /// favourites the order *is* the information.
    private var recentEffects: [WorkspaceAdjustableEffect] {
        preferences.recentEffects.compactMap(WorkspaceAdjustableEffect.init(rawValue:))
    }

    @ViewBuilder
    private var recentCards: some View {
        if recentEffects.isEmpty {
            emptyRailNotice("No recent effects · Your picks will appear here")
        } else {
            effectCards(recentEffects, preserveVariants: true)
        }
    }

    @ViewBuilder
    private var favoriteCards: some View {
        if favoriteEffects.isEmpty {
            // An empty rail with no explanation reads as a broken category.
            emptyRailNotice("No favorites yet · Open an effect and tap ☆ to pin it")
        } else {
            effectCards(favoriteEffects, preserveVariants: true)
        }
    }

    private func emptyRailNotice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(GVTheme.ash)
            .frame(height: GVMetrics.cardHeight)
            .padding(.horizontal, 12)
    }

    private var shaderCards: some View {
        effectCards(EffectCatalog.effects(in: "shaders"))
    }

    private func effectCards(_ effects: [WorkspaceAdjustableEffect], preserveVariants: Bool = false) -> some View {
        // Deduped once per category rather than per body pass. The rail is
        // re-rendered on every parameter write, and rebuilding a 192-element
        // `enumerated()` array each time to number the cards was pure churn.
        let displayed = WorkspaceDockView.displayedCards(
            for: effects,
            preserveVariants: preserveVariants
        )
        return ForEach(displayed, id: \.effect) { card in
            effectCard(
                card.position,
                card.effect,
                card.effect.detail,
                active: isEffectEnabled(card.effect),
                preserveVariant: true
            )
            .id(card.effect.rawValue)
        }
    }

    /// One numbered card, resolved once per category selection.
    private struct CardEntry: Identifiable {
        let effect: WorkspaceAdjustableEffect
        let position: Int
        var id: String { effect.rawValue }
    }

    private static func displayedCards(
        for effects: [WorkspaceAdjustableEffect],
        preserveVariants: Bool
    ) -> [CardEntry] {
        var seen = Set<WorkspaceAdjustableEffect>()
        let ordered = preserveVariants
            ? effects.filter { seen.insert($0).inserted }
            : effects.flatMap { EffectCatalog.variants(for: $0) }.filter { seen.insert($0).inserted }
        return ordered.enumerated().map { CardEntry(effect: $0.element, position: $0.offset + 1) }
    }

    private var lidarCards: some View {
        ForEach(Array(DepthEffectMode.allCases.enumerated()), id: \.element.id) { index, effect in
            actionCard(
                index + 1,
                effect.label,
                depthRuntime.capability.isSupported ? effect.detail : depthRuntime.capability.reason,
                active: appModel.sourceMode == .lidar && depthRuntime.effect == effect && depthRuntime.isActive,
                selected: selectedDepthEffect == effect,
                available: depthRuntime.capability.isSupported
            ) {
                selectDepth(effect)
            }
        }
    }

    private func effectCard(
        _ index: Int,
        _ effect: WorkspaceAdjustableEffect,
        _ detail: String,
        active: Bool,
        preserveVariant: Bool = false
    ) -> some View {
        actionCard(
            index,
            effect.label,
            detail,
            active: active,
            selected: preserveVariant ? selectedEffect == effect : selectedEffect.map { EffectCatalog.canonical($0) == effect } ?? false,
            // #17. What this effect costs the renderer, as a one-to-three dot
            // read. The requirements behind it are already declared per
            // effect; the rail just never showed them, so stacking a fluid
            // solve on top of three datamoshes looked like any other pair of
            // choices until the frames started dropping.
            cost: effect.gpuCost,
            // #18. A family card that stands in for siblings says so, rather
            // than silently hiding `kaleido6`, `curlWarp` and
            // `opticalFlowLiquid` behind a label that does not contain them.
            variantCount: EffectCatalog.variants(for: effect).count,
            needsMicrophone: effect.requiresAudioAnalysis && audioRuntime.state != .running,
            thumbnailProvider: {
                GVEffectThumbnailStore.isEligible(effect) ? thumbnails.image(for: effect) : nil
            }
        ) {
            searchFocused = false
            select(effect, preferExactVariant: preserveVariant)
        }
        // Asks for the render when the card is actually on screen, which is
        // the whole scheduling policy: one thumbnail per card the operator
        // actually looked at, on a utility queue, and never for a card they
        // scrolled past without stopping on.
        .onAppear {
            guard GVEffectThumbnailStore.isEligible(effect) else { return }
            thumbnails.request(effect)
        }
        // #12. Press and hold to see the effect on the live frame before
        // committing to it. With 192 effects, browsing by committing to a
        // guess is the wrong interaction; this is the same non-destructive
        // preview the preset drawer already uses, pointed at a single effect.
        .simultaneousGesture(holdToPreview(effect))
        // Marked, not tappable. The card face is the select target; starring
        // happens in the effect's own deck and shows up here.
        .overlay(alignment: .topTrailing) {
            if preferences.isFavorite(effect.rawValue) {
                Image(systemName: "star.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.top, 6)
                    .padding(.trailing, 7)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Previews an effect on the live frame while a finger is down and puts
    /// the composition back exactly as it was on release.
    ///
    /// The stash is taken once per hold, so dragging off the card mid-gesture
    /// cannot leave a partial preview behind. `beginPreview` deliberately does
    /// not touch the focused slot or the undo history, which is what makes it
    /// safe to fire on a control the operator is also tapping.
    private func holdToPreview(_ effect: WorkspaceAdjustableEffect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard previewHeldEffect != effect else { return }
                previewHeldEffect = effect
                var stack = editor.effectStack
                var rgb = editor.rgbSplitParameters
                stack.setEnabled(true, for: effect)
                editor.beginPreview(CompositionSnapshot(stack: stack, rgb: rgb))
            }
            .onEnded { _ in endEffectPreview() }
    }

    private func endEffectPreview() {
        guard previewHeldEffect != nil else { return }
        previewHeldEffect = nil
        editor.endPreview()
    }

    private func actionCard(
        _ index: Int,
        _ label: String,
        _ detail: String,
        active: Bool = false,
        selected: Bool = false,
        available: Bool = true,
        cost: GVEffectGPUCost? = nil,
        variantCount: Int = 1,
        needsMicrophone: Bool = false,
        /// Supplies the card's thumbnail, if the effect has one. Injected
        /// rather than read from the store directly so the non-effect rails —
        /// LiDAR, objects, tracking — stay untouched by it.
        thumbnailProvider: (() -> UIImage?)? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let motionReduced = reduceMotion
        let isLit = active || selected
        // Resolved before the label is built so the card can show it in the
        // same pass. A nil here is the normal case for an unseen effect.
        let thumbnail = thumbnailProvider?()

        return Button {
            action()
        } label: {
            VStack(spacing: 3) {
                // #20. The thumbnail is a legibility aid, not the identity:
                // it sits behind the text at low contrast and is simply absent
                // until it has been rendered, so a card the operator has never
                // scrolled to looks exactly as it did before.
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .clipped()
                        .opacity(isLit ? 0.5 : 0.34)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 4) {
                    Text(label.capitalized)
                        .font(.system(size: 13, weight: isLit ? .semibold : .medium))
                        .foregroundStyle(isLit ? Color.white : GVTheme.bone.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if !available {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(GVTheme.record)
                    } else if needsMicrophone {
                        // #14. An audio-reactive effect with the microphone
                        // closed renders against a silent uniform, and the card
                        // used to look exactly like one that would work. A
                        // struck-through mic says the difference without a
                        // word, and the tap below opens Settings.
                        Image(systemName: "mic.slash.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(GVTheme.warn)
                            .accessibilityHidden(true)
                    }
                    if variantCount > 1 {
                        // #18. This card stands in for its siblings.
                        Text("\(variantCount)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(GVTheme.ash)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                            .accessibilityHidden(true)
                    }
                }

                HStack(spacing: 4) {
                    Text(detail.capitalized)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(isLit ? Color.white.opacity(0.68) : GVTheme.ash.opacity(0.85))
                        .lineLimit(1)
                    if let cost {
                        // #17. Filled pips up to the band, so the heaviest
                        // reads as the loudest mark rather than as a number
                        // the operator has to look up.
                        HStack(spacing: 1.5) {
                            ForEach(0 ..< 3, id: \.self) { index in
                                Circle()
                                    .fill(index < cost.rawValue
                                        ? costTint(cost)
                                        : Color.white.opacity(0.16))
                                    .frame(width: 3.5, height: 3.5)
                            }
                        }
                        .accessibilityHidden(true)
                    }
                }
            }
            .frame(width: 128, height: GVMetrics.cardHeight)
        }
        .buttonStyle(GVGlassCardStyle(active: isLit, available: available))
        .gvLiquidGlassID("effects-card-\(slug(label))", in: glassNamespace)
        .scrollTransition(.interactive, axis: .horizontal) { content, phase in
            content
                .opacity(motionReduced || phase.isIdentity ? 1 : 0.84)
                .scaleEffect(motionReduced || phase.isIdentity ? 1 : 0.98)
        }
        .accessibilityLabel(label)
        .accessibilityHint(detail)
        .accessibilityIdentifier("workspace.action.\(slug(label))")
        .accessibilityValue(accessibilityState(active: active, cost: cost, variants: variantCount, needsMicrophone: needsMicrophone))
        .accessibilityAction(named: "Open Microphone Settings") {
            openMicrophoneSettings()
        }
    }

    /// The spoken form of everything the card face encodes in dots and
    /// glyphs. A cost pip is meaningless read aloud.
    private func accessibilityState(
        active: Bool,
        cost: GVEffectGPUCost?,
        variants: Int,
        needsMicrophone: Bool
    ) -> String {
        var parts = [active ? "active" : "inactive"]
        if let cost {
            parts.append("render cost \(cost.rawValue) of 3")
        }
        if variants > 1 {
            parts.append("\(variants) variants in this family")
        }
        if needsMicrophone {
            parts.append("microphone off, tap to open Settings")
        }
        return parts.joined(separator: ", ")
    }

    private func costTint(_ cost: GVEffectGPUCost) -> Color {
        switch cost {
        case .light: GVTheme.bone.opacity(0.8)
        case .moderate: GVTheme.warn
        case .heavy: GVTheme.record
        }
    }

    /// #14. A denied effect is a dead end unless the operator can reach the
    /// switch that fixes it, so the toast and the card both offer the way out.
    private func openMicrophoneSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private struct GVGlassCardStyle: ButtonStyle {
        let active: Bool
        let available: Bool

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .gvGlassChip(
                    radius: 12,
                    active: active || configuration.isPressed,
                    tint: .white
                )
                .opacity(active ? 1 : (available ? 1 : 0.6))
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.985 : 1))
                .brightness(configuration.isPressed ? 0.02 : 0)
                .animation(GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion), value: configuration.isPressed)
        }
    }

    private func lockedCard(_ index: Int, _ label: String, _ reason: String) -> some View {
        actionCard(index, label, reason, available: false) {
            showUnavailable("\(label): \(reason)")
        }
    }

    private func statusDots(active: Bool, available: Bool) -> some View {
        HStack(spacing: 3) {
            ForEach(0 ..< 4, id: \.self) { index in
                let primaryColor = active
                    ? Color.white
                    : available ? GVTheme.bone.opacity(0.55) : GVTheme.record
                let secondaryColor = active ? Color.white.opacity(0.32) : Color(white: 0.22)
                Circle()
                    .fill(index == 0 ? primaryColor : secondaryColor)
                    .frame(width: 4.5, height: 4.5)
            }
        }
    }

    /// Whether a shelf family currently holds anything — favourites and
    /// recents are the only ones that can be empty, and their glyphs say so.
    private func hasContent(_ category: WorkspaceDockCategory) -> Bool {
        switch category {
        case .favorites: !favoriteEffects.isEmpty
        case .recents: !recentEffects.isEmpty
        default: true
        }
    }

    @ViewBuilder
    private func categoryLabel(_ category: WorkspaceDockCategory, selected: Bool, populated: Bool = true) -> some View {
        if let symbol = category.symbol {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                // Populated shelf reads lit; an empty one dims to a whisper so
                // "nothing here yet" is visible without opening it.
                .foregroundStyle(selected ? GVTheme.bone : (populated ? GVTheme.bone.opacity(0.72) : GVTheme.ash.opacity(0.38)))
                // Matches the optical width of a short word so the star does
                // not read as a gap in the rail.
                .frame(width: 22)
                .accessibilityLabel("Favourites")
        } else {
            Text(category.displayLabel)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                // Quiet. The rail is a list of what is available, not five
                // things all claiming to be selected.
                .foregroundStyle(selected ? GVTheme.bone : GVTheme.ash)
        }
    }

    private func categoryBorder(selected: Bool) -> some View {
        GVChamferedPlate()
            .stroke(selected ? GVTheme.bone.opacity(0.82) : GVTheme.ash.opacity(0.38), lineWidth: selected ? 1 : GVMetrics.hairline)
    }

    private func select(_ effect: WorkspaceAdjustableEffect, preferExactVariant: Bool = false) {
        selectedDepthEffect = nil
        appModel.deactivateDepthMode()
        appModel.deactivateObjectMode()
        armAudioIfNeeded(for: effect)
        let activated = editor.selectFamily(effect, preferExactVariant: preferExactVariant)
        // Recorded on activation only. An effect the operator turned off is
        // not one they were reaching for.
        if activated {
            preferences.noteEffectUsed((editor.selectedEffect ?? effect).rawValue)
        }
    }

    private func selectDepth(_ effect: DepthEffectMode) {
        guard depthRuntime.capability.isSupported else {
            showUnavailable("\(effect.label): \(depthRuntime.capability.reason)")
            return
        }
        selectedEffect = nil
        disableAllEffects()
        appModel.deactivateObjectMode()
        selectedDepthEffect = effect
        appModel.activateDepthEffect(effect)
    }

    private func activateOnly(_ effect: WorkspaceAdjustableEffect) {
        editor.enableOnly(effect)
    }

    private func setStackArmed(_ armed: Bool) {
        editor.setStackArmed(armed)
    }

    private func disableAllEffects() {
        editor.disableAll()
    }

    private func setEnabled(_ effect: WorkspaceAdjustableEffect, _ enabled: Bool) {
        editor.setEnabled(effect, enabled)
    }

    private func isEffectEnabled(_ effect: WorkspaceAdjustableEffect) -> Bool {
        editor.isEnabled(effect)
    }

    /// Audio-reactive effects are inert without the analyser, so selecting one
    /// requests the microphone rather than presenting a dead control.
    private func armAudioIfNeeded(for effect: WorkspaceAdjustableEffect) {
        guard effect.requiresAudioAnalysis, !audioRuntime.isEnabled else { return }
        switch audioRuntime.state {
        case .denied:
            showUnavailable("\(effect.label) needs microphone access")
        case .failed:
            showUnavailable("\(effect.label): audio engine unavailable")
        default:
            Task { @MainActor in
                await audioRuntime.start()
                if audioRuntime.state == .denied {
                    showUnavailable("\(effect.label) needs microphone access")
                }
            }
        }
    }

    private func showUnavailable(_ message: String) {
        toasts.show(message)
    }

    private func slug(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}

private enum WorkspaceDockCategory: String, CaseIterable, Identifiable {
    case all
    /// Everything rendering right now, in pipeline order. The answer to
    /// "what is actually on" without hunting across ten families.
    case active
    /// The operator's own shortlist, alongside the complete ALL shelf.
    case favorites
    /// The last handful the operator reached for. Sits beside favourites
    /// because both answer "where was that one" — favourites for the effects
    /// they chose to keep, recents for the ones they are working with now.
    case recents
    case color
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
    case objects
    case blobs
    case lidar

    var id: String {
        rawValue
    }

    var label: String {
        labelOverride ?? rawValue.uppercased()
    }

    /// Clean display form for the rail. Identifiers and logic keep `label`;
    /// the visible rail uses title case for a calmer, professional read.
    var displayLabel: String {
        switch self {
        case .all: "All"
        case .color: "Color"
        case .time: "Time"
        case .motion: "Motion"
        case .decay: "Decay"
        case .signal: "Signal"
        case .optics: "Optics"
        case .form: "Form"
        case .shaders: "Shaders"
        case .audio: "Audio"
        case .scope: "Scope"
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
        default: nil
        }
    }

    var labelOverride: String? {
        self == .active ? "ACTIVE" : nil
    }
}

// swiftlint:enable file_length

/// Reports the dock browser's natural content height up to `dockControls`.
private struct DockContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct GVRadialHoldGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    var allowsSimultaneousTaps = true
    /// Preview path widens this so the hold survives finger drift and the
    /// preview's competing pan recognizer; the dock keeps 12.
    var allowableMovement: CGFloat = 12
    let onAction: (UIGestureRecognizer.State, CGPoint) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.22
        recognizer.allowableMovement = allowableMovement
        recognizer.isEnabled = isEnabled
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func makeCoordinator(converter _: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(allowsSimultaneousTaps: allowsSimultaneousTaps)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var allowsSimultaneousTaps: Bool

        init(allowsSimultaneousTaps: Bool) {
            self.allowsSimultaneousTaps = allowsSimultaneousTaps
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool
        {
            // The camera preview installs its own eager tap / pan recognizers on
            // the MTKView (focus, touch-drag, spectrum overlay). If the hold does
            // not recognize simultaneously, the pan recognizer steals the touch on
            // the slightest finger drift and fails the long-press before its
            // minimumPressDuration elapses — so the radial menu never appears.
            // Recognizing simultaneously lets the hold complete; the workspace's
            // isPreviewHoldActive guard suppresses the competing tap/focus after a
            // completed hold, so nothing double-fires.
            if gestureRecognizer.view !== otherGestureRecognizer.view {
                return true
            }
            // Button highlighting starts on touch-down. It must not defeat a
            // later hold; movement still fails the hold before a normal swipe.
            // A completed hold must not also focus/tap-dismiss the preview.
            return allowsSimultaneousTaps || !(otherGestureRecognizer is UITapGestureRecognizer)
        }
    }

    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
        recognizer.allowableMovement = allowableMovement
        context.coordinator.allowsSimultaneousTaps = allowsSimultaneousTaps
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        onAction(recognizer.state, context.converter.location(in: .global))
    }
}
