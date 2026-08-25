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

    @Binding var rgbSplitParameters: RGBSplitEffectParameters
    @Binding var effectStack: CameraEffectStackParameters
    @Binding var dismissSelectionSignal: Int
    /// Read only so the parameter decks can plate themselves against a bright
    /// frame. The rails stay unplated — they are short labels with a scrim
    /// under them; the decks carry numbers.
    let statsMailbox: CameraRenderStatsMailbox
    let onHideChrome: () -> Void
    /// Capture actions moved into the dock: recording and photo live beside
    /// where effects are chosen, instead of floating over the frame.
    let onCapturePhoto: () -> Void
    let onToggleRecording: () -> Void

    @Binding var presetsPresented: Bool

    @State private var selectedCategory: WorkspaceDockCategory?
    @State private var selectedEffect: WorkspaceAdjustableEffect?
    @State private var selectedDepthEffect: DepthEffectMode?
    @State private var isStackArmed = false
    @State private var searchText = ""
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool

    // MARK: - Charcoal / Black palette — single cohesive material for the whole dock
    private var dockCharcoal: Color { Color(red: 0.135, green: 0.135, blue: 0.143) }
    private var dockCharcoalElevated: Color { Color(red: 0.175, green: 0.175, blue: 0.183) }
    private var dockDeep: Color { Color(red: 0.078, green: 0.078, blue: 0.085) }
    private var dockBlack: Color { Color(red: 0.045, green: 0.045, blue: 0.05) }

    var body: some View {
        VStack(spacing: 5) {
            // One lit rule terminating the bottom chrome, matching the top.
            GVEdgeRule()
                .padding(.horizontal, 14)
                .padding(.bottom, 1)

            if let selectedDepthEffect {
                DepthEffectParameterDeck(
                    effect: selectedDepthEffect,
                    parameters: $depthRuntime.parameters,
                    onClose: { self.selectedDepthEffect = nil },
                    onExitDepth: appModel.deactivateDepthMode
                )
                .gvAdaptivePlate(statsMailbox)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let selectedEffect {
                WorkspaceEffectParameterDeck(
                    effect: selectedEffect,
                    rgbSplitParameters: $rgbSplitParameters,
                    effectStack: $effectStack,
                    isStackArmed: isStackArmed,
                    onStackChanged: setStackArmed,
                    isFavorite: preferences.isFavorite(selectedEffect.rawValue),
                    onFavoriteToggled: { preferences.toggleFavorite(selectedEffect.rawValue) },
                    onHideChrome: onHideChrome,
                    onClose: { self.selectedEffect = nil }
                )
                .gvAdaptivePlate(statsMailbox)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if selectedCategory == .objects, appModel.sourceMode == .objects {
                ARObjectsParameterDeck(
                    parameters: $objectsRuntime.parameters,
                    objectCount: objectsRuntime.objects.count,
                    isRecording: objectsRuntime.isRecording,
                    onRecordToggle: { objectsRuntime.toggleRecording() },
                    onClear: { objectsRuntime.clearObjects() },
                    onExit: appModel.deactivateObjectMode,
                    onClose: { self.selectedCategory = nil }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if selectedCategory == .blobs, blobRuntime.isEnabled {
                BlobTrackingParameterDeck(
                    parameters: $blobRuntime.parameters,
                    isEnabled: blobRuntime.isEnabled,
                    status: blobRuntime.status,
                    onParametersChanged: { blobRuntime.setParameters($0) },
                    onToggle: toggleBlobs,
                    onClose: { self.selectedCategory = nil }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let selectedCategory {
                actionRail(for: selectedCategory)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            activeStackStrip
            captureRow
            categoryRail
        }
        .padding(.top, 6)
        .padding(.bottom, 7)
        .padding(.horizontal, 4)
        .background(
            ZStack(alignment: .top) {
                // Single cohesive charcoal → black material for entire dock
                LinearGradient(
                    colors: [dockCharcoal, dockDeep, dockBlack],
                    startPoint: .top,
                    endPoint: .bottom
                )
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 1 / UIScreen.main.scale)
                    .frame(maxHeight: .infinity, alignment: .top)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.065), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.72), radius: 18, y: 10)
            .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .animation(GVMotion.panel, value: selectedCategory)
        .animation(GVMotion.panel, value: selectedEffect)
        .animation(GVMotion.panel, value: selectedDepthEffect)
        .onChange(of: dismissSelectionSignal) { _, _ in
            // A preview tap CLOSES THE EDITOR and nothing else. It used to
            // also power the effect down, which made an ordinary focus
            // gesture capable of changing the composition. Only explicit
            // power, remove, clear or undo touch what is rendering now.
            selectedEffect = nil
            if selectedDepthEffect != nil {
                appModel.deactivateDepthMode()
            }
            selectedDepthEffect = nil
            if appModel.sourceMode == .objects {
                appModel.deactivateObjectMode()
            }
        }
    }

    /// Experimental families stay hidden until the operator opts in from the
    /// settings deck, so the default rail is only the stable set.
    private var visibleCategories: [WorkspaceDockCategory] {
        WorkspaceDockCategory.allCases.filter { category in
            preferences.experimentalEnabled || !category.isExperimental
        }
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    /// Every effect whose name or one-line description contains the query.
    ///
    /// Experimental families stay hidden here too — search should not be a
    /// side door around a switch the operator deliberately left off.
    private var searchMatches: [WorkspaceAdjustableEffect] {
        let query = trimmedSearch
        guard !query.isEmpty else { return [] }
        let hidden: Set<WorkspaceAdjustableEffect> = preferences.experimentalEnabled
            ? []
            : Set(
                WorkspaceAdjustableEffect.experimentalCategoryEffects
                    + WorkspaceAdjustableEffect.decayCategoryEffects
                    + WorkspaceAdjustableEffect.fieldCategoryEffects
            )
        return WorkspaceAdjustableEffect.allCases.filter { effect in
            guard !hidden.contains(effect) else { return false }
            return effect.label.localizedCaseInsensitiveContains(query)
                || effect.detail.localizedCaseInsensitiveContains(query)
        }
    }

    private var searchField: some View {
        HStack(spacing: GVMetrics.gapTight) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: GVMetrics.textBody, weight: .black))
                .foregroundStyle(GVTheme.ash)
            TextField("FIND EFFECT", text: $searchText)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .gvMono(GVMetrics.textBody, .bold)
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
        // Charcoal plate — cohesive with dock, not a divergent surface
        .background(
            GVChamferedPlate()
                .fill(dockCharcoalElevated)
                .overlay(
                    GVChamferedPlate()
                        .stroke(Color.white.opacity(searchFocused ? 0.14 : 0.08), lineWidth: searchFocused ? 1.1 : GVMetrics.hairline)
                )
                .shadow(color: searchFocused ? .white.opacity(0.13) : .clear, radius: 6)
                .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
        )
        .padding(.horizontal, GVMetrics.screenInset)
    }

    private var searchRail: some View {
        GVAnimatedGlassPanel(cornerRadius: 14, tint: dockDeep, fillOpacity: 0.42) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if searchMatches.isEmpty {
                        emptyRailNotice("NO EFFECT MATCHES \(trimmedSearch.uppercased())")
                    } else {
                        effectCards(searchMatches)
                    }
                }
                .padding(4)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .gvHorizontalEdgeFade()
        }
        .accessibilityIdentifier("workspace.effects.search")
    }

    /// The live composition, one chip per contributing slot: power, reorder,
    /// remove, and tap-to-edit. Always visible while anything renders, so
    /// "what is on" has a permanent address instead of living only in the
    /// browser.
    @ViewBuilder
    private var activeStackStrip: some View {
        let slots = effectStack.orderedSlots
        let rgbOn = rgbSplitParameters.isEnabled
        if !slots.isEmpty || rgbOn {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Text("STACK")
                        .gvMono(GVMetrics.textMicro, .black)
                        .tracking(1.2)
                        .foregroundStyle(GVTheme.ash)
                    Text("\(slots.count + (rgbOn ? 1 : 0)) LIVE")
                        .gvMono(GVMetrics.textMicro, .black)
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(color: .white.opacity(0.35), radius: 3)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, GVMetrics.screenInset)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        if rgbOn {
                            stackChip(
                                title: "RGB",
                                isOn: true,
                                onPower: { rgbSplitParameters.isEnabled = false },
                                onMove: nil,
                                onRemove: { rgbSplitParameters.isEnabled = false }
                            ) {
                                selectedEffect = .rgbSplit
                            }
                        }
                        ForEach(slots) { slot in
                            let index = slots.firstIndex(where: { $0.id == slot.id }) ?? 0
                            stackChip(
                                title: slot.effect.label,
                                isOn: slot.parameters.isEnabled,
                                onPower: { effectStack.setEnabled(!slot.parameters.isEnabled, slot: slot.id) },
                                onMove: { delta in
                                    let target = min(max(index + delta, 0), slots.count)
                                    guard target != index else { return }
                                    effectStack.move(fromOffsets: IndexSet(integer: index), toOffset: target)
                                },
                                onDuplicate: { _ = effectStack.duplicate(slot.id) },
                                onRemove: { effectStack.remove(slot.id) }
                            ) {
                                selectedDepthEffect = nil
                                selectedEffect = slot.effect
                            }
                        }
                    }
                    .padding(.horizontal, GVMetrics.screenInset - 4)
                }
                .gvHorizontalEdgeFade()
            }
            .padding(.top, 2)
        }
    }

    private func stackChip(
        title: String,
        isOn: Bool,
        onPower: @escaping () -> Void,
        onMove: ((Int) -> Void)?,
        onDuplicate: (() -> Void)? = nil,
        onRemove: @escaping () -> Void,
        onSelect: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 4) {
            Button(action: onPower) {
                Image(systemName: isOn ? "power" : "power.dotted")
                    .font(.system(size: GVMetrics.textMicro + 2, weight: .bold))
                    .foregroundStyle(isOn ? Color.white : GVTheme.ash)
                    .shadow(color: isOn ? .white.opacity(0.55) : .clear, radius: 3)
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(GVPressStyle(scale: 0.9))
            .accessibilityLabel("\(title) power")

            Button(action: onSelect) {
                Text(title)
                    .gvMono(GVMetrics.textMicro, .black)
                    .tracking(0.7)
                    .foregroundStyle(isOn ? Color.white.opacity(0.92) : GVTheme.bone.opacity(0.55))
                    .lineLimit(1)
                    .frame(maxWidth: 96)
            }
            .buttonStyle(GVPressStyle())
            .accessibilityLabel("Edit \(title)")

            if let onMove {
                Button { onMove(-1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(GVTheme.bone.opacity(0.55))
                        .frame(width: 14, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(GVPressStyle(scale: 0.85))
                .accessibilityLabel("Move \(title) earlier")

                Button { onMove(1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(GVTheme.bone.opacity(0.55))
                        .frame(width: 14, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(GVPressStyle(scale: 0.85))
                .accessibilityLabel("Move \(title) later")
            }

            if let onDuplicate {
                Button(action: onDuplicate) {
                    Image(systemName: "plus.square.on.square")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(GVTheme.bone.opacity(0.55))
                        .frame(width: 16, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(GVPressStyle(scale: 0.85))
                .accessibilityLabel("Duplicate \(title)")
            }

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(GVTheme.record.opacity(0.8))
                    .frame(width: 16, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(GVPressStyle(scale: 0.85))
            .accessibilityLabel("Remove \(title)")
        }
        .padding(.horizontal, 5)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(white: 0.105))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isOn ? Color.white.opacity(0.22) : Color.white.opacity(0.08),
                            lineWidth: 1
                        )
                )
        )
    }

    /// Capture pair inside the dock. Record carries its state in the glyph
    /// and border together; photo is a plain instrument button.
    private var captureRow: some View {
        HStack(spacing: 7) {
            Spacer(minLength: 0)

            Button {
                onCapturePhoto()
            } label: {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(GVTheme.bone.opacity(0.9))
                    .frame(width: 34, height: 32)
                    .background(
                        GVChamferedPlate(cut: 6)
                            .fill(Color(white: 0.105).opacity(0.92))
                    )
                    .overlay(
                        GVChamferedPlate(cut: 6)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(GVPressStyle())
            .accessibilityLabel("Capture photo")
            .accessibilityIdentifier("workspace.capture.photo")

            let recording = cameraRuntime.isRecording
            Button {
                onToggleRecording()
            } label: {
                Image(systemName: recording ? "stop.fill" : "record.circle")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(recording ? GVTheme.record : GVTheme.bone.opacity(0.9))
                    .shadow(color: recording ? GVTheme.record.opacity(0.6) : .clear, radius: 4)
                    .frame(width: 34, height: 32)
                    .background(
                        GVChamferedPlate(cut: 6)
                            .fill(recording ? GVTheme.record.opacity(0.14) : Color(white: 0.105).opacity(0.92))
                    )
                    .overlay(
                        GVChamferedPlate(cut: 6)
                            .strokeBorder(
                                recording ? GVTheme.record.opacity(0.75) : Color.white.opacity(0.16),
                                lineWidth: 1
                            )
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(GVPressStyle())
            .animation(GVMotion.micro, value: cameraRuntime.isRecording)
            .accessibilityLabel(recording ? "Stop recording" : "Record video")
            .accessibilityIdentifier("workspace.record.toggle")
        }
        .padding(.horizontal, GVMetrics.screenInset)
    }

    private var categoryRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Favourites is the only shelf glyph left of the families —
                // presets and the active/recents shelves moved out to keep
                // this rail scannable.
                categoryButton(.favorites, populated: hasContent(.favorites))
                ForEach(visibleCategories.filter { $0 != .active && $0 != .favorites && $0 != .recents }) { category in
                    categoryButton(category, populated: hasContent(category))
                }
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .scrollTargetLayout()
        }
        .gvScrollProgressLine()
        .contentMargins(.horizontal, 2, for: .scrollContent)
        // Velocity-aware settle rather than paging, so a flick still travels.
        .scrollTargetBehavior(.viewAligned)
        // Clipped pills should read as "more over here", not layout overflow.
        .gvHorizontalEdgeFade()
        .accessibilityIdentifier("workspace.categories")
    }

    private func categoryButton(_ category: WorkspaceDockCategory, populated: Bool = true) -> some View {
        let selected = selectedCategory == category
        return Button {
            decay.fire(.effectActivated)
            // Leaving STACK armed makes every later effect tap additive, which
            // is indistinguishable from "effects stack by default". Changing
            // category always returns to exclusive selection.
            isStackArmed = false
            withAnimation(GVMotion.panel) {
                if selected {
                    selectedCategory = nil
                    selectedEffect = nil
                    selectedDepthEffect = nil
                    disableAllEffects()
                    appModel.deactivateDepthMode()
                } else {
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
        } label: {
            categoryLabel(category, selected: selected, populated: populated)
                .padding(.horizontal, selected ? 13 : 9)
                .frame(height: GVMetrics.controlHeight)
                .background {
                    if selected {
                        GVChamferedPlate()
                            .fill(Color.white.opacity(0.13))
                            .overlay { categoryBorder(selected: true) }
                            .overlay { GVPlateRegistration(color: .white.opacity(0.90)) }
                            .shadow(color: .black.opacity(0.55), radius: 8, y: 4)
                            .shadow(color: .white.opacity(0.45), radius: 10)
                            .shadow(color: .white.opacity(0.22), radius: 18)
                    } else {
                        GVChamferedPlate()
                            .fill(dockCharcoalElevated)
                            .overlay(
                                GVChamferedPlate()
                                    .stroke(Color.white.opacity(0.07), lineWidth: 0.9)
                            )
                            .shadow(color: .black.opacity(0.48), radius: 5, y: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        .accessibilityIdentifier("workspace.category.\(category.rawValue)")
        .accessibilityValue(selected ? "expanded" : "collapsed")
    }

    private func actionRail(for category: WorkspaceDockCategory) -> some View {
        GVAnimatedGlassPanel(cornerRadius: 14, tint: dockDeep, fillOpacity: 0.42) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    actionCards(for: category)
                }
                .padding(4)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .gvHorizontalEdgeFade()
            .gvScrollProgressLine()
            .id(category)
            // Cards travel in the direction the category moved rather than
            // being swapped out, so switching category reads as one motion.
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
        }
        .accessibilityIdentifier("workspace.effects.\(category.rawValue)")
    }

    @ViewBuilder
    // swiftlint:disable:next cyclomatic_complexity
    private func actionCards(for category: WorkspaceDockCategory) -> some View {
        switch category {
        case .active:
            if activeEffectList.isEmpty {
                emptyRailNotice("NOTHING RENDERING // POWER AN EFFECT ON")
            } else {
                effectCards(activeEffectList)
            }
        case .favorites:
            favoriteCards
        case .recents:
            recentCards
        case .datamosh:
            datamoshCards
        case .block:
            blockCards
        case .feedback:
            feedbackCards
        case .flow:
            flowCards
        case .glitch:
            glitchCards
        case .optics:
            opticsCards
        case .analog:
            analogCards
        case .geometry:
            geometryCards
        case .field:
            fieldCards
        case .sarin:
            sarinCards
        case .damage:
            damageCards
        case .decay:
            decayCards
        case .experimental:
            experimentalCards
        case .audio:
            audioCards
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
            "AR OBJECTS",
            objectsRuntime.capability.isSupported ? "PLACED 3D GEOMETRY" : objectsRuntime.capability.reason,
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
            "BLOB TRACK",
            "COLOR FIELD ANALYZER",
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
        effectCards(WorkspaceAdjustableEffect.audioCategoryEffects)
    }

    /// Every effect currently contributing pixels: RGB split plus each live
    /// stack slot, in the order the renderer applies them.
    private var activeEffectList: [WorkspaceAdjustableEffect] {
        var list: [WorkspaceAdjustableEffect] = []
        if rgbSplitParameters.isEnabled { list.append(.rgbSplit) }
        list.append(contentsOf: effectStack.activeEffects.map(\.0))
        return list
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
            emptyRailNotice("NO RECENT EFFECTS // PICK ONE AND IT LANDS HERE")
        } else {
            effectCards(recentEffects)
        }
    }

    @ViewBuilder
    private var favoriteCards: some View {
        if favoriteEffects.isEmpty {
            // An empty rail with no explanation reads as a broken category.
            emptyRailNotice("NO FAVOURITES // OPEN AN EFFECT AND TAP ☆ TO PIN IT HERE")
        } else {
            effectCards(favoriteEffects)
        }
    }

    private func emptyRailNotice(_ text: String) -> some View {
        GVTerminalText(
            text: text,
            size: GVMetrics.textMicro,
            weight: .bold,
            tracking: 0.8,
            baseColor: GVTheme.ash,
            intensity: 0.6
        )
        .frame(height: GVMetrics.cardHeight)
        .padding(.horizontal, 12)
    }

    private var sarinCards: some View {
        effectCards(WorkspaceAdjustableEffect.sarinCategoryEffects)
    }

    private var damageCards: some View {
        effectCards(WorkspaceAdjustableEffect.damageCategoryEffects)
    }

    private var datamoshCards: some View {
        effectCards(WorkspaceAdjustableEffect.datamoshCategoryEffects)
    }

    private var opticsCards: some View {
        effectCards(WorkspaceAdjustableEffect.opticsCategoryEffects)
    }

    private var analogCards: some View {
        effectCards(WorkspaceAdjustableEffect.analogCategoryEffects)
    }

    private var geometryCards: some View {
        effectCards(WorkspaceAdjustableEffect.geometryCategoryEffects)
    }

    private var fieldCards: some View {
        effectCards(WorkspaceAdjustableEffect.fieldCategoryEffects)
    }

    private var decayCards: some View {
        effectCards(WorkspaceAdjustableEffect.decayCategoryEffects)
    }

    private var blockCards: some View {
        effectCards(WorkspaceAdjustableEffect.blockCategoryEffects)
    }

    private var feedbackCards: some View {
        effectCards(WorkspaceAdjustableEffect.feedbackCategoryEffects)
    }

    private var flowCards: some View {
        effectCards(WorkspaceAdjustableEffect.flowCategoryEffects)
    }

    private var glitchCards: some View {
        effectCards(WorkspaceAdjustableEffect.glitchCategoryEffects)
    }

    @ViewBuilder private var experimentalCards: some View {
        effectCards(WorkspaceAdjustableEffect.experimentalCategoryEffects)
        let subjectDecay = DepthEffectMode.subjectDecay
        actionCard(
            WorkspaceAdjustableEffect.experimentalCategoryEffects.count + 1,
            subjectDecay.label,
            depthRuntime.capability.isSupported ? subjectDecay.detail : depthRuntime.capability.reason,
            active: appModel.sourceMode == .lidar && depthRuntime.effect == subjectDecay && depthRuntime.isActive,
            selected: selectedDepthEffect == subjectDecay,
            available: depthRuntime.capability.isSupported
        ) {
            selectDepth(subjectDecay)
        }
    }

    private func effectCards(_ effects: [WorkspaceAdjustableEffect]) -> some View {
        ForEach(Array(effects.enumerated()), id: \.element) { index, effect in
            effectCard(
                index + 1,
                effect,
                effect.detail,
                active: isEffectEnabled(effect)
            )
        }
    }

    private var lidarCards: some View {
        ForEach(Array(DepthEffectMode.allCases.filter { $0 != .subjectDecay }.enumerated()), id: \.element.id) { index, effect in
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
        active: Bool
    ) -> some View {
        actionCard(
            index,
            effect.label,
            detail,
            active: active,
            selected: selectedEffect == effect
        ) {
            select(effect)
        }
        // Marked, not tappable. The card is 112pt wide and its whole face is
        // the select target; a second control inside it would be a coin-flip
        // hit. Starring happens in the effect's own deck, where there is room
        // for a proper target, and shows up here.
        .overlay(alignment: .topTrailing) {
            if preferences.isFavorite(effect.rawValue) {
                Image(systemName: "star.fill")
                    .font(.system(size: GVMetrics.textMicro, weight: .black))
                    .foregroundStyle(.white)
                    .shadow(color: .white.opacity(0.6), radius: 2)
                    .padding(.top, 4)
                    .padding(.trailing, 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private func actionCard(
        _ index: Int,
        _ label: String,
        _ detail: String,
        active: Bool = false,
        selected: Bool = false,
        available: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 5) {
                    Text(String(format: "%02d", index))
                        .foregroundStyle((active || selected) ? Color.white : GVTheme.ash)
                        .shadow(color: (active || selected) ? .white.opacity(0.65) : .clear, radius: 3)
                    Text(label)
                        .foregroundStyle((active || selected) ? Color.white : GVTheme.bone)
                        .shadow(color: (active || selected) ? .white.opacity(0.45) : .clear, radius: 4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.58)
                    if !available {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: GVMetrics.textMicro, weight: .bold))
                            .foregroundStyle(GVTheme.record)
                    }
                }
                .gvMono(GVMetrics.textSmall, .black)
                .tracking(1.0)

                Text(detail)
                    .gvMono(GVMetrics.textMicro, .bold)
                    .tracking(0.58)
                    .foregroundStyle((active || selected) ? Color.white.opacity(0.88) : GVTheme.ash)
                    .shadow(color: (active || selected) ? .white.opacity(0.28) : .clear, radius: 3)
                    .lineLimit(1)

                statusDots(active: active, available: available)
            }
            .frame(width: 112, height: GVMetrics.cardHeight)
            .background(
                GVChamferedPlate(cut: 10)
                    .fill(active || selected ? Color.white.opacity(0.13) : dockCharcoalElevated)
                    .overlay(
                        GVChamferedPlate(cut: 10)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(active || selected ? 0.07 : 0), .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
            )
            .overlay(
                GVChamferedPlate(cut: 10)
                    .stroke(
                        selected ? Color.white.opacity(0.98) :
                            active ? Color.white.opacity(0.92) : Color.white.opacity(available ? 0.075 : 0.035),
                        lineWidth: selected ? 1.45 : active ? 1.35 : GVMetrics.hairline
                    )
            )
            .shadow(color: .black.opacity(0.70), radius: 4, y: 2)
            .shadow(color: .black.opacity(0.38), radius: 8, y: 4)
            .shadow(color: (active || selected) ? .white.opacity(selected ? 0.52 : 0.44) : .clear, radius: 11)
            .shadow(color: (active || selected) ? .white.opacity(selected ? 0.22 : 0.18) : .clear, radius: 20)
        }
        .buttonStyle(GVPressStyle())
        .accessibilityLabel(label)
        .accessibilityHint(detail)
        .accessibilityIdentifier("workspace.action.\(slug(label))")
        .accessibilityValue(active ? "active" : "inactive")
    }

    private func lockedCard(_ index: Int, _ label: String, _ reason: String) -> some View {
        actionCard(index, label, reason, available: false) {
            showUnavailable("\(label) // \(reason)")
        }
    }

    private func statusDots(active: Bool, available: Bool) -> some View {
        HStack(spacing: 3) {
            ForEach(0 ..< 4, id: \.self) { index in
                let isLit = index == 0 && active
                let primaryColor = active
                    ? Color.white
                    : available ? GVTheme.bone.opacity(0.55) : GVTheme.record
                let secondaryColor = active ? Color.white.opacity(0.32) : Color(white: 0.22)
                Circle()
                    .fill(index == 0 ? primaryColor : secondaryColor)
                    .shadow(color: isLit ? .white.opacity(0.95) : .clear, radius: 4)
                    .shadow(color: isLit ? .white.opacity(0.45) : .clear, radius: 7)
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
                .font(.system(size: 12, weight: .black))
                // Populated shelf reads lit; an empty one dims to a whisper so
                // "nothing here yet" is visible without opening it.
                .foregroundStyle(selected ? .white : (populated ? GVTheme.bone.opacity(0.85) : GVTheme.ash.opacity(0.38)))
                .shadow(color: selected ? .white.opacity(0.6) : (populated ? .white.opacity(0.18) : .clear), radius: 3)
                .shadow(color: .black.opacity(0.92), radius: 2, y: 1)
                // Matches the optical width of a short word so the star does
                // not read as a gap in the rail.
                .frame(width: 22)
                .accessibilityLabel("Favourites")
        } else if selected {
            GVTerminalText(
                text: category.label,
                size: GVMetrics.textSmall,
                weight: .black,
                tracking: 0.9,
                baseColor: .white,
                intensity: 1.5
            )
        } else {
            Text(category.label)
                .gvMono(GVMetrics.textSmall, .black)
                .tracking(0.9)
                // Quiet. The rail is a list of what is available, not five
                // things all claiming to be selected.
                .foregroundStyle(GVTheme.ash)
                .shadow(color: .black.opacity(0.92), radius: 3, y: 1)
        }
    }

    @ViewBuilder
    private func categoryBorder(selected: Bool) -> some View {
        if selected {
            TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30, paused: reduceMotion)) { timeline in
                let cycle = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.8) / 1.8
                let phase = reduceMotion ? 0.5 : cycle
                GVChamferedPlate()
                    .stroke(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.28),
                                .white,
                                .white,
                                .white.opacity(0.32)
                            ],
                            startPoint: UnitPoint(x: max(0, phase - 0.42), y: 0),
                            endPoint: UnitPoint(x: min(1, phase + 0.42), y: 1)
                        ),
                        lineWidth: 1.35
                    )
                    .shadow(color: .white.opacity(0.35), radius: 6)
            }
        } else {
            GVChamferedPlate()
                .stroke(.white.opacity(0.56), lineWidth: 0.8)
        }
    }

    private func select(_ effect: WorkspaceAdjustableEffect) {
        selectedDepthEffect = nil
        appModel.deactivateDepthMode()
        appModel.deactivateObjectMode()
        armAudioIfNeeded(for: effect)
        if selectedEffect == effect {
            setEnabled(effect, false)
            selectedEffect = nil
            return
        }
        
        if !isStackArmed {
            disableAllEffects()
        }

        // A tap IS the power switch. Exclusive mode replaces whatever was
        // rendering; ADD mode stacks this one on top of the living slots.
        setEnabled(effect, true)
        selectedEffect = effect
        // Recorded on activation only. An effect the operator turned off is
        // not one they were reaching for.
        preferences.noteEffectUsed(effect.rawValue)
    }

    private func selectDepth(_ effect: DepthEffectMode) {
        guard depthRuntime.capability.isSupported else {
            showUnavailable("\(effect.label) // \(depthRuntime.capability.reason)")
            return
        }
        selectedEffect = nil
        disableAllEffects()
        appModel.deactivateObjectMode()
        selectedDepthEffect = effect
        appModel.activateDepthEffect(effect)
    }

    private func activateOnly(_ effect: WorkspaceAdjustableEffect) {
        disableAllEffects()
        setEnabled(effect, true)
    }

    private func setStackArmed(_ armed: Bool) {
        isStackArmed = armed
        guard !armed else { return }
        guard let selectedEffect else {
            disableAllEffects()
            return
        }
        activateOnly(selectedEffect)
    }

    private func disableAllEffects() {
        rgbSplitParameters.isEnabled = false
        effectStack.disableAll()
    }

    private func setEnabled(_ effect: WorkspaceAdjustableEffect, _ enabled: Bool) {
        switch effect {
        case .rgbSplit:
            rgbSplitParameters.isEnabled = enabled
        default:
            effectStack.setEnabled(enabled, for: effect)
        }
    }

    private func isEffectEnabled(_ effect: WorkspaceAdjustableEffect) -> Bool {
        switch effect {
        case .rgbSplit:
            rgbSplitParameters.isEnabled
        default:
            effectStack[effect].isEnabled
        }
    }

    /// Audio-reactive effects are inert without the analyser, so selecting one
    /// requests the microphone rather than presenting a dead control.
    private func armAudioIfNeeded(for effect: WorkspaceAdjustableEffect) {
        guard effect.requiresAudioAnalysis, !audioRuntime.isEnabled else { return }
        switch audioRuntime.state {
        case .denied:
            showUnavailable("\(effect.label) // MICROPHONE DENIED")
        case .failed:
            showUnavailable("\(effect.label) // AUDIO ENGINE FAILED")
        default:
            Task { @MainActor in
                await audioRuntime.start()
                if audioRuntime.state == .denied {
                    showUnavailable("\(effect.label) // MICROPHONE DENIED")
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
    /// Everything rendering right now, in pipeline order. The answer to
    /// "what is actually on" without hunting across nineteen families.
    case active
    /// Was ALL — every effect in one undifferentiated list, which is the same
    /// thing the other categories already provide and got longer with every
    /// effect added. Now the operator's own shortlist.
    case favorites
    /// The last handful the operator reached for. Sits beside favourites
    /// because both answer "where was that one" — favourites for the effects
    /// they chose to keep, recents for the ones they are working with now.
    case recents
    case datamosh
    case block
    case feedback
    case flow
    case glitch
    case experimental
    case audio
    case optics
    case analog
    case geometry
    case field
    case sarin = "sarin.dev"
    case damage
    case decay
    case lidar
    case objects
    case blobs

    var id: String {
        rawValue
    }

    var label: String {
        labelOverride ?? rawValue.uppercased()
    }

    /// Favourites and recents are drawn as glyphs instead of words, so they
    /// read as shelves rather than as two more families among the others.
    var symbol: String? {
        switch self {
        case .active: "poweron"
        case .favorites: "star.fill"
        case .recents: "clock.arrow.circlepath"
        default: nil
        }
    }

    var labelOverride: String? {
        self == .active ? "ACTIVE" : nil
    }

    /// Families gated behind the EXPERIMENTAL switch. These are the ones that
    /// are unstable, expensive, or need hardware that may not be present.
    var isExperimental: Bool {
        switch self {
        // Objects and blobs are shipped features with their own hardware
        // gating, not experiments. Hiding them behind the EXPERIMENTAL switch
        // made AR unreachable on a default install.
        case .experimental, .decay, .field:
            true
        default:
            false
        }
    }
}

// swiftlint:enable file_length
