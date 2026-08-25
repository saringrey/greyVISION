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
    @Binding var rgbSplitParameters: RGBSplitEffectParameters
    @Binding var effectStack: CameraEffectStackParameters
    let onClose: () -> Void

    @State private var newName = ""
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var importPresented = false
    @EnvironmentObject private var toasts: GVToastBox

    // Hold-to-preview stash.
    @State private var previewStash: (CaptureSetupDraft, RGBSplitEffectParameters, CameraEffectStackParameters)?

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
        .transition(.move(edge: .bottom).combined(with: .opacity))
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
            GVTerminalText(
                text: "RECIPES // \(store.presets.count)",
                size: GVMetrics.textSmall,
                weight: .black,
                tracking: 1.2,
                alignment: .leading,
                intensity: 1.1
            )
            Spacer(minLength: 6)
            GVDeckChip(label: "", symbol: "square.and.arrow.down", id: "preset.import") {
                importPresented = true
            }
            GVDeckChip(label: "", symbol: "xmark", id: "preset.close") {
                onClose()
            }
        }
    }

    private var saveRow: some View {
        HStack(spacing: 6) {
            TextField("NAME THIS LOOK", text: $newName)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .gvMono(GVMetrics.textSmall, .bold)
                .tracking(0.8)
                .foregroundStyle(GVTheme.bone)
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(white: 0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
            GVDeckChip(label: "SAVE", symbol: "tray.and.arrow.down", active: true, tint: .white, id: "preset.save") {
                store.save(name: newName, from: setup, rgb: rgbSplitParameters, stack: effectStack)
                toasts.show("RECIPE SAVED // \(newName.isEmpty ? "UNTITLED" : newName.uppercased())")
                newName = ""
            }
        }
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 5) {
                ForEach(store.presets) { preset in
                    if renamingID == preset.id {
                        renameRow(preset)
                    } else {
                        recipeRow(preset)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 236)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .gvMono(GVMetrics.textSmall, .black)
                    .tracking(1.0)
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Text("\(preset.summary)   \(preset.codecShort) \u{00B7} \(preset.frameRate)FPS \u{00B7} \(preset.resolutionRaw)")
                    .gvMono(GVMetrics.textMicro, .bold)
                    .tracking(0.5)
                    .foregroundStyle(GVTheme.ash)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 4)

            if preset.isFactory {
                Text("FACTORY")
                    .gvMono(6.5, .bold)
                    .tracking(0.8)
                    .foregroundStyle(GVTheme.acid.opacity(0.8))
            }

            // HOLD TO PREVIEW — reapplies on release. The whole point of a
            // recipe browser is trying looks without committing.
            Image(systemName: "eye")
                .font(.system(size: GVMetrics.textSmall, weight: .bold))
                .foregroundStyle(GVTheme.bone.opacity(0.75))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .gesture(holdToPreview(preset))
                .accessibilityLabel("Hold to preview \(preset.name)")

            GVDeckChip(label: "", symbol: "arrow.down.to.line", id: "load.\(preset.id)") {
                store.apply(preset, to: &setup, rgb: &rgbSplitParameters, stack: &effectStack)
                toasts.show("LOADED // \(preset.name)")
            }
            .accessibilityLabel("Load \(preset.name)")

            Menu {
                Button("RENAME") { renamingID = preset.id; renameText = preset.name }
                Button("DUPLICATE") { store.duplicate(preset.id) }
                Button("EXPORT…") {
                    if let url = store.exportURL(preset) {
                        shareURL = url
                    }
                }
                Button("DELETE", role: .destructive) {
                    store.delete(preset.id)
                    toasts.show("DELETED // \(preset.name)")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: GVMetrics.textSmall, weight: .black))
                    .foregroundStyle(GVTheme.bone.opacity(0.7))
                    .frame(width: 26, height: 30)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(white: 0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
        )
    }

    private func renameRow(_ preset: GVPreset) -> some View {
        HStack(spacing: 6) {
            TextField("NAME", text: $renameText)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.characters)
                .gvMono(GVMetrics.textSmall, .bold)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.08)))
            GVDeckChip(label: "OK", active: true, id: "rename.ok.\(preset.id)") {
                store.rename(preset.id, to: renameText)
                renamingID = nil
            }
            GVDeckChip(label: "ESC", id: "rename.esc.\(preset.id)") {
                renamingID = nil
            }
        }
    }

    private var footerRow: some View {
        HStack(spacing: 6) {
            Text("HOLD EYE TO PREVIEW \u{00B7} TAP ARROW TO LOAD")
                .gvMono(GVMetrics.textMicro, .bold)
                .tracking(0.8)
                .foregroundStyle(GVTheme.ash.opacity(0.7))
            Spacer(minLength: 0)
            if let shareURL {
                ShareLink(item: shareURL) {
                    Text("SHARE READY")
                        .gvMono(GVMetrics.textMicro, .bold)
                        .tracking(0.8)
                        .foregroundStyle(GVTheme.acid.opacity(0.9))
                }
            }
        }
    }

    @State private var shareURL: URL?

    private func holdToPreview(_ preset: GVPreset) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard previewStash == nil else { return }
                previewStash = (setup, rgbSplitParameters, effectStack)
                store.apply(preset, to: &setup, rgb: &rgbSplitParameters, stack: &effectStack)
            }
            .onEnded { _ in
                guard let stash = previewStash else { return }
                setup = stash.0
                rgbSplitParameters = stash.1
                effectStack = stash.2
                previewStash = nil
            }
    }
}

private extension GVPreset {
    var codecShort: String {
        CaptureSetupDraft.VideoCodec(rawValue: codecRaw)?.compactLabel ?? codecRaw
    }
}
