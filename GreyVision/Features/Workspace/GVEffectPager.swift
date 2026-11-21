import SwiftUI

/// A grid that pages sideways instead of scrolling down.
///
/// Columns and rows are solved from the space the panel actually has, so a
/// page is always exactly full-screen: no tile is ever half off the bottom
/// edge, and the operator sees how far a shelf goes from the page meter
/// instead of discovering it by scrolling.
struct GVEffectPager<Item: Identifiable, Tile: View>: View {
    let items: [Item]
    /// A new value resets to the first page — a new shelf or a new search.
    let resetKey: String
    var minimumTile: CGFloat = 78
    var spacing: CGFloat = 8
    @ViewBuilder let tile: (Item, Int) -> Tile

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: Int? = 0

    private static var meterHeight: CGFloat { 22 }

    struct Layout: Equatable {
        let columns: Int
        let rows: Int
        let side: CGFloat
        /// Rows stretch or squeeze a little from square so a page fills the
        /// panel exactly instead of leaving a band of dead space under it.
        let rowHeight: CGFloat

        init(size: CGSize, minimumTile: CGFloat, spacing: CGFloat) {
            let columns = max(Int((size.width + spacing) / (minimumTile + spacing)), 3)
            let side = max((size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns), 1)
            self.columns = columns
            self.side = side
            let rows = max(Int(((size.height + spacing) / (side + spacing)).rounded()), 1)
            self.rows = rows
            rowHeight = max((size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows), 1)
        }

        var perPage: Int { columns * rows }
    }

    var body: some View {
        GeometryReader { geometry in
            let gridSize = CGSize(width: geometry.size.width, height: max(geometry.size.height - Self.meterHeight - 8, 1))
            let layout = Layout(size: gridSize, minimumTile: minimumTile, spacing: spacing)
            let pages = max((items.count + layout.perPage - 1) / layout.perPage, 1)
            VStack(spacing: 8) {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(0 ..< pages, id: \.self) { index in
                            pageView(index, layout: layout)
                                .frame(width: gridSize.width, height: gridSize.height, alignment: .top)
                                .scrollTransition(.interactive, axis: .horizontal) { [reduceMotion] content, phase in
                                    // Smoothstep keeps the page flat near rest and gives
                                    // a reversing swipe the same continuous depth curve.
                                    let distance = min(abs(phase.value), 1)
                                    let depth = distance * distance * (3 - 2 * distance)
                                    return content
                                        .opacity(1 - depth * (reduceMotion ? 0.08 : 0.18))
                                        .scaleEffect(reduceMotion ? 1 : 1 - depth * 0.035)
                                        .rotation3DEffect(
                                            .degrees(reduceMotion ? 0 : phase.value * 3),
                                            axis: (x: 0, y: 1, z: 0), perspective: 0.25
                                        )
                                }
                                .id(index)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $page)
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                meter(pages: pages)
            }
            .onChange(of: layout.perPage) { _, _ in jump(to: 0) }
            .onChange(of: pages) { _, count in
                if let page, page >= count { jump(to: count - 1) }
            }
        }
        .onChange(of: resetKey) { _, _ in jump(to: 0) }
    }

    /// Shelf changes and resizing replace content in place instead of
    /// inheriting a parent animation and travelling through unrelated pages.
    private func jump(to index: Int) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { page = index }
    }

    private func pageView(_ index: Int, layout: Layout) -> some View {
        let start = index * layout.perPage
        let slice = items[min(start, items.count) ..< min(start + layout.perPage, items.count)]
        // Laziness belongs at the page boundary. Building the small, bounded
        // grid together keeps rows from appearing halfway through a swipe.
        return Grid(alignment: .topLeading, horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(0 ..< layout.rows, id: \.self) { row in
                GridRow {
                    let rowStart = row * layout.columns
                    let rowItems = slice.dropFirst(rowStart).prefix(layout.columns)
                    ForEach(Array(rowItems.enumerated()), id: \.element.id) { offset, item in
                        tile(item, start + rowStart + offset)
                            .frame(width: layout.side, height: layout.rowHeight)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // A new shelf replays its entrance rather than diffing tiles in place.
        .id("\(resetKey)-\(index)")
    }

    /// The page meter: one segment per page, the current one long and lit,
    /// and a readout of where the operator is. Segments are tappable jumps.
    private func meter(pages: Int) -> some View {
        let current = min(page ?? 0, pages - 1)
        return HStack(spacing: 6) {
            Text(String(format: "%02d", items.count))
                .font(GVTheme.mono(10, .semibold))
                .foregroundStyle(GVTheme.bone.opacity(0.8))
                .monospacedDigit()
                .contentTransition(.numericText())
            Spacer(minLength: 4)
            if pages > 1, pages <= 18 {
                HStack(spacing: 4) {
                    ForEach(0 ..< pages, id: \.self) { index in
                        Button {
                            if reduceMotion {
                                jump(to: index)
                            } else {
                                withAnimation(GVMotion.cinematic) { page = index }
                            }
                        } label: {
                            Capsule()
                                .fill(GVTheme.bone.opacity(index == current ? 0.95 : 0.22))
                                .frame(width: index == current ? 18 : 6, height: 4)
                                .frame(height: Self.meterHeight)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Page \(index + 1)")
                    }
                }
            }
            Spacer(minLength: 4)
            Text("\(current + 1)/\(pages)")
                .font(GVTheme.mono(10, .medium))
                .foregroundStyle(GVTheme.bone.opacity(0.55))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(height: Self.meterHeight)
        .padding(.horizontal, 4)
        .animation(GVMotion.resolved(GVMotion.normal, reduceMotion: reduceMotion), value: current)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page \(current + 1) of \(pages), \(items.count) effects")
        .accessibilityIdentifier("workspace.browser.pages")
    }
}
