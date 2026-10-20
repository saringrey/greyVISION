import SwiftUI

/// A bottom sheet that lists the saved `GVTimeline`s and lets the operator
/// play, rename, or delete them. Stays inside the existing `GVPresetsDrawer`
/// visual language (glass plates, mono labels) so it feels native to the app.
struct GVTimelinePickerSheet: View {
    @ObservedObject var store: GVTimelineStore
    @ObservedObject var player: GVTimelinePlayer
    let editor: EffectEditingSession
    let setup: CaptureSetupDraft
    /// Vertical budget handed down by the workspace, shared with the other two
    /// collection plates.
    let maximumHeight: CGFloat
    let onClose: () -> Void

    @State private var renaming: GVTimeline?
    @State private var renameDraft: String = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header

            GVDeckList(maxHeight: max(84, maximumHeight - 44)) {
                VStack(spacing: GVMetrics.gap) {
                    if store.timelines.isEmpty {
                        Text("No timelines saved yet")
                            .font(GVTheme.font(.control, scale: 0.8125))
                            .foregroundStyle(GVTheme.ash)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }
                    ForEach(store.timelines) { timeline in
                        timelineRow(timeline)
                    }
                }
                .padding(.horizontal, GVMetrics.screenInset + 2)
                .padding(.bottom, 8)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: GVMetrics.radiusPanel + 4, style: .continuous)
                .fill(GVTheme.surfacePrimary)
                .overlay {
                    RoundedRectangle(cornerRadius: GVMetrics.radiusPanel + 4, style: .continuous)
                        .strokeBorder(GVTheme.bone.opacity(0.12), lineWidth: GVMetrics.hairline)
                }
        }
        // The other two collection plates rise into the dock's space on this
        // exact transition; this one used to appear already in place.
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        .accessibilityIdentifier("workspace.timeline.picker")
        .alert("RENAME TIMELINE", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameDraft)
                .textInputAutocapitalization(.characters)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let timeline = renaming {
                    store.rename(timeline.id, to: renameDraft)
                }
                renaming = nil
            }
        }
    }

    private var header: some View {
        HStack {
            Text("TIMELINES")
                .font(GVTheme.font(.control, scale: 0.8125))
                .tracking(1.2)
                .foregroundStyle(GVTheme.bone)
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: GVMetrics.textValue * 1.565, weight: .regular))
                    .foregroundStyle(GVTheme.bone.opacity(0.55))
            }
            .buttonStyle(GVPressStyle())
            .contentShape(Rectangle())
            .accessibilityLabel("Close")
            .accessibilityIdentifier("workspace.timeline.picker.close")
        }
        .padding(.horizontal, GVMetrics.screenInset + 4)
        .padding(.top, GVMetrics.stepInternal)
        .padding(.bottom, GVMetrics.gapTight)
    }

    private func timelineRow(_ timeline: GVTimeline) -> some View {
        // Selection, not just playback, is the state the row reports: stopping the
        // transport leaves the timeline armed for scrubbing, and a row that went
        // quiet at that moment would look like the choice had been taken away.
        let isActive = (player.activeTimeline?.id ?? player.selectedTimeline?.id) == timeline.id
        return HStack(spacing: GVMetrics.gap) {
            Button {
                player.selectForScrub(timeline)
            } label: {
                VStack(alignment: .leading, spacing: GVMetrics.gapHair) {
                    Text(timeline.name)
                        .font(GVTheme.font(.control, scale: 0.8125))
                        .tracking(0.8)
                        .foregroundStyle(GVTheme.bone)
                    HStack(spacing: GVMetrics.gapTight) {
                        Text("\(Int(timeline.duration))s")
                        Text("·")
                        Text("\(timeline.keyframes.count) KF")
                        if timeline.isFactory {
                            Text("· FACTORY")
                        }
                    }
                    .font(GVTheme.font(.diagnostic, scale: 1.1765))
                    .foregroundStyle(GVTheme.bone.opacity(0.55))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(GVPressStyle())
            .contentShape(Rectangle())
            .accessibilityLabel("Scrub \(timeline.name)")

            Spacer()

            Button {
                // The glyph says Stop, so the press has to stop. Running
                // `play(timeline)` in every state meant a playing cue restarted
                // from zero on each tap and the row never went quiet.
                if isActive, player.isPlaying {
                    player.stop()
                } else {
                    player.play(timeline)
                    onClose()
                }
            } label: {
                Image(systemName: isActive && player.isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: GVMetrics.textValue * 1.13, weight: .black))
                    .foregroundStyle(GVTheme.bone)
                    .frame(width: GVMetrics.controlHeight - 4, height: GVMetrics.cardHeight - 16)
                    .background {
                        RoundedRectangle(cornerRadius: GVMetrics.radiusTight, style: .continuous)
                            .fill(isActive ? GVTheme.record.opacity(0.65) : GVTheme.bone.opacity(0.18))
                    }
            }
            .buttonStyle(GVPressStyle())
            .contentShape(Rectangle())
            .accessibilityLabel(isActive && player.isPlaying ? "Stop" : "Play")
            .accessibilityIdentifier("workspace.timeline.picker.play.\(timeline.id.uuidString)")

            Button {
                renaming = timeline
                renameDraft = timeline.name
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: GVMetrics.textValue * 1.043, weight: .black))
                    .foregroundStyle(GVTheme.bone)
                    .frame(width: GVMetrics.cardHeight - 6, height: GVMetrics.cardHeight - 6)
                    .background {
                        RoundedRectangle(cornerRadius: GVMetrics.radiusTight, style: .continuous)
                            .fill(GVTheme.bone.opacity(0.10))
                    }
            }
            .buttonStyle(GVPressStyle())
            .contentShape(Rectangle())
            .accessibilityLabel("Rename timeline")

            Button {
                store.delete(timeline.id)
                player.deselect(timeline)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: GVMetrics.textValue * 1.043, weight: .black))
                    .foregroundStyle(GVTheme.bone)
                    .frame(width: GVMetrics.cardHeight - 6, height: GVMetrics.cardHeight - 6)
                    .background {
                        RoundedRectangle(cornerRadius: GVMetrics.radiusTight, style: .continuous)
                            .fill(GVTheme.record.opacity(0.18))
                    }
            }
            .buttonStyle(GVPressStyle())
            .contentShape(Rectangle())
            .accessibilityLabel("Delete timeline")
        }
        .padding(.horizontal, GVMetrics.gap)
        .padding(.vertical, GVMetrics.gapTight)
        .background {
            RoundedRectangle(cornerRadius: GVMetrics.radius, style: .continuous)
                .fill(isActive ? GVTheme.bone.opacity(0.12) : GVTheme.bone.opacity(0.04))
                .overlay {
                    RoundedRectangle(cornerRadius: GVMetrics.radius, style: .continuous)
                        .strokeBorder(GVTheme.bone.opacity(isActive ? 0.45 : 0.08), lineWidth: GVMetrics.hairline)
                }
        }
    }
}
