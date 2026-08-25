import SwiftUI

/// Scrolls a block of arbitrary content upward, forever.
///
/// Two copies of the same content stacked and offset by elapsed time modulo one
/// copy's height, so the wrap lands on an identical frame and there is no seam
/// to see. This replaces `GVScrollingManifest`, which could only travel rows of
/// plain text — which is why the version header and the signature sat still
/// above a block that moved. Everything in the lower group travels together now.
///
/// The window is deliberately larger than the content. Rows crossing the top
/// and bottom edges are feathered rather than cut, so the block reads as a
/// continuous feed running behind the artwork instead of a panel with margins.
struct GVInfiniteColumn<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Height of the visible window. `nil` sizes the window to one copy of the
    /// content, which is what a block that should scroll in place — filling
    /// exactly the room it already occupies — wants.
    var windowHeight: CGFloat?
    /// Points per second. Slow enough to read, quick enough to be alive.
    var speed: Double = 11
    /// Fraction of the window each edge fades across. Small on purpose: a wide
    /// fade is what made the block look like it had empty margins.
    var feather: CGFloat = 0.07
    @ViewBuilder var content: () -> Content

    @State private var contentHeight: CGFloat = 0

    /// Falls back to the measured content height, so an unspecified window
    /// occupies exactly the space the block would have taken standing still.
    private var resolvedWindow: CGFloat? {
        windowHeight ?? (contentHeight > 0 ? contentHeight : nil)
    }

    var body: some View {
        Group {
            if reduceMotion || contentHeight <= 0 {
                // No travel under Reduce Motion. The block still reads; it just
                // does not move. Also the first-frame state, before the content
                // has been measured.
                column
                    .frame(height: resolvedWindow, alignment: .top)
                    .clipped()
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { timeline in
                    let travel = CGFloat(timeline.date.timeIntervalSinceReferenceDate * speed)
                        .truncatingRemainder(dividingBy: max(contentHeight, 1))

                    column
                        .offset(y: -travel)
                        .frame(height: resolvedWindow, alignment: .top)
                        .clipped()
                }
            }
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white, location: feather),
                    .init(color: .white, location: 1 - feather),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    /// Two copies, with the first reporting its own height.
    ///
    /// Measured from the live copy rather than a hidden third one: a hidden
    /// measurement view takes the window's height proposal, not the content's,
    /// and would report the window back as the wrap period.
    private var column: some View {
        VStack(spacing: 0) {
            content()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
            if !reduceMotion {
                content()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
