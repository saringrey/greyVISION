import AVKit
import SwiftUI

/// The take library: every movie the instrument has written, whether or not
/// Photos accepted it.
///
/// Reviewing a take is the half of recording that this app used to drop on the
/// floor — footage existed only inside the session that made it, and a denied
/// Photos permission deleted it. Rows are ordered newest first, the selected
/// take plays in place, and the export retry works on the original file rather
/// than a copy.
struct GVTakeLibrarySheet: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = GVTakeLibraryModel()
    @State private var selected: GVTake?
    @State private var player: AVPlayer?
    @State private var pendingDelete: GVTake?

    /// Vertical budget handed down by the workspace, shared with the other two
    /// collection plates.
    let maximumHeight: CGFloat
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            header
            if let selected {
                reviewPanel(selected)
            }
            list
            footer
        }
        .gvCompactDeckPlate()
        .padding(.horizontal, 6)
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        .task {
            model.followArchiveChanges()
            await model.refresh()
        }
        .onDisappear {
            model.stopFollowingArchiveChanges()
            player?.pause()
        }
        .confirmationDialog(
            "Delete this take?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { take in
            Button("Delete \(take.source.label) \(take.kind.isMovie ? "take" : "still")", role: .destructive) {
                Task {
                    await model.delete(take)
                    if selected?.id == take.id { clearSelection() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { take in
            Text("Removes the \(take.kind.isMovie ? "movie" : "photograph") from this device. \(take.photosStatus == .saved ? "It stays in your Photos library." : "It has never been exported.")")
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Text(model.isLoading ? "Takes · Loading" : "Takes · \(model.takes.count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(GVTheme.bone)
            Spacer(minLength: 6)
            GVDeckChip(label: "", symbol: "arrow.clockwise", id: "takes.refresh") {
                Task { await model.refresh() }
            }
            GVDeckChip(label: "", symbol: "xmark", id: "takes.close") {
                clearSelection()
                onClose()
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        if model.takes.isEmpty, !model.isLoading {
            VStack(spacing: 6) {
                Text("NO TAKES YET")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(GVTheme.bone.opacity(0.85))
                Text("Recordings and stills are kept here even when Photos refuses them.")
                    .font(.system(size: 11))
                    .foregroundStyle(GVTheme.ash)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
        } else {
            // A selected take buys itself a player panel out of the same
            // budget, so the list gives the difference back.
            GVDeckList(maxHeight: max(84, maximumHeight - (selected == nil ? 132 : 340))) {
                VStack(spacing: 5) {
                    ForEach(model.takes) { take in
                        takeRow(take)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func takeRow(_ take: GVTake) -> some View {
        let isSelected = selected?.id == take.id
        return Button {
            select(take)
        } label: {
            HStack(spacing: 8) {
                TakePoster(take: take, model: model)
                    .frame(width: 56, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(take.kind.isMovie ? take.source.label : "\(take.source.label) still")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    Text(Self.dateFormatter.string(from: take.createdAt))
                        .font(.system(size: 11))
                        .foregroundStyle(GVTheme.ash)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                statusMark(take)
            }
            .padding(.horizontal, 8)
            .frame(height: 48)
            .gvGlassChip(radius: 8, active: isSelected, tint: .white)
        }
        .buttonStyle(GVPressStyle())
        .accessibilityIdentifier("take.row.\(take.id.uuidString)")
        .accessibilityLabel(
            "\(take.source.label) \(take.kind.isMovie ? "take" : "still"), "
                + Self.dateFormatter.string(from: take.createdAt)
        )
        .accessibilityValue(accessibilityStatus(take))
    }

    /// The frame of a still, read through the same poster path the rows use.
    private func reviewImage(_ take: GVTake) -> some View {
        TakePoster(take: take, model: model)
            .frame(maxWidth: .infinity)
            .frame(height: 168)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityIdentifier("take.still")
    }

    private func statusMark(_ take: GVTake) -> some View {
        let (symbol, color) = switch take.photosStatus {
        case .saved: ("checkmark.circle.fill", GVTheme.acid)
        case .pending: ("clock", GVTheme.bone.opacity(0.6))
        case .failed: ("exclamationmark.arrow.circlepath", GVTheme.warn)
        }
        return Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(color)
    }

    private func accessibilityStatus(_ take: GVTake) -> String {
        switch take.photosStatus {
        case .saved: "Saved to Photos"
        case .pending: "Export not finished"
        case .failed: "Kept on device, Photos export failed"
        }
    }

    private func reviewPanel(_ take: GVTake) -> some View {
        VStack(spacing: 6) {
            if take.kind.isMovie {
                VideoPlayer(player: player)
                    .frame(height: 168)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityIdentifier("take.player")
            } else {
                // A still has no timeline to scrub, so the frame itself is the
                // review. ScaledAspect keeps a portrait photograph portrait.
                reviewImage(take)
            }

            HStack(spacing: 6) {
                Text(take.photosStatus == .saved ? "In Photos" : "On this device only")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(take.photosStatus == .saved ? GVTheme.acid : GVTheme.warn)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if take.photosStatus != .saved {
                    GVDeckChip(label: "Save", symbol: "square.and.arrow.down", id: "take.export.\(take.id.uuidString)") {
                        Task { await model.exportToPhotos(take) }
                    }
                }
                ShareLink(item: model.url(for: take)) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: GVMetrics.textSmall, weight: .bold))
                        .foregroundStyle(GVTheme.bone.opacity(0.85))
                        .frame(width: 34, height: 30)
                }
                .accessibilityLabel("Share take")
                .accessibilityIdentifier("take.share.\(take.id.uuidString)")

                GVDeckChip(label: "", symbol: "trash", id: "take.delete.\(take.id.uuidString)") {
                    pendingDelete = take
                }
            }
        }
        .padding(8)
        .gvGlassChip(radius: 10, active: true, tint: .white)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(footerHint)
                .font(.system(size: 11))
                .foregroundStyle(GVTheme.ash.opacity(0.85))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    /// One line that says what the plate can do right now, rather than
    /// inviting a tap on a take that is already up.
    private var footerHint: String {
        if let notice = model.notice { return notice }
        if selected != nil { return "Tap the row again to close the review" }
        return model.takes.isEmpty
            ? "Recorded takes land here, whether or not Photos takes them"
            : "Tap a take to review it"
    }

    private func select(_ take: GVTake) {
        if selected?.id == take.id {
            clearSelection()
            return
        }
        player?.pause()
        player = nil
        selected = take
        guard take.kind.isMovie else { return }
        let newPlayer = AVPlayer(url: model.url(for: take))
        player = newPlayer
        newPlayer.play()
    }

    private func clearSelection() {
        player?.pause()
        player = nil
        selected = nil
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// One frame out of the movie, generated on demand and cached by the model.
/// A library of unlabelled rows is a list of UUIDs; the poster is what makes a
/// take recognisable without opening it.
private struct TakePoster: View {
    let take: GVTake
    let model: GVTakeLibraryModel

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .overlay {
                        Image(systemName: take.kind.isMovie ? "film" : "photo")
                            .font(.system(size: 12))
                            .foregroundStyle(GVTheme.ash.opacity(0.7))
                    }
            }
        }
        .task(id: take.id) {
            guard image == nil else { return }
            image = await model.poster(for: take)
        }
        .accessibilityHidden(true)
    }
}
