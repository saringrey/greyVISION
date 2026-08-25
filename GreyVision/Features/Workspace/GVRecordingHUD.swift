import SwiftUI

/// What the instrument looks like mid-take.
///
/// The effect browser is already collapsed by this point. What replaces it is
/// not more chrome but a summary: the mark, a running timecode, and a single
/// line naming what is actually being applied to the image. Everything else
/// gets out of the way of the frame.
///
/// One `TimelineView` at 2 Hz drives the timecode. A per-second clock is
/// enough for `HH:MM:SS` and costs nothing next to the render path.
struct GVRecordingHUD: View {
    @EnvironmentObject private var cameraRuntime: CameraRuntime
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let startedAt: Date?
    /// Names of the effects currently running, in stack order.
    let activeEffects: [String]
    let geometry: GeometryProxy

    /// The mark and the timecode, sized and placed to sit in the shoulders
    /// either side of the Dynamic Island.
    ///
    /// Rendered in the same slot as the workspace's own top row rather than as
    /// a separate overlay with its own padding — that is what dropped it half
    /// an inch the moment RECORD was pressed, so the interface appeared to
    /// slump rather than swap.
    var body: some View {
        let portrait = geometry.size.width < geometry.size.height
        let compact = geometry.size.width < 400
        let islandReserve = portrait
            ? min(max(geometry.size.width * 0.30, compact ? 104 : 122), 146)
            : 0

        return header(portrait: portrait, compact: compact, islandReserve: islandReserve)
            .allowsHitTesting(false)
            .accessibilityElement(children: .contain)
    }

    /// The bottom line naming what is on the image. Separate from the header
    /// because it belongs at the other end of the screen.
    @ViewBuilder
    var summary: some View {
        if !activeEffects.isEmpty {
            effectSummary
        }
    }

    // MARK: - Header

    private func header(portrait: Bool, compact: Bool, islandReserve: CGFloat) -> some View {
        let panelHeight: CGFloat = portrait ? 56 : 50
        let horizontalInset: CGFloat = portrait ? 12 : 11

        return TimelineView(.periodic(from: .now, by: reduceMotion ? 1 : 0.5)) { timeline in
            HStack(spacing: 0) {
                HStack {
                    GVCyclingWordmark(
                        text: "grey//VISION",
                        size: portrait ? (compact ? 13.2 : 14.5) : 11.4,
                        tracking: portrait ? 0.34 : 0.5
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Color.clear
                    .frame(width: islandReserve)
                    .accessibilityHidden(true)

                HStack(spacing: GVMetrics.stepRelated) {
                    Circle()
                        .fill(GVTheme.record)
                        .frame(width: 8, height: 8)
                        .opacity(blinkOpacity(at: timeline.date))
                        .shadow(color: GVTheme.record.opacity(0.8), radius: 5)

                    Text(timecode(at: timeline.date))
                        .gvFont(.control)
                        .monospacedDigit()
                        .foregroundStyle(GVTheme.bone)
                        .lineLimit(1)
                        .fixedSize()
                }
                .fixedSize()
            }
            .padding(.horizontal, horizontalInset)
            .frame(height: panelHeight)
            .shadow(color: .black.opacity(0.85), radius: 3)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recording \(timecode(at: timeline.date))")
        }
    }

    /// One line naming what is on the image, so the operator can see the
    /// treatment without reopening the browser they just collapsed.
    private var effectSummary: some View {
        HStack(spacing: GVMetrics.stepSection) {
            ForEach(activeEffects.prefix(4), id: \.self) { name in
                Text(name.uppercased())
                    .gvFont(.diagnostic)
                    .tracking(GVTheme.TypeLevel.diagnostic.tracking)
                    .foregroundStyle(GVTheme.violet)
            }
        }
        .shadow(color: .black.opacity(0.9), radius: 3)
        .frame(maxWidth: .infinity)
        .padding(.bottom, GVMetrics.stepSection)
    }

    // MARK: - Time

    private func timecode(at date: Date) -> String {
        guard let startedAt else { return "00:00:00" }
        let total = Int(date.timeIntervalSince(startedAt))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    private func blinkOpacity(at date: Date) -> Double {
        guard !reduceMotion else { return 1 }
        return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : 0.25
    }
}
