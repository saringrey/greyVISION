import Combine
import Foundation
import SwiftUI

/// A complete look, stored by name.
///
/// Everything needed to rebuild a composition atomically: the capture format,
/// RGB split and the whole effect stack. Depth/AR state is deliberately NOT
/// included — those are sensor modes with hardware preconditions, not looks.
struct GVPreset: Identifiable, Codable, Equatable {
    var id: UUID = .init()
    var name: String
    var createdAt: Date = .init()
    var isFactory: Bool = false

    var codecRaw: String
    var frameRate: Int
    var resolutionRaw: String
    var rgbSplit: RGBSplitEffectParameters
    var stack: CameraEffectStackParameters

    /// One-line summary for the drawer row.
    var summary: String {
        let active = stack.orderedSlots.compactMap { $0.parameters.isEnabled ? $0.effect.label : nil }
        let rgb = rgbSplit.isEnabled ? ["RGB"] : []
        let parts = (rgb + active).prefix(4)
        return parts.isEmpty ? "EMPTY PLATE" : parts.joined(separator: " \u{00B7} ")
    }
}

/// Named recipes.
///
/// Recipes live as one JSON document in Application Support so they can be
/// exported by handing over the file.
@MainActor
final class GVPresetStore: ObservableObject {
    @Published private(set) var presets: [GVPreset] = []
    @Published private(set) var starredIDs: Set<UUID> = []
    @Published private(set) var storageError: String?

    static let shared = GVPresetStore(directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Presets", isDirectory: true))

    private struct Collections: Codable {
        var catalogVersion = 0
        var starredIDs: Set<UUID> = []
    }

    private let directory: URL
    private var collections = Collections()
    private var isReadOnly = false
    private var presetsURL: URL { directory.appendingPathComponent("recipes.json") }
    private var collectionsURL: URL { directory.appendingPathComponent("collections.json") }

    init(directory: URL) {
        self.directory = directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Launch remains clean; only explicitly named recipes are restored.
            let legacySession = directory.appendingPathComponent("last-session.json")
            if FileManager.default.fileExists(atPath: legacySession.path) {
                try FileManager.default.removeItem(at: legacySession)
            }
            if FileManager.default.fileExists(atPath: presetsURL.path) {
                presets = try JSONDecoder().decode([GVPreset].self, from: Data(contentsOf: presetsURL))
            } else {
                seedFactoryRecipes()
            }
            if FileManager.default.fileExists(atPath: collectionsURL.path) {
                collections = try JSONDecoder().decode(Collections.self, from: Data(contentsOf: collectionsURL))
            }
            starredIDs = collections.starredIDs.intersection(presets.map(\.id))
            if collections.catalogVersion < 1 {
                if !presets.isEmpty { appendCuratedRecipes() }
                collections.catalogVersion = 1
                persist()
            }
        } catch {
            isReadOnly = true
            storageError = "Your recipe library could not be opened. Original files have been kept. \(error.localizedDescription)"
        }
    }

    func toggleStar(_ id: UUID) {
        guard !isReadOnly, presets.contains(where: { $0.id == id }) else { return }
        if starredIDs.contains(id) { starredIDs.remove(id) } else { starredIDs.insert(id) }
        persist()
    }

    // MARK: - CRUD

    func save(name: String, from setup: CaptureSetupDraft, rgb: RGBSplitEffectParameters, stack: CameraEffectStackParameters) {
        guard !isReadOnly else { return }
        var trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { trimmed = "RECIPE \(presets.count + 1)" }
        // Saving under an existing name overwrites it — renaming by re-save.
        if let index = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            presets[index].codecRaw = setup.videoCodec.rawValue
            presets[index].frameRate = setup.frameRate.rawValue
            presets[index].resolutionRaw = setup.resolution.rawValue
            presets[index].rgbSplit = rgb
            presets[index].stack = stack
        } else {
            presets.insert(
                GVPreset(
                    name: trimmed.uppercased(),
                    codecRaw: setup.videoCodec.rawValue,
                    frameRate: setup.frameRate.rawValue,
                    resolutionRaw: setup.resolution.rawValue,
                    rgbSplit: rgb,
                    stack: stack
                ),
                at: 0
            )
        }
        persist()
    }

    func rename(_ id: UUID, to newName: String) {
        guard !isReadOnly, let index = presets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        presets[index].name = trimmed.uppercased()
        persist()
    }

    func duplicate(_ id: UUID) {
        guard !isReadOnly, let index = presets.firstIndex(where: { $0.id == id }) else { return }
        var copy = presets[index]
        copy.id = UUID()
        copy.name = (copy.name + " COPY").prefix(28).uppercased()
        copy.createdAt = Date()
        copy.isFactory = false
        presets.insert(copy, at: index + 1)
        persist()
    }

    func delete(_ id: UUID) {
        guard !isReadOnly else { return }
        presets.removeAll { $0.id == id }
        starredIDs.remove(id)
        persist()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        guard !isReadOnly else { return }
        presets.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist()
    }

    /// Applies a recipe in one move — no intermediate half-applied states.
    func apply(_ preset: GVPreset, to setup: inout CaptureSetupDraft, rgb: inout RGBSplitEffectParameters, stack: inout CameraEffectStackParameters) {
        if let codec = CaptureSetupDraft.VideoCodec(rawValue: preset.codecRaw),
           codec.isOperatingSystemAvailable || !CaptureSetupDraft.VideoCodec.curated.contains(codec)
        {
            setup.videoCodec = codec
        }
        if let rate = CaptureSetupDraft.FrameRate(rawValue: preset.frameRate) {
            setup.frameRate = rate
        }
        if let resolution = CaptureSetupDraft.Resolution(rawValue: preset.resolutionRaw) {
            setup.resolution = resolution
        }
        rgb = preset.rgbSplit
        stack = preset.stack
    }

    // MARK: - Export / import

    func exportURL(_ preset: GVPreset) -> URL? {
        let slug = Self.filesystemSafeSlug(preset.name)
        let url = directory.appendingPathComponent("\(slug).gvrecipe.json")
        let data: Data
        do {
            data = try JSONEncoder().encode(preset)
        } catch {
            GVLog.app.error("Recipe export encode failed for \(preset.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            GVLog.app.error("Recipe export write failed for \(preset.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Filesystem-safe slug independent of the display name: path separators
    /// and invalid filename characters can otherwise fail export or escape
    /// the recipe directory.
    static func filesystemSafeSlug(_ name: String) -> String {
        let upper = name.uppercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let filtered = upper.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.map(String.init).joined()
        let collapsed = filtered.split(separator: " ").joined(separator: "-")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .prefix(40)
        return trimmed.isEmpty ? "RECIPE" : String(trimmed)
    }

    func importPreset(from url: URL) -> String? {
        guard !isReadOnly else { return storageError }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            GVLog.app.error("Recipe import read failed: \(error.localizedDescription, privacy: .public)")
            return "IMPORT FAILED // UNREADABLE RECIPE"
        }
        let decoded: GVPreset
        do {
            decoded = try JSONDecoder().decode(GVPreset.self, from: data)
        } catch {
            GVLog.app.error("Recipe import decode failed: \(error.localizedDescription, privacy: .public)")
            return "IMPORT FAILED // UNREADABLE RECIPE"
        }
        var preset = decoded
        preset.id = UUID()
        preset.isFactory = false
        preset.name = (preset.name + " IMPORT").prefix(30).uppercased()
        presets.insert(preset, at: 0)
        persist()
        return "IMPORTED // \(preset.name)"
    }

    // MARK: - Disk

    private func persist() {
        guard !isReadOnly else { return }
        do {
            collections.starredIDs = starredIDs
            try JSONEncoder().encode(presets).write(to: presetsURL, options: .atomic)
            try JSONEncoder().encode(collections).write(to: collectionsURL, options: .atomic)
            storageError = nil
        } catch {
            storageError = "Recipe changes could not be saved. \(error.localizedDescription)"
            GVLog.app.error("Recipe persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func appendCuratedRecipes() {
        let names = ["SILVER LIGHT", "CHROMA STUDY", "AFTERIMAGE", "SOFT SIGNAL"]
        for (index, name) in names.enumerated() {
            let id = UUID(uuidString: "A6DC1000-441B-4864-8FCA-00000000000\(index)")!
            guard !presets.contains(where: { $0.id == id }) else { continue }
            var preset = GVPreset(
                id: id, name: name, isFactory: true,
                codecRaw: CaptureSetupDraft.VideoCodec.hevc.rawValue,
                frameRate: 30, resolutionRaw: CaptureSetupDraft.Resolution.ultraHD.rawValue,
                rgbSplit: .init(), stack: .init()
            )
            preset.stack.setEnabled(true, for: .grain)
            preset.stack[.grain].primary = 0.16
            switch index {
            case 0:
                preset.stack.setEnabled(true, for: .vignette)
                preset.stack[.vignette].primary = 0.28
            case 1:
                preset.rgbSplit.isEnabled = true
                preset.rgbSplit.amount = 0.006
            case 2:
                preset.stack.setEnabled(true, for: .echo)
                preset.stack[.echo].primary = 0.25
                preset.stack[.echo].blend = 0.4
            default:
                preset.stack.setEnabled(true, for: .vhs)
                preset.stack[.vhs].primary = 0.22
                preset.stack[.vhs].blend = 0.45
            }
            presets.append(preset)
        }
    }

    /// Four safe demonstrations that show the range without ever producing an
    /// unusable image.
    private func seedFactoryRecipes() {
        func recipe(_ name: String, _ build: (inout GVPreset) -> Void) -> GVPreset {
            var preset = GVPreset(
                name: name,
                codecRaw: CaptureSetupDraft.VideoCodec.hevc.rawValue,
                frameRate: CaptureSetupDraft.FrameRate.realtime.rawValue,
                resolutionRaw: CaptureSetupDraft.Resolution.ultraHD.rawValue,
                rgbSplit: RGBSplitEffectParameters(),
                stack: CameraEffectStackParameters()
            )
            preset.isFactory = true
            build(&preset)
            return preset
        }

        presets = [
            recipe("CLEAN PLATE") { _ in
                // Deliberately empty — the way back to the true image.
            },
            recipe("VHS NIGHT") { preset in
                preset.stack.setEnabled(true, for: .vhs)
                preset.stack[.vhs].primary = 0.62
                preset.stack[.vhs].secondary = 0.55
                preset.stack[.vhs].tertiary = 0.48
                preset.stack.setEnabled(true, for: .grain)
                preset.stack[.grain].primary = 0.38
                preset.stack.setEnabled(true, for: .vignette)
                preset.stack[.vignette].primary = 0.55
            },
            recipe("SIGNAL GHOST") { preset in
                preset.stack.setEnabled(true, for: .feedback)
                preset.stack[.feedback].primary = 0.55
                preset.stack[.feedback].blend = 0.9
                preset.stack.setEnabled(true, for: .echo)
                preset.stack[.echo].primary = 0.45
                preset.stack[.echo].secondary = 0.35
                preset.rgbSplit.isEnabled = true
                preset.rgbSplit.amount = 0.012
            },
            recipe("DATA COLLAPSE") { preset in
                preset.stack.setEnabled(true, for: .datamosh)
                preset.stack[.datamosh].primary = 0.6
                preset.stack[.datamosh].secondary = 0.5
                preset.stack.setEnabled(true, for: .pixelate)
                preset.stack[.pixelate].primary = 0.42
                preset.stack[.pixelate].blend = 0.7
            }
        ]
    }
}
