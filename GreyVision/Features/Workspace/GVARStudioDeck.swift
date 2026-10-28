import SwiftUI
import UniformTypeIdentifiers

/// The AR studio: everything the AR runtime can do, on the shared compact
/// deck plate. Spawn shapes, import your own 3D models, set the look and the
/// motion, apply presets, and let objects hide behind real things (LAYERS).
struct GVARStudioDeck: View {
    @ObservedObject var runtime: ARObjectRuntime
    let onRecordToggle: () -> Void
    let onExit: () -> Void
    let onClose: () -> Void

    @EnvironmentObject private var toasts: GVToastBox
    @State private var page = Page.spawn
    @State private var importing = false
    @State private var renaming: ARUserModel?
    @State private var newName = ""

    enum Page: String, CaseIterable, Identifiable {
        case spawn = "Spawn", models = "Models", look = "Look", motion = "Motion", presets = "Presets"
        var id: String { rawValue }
    }

    private static let modelTypes: [UTType] = ARUserModelStore.supportedExtensions
        .compactMap { UTType(filenameExtension: $0) } + [.usdz, .threeDContent]

    var body: some View {
        VStack(spacing: 6) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Page.allCases) { item in
                        GVDeckChip(label: item.rawValue, active: page == item, tint: .white,
                                   id: "ar.page.\(item.rawValue.lowercased())") { page = item }
                    }
                }
            }
            Group {
                switch page {
                case .spawn: spawnPage
                case .models: modelsPage
                case .look: lookPage
                case .motion: motionPage
                case .presets: presetsPage
                }
            }
            .frame(minHeight: 52)
        }
        .gvCompactDeckPlate()
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.modelTypes) { result in
            do {
                let model = try runtime.importUserModel(from: result.get())
                runtime.selectUserModel(model)
                toasts.show("\(model.name) imported")
            } catch {
                toasts.show(error.localizedDescription)
            }
        }
        .alert("Rename model", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    runtime.renameUserModel(renaming.id, to: newName)
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.parameters.ar")
    }

    private var header: some View {
        HStack(spacing: 5) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AR STUDIO")
                    .font(GVTheme.mono(13, .semibold))
                    .foregroundStyle(GVTheme.bone)
                    .lineLimit(1)
                    .fixedSize()
                Text("\(runtime.objects.count) OBJ · \(runtime.snapshot.formatLabel)")
                    .font(GVTheme.mono(9, .medium))
                    .foregroundStyle(runtime.snapshot.formatLabel == "TRACKING NORMAL" ? Color.mint : GVTheme.ash)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityIdentifier("workspace.ar.tracking")
            }
            Spacer(minLength: 4)
            GVDeckChip(label: "Layers", symbol: "square.3.layers.3d", active: runtime.occlusionEnabled,
                       tint: .white, id: "ar.occlusion") {
                runtime.occlusionEnabled.toggle()
                toasts.show(runtime.occlusionEnabled
                    ? "Objects hide behind real things · \(ARObjectRuntime.occlusionSupport)"
                    : "Objects always in front")
            }
            GVDeckChip(label: runtime.isRecording ? "Stop" : "Rec", active: runtime.isRecording,
                       tint: GVTheme.record, id: "ar.record", action: onRecordToggle)
            GVDeckChip(label: "", symbol: "trash", accessibilityLabel: "Clear all objects", id: "ar.clear") {
                runtime.clearObjects()
                toasts.show("AR objects cleared")
            }
            GVDeckChip(label: "", symbol: "camera.aperture", accessibilityLabel: "Return to camera", id: "ar.exit") {
                onExit()
                onClose()
            }
            GVDeckChip(label: "", symbol: "xmark", id: "ar.close", action: onClose)
        }
    }

    // MARK: Pages

    private var spawnPage: some View {
        VStack(alignment: .leading, spacing: 6) {
            chips {
                GVDeckChip(label: "Cycle", symbol: "arrow.triangle.2.circlepath",
                           active: runtime.spawnSource == .cycle, tint: .white, id: "ar.spawn.cycle") {
                    runtime.spawnSource = .cycle
                }
                GVDeckChip(label: "Random", symbol: "dice", active: runtime.spawnSource == .random,
                           tint: .white, id: "ar.spawn.random") {
                    runtime.spawnSource = .random
                }
                ForEach(ARObjectShape.allCases) { shape in
                    GVDeckChip(label: shape.label.capitalized, active: runtime.spawnSource == .shape(shape),
                               tint: .white, id: "ar.shape.\(shape.rawValue)") {
                        runtime.selectSpawnShape(shape)
                    }
                }
            }
            HStack(spacing: 4) {
                Text(runtime.selectedObjectID == nil ? "TAP TO PLACE · PINCH · TWIST · HOLD TO DELETE" : "OBJECT SELECTED")
                    .font(GVTheme.mono(8.5, .medium))
                    .foregroundStyle(GVTheme.ash)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                if runtime.selectedObjectID != nil {
                    GVDeckChip(label: "Copy", symbol: "plus.square.on.square", id: "ar.duplicate") {
                        runtime.duplicateSelectedObject()
                    }
                    GVDeckChip(label: "Delete", symbol: "trash", tint: GVTheme.record, id: "ar.delete") {
                        runtime.removeSelectedObject()
                    }
                }
            }
        }
    }

    private var modelsPage: some View {
        VStack(alignment: .leading, spacing: 6) {
            modelChips
            Text(runtime.userModels.isEmpty
                 ? "IMPORT FROM FILES · OR SHARE A USDZ/OBJ/STL TO GREYVISION"
                 : "\(runtime.userModels.count) MODELS · TAP TO SPAWN · HOLD TO RENAME OR DELETE")
                .font(GVTheme.mono(8.5, .medium))
                .foregroundStyle(GVTheme.ash)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var modelChips: some View {
        chips {
            GVDeckChip(label: "Import", symbol: "square.and.arrow.down", active: true, tint: .white, id: "ar.import") {
                importing = true
            }
            GVDeckChip(label: "Sample", symbol: "cube.transparent", tint: .white, id: "ar.sample") {
                if let model = try? runtime.createSampleUserModel() { runtime.selectUserModel(model) }
            }
            ForEach(runtime.userModels) { model in
                GVDeckChip(label: model.name, active: runtime.spawnSource == .userModel(model.id),
                           tint: .white, id: "ar.model.\(model.id.uuidString)") {
                    runtime.selectUserModel(model)
                }
                .contextMenu {
                    Text("\(model.fileExtension.uppercased()) · \(model.vertexCount.formatted()) vertices")
                    Button("Rename", systemImage: "pencil") {
                        newName = model.name
                        renaming = model
                    }
                    Button("Delete model", systemImage: "trash", role: .destructive) {
                        runtime.deleteUserModel(model.id)
                    }
                }
            }
        }
    }

    private var lookPage: some View {
        VStack(spacing: 6) {
            chips {
                ForEach(ARObjectMaterialMode.allCases) { material in
                    GVDeckChip(label: material.label, symbol: material.symbol,
                               active: runtime.parameters.material == material, tint: .white,
                               id: "ar.material.\(material.rawValue)") {
                        runtime.parameters.material = material
                    }
                }
            }
            HStack(spacing: 8) {
                slider("Size", \.size, 0.35 ... 1.8)
                slider("Glow", \.glow, 0.1 ... 1.6)
                slider("Metal", \.metallic, 0 ... 1)
                slider("Opacity", \.opacity, 0.2 ... 1)
            }
        }
    }

    private var motionPage: some View {
        VStack(spacing: 6) {
            chips {
                ForEach(ARObjectPhysicsMode.allCases) { mode in
                    GVDeckChip(label: mode.label, symbol: mode.symbol, active: runtime.parameters.physicsMode == mode,
                               tint: .white, id: "ar.physics.\(mode.rawValue)") {
                        runtime.parameters.physicsMode = mode
                    }
                }
                ForEach(ARObjectSpinAxis.allCases) { axis in
                    GVDeckChip(label: axis.label, active: runtime.parameters.spinAxis == axis, tint: .white,
                               id: "ar.axis.\(axis.rawValue)") {
                        runtime.parameters.spinAxis = axis
                    }
                }
            }
            HStack(spacing: 8) {
                slider("Spin", \.spin, 0 ... 2)
                slider("Bob", \.bobAmplitude, 0 ... 0.3)
                slider("Orbit", \.orbitSpeed, 0 ... 1.5)
            }
        }
    }

    private var presetsPage: some View {
        chips {
            ForEach(GVObjectPreset.all) { preset in
                GVDeckChip(label: preset.name, symbol: preset.symbol, tint: .white, id: "ar.preset.\(preset.id)") {
                    runtime.apply(preset)
                    toasts.show(preset.name)
                }
            }
        }
    }

    // MARK: Building blocks

    private func chips(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) { content() }.padding(.horizontal, 2)
        }
    }

    private func slider(_ label: String, _ keyPath: WritableKeyPath<ARObjectParameters, Double>,
                        _ range: ClosedRange<Double>) -> some View
    {
        GVRailSlider(
            label: label,
            value: Binding(get: { runtime.parameters[keyPath: keyPath] },
                           set: { runtime.parameters[keyPath: keyPath] = $0 }),
            defaultValue: ARObjectParameters.defaults[keyPath: keyPath],
            range: range,
            format: { String(format: "%.2f", $0) }
        )
        .accessibilityIdentifier("workspace.param.ar.\(label.lowercased())")
    }
}
