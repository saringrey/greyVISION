import SwiftUI

/// The recipes drawer: save, load, hold-to-preview, rename, duplicate,
/// delete, reorder, export and import.
///
/// Presented as a charcoal plate rising over the dock. Loading applies the
/// whole recipe atomically; holding a row previews it for as long as the
/// finger stays down and restores whatever was live before the hold.
struct GVPresetsDrawer: View {
    @EnvironmentObject private var store: GVPresetStore
    @Binding var setup: CaptureSetupDraft
    @ObservedObject var editor: EffectEditingSession
    /// Vertical budget handed down by the workspace. The plate sits in the
    /// same bottom group as the capture pair, so an ideal-height drawer would
    /// push its own header off the top of the screen.
    let maximumHeight: CGFloat
    let onClose: () -> Void

    @State private var newName = ""
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var importPresented = false
    @EnvironmentObject private var toasts: GVToastBox
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var previewSetup: CaptureSetupDraft?
    @State private var previewID: UUID?
    @State private var previewTask: Task<Void, Never>?
    @SwiftUI.GestureState private var isPreviewHeld = false
    /// Starred-only view of the collection. A filter rather than a separate
    /// list, so the row order the operator set by dragging stays intact.
    @State private var showsStarredOnly = false

    private var visiblePresets: [GVPreset] {
        showsStarredOnly ? store.presets.filter { store.starredIDs.contains($0.id) } : store.presets
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            saveRow
            list
            footerRow
        }
        .gvCompactDeckPlate()
        .padding(.horizontal, 6)
        .background(alignment: .top) { Color.clear }
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        .onDisappear { cancelPreview() }
        .onChange(of: isPreviewHeld) { _, held in
            if !held, previewTask == nil { cancelPreview() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelPreview() }
        }
        .onChange(of: importPresented) { _, presented in
            if presented { cancelPreview() }
        }
        .fileImporter(
            isPresented: $importPresented,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                let message = store.importPreset(from: url) ?? "IMPORT FAILED"
                toasts.show(message)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Text("Recipes · \(store.presets.count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(GVTheme.bone)
            Spacer(minLength: 6)
            GVDeckChip(
                label: "",
                symbol: showsStarredOnly ? "star.fill" : "star",
                active: showsStarredOnly,
                id: "preset.filter.starred"
            ) {
                withAnimation(GVMotion.resolved(GVMotion.deck, reduceMotion: reduceMotion)) {
                    showsStarredOnly.toggle()
                }
            }
            .accessibilityLabel(showsStarredOnly ? "Show all recipes" : "Show starred recipes")
            GVDeckChip(label: "", symbol: "square.and.arrow.down", id: "preset.import") {
                importPresented = true
            }
            GVDeckChip(label: "", symbol: "xmark", id: "preset.close") {
                cancelPreview()
                onClose()
            }
        }
    }

    private var saveRow: some View {
        HStack(spacing: 6) {
            TextField("Name this look", text: $newName)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(GVTheme.bone)
                .padding(.horizontal, 9)
                .frame(height: 30)
                .gvGlassField(radius: 6)
            GVDeckChip(label: "Save", symbol: "tray.and.arrow.down", active: true, tint: .white, id: "preset.save") {
                cancelPreview()
                store.save(
                    name: newName,
                    from: setup,
                    rgb: editor.rgbSplitParameters,
                    stack: editor.effectStack
                )
                toasts.show("Preset saved · \(newName.isEmpty ? "Untitled" : newName)")
                newName = ""
            }
        }
    }

    private var list: some View {
        GVDeckList(maxHeight: max(84, maximumHeight - 145)) {
            VStack(spacing: 5) {
                if let error = store.storageError {
                    Text(error)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(GVTheme.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .gvGlassChip(radius: 8, active: false, tint: GVTheme.warn)
                        .accessibilityIdentifier("preset.storage-error")
                }
                if visiblePresets.isEmpty {
                    Text(showsStarredOnly ? "Nothing starred yet · tap the star to keep a look here" : "No recipes saved")
                        .font(.system(size: 11))
                        .foregroundStyle(GVTheme.ash)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                }
                ForEach(visiblePresets) { preset in
                    if renamingID == preset.id {
                        renameRow(preset)
                    } else {
                        recipeRow(preset)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.05),
                    .init(color: .black, location: 0.95),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func recipeRow(_ preset: GVPreset) -> some View {
        HStack(spacing: 7) {
            // STAR TO COLLECTION — the mark itself is the control, so the row
            // does not need a fifth 44pt button to hold the looks worth keeping.
            Button {
                store.toggleStar(preset.id)
            } label: {
                Image(systemName: store.starredIDs.contains(preset.id) ? "star.fill" : "star")
                    .font(.system(size: GVMetrics.textSmall, weight: .bold))
                    .foregroundStyle(store.starredIDs.contains(preset.id) ? GVTheme.acid : GVTheme.bone.opacity(0.55))
                    .frame(width: 24, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(GVPressStyle())
            .accessibilityLabel(store.starredIDs.contains(preset.id) ? "Unstar \(preset.name)" : "Star \(preset.name)")
            .accessibilityIdentifier("preset.star.\(preset.id)")

            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Text("\(preset.summary) · \(preset.codecShort) · \(preset.frameRate)fps · \(preset.resolutionRaw)")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(GVTheme.ash)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 4)

            if preset.isFactory {
                Text("Factory")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(GVTheme.ash)
            }

            // HOLD TO PREVIEW — reapplies on release. The whole point of a
            // recipe browser is trying looks without committing.
            Image(systemName: previewID == preset.id ? "eye.fill" : "eye")
                .font(.system(size: GVMetrics.textSmall, weight: .bold))
                .foregroundStyle(GVTheme.bone.opacity(0.75))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .gesture(holdToPreview(preset))
                .accessibilityLabel("Hold to preview \(preset.name)")
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(previewID == preset.id ? "Previewing" : "")
                .accessibilityAction {
                    if previewID == preset.id {
                        cancelPreview()
                    } else {
                        startPreview(preset)
                        previewTask = Task { @MainActor in
                            try? await Task.sleep(for: .seconds(3))
                            guard !Task.isCancelled else { return }
                            cancelPreview()
                        }
                    }
                }
                .accessibilityAction(named: "End preview") { cancelPreview() }

            GVDeckChip(label: "", symbol: "arrow.down.to.line", id: "load.\(preset.id)") {
                cancelPreview()
                editor.apply(preset, using: store, setup: &setup)
                toasts.show("Loaded \(preset.name)")
            }
            .accessibilityLabel("Load \(preset.name)")

            Menu {
                Button("Rename") { renamingID = preset.id; renameText = preset.name }
                Button("Duplicate") { store.duplicate(preset.id) }
                Button("Export…") {
                    if let url = store.exportURL(preset) {
                        shareURL = url
                    } else {
                        shareURL = nil
                        toasts.show("EXPORT FAILED")
                    }
                }
                Button("Delete", role: .destructive) {
                    cancelPreview()
                    store.delete(preset.id)
                    toasts.show("Deleted \(preset.name)")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: GVMetrics.textSmall, weight: .black))
                    .foregroundStyle(GVTheme.bone.opacity(0.7))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Actions for \(preset.name)")
        }
        .padding(.horizontal, 9)
        .frame(height: 44)
        .gvGlassChip(radius: 8, active: false, tint: .white)
    }

    private func renameRow(_ preset: GVPreset) -> some View {
        HStack(spacing: 6) {
            TextField("Name", text: $renameText)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .gvGlassField(radius: 6)
            GVDeckChip(label: "Done", active: true, id: "rename.ok.\(preset.id)") {
                store.rename(preset.id, to: renameText)
                renamingID = nil
            }
            GVDeckChip(label: "Cancel", id: "rename.esc.\(preset.id)") {
                renamingID = nil
            }
        }
    }

    private var footerRow: some View {
        HStack(spacing: 6) {
            Text("Hold the eye icon to preview · Tap the arrow to load")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(GVTheme.ash.opacity(0.75))
            Spacer(minLength: 0)
            if let shareURL {
                ShareLink(item: shareURL) {
                    Text("Share ready")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(GVTheme.acid.opacity(0.9))
                }
            }
        }
    }

    @State private var shareURL: URL?

    private func holdToPreview(_ preset: GVPreset) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isPreviewHeld) { _, held, _ in held = true }
            .onChanged { _ in
                guard previewID != preset.id else { return }
                startPreview(preset)
            }
            .onEnded { _ in cancelPreview() }
    }

    private func startPreview(_ preset: GVPreset) {
        previewTask?.cancel()
        if previewSetup == nil { previewSetup = setup }
        var previewCapture = setup
        var rgb = editor.rgbSplitParameters
        var stack = editor.effectStack
        store.apply(preset, to: &previewCapture, rgb: &rgb, stack: &stack)
        editor.beginPreview(CompositionSnapshot(stack: stack, rgb: rgb))
        setup = previewCapture
        previewID = preset.id
    }

    private func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
        if let original = previewSetup { setup = original }
        editor.endPreview()
        previewSetup = nil
        previewID = nil
    }
}

private extension GVPreset {
    var codecShort: String {
        CaptureSetupDraft.VideoCodec(rawValue: codecRaw)?.compactLabel ?? codecRaw
    }
}
