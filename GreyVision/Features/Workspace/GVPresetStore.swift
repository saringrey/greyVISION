import Combine
import Foundation
import SwiftUI

/// A complete look, stored by name.
///
/// Everything needed to rebuild a composition atomically: the capture format,
/// RGB split and the whole effect stack. Depth/AR state is deliberately NOT
/// included — those are sensor modes with hardware preconditions, not looks.
struct GVPreset: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var isFactory: Bool = false

    var codecRaw: String
    var frameRate: Int
    var resolutionRaw: String
    var rgbSplit: RGBSplitEffectParameters
    var stack: CameraEffectStackParameters

    /// One-line summary for the drawer row.
    var summary: String {
        let active = stack.activeEffects.map(\.0.label)
        let rgb = rgbSplit.isEnabled ? ["RGB"] : []
        let parts = (rgb + active).prefix(4)
        return parts.isEmpty ? "EMPTY PLATE" : parts.joined(separator: " \u{00B7} ")
    }
}

/// Named recipes plus automatic last-session recovery.
///
/// Recipes live as one JSON document in Application Support so they can be
/// exported by handing over the file. The last session is a separate file the
/// workspace rewrites whenever its composition changes, which is what makes
/// relaunch restore the exact prior look without any explicit save step.
@MainActor
final class GVPresetStore: ObservableObject {
    @Published private(set) var presets: [GVPreset] = []

    static let shared = GVPresetStore()

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Presets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var presetsURL: URL { directory.appendingPathComponent("recipes.json") }
    private static var sessionURL: URL { directory.appendingPathComponent("last-session.json") }

    private init() {
        loadFromDisk()
        if presets.isEmpty {
            seedFactoryRecipes()
        }
    }

    // MARK: - CRUD

    func save(name: String, from setup: CaptureSetupDraft, rgb: RGBSplitEffectParameters, stack: CameraEffectStackParameters) {
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
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        presets[index].name = trimmed.uppercased()
        persist()
    }

    func duplicate(_ id: UUID) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        var copy = presets[index]
        copy.id = UUID()
        copy.name = (copy.name + " COPY").prefix(28).uppercased()
        copy.createdAt = Date()
        copy.isFactory = false
        presets.insert(copy, at: index + 1)
        persist()
    }

    func delete(_ id: UUID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        presets.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist()
    }

    // MARK: - Session recovery

    func writeLastSession(setup: CaptureSetupDraft, rgb: RGBSplitEffectParameters, stack: CameraEffectStackParameters) {
        let preset = GVPreset(
            name: "LAST SESSION",
            codecRaw: setup.videoCodec.rawValue,
            frameRate: setup.frameRate.rawValue,
            resolutionRaw: setup.resolution.rawValue,
            rgbSplit: rgb,
            stack: stack
        )
        guard let data = try? JSONEncoder().encode(preset) else { return }
        try? data.write(to: Self.sessionURL, options: .atomic)
    }

    /// Returns true when a prior session existed and was applied.
    @discardableResult
    func restoreLastSession(to setup: inout CaptureSetupDraft, rgb: inout RGBSplitEffectParameters, stack: inout CameraEffectStackParameters) -> Bool {
        guard let data = try? Data(contentsOf: Self.sessionURL),
              let preset = try? JSONDecoder().decode(GVPreset.self, from: data)
        else { return false }
        apply(preset, to: &setup, rgb: &rgb, stack: &stack)
        return true
    }

    /// Applies a recipe in one move — no intermediate half-applied states.
    func apply(_ preset: GVPreset, to setup: inout CaptureSetupDraft, rgb: inout RGBSplitEffectParameters, stack: inout CameraEffectStackParameters) {
        if let codec = CaptureSetupDraft.VideoCodec(rawValue: preset.codecRaw),
           codec.isOperatingSystemAvailable || !CaptureSetupDraft.VideoCodec.curated.contains(codec) {
            setup.videoCodec = codec
        }
        if let rate = CaptureSetupDraft.FrameRate(rawValue: preset.frameRate) {
            setup.frameRate = rate
        }
        if let resolution = CaptureSetupDraft.Resolution(rawValue: preset.resolutionRaw), resolution.isSelectable {
            setup.resolution = resolution
        }
        rgb = preset.rgbSplit
        stack = preset.stack
    }

    // MARK: - Export / import

    func exportURL(_ preset: GVPreset) -> URL? {
        let url = Self.directory.appendingPathComponent("\(preset.name).gvrecipe.json")
        guard let data = try? JSONEncoder().encode(preset) else { return nil }
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }

    func importPreset(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              var preset = try? JSONDecoder().decode(GVPreset.self, from: data)
        else { return "IMPORT FAILED // UNREADABLE RECIPE" }
        preset.id = UUID()
        preset.isFactory = false
        preset.name = (preset.name + " IMPORT").prefix(30).uppercased()
        presets.insert(preset, at: 0)
        persist()
        return "IMPORTED // \(preset.name)"
    }

    // MARK: - Disk

    private func persist() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        try? data.write(to: Self.presetsURL, options: .atomic)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: Self.presetsURL),
              let decoded = try? JSONDecoder().decode([GVPreset].self, from: data)
        else { return }
        presets = decoded
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
        persist()
    }
}
