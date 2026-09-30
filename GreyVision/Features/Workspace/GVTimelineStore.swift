import Combine
import Foundation
import SwiftUI

/// One keyframe for a single named parameter on one effect slot.
///
/// Identity is `slotID + field` so the same field on two slots of the same
/// effect can be animated independently. The slot id is a UUID; if the slot is
/// removed the keyframe simply becomes a no-op when interpolated, which keeps
/// old timelines usable after the user edits the stack.
struct GVTimelineKeyframe: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = .init()
    /// Seconds from timeline start. Clamped to the timeline duration on commit.
    var time: TimeInterval
    /// Which field of `CameraEffectParameters` this keyframe animates.
    var field: AnimatedField
    /// Target value, normalised 0...1 the same way the renderer reads it.
    var value: Double
    /// Easing curve between this keyframe and the next one on the same field.
    var curve: GVTimelineCurve = .hold

    enum AnimatedField: String, Codable, CaseIterable, Sendable {
        case isEnabled
        case primary
        case secondary
        case tertiary
        case blend
        case overlayX
        case overlayY
        case rgbEnabled
        case rgbAmount
        case rgbAngle

        var label: String {
            switch self {
            case .isEnabled: "ON"
            case .primary: "PRI"
            case .secondary: "SEC"
            case .tertiary: "TER"
            case .blend: "MIX"
            case .overlayX: "X"
            case .overlayY: "Y"
            case .rgbEnabled: "RGB"
            case .rgbAmount: "AMT"
            case .rgbAngle: "ANG"
            }
        }
    }
}

/// Easing between two adjacent keyframes. `hold` is a step (next value wins
/// instantly); everything else is a 0...1 ease over the segment.
enum GVTimelineCurve: String, Codable, CaseIterable, Sendable {
    case hold
    case linear
    case easeIn
    case easeOut
    case easeInOut

    func apply(_ t: Double) -> Double {
        switch self {
        case .hold: 0
        case .linear: t
        case .easeIn: t * t
        case .easeOut: 1 - (1 - t) * (1 - t)
        case .easeInOut: t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        }
    }
}

/// A named, persisted timeline of keyframes across the operator's composition.
///
/// A timeline is a recipe that changes over time. It records the starting
/// composition (so a replay begins from a known place), the loop duration, and
/// the keyframes that warp parameters between then and now.
struct GVTimeline: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = .init()
    var name: String
    var createdAt: Date = .init()
    var isFactory: Bool = false

    /// Capture format captured at save time. Applied before playback begins.
    var codecRaw: String
    var frameRate: Int
    var resolutionRaw: String

    /// RGB split + stack at time zero. The timeline animates parameters away
    /// from this base composition.
    var baseRGB: RGBSplitEffectParameters
    var baseStack: CameraEffectStackParameters

    /// Total playback length in seconds. Loops back to base at the end.
    var duration: TimeInterval

    /// Keyframes ordered by time per (slotID, field) so playback can do a
    /// sorted scan rather than a full filter on every tick.
    var keyframes: [GVTimelineKeyframe]

    static let empty = GVTimeline(
        name: "EMPTY",
        codecRaw: CaptureSetupDraft.VideoCodec.hevc.rawValue,
        frameRate: CaptureSetupDraft.FrameRate.realtime.rawValue,
        resolutionRaw: CaptureSetupDraft.Resolution.ultraHD.rawValue,
        baseRGB: .init(),
        baseStack: .init(),
        duration: 8,
        keyframes: []
    )
}

/// A timeline that can be edited without owning an `EffectEditingSession`.
///
/// The store is the public surface; playback is driven by `GVTimelinePlayer`
/// which holds a strong reference to the editor and animates in lockstep with
/// the recording mailbox.
@MainActor
final class GVTimelineStore: ObservableObject {
    @Published private(set) var timelines: [GVTimeline] = []
    static let shared = GVTimelineStore()

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Timelines", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var timelinesURL: URL { directory.appendingPathComponent("timelines.json") }

    private init() {
        loadFromDisk()
        if timelines.isEmpty {
            seedFactoryTimelines()
        }
    }

    // MARK: - CRUD

    func save(
        name: String,
        duration: TimeInterval,
        from editor: EffectEditingSession,
        setup: CaptureSetupDraft
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let finalName = trimmed.isEmpty ? "TIMELINE \(timelines.count + 1)" : trimmed.uppercased()
        if let index = timelines.firstIndex(where: { $0.name.caseInsensitiveCompare(finalName) == .orderedSame }) {
            timelines[index].codecRaw = setup.videoCodec.rawValue
            timelines[index].frameRate = setup.frameRate.rawValue
            timelines[index].resolutionRaw = setup.resolution.rawValue
            timelines[index].baseRGB = editor.rgbSplitParameters
            timelines[index].baseStack = editor.effectStack
            timelines[index].duration = max(0.5, duration)
        } else {
            timelines.insert(
                GVTimeline(
                    name: finalName,
                    codecRaw: setup.videoCodec.rawValue,
                    frameRate: setup.frameRate.rawValue,
                    resolutionRaw: setup.resolution.rawValue,
                    baseRGB: editor.rgbSplitParameters,
                    baseStack: editor.effectStack,
                    duration: max(0.5, duration),
                    keyframes: []
                ),
                at: 0
            )
        }
        persist()
    }

    func delete(_ id: UUID) {
        timelines.removeAll { $0.id == id }
        persist()
    }

    func rename(_ id: UUID, to newName: String) {
        guard let index = timelines.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        timelines[index].name = trimmed.uppercased()
        persist()
    }

    func setKeyframes(_ id: UUID, _ keyframes: [GVTimelineKeyframe]) {
        guard let index = timelines.firstIndex(where: { $0.id == id }) else { return }
        let duration = timelines[index].duration
        timelines[index].keyframes = keyframes.map { kf in
            var clamped = kf
            clamped.time = min(max(kf.time, 0), duration)
            return clamped
        }.sorted { $0.time < $1.time }
        persist()
    }

    func addKeyframe(_ id: UUID, _ keyframe: GVTimelineKeyframe) {
        guard let index = timelines.firstIndex(where: { $0.id == id }) else { return }
        var kf = keyframe
        kf.time = min(max(kf.time, 0), timelines[index].duration)
        timelines[index].keyframes.append(kf)
        timelines[index].keyframes.sort { $0.time < $1.time }
        persist()
    }

    func removeKeyframe(timeline id: UUID, keyframe kfID: UUID) {
        guard let index = timelines.firstIndex(where: { $0.id == id }) else { return }
        timelines[index].keyframes.removeAll { $0.id == kfID }
        persist()
    }

    func setDuration(_ id: UUID, _ seconds: TimeInterval) {
        guard let index = timelines.firstIndex(where: { $0.id == id }) else { return }
        timelines[index].duration = max(0.5, seconds)
        timelines[index].keyframes = timelines[index].keyframes.map { kf in
            var clamped = kf
            clamped.time = min(max(kf.time, 0), timelines[index].duration)
            return clamped
        }
        persist()
    }

    // MARK: - Disk

    private func persist() {
        guard let data = try? JSONEncoder().encode(timelines) else { return }
        try? data.write(to: Self.timelinesURL, options: .atomic)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: Self.timelinesURL),
              let decoded = try? JSONDecoder().decode([GVTimeline].self, from: data)
        else { return }
        timelines = decoded
    }

    // MARK: - Factory content

    private func seedFactoryTimelines() {
        let baseStack = CameraEffectStackParameters()
        let vhs = GVTimeline(
            name: "VHS BREATHE",
            codecRaw: CaptureSetupDraft.VideoCodec.hevc.rawValue,
            frameRate: CaptureSetupDraft.FrameRate.realtime.rawValue,
            resolutionRaw: CaptureSetupDraft.Resolution.ultraHD.rawValue,
            baseRGB: .init(),
            baseStack: baseStack,
            duration: 8,
            keyframes: []
        )
        timelines = [vhs, .empty]
        persist()
    }
}
