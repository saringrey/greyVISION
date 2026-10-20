import Combine
import Foundation
import QuartzCore
import SwiftUI

/// Drives an `EffectEditingSession` from a `GVTimeline` by interpolating
/// keyframes onto the current slot's `CameraEffectParameters` and the RGB
/// split parameters. The render path never knows the timeline exists — it
/// just reads the editor's published state on the next frame.
///
/// Loop mode: at the end of `duration` the player rewinds to `t = 0` and
/// continues. One-shot is also available for the "fire and forget" cue case.
@MainActor
final class GVTimelinePlayer: ObservableObject {
    enum Mode: String, Sendable {
        case loop
        case oneShot
        case paused
    }

    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var activeTimeline: GVTimeline?
    /// The timeline the operator has chosen, whether or not it has ever played.
    /// Scrubbing needs keyframes to read, and the first drag always precedes the
    /// transport — so the thing being scrubbed cannot be only "whatever is playing".
    @Published private(set) var selectedTimeline: GVTimeline?
    @Published var mode: Mode = .loop

    private weak var editor: EffectEditingSession?
    private var displayLink: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var lastTickAt: CFTimeInterval = 0

    func attach(editor: EffectEditingSession) {
        self.editor = editor
    }

    /// Arms a timeline for scrubbing without touching the transport.
    ///
    /// Selecting is not seeking: the playhead keeps its time, clamped into the
    /// newly chosen timeline so a short cue picked after a long one does not report
    /// a time that does not exist in it.
    func selectForScrub(_ timeline: GVTimeline) {
        selectedTimeline = timeline
        activeTimeline = timeline
        currentTime = min(currentTime, timeline.duration)
    }

    /// Begins playback from the timeline's base composition. Calling play with
    /// a different timeline swaps the active one mid-flight, which the operator
    /// uses for chained cues.
    func play(_ timeline: GVTimeline) {
        guard let editor else { return }
        activeTimeline = timeline
        // Playing a timeline is also selecting it, so stopping does not leave the
        // operator with a named timeline that can no longer be scrubbed.
        selectedTimeline = timeline
        // Apply the base composition so a replay begins from a known place.
        editor.rgbSplitParameters = timeline.baseRGB
        editor.effectStack = timeline.baseStack
        currentTime = 0
        startedAt = CACurrentMediaTime()
        lastTickAt = startedAt
        isPlaying = true
        startDisplayLink()
    }

    func stop() {
        isPlaying = false
        activeTimeline = nil
        stopDisplayLink()
    }

    /// Unarms a timeline the operator has removed. A playhead that kept scrubbing a
    /// deleted cue would be interpolating keyframes out of a timeline that no longer
    /// exists in the store, which reads as a control still working on a dead file.
    func deselect(_ timeline: GVTimeline) {
        guard selectedTimeline?.id == timeline.id else { return }
        selectedTimeline = nil
        if activeTimeline?.id == timeline.id { stop() }
    }

    /// Play, or stop and re-arm the same cue. Stopping clears the active
    /// timeline but keeps the selection, so the transport's second press has to
    /// be able to restart what it just stopped — otherwise the button reads
    /// "play" and does nothing until the operator re-picks the timeline.
    func toggle() {
        if isPlaying {
            stop()
        } else if let timeline = activeTimeline ?? selectedTimeline {
            play(timeline)
        }
    }

    /// Jumps to a specific time and applies the interpolated state without
    /// playing. Used by the timeline scrubber and the "jump to next cue" UI.
    func scrub(to time: TimeInterval) {
        guard let timeline = activeTimeline ?? storedTimelineForScrub() else { return }
        if activeTimeline == nil { activeTimeline = timeline }
        currentTime = min(max(time, 0), timeline.duration)
        if let editor { apply(timeline: timeline, at: currentTime, into: editor) }
    }

    /// What a drag reads when nothing is active: the timeline that was selected
    /// before the transport stopped, then the most recently saved one. The store
    /// fallback is deliberate — the picker writes the store, and its newest entry is
    /// a defensible answer for a drag that arrives with nothing selected. Factory
    /// timelines are included because they are what a first run meets.
    private func storedTimelineForScrub() -> GVTimeline? {
        selectedTimeline ?? GVTimelineStore.shared.timelines.first
    }

    // MARK: - Display link

    private func startDisplayLink() {
        stopDisplayLink()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let timeline = activeTimeline, let editor else { return }
        let now = link.timestamp
        let delta = now - lastTickAt
        lastTickAt = now
        currentTime += delta
        if currentTime >= timeline.duration {
            switch mode {
            case .loop:
                // Re-apply the base so the loop seam is clean.
                editor.rgbSplitParameters = timeline.baseRGB
                editor.effectStack = timeline.baseStack
                currentTime = currentTime.truncatingRemainder(dividingBy: timeline.duration)
            case .oneShot:
                currentTime = timeline.duration
                apply(timeline: timeline, at: currentTime, into: editor)
                stop()
                return
            case .paused:
                currentTime = timeline.duration
                stop()
                return
            }
        }
        apply(timeline: timeline, at: currentTime, into: editor)
    }

    // MARK: - Interpolation

    /// For each animated (slotID, field) pair, finds the surrounding keyframes
    /// and writes the eased value into the slot. The editor's @Published
    /// properties fire on the next runloop and the renderer's `update` picks
    /// them up.
    private func apply(timeline: GVTimeline, at time: TimeInterval, into editor: EffectEditingSession) {
        let grouped = Dictionary(grouping: timeline.keyframes) { kf in
            KeyframeKey(slotID: kf.id, field: kf.field)
        }
        for (_, keyframes) in grouped {
            guard keyframes.count >= 1 else { continue }
            let value = interpolate(keyframes: keyframes.sorted { $0.time < $1.time }, at: time)
            apply(value: value.value, curve: value.curve, field: value.field, into: editor)
        }
    }

    private struct ResolvedValue {
        let value: Double
        let curve: GVTimelineCurve
        let field: GVTimelineKeyframe.AnimatedField
    }

    private struct KeyframeKey: Hashable {
        let slotID: UUID
        let field: GVTimelineKeyframe.AnimatedField
    }

    private func interpolate(keyframes: [GVTimelineKeyframe], at time: TimeInterval) -> ResolvedValue {
        guard let first = keyframes.first else { return ResolvedValue(value: 0, curve: .hold, field: .primary) }
        if time <= first.time {
            return ResolvedValue(value: first.value, curve: first.curve, field: first.field)
        }
        guard let last = keyframes.last else { return ResolvedValue(value: 0, curve: .hold, field: first.field) }
        if time >= last.time, keyframes.count == 1 {
            return ResolvedValue(value: last.value, curve: last.curve, field: last.field)
        }
        if time >= last.time {
            return ResolvedValue(value: last.value, curve: last.curve, field: last.field)
        }
        for index in 0 ..< (keyframes.count - 1) {
            let a = keyframes[index]
            let b = keyframes[index + 1]
            if time >= a.time, time < b.time {
                let span = b.time - a.time
                let t = span > 0 ? (time - a.time) / span : 0
                let eased = a.curve.apply(t)
                let value = a.value + (b.value - a.value) * eased
                return ResolvedValue(value: value, curve: a.curve, field: a.field)
            }
        }
        return ResolvedValue(value: last.value, curve: last.curve, field: last.field)
    }

    private func apply(value: Double, curve _: GVTimelineCurve, field: GVTimelineKeyframe.AnimatedField, into editor: EffectEditingSession) {
        switch field {
        case .rgbEnabled:
            editor.rgbSplitParameters.isEnabled = value > 0.5
        case .rgbAmount:
            editor.rgbSplitParameters.amount = min(max(value, 0), 1)
        case .rgbAngle:
            editor.rgbSplitParameters.angleDegrees = value * 360
        default:
            applySlotField(value: value, field: field, into: editor)
        }
    }

    private func applySlotField(value: Double, field: GVTimelineKeyframe.AnimatedField, into editor: EffectEditingSession) {
        // Slot id was encoded into the keyframe's own id via the first 8 bytes
        // in the factory seed; for the runtime path the operator adds keyframes
        // against the focused slot, so the focused slot is the target.
        guard let slotID = editor.focusedSlot,
              var parameters = editor.effectStack[slot: slotID]
        else { return }
        switch field {
        case .isEnabled:
            parameters.isEnabled = value > 0.5
        case .primary:
            parameters.primary = min(max(value, 0), 1)
        case .secondary:
            parameters.secondary = min(max(value, 0), 1)
        case .tertiary:
            parameters.tertiary = min(max(value, 0), 1)
        case .blend:
            parameters.blend = min(max(value, 0), 1)
        case .overlayX:
            parameters.overlayX = min(max(value, 0.05), 0.95)
        case .overlayY:
            parameters.overlayY = min(max(value, 0.05), 0.95)
        case .rgbEnabled, .rgbAmount, .rgbAngle:
            return
        }
        editor.effectStack[slot: slotID] = parameters
    }
}
