import SwiftUI

/// A compact transport bar for the active `GVTimeline`. The big idea is that
/// the operator never has to leave the live preview to fire a cue — the bar
/// sits above the dock, shows the current time, and has play / loop / oneshot
/// affordances. The recording transaction picks up the editor state on the
/// next frame, so a timeline running in the background is automatically
/// captured by a take.
struct GVTimelineBar: View {
    @ObservedObject var player: GVTimelinePlayer
    /// The preview comes from the capture session, not the player: it is the
    /// runtime that holds the finished take and the mailbox the render loop reads.
    @EnvironmentObject private var cameraRuntime: CameraRuntime
    let onPickTimeline: () -> Void
    let onSaveTimeline: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse: Bool = false

    var body: some View {
        HStack(spacing: GVMetrics.gap) {
            playButton

            VStack(alignment: .leading, spacing: GVMetrics.gapHair) {
                Text(player.activeTimeline?.name ?? player.selectedTimeline?.name ?? "NO TIMELINE")
                    .font(GVTheme.font(.control, scale: 0.6875))
                    .tracking(0.8)
                    .foregroundStyle(GVTheme.bone)
                    .lineLimit(1)

                HStack(spacing: GVMetrics.gapTight) {
                    Text(timecode)
                        .font(GVTheme.font(.diagnostic, scale: 1.0588))
                        .foregroundStyle(player.isPlaying ? GVTheme.bone : GVTheme.ash)
                    if let timeline = player.activeTimeline ?? player.selectedTimeline {
                        Text("/ \(formatDuration(timeline.duration))")
                            .font(GVTheme.font(.diagnostic, scale: 1.0588))
                            .foregroundStyle(GVTheme.ash.opacity(0.7))
                    }
                    // The viewfinder is showing recorded content while scrubbing, and
                    // it has to say so: this instrument also has a real freeze
                    // control, and the two must not be confusable.
                    if cameraRuntime.isShowingTakePreview {
                        Text("SCRUB")
                            .font(GVTheme.font(.diagnostic, scale: 1.0588))
                            .tracking(0.6)
                            .foregroundStyle(GVTheme.bone.opacity(0.75))
                            .accessibilityLabel("Showing a frame from the recorded take")
                    }
                }

                scrubTrack
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            modeToggle
            pickButton
            saveButton
        }
        .padding(.horizontal, GVMetrics.screenInset)
        .padding(.vertical, GVMetrics.gapTight)
        .background {
            RoundedRectangle(cornerRadius: GVMetrics.radiusPanel, style: .continuous)
                .fill(GVTheme.surfaceSecondary)
                .overlay {
                    RoundedRectangle(cornerRadius: GVMetrics.radiusPanel, style: .continuous)
                        .strokeBorder(GVTheme.violet.opacity(player.isPlaying ? 0.65 : 0.18), lineWidth: GVMetrics.hairline)
                }
        }
        .scaleEffect(pulse ? 1.02 : 1)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.4), value: pulse)
        .onChange(of: player.isPlaying) { _, playing in
            if playing {
                pulse = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { pulse = false }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.timeline.bar")
    }

    private var playButton: some View {
        Button {
            player.toggle()
        } label: {
            Image(systemName: player.isPlaying ? "stop.fill" : "play.fill")
                .font(.system(size: GVMetrics.textValue * 1.217, weight: .black))
                .foregroundStyle(GVTheme.bone)
                .frame(width: GVMetrics.controlHeight - 8, height: GVMetrics.controlHeight - 8)
                .background {
                    Circle().fill(player.isPlaying ? GVTheme.record.opacity(0.65) : GVTheme.bone.opacity(0.18))
                }
        }
        .buttonStyle(GVPressStyle())
        .contentShape(Rectangle())
        .accessibilityLabel(player.isPlaying ? "Stop timeline" : "Play timeline")
        .accessibilityIdentifier("workspace.timeline.play")
    }

    private var modeToggle: some View {
        Button {
            player.mode = nextMode(after: player.mode)
        } label: {
            Text(player.mode.rawValue.uppercased())
                .font(GVTheme.font(.diagnostic, scale: 1.0588))
                .tracking(0.6)
                .foregroundStyle(GVTheme.bone)
                .padding(.horizontal, GVMetrics.gapTight)
                .frame(height: GVMetrics.controlHeight - 16)
                .background {
                    Capsule().fill(GVTheme.bone.opacity(0.10))
                }
        }
        .buttonStyle(GVPressStyle())
        .contentShape(Rectangle())
        .accessibilityLabel("Mode \(player.mode.rawValue)")
        .accessibilityIdentifier("workspace.timeline.mode")
    }

    private var pickButton: some View {
        Button(action: onPickTimeline) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: GVMetrics.textValue * 1.043, weight: .black))
                .foregroundStyle(GVTheme.bone)
                .frame(width: GVMetrics.controlHeight - 12, height: GVMetrics.controlHeight - 12)
                .background {
                    RoundedRectangle(cornerRadius: GVMetrics.radiusTight, style: .continuous)
                        .fill(GVTheme.bone.opacity(0.10))
                }
        }
        .buttonStyle(GVPressStyle())
        .contentShape(Rectangle())
        .accessibilityLabel("Pick timeline")
        .accessibilityIdentifier("workspace.timeline.pick")
    }

    private var saveButton: some View {
        Button(action: onSaveTimeline) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: GVMetrics.textValue * 1.043, weight: .black))
                .foregroundStyle(GVTheme.bone)
                .frame(width: GVMetrics.controlHeight - 12, height: GVMetrics.controlHeight - 12)
                .background {
                    RoundedRectangle(cornerRadius: GVMetrics.radiusTight, style: .continuous)
                        .fill(GVTheme.bone.opacity(0.10))
                }
        }
        .buttonStyle(GVPressStyle())
        .contentShape(Rectangle())
        .accessibilityLabel("Save current composition as timeline")
        .accessibilityIdentifier("workspace.timeline.save")
    }

    /// The playhead. Nothing drove `scrub(to:)` before this existed — the bar
    /// printed a timecode and no track — so the operator could not get to a cue
    /// without starting the transport and hoping. A tap seeks as well as a drag
    /// because `minimumDistance` is zero, which is what lets one gesture cover both.
    @MainActor private var scrubTrack: some View {
        let duration = player.activeTimeline?.duration ?? player.selectedTimeline?.duration ?? 0
        let fraction = duration > 0 ? min(max(player.currentTime / duration, 0), 1) : 0

        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(GVTheme.bone.opacity(0.14))
                    .frame(height: GVMetrics.hairline * 2)
                Capsule()
                    .fill(GVTheme.bone.opacity(duration > 0 ? 0.5 : 0.14))
                    .frame(width: max(0, proxy.size.width * fraction), height: GVMetrics.hairline * 2)
                // A rule with no handle reads as progress that has stalled, not as
                // something to grab.
                if duration > 0 {
                    Circle()
                        .fill(GVTheme.bone)
                        .frame(width: GVMetrics.hairline * 2, height: GVMetrics.hairline * 2)
                        .offset(x: max(0, proxy.size.width * fraction - GVMetrics.hairline))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        let travelled = min(max(value.location.x / max(proxy.size.width, 1), 0), 1)
                        seek(to: travelled * duration)
                    }
            )
        }
        // The rule is 8pt; the hit area is 22 (GVMetrics.touchTarget - 22 padding).
        // Nothing here was meant to be hit at its drawn size.
        .frame(maxWidth: .infinity, minHeight: GVMetrics.touchTarget - 22)
        .accessibilityRepresentation {
            Slider(value: scrubBinding, in: 0 ... max(duration, 0.01), step: 0.05)
        }
        .accessibilityLabel("Timeline playhead")
        .accessibilityIdentifier("workspace.timeline.scrub")
    }

    /// VoiceOver and the finger drive one path, and one path drives the preview: the
    /// cue is interpolated and the frame it looks like is asked for together, so a
    /// moved playhead can never be showing a time it is not.
    @MainActor private var scrubBinding: Binding<Double> {
        Binding(
            get: { player.currentTime },
            set: { seek(to: $0) }
        )
    }

    /// Seeking the parameters and requesting the preview frame are one gesture, not
    /// two. The reader coalesces on its own — a drag issues more requests than a
    /// decoder can service, and the superseded ones answer without decoding — so
    /// there is nothing to throttle here beyond what that already costs.
    @MainActor private func seek(to time: TimeInterval) {
        player.scrub(to: time)
        cameraRuntime.requestPreviewFrame(at: time)
    }

    private var timecode: String {
        formatDuration(player.currentTime)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds * 100)
        let centi = total % 100
        let secs = (total / 100) % 60
        let mins = total / 6000
        return String(format: "%02d:%02d.%02d", mins, secs, centi)
    }

    private func nextMode(after mode: GVTimelinePlayer.Mode) -> GVTimelinePlayer.Mode {
        switch mode {
        case .loop: .oneShot
        case .oneShot: .paused
        case .paused: .loop
        }
    }
}
