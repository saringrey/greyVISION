import SwiftUI

/// A bottom sheet that lists the saved `GVTimeline`s and lets the operator
/// play, rename, or delete them. Stays inside the existing `GVPresetsDrawer`
/// visual language (glass plates, mono labels) so it feels native to the app.
struct GVTimelinePickerSheet: View {
    @ObservedObject var store: GVTimelineStore
    @ObservedObject var player: GVTimelinePlayer
    let editor: EffectEditingSession
    let setup: CaptureSetupDraft
    let onClose: () -> Void

    @State private var renaming: GVTimeline?
    @State private var renameDraft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.timelines) { timeline in
                        timelineRow(timeline)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 24)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.078, green: 0.078, blue: 0.085).opacity(0.94))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }
        }
        .frame(maxHeight: 520)
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
                .font(.system(size: 13, weight: .black))
                .tracking(1.2)
                .foregroundStyle(.white)
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("workspace.timeline.picker.close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func timelineRow(_ timeline: GVTimeline) -> some View {
        let isActive = player.activeTimeline?.id == timeline.id
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(timeline.name)
                    .font(.system(size: 13, weight: .black))
                    .tracking(0.8)
                    .foregroundStyle(.white)
                HStack(spacing: 6) {
                    Text("\(Int(timeline.duration))s")
                    Text("·")
                    Text("\(timeline.keyframes.count) KF")
                    if timeline.isFactory {
                        Text("· FACTORY")
                    }
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
            }

            Spacer()

            Button {
                player.play(timeline)
            } label: {
                Image(systemName: isActive && player.isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 30)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isActive ? Color.red.opacity(0.65) : Color.white.opacity(0.18))
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isActive && player.isPlaying ? "Stop" : "Play")

            Button {
                renaming = timeline
                renameDraft = timeline.name
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.white.opacity(0.10))
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rename timeline")

            Button {
                store.delete(timeline.id)
                if player.activeTimeline?.id == timeline.id {
                    player.stop()
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.red.opacity(0.18))
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete timeline")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(isActive ? 0.45 : 0.08), lineWidth: 1)
                }
        }
    }
}
