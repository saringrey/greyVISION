// swiftlint:disable file_length
import SwiftUI

/// The bottom chrome: the parameter decks, the category rail, and the rail's
/// three capture-mode cards.
///
/// Effects are not browsed from here any more. The rail used to open a
/// horizontal strip of 128-point cards that showed three effects at a time and
/// hid the rest behind a scroll with no affordance; it now opens the effect
/// browser, which lists every category down one side and every effect as a
/// thumbnail in a grid. What stays here is what belongs to the dock: the
/// parameter deck for whatever is selected, and the AR, blob-tracking and
/// LiDAR cards, which are capture modes rather than effects.
/// The three collection surfaces the rail opens: the operator's own material,
/// as opposed to the effect shelves, which are the instrument's.
enum GVCollectionPlate: String, CaseIterable, Identifiable, Hashable {
    case recipes
    case takes
    case timeline

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .recipes: "bookmark"
        case .takes: "film"
        case .timeline: "clock.arrow.2.circlepath"
        }
    }

    var label: String {
        switch self {
        case .recipes: "Recipes"
        case .takes: "Takes"
        case .timeline: "Timeline"
        }
    }

    var identifier: String { "workspace.\(rawValue)" }
}

struct WorkspaceDockView: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var cameraRuntime: CameraRuntime
    @EnvironmentObject private var depthRuntime: DepthRuntime
    @EnvironmentObject private var objectsRuntime: ARObjectRuntime
    @EnvironmentObject private var blobRuntime: BlobTrackingRuntime
    @EnvironmentObject private var preferences: GVPreferences
    @EnvironmentObject private var decay: GVDecayEngine
    @EnvironmentObject private var toasts: GVToastBox

    @ObservedObject var editor: EffectEditingSession
    @ObservedObject var recording: GVRecordingTransaction
    @Binding var dismissSelectionSignal: Int
    /// The three collection surfaces. They are the operator's own material —
    /// saved looks, recorded takes, armed timelines — so they belong on the rail
    /// that opens collections, not two levels up in the settings deck where
    /// nothing in them can be auditioned against the live frame.
    let onOpenRecipes: () -> Void
    let onOpenTakes: () -> Void
    let onOpenTimeline: () -> Void
    /// Which collection plate is currently up, so its chip reads as open.
    let activeCollection: GVCollectionPlate?
    /// A collection plate takes the parameter browser's room, so the browser
    /// stands down while one is up — but the rail stays put, because it is what
    /// closes the plate again.
    let hidesBrowser: Bool
    /// Read only so the parameter decks can plate themselves against a bright
    /// frame. The rails stay unplated — they are short labels with a scrim
    /// under them; the decks carry numbers.
    let statsMailbox: CameraRenderStatsMailbox
    /// Prevents the dock from claiming more height than a short landscape
    /// viewport can spare. The category rail remains pinned below the scrollable
    /// controls, so an expanded deck never makes navigation unreachable.
    var maximumHeight: CGFloat?

    /// Only ever a capture mode. Effect categories live in the browser, and
    /// `browserCategory` is what is actually presented.
    @State private var selectedCategory: WorkspaceDockCategory?
    @State private var selectedDepthEffect: DepthEffectMode?
    @State private var browserCategory: WorkspaceDockCategory?
    /// Natural height of the browser's content, measured so the scroll view
    /// can size to it instead of filling the cap. See `dockControls`.
    @State private var contentHeight: CGFloat = 0
    @Namespace private var glassNamespace

    init(
        editor: EffectEditingSession,
        recording: GVRecordingTransaction,
        dismissSelectionSignal: Binding<Int>,
        statsMailbox: CameraRenderStatsMailbox,
        onOpenRecipes: @escaping () -> Void,
        onOpenTakes: @escaping () -> Void,
        onOpenTimeline: @escaping () -> Void,
        activeCollection: GVCollectionPlate?,
        hidesBrowser: Bool,
        maximumHeight: CGFloat? = nil
    ) {
        self.editor = editor
        self.recording = recording
        self._dismissSelectionSignal = dismissSelectionSignal
        self.statsMailbox = statsMailbox
        self.onOpenRecipes = onOpenRecipes
        self.onOpenTakes = onOpenTakes
        self.onOpenTimeline = onOpenTimeline
        self.activeCollection = activeCollection
        self.hidesBrowser = hidesBrowser
        self.maximumHeight = maximumHeight
        // Debug affordance in the same family as `--uitesting-workspace`:
        // opens the browser on launch so a device screenshot can see the grid
        // and the thumbnails without a finger on the glass. Seeded here rather
        // than in `onAppear` because the dock is mounted inside a collapsible
        // frame, and a hook that depends on appearance is a hook that can miss.
        _browserCategory = State(
            initialValue: ProcessInfo.processInfo.arguments.contains("--open-effect-browser") ? .all : nil
        )
    }

    // MARK: - Charcoal / Black palette

    private var dockCharcoalElevated: Color { Color(red: 0.175, green: 0.175, blue: 0.183) }
    private var dockDeep: Color { Color(red: 0.078, green: 0.078, blue: 0.085) }

    private var selectedEffect: WorkspaceAdjustableEffect? {
        get { editor.selectedEffect }
        nonmutating set { editor.focus(newValue) }
    }

    var body: some View {
        VStack(spacing: 5) {
            // One lit rule terminating the bottom chrome, matching the top.
            GVEdgeRule()
                .padding(.horizontal, 14)
                .padding(.bottom, 1)

            if !hidesBrowser {
                dockControls
            }

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
        .fullScreenCover(item: $browserCategory) { category in
            GVEffectBrowser(editor: editor, initialCategory: category)
        }
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
            } else if let selectedCategory {
                modeRail(for: selectedCategory)
                    .transition(deckTransition)
            }
        }
        .animation(GVMotion.resolved(GVMotion.panel, reduceMotion: reduceMotion), value: selectedCategory)
        .animation(GVMotion.resolved(GVMotion.panel, reduceMotion: reduceMotion), value: selectedEffect != nil)
        .animation(GVMotion.resolved(GVMotion.panel, reduceMotion: reduceMotion), value: selectedDepthEffect != nil)
    }

    private var deckTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    // MARK: - Category rail

    private var categoryRail: some View {
        VStack(spacing: 3) {
            collectionRow
            HStack(spacing: 4) {
                Button { openBrowser(.all) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2")
                        Text("Effects").font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(GVTheme.bone)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(dockDeep, in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel("Browse effects")
                .accessibilityIdentifier("workspace.categories.all")
                categoryScrollRail
            }
        }
    }

    /// Recipes, Takes and Timeline, one third of the width each. They get their
    /// own row rather than a place at the end of the category rail: three fixed
    /// chips beside a scrolling rail left the category pills clipped before the
    /// operator had touched anything, and inside the rail the last chip sat
    /// beyond the edge where it cannot be tapped.
    private var collectionRow: some View {
        HStack(spacing: 3) {
            ForEach(GVCollectionPlate.allCases) { plate in
                collectionChip(plate)
            }
        }
    }

    private func collectionChip(_ plate: GVCollectionPlate) -> some View {
        let active = activeCollection == plate
        return Button {
            switch plate {
            case .recipes: onOpenRecipes()
            case .takes: onOpenTakes()
            case .timeline: onOpenTimeline()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: plate.symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(plate.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? GVTheme.bone : GVTheme.bone.opacity(0.7))
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(dockDeep)
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                GVTheme.bone.opacity(active ? 0.4 : 0.1),
                                lineWidth: GVMetrics.hairline
                            )
                    }
            )
        }
        .buttonStyle(GVPressStyle())
        .frame(minHeight: GVMetrics.touchTarget)
        .contentShape(Rectangle())
        .accessibilityIdentifier(plate.identifier)
        .accessibilityValue(active ? "open" : "collapsed")
    }

    private var categoryScrollRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                categoryButton(.active, populated: hasContent(.active))
                categoryButton(.favorites, populated: hasContent(.favorites))
                categoryButton(.recents, populated: hasContent(.recents))
                Menu {
                    ForEach([WorkspaceDockCategory.objects, .blobs, .lidar]) { mode in
                        Button(mode.displayLabel) { selectCategory(mode) }
                            .accessibilityIdentifier("workspace.category.\(mode.rawValue)")
                    }
                } label: {
                    Image(systemName: "camera.aperture")
                        .font(.body)
                        .foregroundStyle(GVTheme.bone.opacity(0.8))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Capture modes")
                .accessibilityIdentifier("workspace.capture.modes")
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .scrollTargetLayout()
            .gvLiquidGlassContainer(spacing: 6)
        }
        .contentMargins(.horizontal, 2, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        // Clipped pills should read as "more over here", not layout overflow.
        .gvHorizontalEdgeFade()
        .background(dockDeep.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("workspace.categories")
    }

    private struct GVGlassChipButtonStyle: ButtonStyle {
        let active: Bool
        let tint: Color

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(tint.opacity(active || configuration.isPressed ? 0.10 : 0.025))
                )
                .frame(height: GVMetrics.controlHeight)
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.98 : 1))
                .brightness(configuration.isPressed ? 0.025 : 0)
                .animation(GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion), value: configuration.isPressed)
        }
    }

    private func categoryButton(_ category: WorkspaceDockCategory, populated: Bool = true) -> some View {
        // An effect shelf reads as open while the browser is up on it; a
        // capture mode reads as open while its card is showing.
        let selected = category == browserCategory || category == selectedCategory
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
        .accessibilityHint(category.isShelf ? "Opens the effect browser" : "Opens the " + category.displayLabel + " controls")
    }

    /// Effect shelves open the browser; the three capture modes stay in the
    /// dock, because their controls are decks rather than a list of effects.
    private func selectCategory(_ category: WorkspaceDockCategory) {
        decay.fire(.effectActivated)
        switch category {
        case .objects, .blobs, .lidar:
            browserCategory = nil
            let selected = selectedCategory == category
            withAnimation(GVMotion.resolved(GVMotion.panel, reduceMotion: reduceMotion)) {
                selectedEffect = nil
                selectedDepthEffect = nil
                selectedCategory = selected ? nil : category
                if category != .lidar {
                    selectedDepthEffect = nil
                }
                if category != .objects, appModel.sourceMode == .objects {
                    appModel.deactivateObjectMode()
                }
            }
        default:
            openBrowser(category)
        }
    }

    private func openBrowser(_ category: WorkspaceDockCategory) {
        decay.fire(.effectActivated)
        // Leaving a capture mode open behind the browser would restore its
        // deck the moment the browser closed.
        selectedCategory = nil
        selectedDepthEffect = nil
        selectedEffect = nil
        browserCategory = category
    }

    // MARK: - Capture-mode cards

    private func modeRail(for category: WorkspaceDockCategory) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 6) {
                switch category {
                case .objects:
                    objectsCard
                case .blobs:
                    blobCard
                case .lidar:
                    lidarCards
                default:
                    EmptyView()
                }
            }
            .padding(4)
            .scrollTargetLayout()
            .gvLiquidGlassContainer(spacing: 6)
        }
        .scrollTargetBehavior(.viewAligned)
        .gvHorizontalEdgeFade()
        .gvScrollProgressLine()
        .gvGlassRail(radius: 14, tint: dockDeep.opacity(0.38))
        .transition(.opacity)
        .accessibilityIdentifier("workspace.effects.\(category.rawValue)")
    }

    private var objectsCard: some View {
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

    private var blobCard: some View {
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

    private func actionCard(
        _: Int,
        _ label: String,
        _ detail: String,
        active: Bool = false,
        selected: Bool = false,
        available: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        let motionReduced = reduceMotion
        let isLit = active || selected
        return Button {
            action()
        } label: {
            VStack(spacing: 3) {
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
                    }
                }
                Text(detail.capitalized)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(isLit ? Color.white.opacity(0.68) : GVTheme.ash.opacity(0.85))
                    .lineLimit(1)
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
        .accessibilityValue(accessibilityState(active: active))
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

    private func selectDepth(_ effect: DepthEffectMode) {
        guard depthRuntime.capability.isSupported else {
            showUnavailable("\(effect.label): \(depthRuntime.capability.reason)")
            return
        }
        selectedEffect = nil
        editor.disableAll()
        appModel.deactivateObjectMode()
        selectedDepthEffect = effect
        appModel.activateDepthEffect(effect)
    }

    private func showUnavailable(_ message: String) {
        toasts.show(message)
    }

    /// Starred effects, in canonical order rather than the order they were
    /// starred, so the rail's dimming stays where the operator last saw it.
    private func hasContent(_ category: WorkspaceDockCategory) -> Bool {
        switch category {
        case .favorites: WorkspaceAdjustableEffect.allCases.contains { preferences.isFavorite($0.rawValue) }
        case .recents: !preferences.recentEffects.isEmpty
        case .active: !editor.activeEffects.isEmpty
        default: true
        }
    }

    @ViewBuilder
    private func categoryLabel(_ category: WorkspaceDockCategory, selected: Bool, populated: Bool = true) -> some View {
        if let symbol = category.symbol, category == .favorites || category == .recents || category == .active {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                // Populated shelf reads lit; an empty one dims to a whisper so
                // "nothing here yet" is visible without opening it.
                .foregroundStyle(selected ? GVTheme.bone : (populated ? GVTheme.bone.opacity(0.8) : GVTheme.bone.opacity(0.52)))
                // Matches the optical width of a short word so the star does
                // not read as a gap in the rail.
                .frame(width: 22)
                .accessibilityLabel(category.displayLabel)
        } else {
            HStack(spacing: 4) {
                if let symbol = category.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(category.displayLabel)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            // Quiet. The rail is a list of what is available, not five
            // things all claiming to be selected.
            .foregroundStyle(selected ? GVTheme.bone : GVTheme.ash)
        }
    }

    /// The spoken form of what the card face encodes in dots and glyphs.
    private func accessibilityState(active: Bool) -> String {
        active ? "active" : "inactive"
    }

    private func slug(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: " ", with: "-")
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
