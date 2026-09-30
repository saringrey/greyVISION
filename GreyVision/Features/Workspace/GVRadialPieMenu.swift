import SwiftUI

/// State for the transient radial menu overlay. The workspace owns one
/// coordinator rather than separately owning menu, drag, release, and family
/// state.
struct GVRadialPieMenuState {
    let center: CGPoint
    /// Per-entry-point menu-center offset: the dock holds the ring clear of
    /// the rail; the preview spawns it around the finger.
    let centerOffset: CGVector
    let title: String
    let slots: [GVRadialPieMenu.Slot]
    let subcategories: [GVRadialSubcategory]
    /// Non-empty only for the preview hold, which opens on the 7 umbrella
    /// families (root tier). The dock hold arms a single family directly
    /// and leaves this empty.
    let families: [GVRadialFamily]
    let onSelect: (WorkspaceAdjustableEffect) -> Void
}

/// Single owner for the radial interaction's cross-view state.
@MainActor
final class GVRadialMenuCoordinator: ObservableObject {
    @Published private(set) var menu: GVRadialPieMenuState?
    @Published var dragLocation: CGPoint?
    @Published var releaseLocation: CGPoint?

    func begin(
        family: GVRadialEffectFamily,
        center: CGPoint,
        isActive: @escaping (WorkspaceAdjustableEffect) -> Bool,
        onSelect: @escaping (WorkspaceAdjustableEffect) -> Void
    ) {
        releaseLocation = nil
        dragLocation = center
        menu = GVRadialPieMenuState(
            center: center,
            centerOffset: GVRadialMenuLayout.centerOffset,
            title: family.title,
            slots: family.effects.map {
                GVRadialPieMenu.Slot(
                    id: "\(family.title)-\($0.rawValue)",
                    effect: $0,
                    isActive: isActive($0)
                )
            },
            subcategories: EffectCatalog.radialSubcategories(title: family.title, effects: family.effects),
            families: [],
            onSelect: onSelect
        )
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.72)
    }

    /// Preview hold: opens on the 7 umbrella families (root tier) instead of
    /// a single armed family. Signatures of begin/move/end/dismiss are stable;
    /// this is an additional entry point, not a replacement.
    func beginRoot(
        center: CGPoint,
        isActive: @escaping (WorkspaceAdjustableEffect) -> Bool,
        onSelect: @escaping (WorkspaceAdjustableEffect) -> Void
    ) {
        releaseLocation = nil
        dragLocation = center
        var families = GVRadialFamily.previewRoot()
        // The menu must ALWAYS appear, never an empty ring. If the curated
        // root ever resolves empty, fall back to the largest static shelf as
        // a single family — same shape as begin(family:).
        if families.isEmpty, let fallback = GVRadialFamily.largestShelfFallback() {
            families = [fallback]
        }
        menu = GVRadialPieMenuState(
            center: center,
            centerOffset: GVRadialMenuLayout.previewCenterOffset,
            title: "EFFECTS",
            slots: families.flatMap(\.effects).map {
                GVRadialPieMenu.Slot(
                    id: "root-\($0.rawValue)",
                    effect: $0,
                    isActive: isActive($0)
                )
            },
            subcategories: [],
            families: families,
            onSelect: onSelect
        )
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.72)
    }

    func move(to location: CGPoint) {
        guard menu != nil else { return }
        dragLocation = location
    }

    func end(at location: CGPoint) {
        guard menu != nil else { return }
        releaseLocation = location
        dragLocation = nil
    }

    func dismiss() {
        menu = nil
        dragLocation = nil
        releaseLocation = nil
    }

    func cancel() {
        dismiss()
    }
}

/// A single true circle around a decoupled menu center held clear of the
/// thumb. Slots are evenly spaced on one ring, with one angular gap centered
/// on the thumb direction — the right thumb's pad and its lower-right
/// approach stay empty so no slot ever spawns under the hand. The release
/// corridor (`thumbOcclusion`) doubles as the cancel zone.
struct GVRadialMenuLayout {
    let invocationPoint: CGPoint
    /// Decoupled menu center: touch point shifted per entry point, then
    /// clamped so the whole ring stays inside the safe rect.
    let menuCenter: CGPoint
    let itemSize: CGFloat
    let thumbClearance: CGFloat
    let thumbOcclusion: CGRect
    let slotCenters: [CGPoint]
    /// Radius of the ring the slots sit on. Exposed for the tests.
    let ringRadius: CGFloat
    /// Direction from the menu center toward the touch point, in radians.
    /// The angular gap that keeps the thumb's sector empty is centered here.
    let thumbAngle: CGFloat

    /// Distance push-through: drag farther than this from the touch point
    /// into a highlighted subcategory wedge expands to its variants.
    static let pushThroughDistance: CGFloat = 48
    /// Dragging back within this distance of the touch point at variant
    /// level returns to categories. Also the release deadzone radius.
    static let backDistance: CGFloat = 34
    /// Up-left decoupling offset applied to the touch point.
    /// Dock default: the ring holds clear of the bottom rail. The preview
    /// path passes previewCenterOffset instead so the ring spawns around
    /// the finger.
    static let centerOffset = CGVector(dx: -72, dy: -128)
    /// Preview-hold offset: near the finger, still clear of the thumb pad.
    static let previewCenterOffset = CGVector(dx: 0, dy: -40)
    /// Per-entry-point offset applied to the touch point. Defaults to the
    /// dock value; the preview hold passes previewCenterOffset.
    let centerOffsetValue: CGVector

    var slotFrames: [CGRect] {
        slotCenters.map {
            CGRect(x: $0.x - itemSize / 2, y: $0.y - itemSize / 2, width: itemSize, height: itemSize)
        }
    }

    init(
        invocationPoint: CGPoint,
        viewportSize: CGSize,
        itemSize: CGFloat,
        slotCount: Int,
        thumbClearance: CGFloat = 40,
        edgeInset: CGFloat = 20,
        safeAreaInsets: EdgeInsets = EdgeInsets(),
        centerOffset: CGVector = Self.centerOffset
    ) {
        self.invocationPoint = invocationPoint
        self.itemSize = itemSize
        self.thumbClearance = thumbClearance
        self.centerOffsetValue = centerOffset
        // Reserve the thumb pad and its near lower-right approach, not the
        // entire quadrant of the screen (which made top-left holds empty).
        let occlusion = CGRect(
            x: invocationPoint.x - 28,
            y: invocationPoint.y - 28,
            width: 112,
            height: 112
        )
        thumbOcclusion = occlusion

        let half = itemSize / 2
        let spacing = itemSize + 8
        let inset = half + edgeInset
        let safeRect = CGRect(
            x: inset + safeAreaInsets.leading,
            y: inset + safeAreaInsets.top,
            width: max(0, viewportSize.width - inset * 2 - safeAreaInsets.leading - safeAreaInsets.trailing),
            height: max(0, viewportSize.height - inset * 2 - safeAreaInsets.top - safeAreaInsets.bottom)
        )
        let rawCenter = CGPoint(
            x: invocationPoint.x + centerOffset.dx,
            y: invocationPoint.y + centerOffset.dy
        )

        // The thumb zone: the touch pad plus half a slot and a small slop, so
        // no slot frame can slide under the thumb. The angular gap is sized so
        // every ring point inside this disc falls inside the gap.
        let forbidden = thumbClearance + half + 8
        // The center hub (~52pt across) must not touch slot frames.
        let minRadius = half + 46

        /// Half the angular gap needed at ring radius `r` when the touch is
        /// `d` from the center. When the ring clears the thumb disc outright,
        /// only a slot's angular half-width is reserved.
        func gapHalfAngle(radius r: CGFloat, distance d: CGFloat) -> CGFloat {
            let frameMargin = asin(min(1, (half + 6) / max(r, 1)))
            guard d > 1 else { return .pi * 0.35 }
            let cosine = (r * r + d * d - forbidden * forbidden) / (2 * r * d)
            if cosine >= 1 { return frameMargin }
            if cosine <= -1 { return .pi * 0.75 }
            return acos(cosine) + frameMargin
        }

        // Initial center estimate (safe-rect clamp) so the touch distance and
        // direction are close before the radius decides the final clamp.
        var center = CGPoint(
            x: min(max(rawCenter.x, safeRect.minX), safeRect.maxX),
            y: min(max(rawCenter.y, safeRect.minY), safeRect.maxY)
        )
        // A degenerate safe rect (zero area) has no clamp range; fall back
        // to the raw offset point so layout never emits NaN.
        if safeRect.isNull { center = rawCenter }
        var distance = hypot(invocationPoint.x - center.x, invocationPoint.y - center.y)

        // Ring radius: prefer clearing the thumb disc outright so the gap is
        // just the slot frame margin; grow until the remaining arc fits the
        // slot count at full spacing. Iterated because the gap depends on the
        // radius and the radius on the gap.
        // Start from the spacing-driven radius with a 100° gap guess, then
        // grow to whatever the exact gap requires. (Starting from the
        // thumb-clearing radius would waste drag distance on dock holds,
        // where the touch is far from the hub.)
        let initialStep = max(0.2, (2 * CGFloat.pi - 100 * .pi / 180) / CGFloat(max(slotCount, 1)))
        var radius = slotCount > 1
            ? max(minRadius, spacing / (2 * sin(min(initialStep / 2, .pi / 2))))
            : minRadius
        for _ in 0 ..< 3 {
            let gap = min(2 * gapHalfAngle(radius: radius, distance: distance), .pi * 1.5)
            let usableArc = 2 * CGFloat.pi - gap
            guard slotCount > 1, usableArc > 0.1 else { break }
            // Chord spacing, not arc length: the straight-line distance
            // between neighbours is what keeps frames from overlapping.
            let step = usableArc / CGFloat(slotCount)
            let needed = spacing / (2 * sin(min(step / 2, .pi / 2)))
            if needed <= radius { break }
            radius = needed
        }

        // Keep the ring on screen: cap the radius at what the viewport can
        // hold, then clamp the center by that radius so every ring point
        // lands inside the safe rect.
        if !safeRect.isNull {
            let fitRadius = max(minRadius, min(safeRect.width, safeRect.height) / 2 - 1)
            radius = min(radius, fitRadius)
            let minX = safeRect.minX + radius, maxX = safeRect.maxX - radius
            let minY = safeRect.minY + radius, maxY = safeRect.maxY - radius
            center = CGPoint(
                x: minX <= maxX ? min(max(rawCenter.x, minX), maxX) : safeRect.midX,
                y: minY <= maxY ? min(max(rawCenter.y, minY), maxY) : safeRect.midY
            )
        }
        menuCenter = center
        distance = hypot(invocationPoint.x - center.x, invocationPoint.y - center.y)
        let angleToThumb = atan2(invocationPoint.y - center.y, invocationPoint.x - center.x)
        thumbAngle = angleToThumb
        ringRadius = radius

        // One circle: slots evenly spaced over the arc that remains after the
        // thumb-direction gap, so the wedge under the hand stays empty.
        let gap = min(2 * gapHalfAngle(radius: radius, distance: distance), .pi * 1.5)
        let usableArc = 2 * CGFloat.pi - gap
        var result: [CGPoint] = []
        if slotCount == 1 {
            // Directly opposite the thumb.
            let angle = angleToThumb + .pi
            result.append(CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
        } else if slotCount > 1 {
            let start = angleToThumb + gap / 2
            let step = usableArc / CGFloat(slotCount)
            for index in 0 ..< slotCount {
                let angle = start + (CGFloat(index) + 0.5) * step
                result.append(CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
            }
        }
        slotCenters = result
    }
}

/// The effect family armed by a category tap. Arming a family does not select
/// an effect; selection only happens when the radial hold ends over a slot.
struct GVRadialEffectFamily {
    let title: String
    let effects: [WorkspaceAdjustableEffect]
}

/// One category on the preview hold's root ring. Same shape as a subcategory
/// (title + hue + glyph + member effects) so the ring, hover, and release
/// machinery is shared; only the tier differs.
struct GVRadialFamily {
    let title: String
    let effects: [WorkspaceAdjustableEffect]
    let hue: GVTheme.RadialHue
    let glyph: GVEffectGlyphKind
    /// The groups an umbrella expands into (curated subcategories of its
    /// member shelves, or one flat group per small shelf). Empty only for the
    /// fallback family, which expands straight to its effects.
    var groups: [GVRadialSubcategory] = []

    /// The preview root ring: the 10 static shelves consolidated into 7
    /// umbrella families (COLOR+OPTICS, TIME, MOTION, SIGNAL+DECAY, FORM,
    /// SHADERS, AUDIO+SCOPE). Grouping is by what an effect does to the image —
    /// color and lens character, time, movement, transmission failure, shape,
    /// generative shaders, and everything audio-driven (filters plus the
    /// scopes that visualise the signal).
    static func previewRoot() -> [GVRadialFamily] {
        let umbrellas: [(title: String, shelves: [String], hue: GVTheme.RadialHue)] = [
            ("COLOR", ["COLOR", "OPTICS"], .rose),
            ("TIME", ["TIME"], .magenta),
            ("MOTION", ["MOTION"], .sky),
            ("SIGNAL", ["SIGNAL", "DECAY"], .amber),
            ("FORM", ["FORM"], .plum),
            ("SHADERS", ["SHADERS"], .lime),
            ("AUDIO", ["AUDIO", "SCOPE"], .teal)
        ]
        var seen = Set<WorkspaceAdjustableEffect>()
        return umbrellas.compactMap { title, shelfLabels, hue in
            var effects: [WorkspaceAdjustableEffect] = []
            var groups: [GVRadialSubcategory] = []
            for label in shelfLabels {
                guard let shelf = EffectCatalog.shelves.first(where: { $0.label == label }) else { continue }
                let shelfEffects = shelf.effects
                    .flatMap(EffectCatalog.variants)
                    .filter { seen.insert($0).inserted }
                effects += shelfEffects
                let subgroups = EffectCatalog.radialSubcategories(title: label, effects: shelfEffects)
                if subgroups.isEmpty {
                    // Small shelves have no curated groups: one flat group
                    // under the shelf's own name keeps every effect reachable.
                    groups.append(GVRadialSubcategory(
                        title: label,
                        hue: hue,
                        glyph: shelfEffects.first.map(GVEffectGlyphKind.kind(for:)) ?? .frame,
                        effects: shelfEffects
                    ))
                } else {
                    groups += subgroups
                }
            }
            guard !effects.isEmpty else { return nil }
            return GVRadialFamily(
                title: title,
                effects: effects,
                hue: hue,
                glyph: effects.first.map(GVEffectGlyphKind.kind(for:)) ?? .frame,
                groups: groups
            )
        }
    }

    /// Fallback when the curated root ever resolves empty: the largest
    /// static shelf as a single family, same shape as begin(family:), so
    /// the menu always appears instead of an empty ring.
    static func largestShelfFallback() -> GVRadialFamily? {
        let order = ["COLOR", "TIME", "MOTION", "DECAY", "SIGNAL", "OPTICS", "FORM", "SHADERS", "AUDIO", "SCOPE"]
        let hues: [String: GVTheme.RadialHue] = [
            "COLOR": .rose, "TIME": .magenta, "MOTION": .sky, "DECAY": .ember,
            "SIGNAL": .amber, "OPTICS": .azure, "FORM": .plum, "SHADERS": .lime,
            "AUDIO": .teal, "SCOPE": .cyan
        ]
        guard let shelf = EffectCatalog.shelves
            .filter({ $0.effects.isEmpty == false })
            .max(by: {
                let lhs = $0.effects.flatMap(EffectCatalog.variants).count
                let rhs = $1.effects.flatMap(EffectCatalog.variants).count
                if lhs == rhs {
                    return (order.firstIndex(of: $0.label) ?? 0) > (order.firstIndex(of: $1.label) ?? 0)
                }
                return lhs < rhs
            })
        else { return nil }
        var seen = Set<WorkspaceAdjustableEffect>()
        let effects = shelf.effects
            .flatMap(EffectCatalog.variants)
            .filter { seen.insert($0).inserted }
        guard !effects.isEmpty else { return nil }
        return GVRadialFamily(
            title: shelf.label,
            effects: effects,
            hue: hues[shelf.label] ?? .sand,
            glyph: effects.first.map(GVEffectGlyphKind.kind(for:)) ?? .frame
        )
    }
}

/// One selectable entry on the radial ring. At category level an entry groups
/// a subcategory's variants; at variant level it is a single effect.
struct GVRadialEntry: Identifiable {
    let id: String
    let title: String
    let hue: Color
    let glyph: GVEffectGlyphKind
    let count: Int
    let effect: WorkspaceAdjustableEffect?
    let isActive: Bool
}

/// Full-screen picker summoned by holding an effect-family button (dock) or
/// the preview (workspace).
///
/// The dock ring has two levels. It first shows the family's subcategories — large,
/// color-coded, with a count badge. Pushing more than 48pt from the touch
/// point into a highlighted subcategory wedge expands that group's effects in
/// the same ring, tinted with the subcategory hue; the center hub becomes a
/// back target and dragging back within 34pt of the touch point returns to
/// categories. The preview ring adds a root tier above this: it first shows
/// the 7 umbrella families, and pushing into one expands its subgroups (or
/// its direct effects ring for small families); dragging back from the
/// subgroups returns to the categories. Releasing over an effect selects it; releasing in the center
/// deadzone, the SE cancel corridor, or outside any slot cancels. Hover only
/// highlights — selection happens on release alone. The same finger that held
/// the category drives hover and release, so the interaction never needs a
/// second touch.
struct GVRadialPieMenu: View {
    struct Slot: Identifiable {
        let id: String
        let effect: WorkspaceAdjustableEffect
        let isActive: Bool
    }

    let center: CGPoint
    let title: String
    let subcategories: [GVRadialSubcategory]
    let fallbackSlots: [Slot]
    /// Preview-hold root tier. Empty for the dock hold, which arms one family.
    var families: [GVRadialFamily] = []
    /// Per-entry-point menu-center offset, carried from the coordinator:
    /// dock holds clear of the rail, preview spawns around the finger.
    var centerOffset: CGVector = GVRadialMenuLayout.centerOffset
    let onSelect: (WorkspaceAdjustableEffect) -> Void
    let onDismiss: () -> Void
    /// The preview forwards the location of the same finger that completed the
    /// hold. Nil is the release event and either commits the hovered slot or
    /// cancels when no slot is highlighted.
    @Binding var externalDragLocation: CGPoint?
    /// Bound separately from the drag stream so lift-off cannot race the
    /// parent update that clears the active location in the same transaction.
    @Binding var externalReleaseLocation: CGPoint?
    var safeAreaInsets = EdgeInsets()

    enum Level {
        /// Preview root: the 7 umbrella families. Hover + push-through
        /// expands one into its subgroups (or its direct effects ring).
        case families
        case categories
        case variants(GVRadialSubcategory)
    }

    @State private var isOpen = false
    @State private var level: Level = .categories
    /// The preview family expanded from the root ring. Nil on the dock path
    /// and while the preview root is showing.
    @State private var activeFamily: GVRadialFamily?
    @State private var highlightedIndex: Int?
    @State private var effectPage = 0
    @State private var transitionPoint: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isVariantLevel: Bool {
        if case .variants = level { return true }
        return false
    }

    private var isRootLevel: Bool {
        if case .families = level { return true }
        return false
    }

    /// Dragging back within the back distance at the preview subgroup level
    /// returns to the family root. The dock root has no parent tier.
    private var isFamilyCategoryLevel: Bool {
        if case .categories = level { return activeFamily != nil }
        return false
    }

    private var activeSubcategory: GVRadialSubcategory? {
        if case let .variants(sub) = level { return sub }
        return nil
    }

    /// Subgroups for the preview family under the finger. The dock path uses
    /// the coordinator-supplied subcategories; the preview path derives them
    /// per family so large families always go through subgroups.
    private var visibleSubcategories: [GVRadialSubcategory] {
        guard !families.isEmpty else { return subcategories }
        // Preview umbrellas are three levels: umbrella, its curated groups,
        // then the group's effects — so even the largest consolidated family
        // stays shallow instead of paging flat effects.
        return activeFamily?.groups ?? []
    }

    /// Active flags for the effects currently addressable: the dock's slots,
    /// or the preview family's members resolved against the flattened slots.
    private var directEffectSlots: [Slot] {
        guard !families.isEmpty, let family = activeFamily else { return fallbackSlots }
        return family.effects.map { effect in
            Slot(
                id: "fam-\(family.title)-\(effect.rawValue)",
                effect: effect,
                isActive: fallbackSlots.first { $0.effect == effect }?.isActive ?? false
            )
        }
    }

    private var allEntries: [GVRadialEntry] {
        if let sub = activeSubcategory {
            return sub.effects.map { effect in
                GVRadialEntry(
                    id: "var-\(effect.rawValue)",
                    title: effect.label,
                    hue: sub.hue.color,
                    glyph: GVEffectGlyphKind.kind(for: effect),
                    count: 0,
                    effect: effect,
                    isActive: directEffectSlots.first { $0.effect == effect }?.isActive ?? false
                )
            }
        }
        if isRootLevel {
            return families.map { family in
                GVRadialEntry(
                    id: "fam-\(family.title)",
                    title: family.title,
                    hue: family.hue.color,
                    glyph: family.glyph,
                    count: family.effects.count,
                    effect: nil,
                    isActive: family.effects.contains { effect in
                        fallbackSlots.first { $0.effect == effect }?.isActive ?? false
                    }
                )
            }
        }
        let visible = visibleSubcategories
        if !visible.isEmpty {
            return visible.map { sub in
                GVRadialEntry(
                    id: "cat-\(sub.title)",
                    title: sub.title,
                    hue: sub.hue.color,
                    glyph: sub.glyph,
                    count: sub.effects.count,
                    effect: nil,
                    isActive: sub.effects.contains { effect in
                        directEffectSlots.first { $0.effect == effect }?.isActive ?? false
                    }
                )
            }
        }
        // Small families without subcategories show their effects directly.
        return directEffectSlots.map { slot in
            GVRadialEntry(
                id: slot.id,
                title: slot.effect.label,
                hue: GVTheme.violet,
                glyph: GVEffectGlyphKind.kind(for: slot.effect),
                count: 0,
                effect: slot.effect,
                isActive: slot.isActive
            )
        }
    }

    private var entries: [GVRadialEntry] {
        let all = allEntries
        guard !isRootLevel, all.count > 6 else { return all }
        let pageCount = (all.count + 5) / 6
        let page = effectPage % pageCount
        let start = page * 6
        return Array(all[start ..< min(start + 6, all.count)]) + [
            GVRadialEntry(id: "next-page", title: "MORE \(page + 1)/\(pageCount)",
                          hue: activeHue, glyph: .frame, count: 0, effect: nil, isActive: false)
        ]
    }

    /// Keep anchors fixed when a held category expands into its effects.
    private var itemSize: CGFloat {
        62
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = GVRadialMenuLayout(
                invocationPoint: localCenter(in: geometry),
                viewportSize: geometry.size,
                itemSize: itemSize,
                slotCount: entries.count,
                safeAreaInsets: safeAreaInsets,
                centerOffset: centerOffset
            )
            let targets = layout.slotCenters

            ZStack {
                backdrop(center: layout.menuCenter)

                // A pathological compact window may not physically fit every
                // requested target. Dynamic shelves never enter the radial,
                // and bounded production groups fit, but prefix defensively so
                // an extreme future family cannot turn layout pressure into an
                // out-of-bounds crash.
                ForEach(Array(entries.prefix(targets.count).enumerated()), id: \.element.id) { index, entry in
                    slotView(entry, highlighted: highlightedIndex == index)
                        .position(isOpen ? targets[index] : layout.menuCenter)
                        .scaleEffect(isOpen ? 1 : 0.2)
                        .opacity(isOpen ? 1 : 0)
                        .animation(slotAnimation(index: index), value: isOpen)
                        .animation(levelAnimation, value: levelKey)
                }

                centerHub
                    .position(layout.menuCenter)
                    .scaleEffect(isOpen ? 1 : 0.5)
                    .opacity(isOpen ? 1 : 0)
            }
            .contentShape(Rectangle())
            // The category button's original hold owns the entire interaction. The
            // overlay is visual only, so mounting it cannot steal that touch
            // and a later tap can never select a slot.
            .allowsHitTesting(false)
            .onChange(of: externalDragLocation) { _, newValue in
                if let global = newValue {
                    let local = CGPoint(
                        x: global.x - geometry.frame(in: .global).minX,
                        y: global.y - geometry.frame(in: .global).minY
                    )
                    let distanceFromTouch = hypot(
                        local.x - layout.invocationPoint.x,
                        local.y - layout.invocationPoint.y
                    )
                    if let point = transitionPoint,
                       hypot(local.x - point.x, local.y - point.y) < 14
                    {
                        return
                    }
                    // Distance push-through back: return to the parent tier when
                    // the finger comes back to the touch point. No timer.
                    if isVariantLevel,
                       distanceFromTouch <= GVRadialMenuLayout.backDistance
                    {
                        highlightedIndex = nil
                        returnToCategories()
                        return
                    }
                    if isFamilyCategoryLevel,
                       distanceFromTouch <= GVRadialMenuLayout.backDistance
                    {
                        highlightedIndex = nil
                        returnToFamilies()
                        return
                    }
                    // Release-only selection: hover just highlights with a
                    // light tick. Nothing is applied until release.
                    let next = layout.thumbOcclusion.contains(local) ? nil : entryIndex(at: local, targets: targets)
                    if next != highlightedIndex {
                        highlightedIndex = next
                        if next != nil {
                            UIImpactFeedbackGenerator(style: .light)
                                .impactOccurred(intensity: 0.22)
                        }
                    }
                    if let next, entries[next].id == "next-page" {
                        effectPage += 1
                        transitionPoint = local
                        highlightedIndex = nil
                        UISelectionFeedbackGenerator().selectionChanged()
                        return
                    }
                    // Distance push-through expand: pushing past 48pt from
                    // the touch point into a highlighted wedge expands the
                    // next tier — a family into its subgroups (or direct
                    // effects ring), a subgroup into its variants. No time
                    // threshold.
                    if isRootLevel,
                       let i = next ?? highlightedIndex,
                       families.indices.contains(i),
                       distanceFromTouch > GVRadialMenuLayout.pushThroughDistance
                    {
                        expandFamily(families[i], at: local)
                    } else if !isVariantLevel, !isRootLevel,
                              let i = next ?? highlightedIndex,
                              entries.indices.contains(i),
                              visibleSubcategories.indices.contains(i),
                              entries[i].effect == nil,
                              distanceFromTouch > GVRadialMenuLayout.pushThroughDistance
                    {
                        expandToVariants(visibleSubcategories[i])
                    }
                } else {
                    let local = externalReleaseLocation.map {
                        CGPoint(x: $0.x - geometry.frame(in: .global).minX,
                                y: $0.y - geometry.frame(in: .global).minY)
                    }
                    // Release coordinates can arrive in the same SwiftUI update
                    // as lift-off. Never commit the previous hover by accident.
                    // Center deadzone: releasing near the touch point cancels.
                    if let point = local,
                       hypot(point.x - layout.invocationPoint.x,
                             point.y - layout.invocationPoint.y) <= GVRadialMenuLayout.backDistance
                       || transitionPoint.map({ hypot(point.x - $0.x, point.y - $0.y) < 14 }) == true
                    {
                        highlightedIndex = nil
                        dismiss()
                    } else {
                        // The SE cancel corridor (thumb occlusion) maps to nil
                        // and cancels; only a release over a slot commits.
                        finish(index: local.flatMap {
                            layout.thumbOcclusion.contains($0) ? nil : entryIndex(at: $0, targets: targets)
                        })
                    }
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            // A release can land in the same render pass that mounts the
            // overlay. In that case there was no visible slot to choose, so
            // cancel instead of leaving an orphaned menu on screen.
            guard externalDragLocation != nil else {
                DispatchQueue.main.async { onDismiss() }
                return
            }
            // The preview hold opens on the family root; the dock hold arms
            // one family and starts at its subgroups.
            if !families.isEmpty { level = .families }
            withAnimation(openAnimation) { isOpen = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) effect variants")
        .accessibilityIdentifier("radial.menu.\(slug(title))")
    }

    /// Stable identity for the level-change animation.
    private var levelKey: String {
        switch level {
        case .families: "families"
        case .categories: activeFamily.map { "categories-\($0.title)" } ?? "categories"
        case let .variants(sub): "variants-\(sub.title)"
        }
    }

    private func entryIndex(at point: CGPoint, targets: [CGPoint]) -> Int? {
        guard !targets.isEmpty else { return nil }
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, target) in targets.enumerated() {
            let distance = hypot(point.x - target.x, point.y - target.y)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return bestDistance <= itemSize * 0.6 ? best : nil
    }

    // MARK: - Level transitions

    /// Pushing past the push-through distance into a highlighted family wedge
    /// expands that family's subgroups — or its direct effects ring for small
    /// families with no subgroups. No time threshold.
    private func expandFamily(_ family: GVRadialFamily, at point: CGPoint) {
        guard isRootLevel else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.55)
        withAnimation(levelAnimation) {
            highlightedIndex = nil
            activeFamily = family
            effectPage = 0
            transitionPoint = point
            if let only = family.groups.count == 1 ? family.groups.first : nil {
                // A single-group umbrella has nothing to choose between:
                // skip straight to its effects.
                level = .variants(only)
            } else {
                level = .categories
            }
        }
    }

    /// Dragging back to the center hub from a preview family's subgroups
    /// returns to the family root.
    private func returnToFamilies() {
        guard isFamilyCategoryLevel else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.3)
        withAnimation(levelAnimation) {
            highlightedIndex = nil
            activeFamily = nil
            effectPage = 0
            transitionPoint = nil
            level = .families
        }
    }

    /// Pushing past the push-through distance into a highlighted subcategory
    /// wedge expands its variants without a lift. No time threshold.
    private func expandToVariants(_ sub: GVRadialSubcategory) {
        guard !isVariantLevel, !isRootLevel else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.55)
        withAnimation(levelAnimation) {
            highlightedIndex = nil
            level = .variants(sub)
        }
    }

    /// Dragging back to the center hub returns from variants to categories.
    private func returnToCategories() {
        guard isVariantLevel else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.3)
        withAnimation(levelAnimation) {
            highlightedIndex = nil
            if let family = activeFamily, family.groups.count <= 1 {
                // Single-group umbrellas expand straight to effects, so back
                // from effects returns to the root ring.
                activeFamily = nil
                level = families.isEmpty ? .categories : .families
            } else {
                level = .categories
            }
        }
    }

    /// Release: commit the hovered effect, or cancel. Release in the center
    /// deadzone, the SE corridor, or outside any slot dismisses with no
    /// selection. Selection happens here only — never on hover.
    private func finish(index: Int?) {
        if let index, index < entries.count,
           let effect = entries[index].effect
        {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.78)
            onSelect(effect)
        }
        highlightedIndex = nil
        dismiss()
    }

    // MARK: - Layers

    /// Quiet dim with one hue pool parked on the menu center, so slots pop
    /// while the preview framing at the edges stays readable underneath.
    private func backdrop(center: CGPoint) -> some View {
        ZStack {
            Color.black.opacity(0.40)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [activeHue.opacity(0.16), .clear],
                        center: .center,
                        startRadius: 8,
                        endRadius: 150
                    )
                )
                .frame(width: 300, height: 300)
                .position(center)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.black.opacity(0.28), .clear],
                        center: .center,
                        startRadius: 40,
                        endRadius: 150
                    )
                )
                .frame(width: 300, height: 300)
                .position(center)
            // Cancel whisper parked in the SE quadrant between the hub and
            // the first ring. Layout never places slots at x > center.x &&
            // y > center.y, so this wedge is empty, thumb-adjacent, and out
            // of the fan. Visual only: no hit testing, no animation, so it
            // is ReduceMotion-safe by construction.
            HStack(spacing: 4) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                Text("release off-target cancels")
                    .gvMono(7.5, .regular)
                    .tracking(0.6)
            }
            .foregroundStyle(.white.opacity(0.52))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
            .position(x: center.x + 54, y: center.y + 60)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private var activeHue: Color {
        activeSubcategory?.hue.color ?? activeFamily?.hue.color ?? GVTheme.violet
    }

    /// Hub title: the family under the finger on the preview path, else the
    /// armed family (dock) or EFFECTS (preview root).
    private var hubTitle: String {
        activeFamily?.title ?? title
    }

    /// Root level: EFFECTS plus a "Pick a category" cue. Category level: the
    /// family name plus a plain "Pick a group" cue.
    /// Variant level: a clear back control with the group name underneath.
    private var centerHub: some View {
        Group {
            if let sub = activeSubcategory {
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .black))
                        Text("Back")
                            .gvMono(10, .black)
                            .tracking(0.8)
                    }
                    Text(sub.title)
                        .gvMono(7.5, .regular)
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.72))
                    Text("release off-target cancels")
                        .gvMono(7, .regular)
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.52))
                }
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            } else {
                VStack(spacing: 2) {
                    Text(hubTitle)
                        .gvMono(11, .black)
                        .tracking(1.1)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(isRootLevel ? "Pick a category" : "Pick an effect")
                        .gvMono(7.5, .regular)
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.68))
                    Text("release off-target cancels")
                        .gvMono(7, .regular)
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.52))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minWidth: 64, minHeight: 50)
        .gvGlassChip(radius: 25, active: true, tint: activeHue)
        .overlay {
            Circle()
                .strokeBorder(Color.white.opacity(isVariantLevel ? 0.45 : 0.30), lineWidth: isVariantLevel ? 1.1 : 0.7)
                .frame(width: 46, height: 46)
        }
        .overlay {
            if isVariantLevel {
                Circle()
                    .strokeBorder(activeHue.opacity(0.7), lineWidth: 1.2)
                    .frame(width: 52, height: 52)
            }
        }
        .shadow(color: activeHue.opacity(0.35), radius: 10, y: 2)
        .allowsHitTesting(false)
        .animation(levelAnimation, value: levelKey)
    }

    private func slotView(_ entry: GVRadialEntry, highlighted: Bool) -> some View {
        let applied = entry.isActive
        let active = applied || highlighted
        // Three tiers at a glance: hovered (bright + glow), applied but not
        // hovered (white type + "on" dot), idle (dimmed bone, quiet ring).
        let glyphSize: CGFloat = isRootLevel ? 22 : 18
        let glyphActivity: Double = highlighted ? 1 : (applied ? 0.9 : 0.25)
        let labelColor: Color = highlighted ? .white : (applied ? .white.opacity(0.98) : GVTheme.bone.opacity(0.78))
        let ringColor: Color = highlighted ? entry.hue.opacity(0.9) : (applied ? .white.opacity(0.7) : .white.opacity(0.16))
        let ringWidth: CGFloat = highlighted ? 1.6 : (applied ? 1.2 : 0.7)
        return VStack(spacing: 2) {
            GVEffectGlyph(
                kind: entry.glyph,
                activity: glyphActivity,
                size: glyphSize
            )
            // Fixed two-line height keeps the glyph anchored: one-line and
            // two-line titles share the same stack geometry instead of
            // pulling the glyph off-center. Applies equally to fallback
            // rings, which share this path.
            Text(entry.title)
                .gvMono(10, .bold)
                .tracking(0.2)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .truncationMode(.tail)
                .allowsTightening(true)
                .multilineTextAlignment(.center)
                .lineSpacing(-1)
                .frame(width: itemSize - 10, height: 24, alignment: .center)
                .foregroundStyle(labelColor)
                .shadow(color: .black.opacity(highlighted ? 0.65 : 0.8), radius: highlighted ? 2 : 3, y: 1)
        }
        .opacity(highlighted ? 1 : (applied ? 1 : 0.92))
        .frame(width: itemSize, height: itemSize)
        .gvGlassChip(
            radius: itemSize / 2,
            active: active,
            tint: entry.hue
        )
        .overlay {
            Circle()
                .strokeBorder(ringColor, lineWidth: ringWidth)
        }
        // The count pill lived in the VStack flow, pushing the glyph/label
        // off-center and overflowing the 66pt circle (28 + ~24 + ~14 +
        // spacing > 66). Straddling the chip's bottom edge instead keeps
        // every stack optically centered with identical geometry.
        .overlay(alignment: .bottom) {
            if entry.count >= 1 {
                Text("\(entry.count)")
                    .gvMono(8, .black)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .overlay(Capsule().strokeBorder(entry.hue.opacity(0.8), lineWidth: 0.8))
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .offset(y: 9)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if applied, !highlighted {
                Circle()
                    .fill(.white)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(entry.hue.opacity(0.9), lineWidth: 1))
                    .offset(x: -6, y: 6)
                    .allowsHitTesting(false)
            }
        }
        .shadow(
            color: highlighted ? entry.hue.opacity(0.45) : (applied ? entry.hue.opacity(0.28) : .black.opacity(0.45)),
            radius: highlighted ? 10 : (applied ? 8 : 4),
            y: 2
        )
        .brightness(highlighted ? 0.04 : 0)
        .scaleEffect(highlighted ? 1.08 : 1)
        .animation(GVMotion.snap, value: highlighted)
        .accessibilityLabel(entry.effect?.label ?? entry.title)
        .accessibilityHint(entry.effect?.detail ?? "\(entry.count) effects")
        .accessibilityValue(entry.isActive ? "active" : "inactive")
        .accessibilityIdentifier("radial.slot.\(slug(entry.id))")
    }

    private var openAnimation: Animation {
        reduceMotion ? .linear(duration: 0) : .spring(response: 0.20, dampingFraction: 0.78)
    }

    private var levelAnimation: Animation {
        reduceMotion ? .linear(duration: 0) : .spring(response: 0.22, dampingFraction: 0.85)
    }

    private func slotAnimation(index: Int) -> Animation {
        guard !reduceMotion else { return .linear(duration: 0) }
        return .spring(response: 0.20, dampingFraction: 0.78)
            .delay(Double(min(index, 6)) * 0.008)
    }

    private func localCenter(in geometry: GeometryProxy) -> CGPoint {
        let globalFrame = geometry.frame(in: .global)
        return CGPoint(x: center.x - globalFrame.minX, y: center.y - globalFrame.minY)
    }

    private func dismiss() {
        withAnimation(reduceMotion ? .none : .easeIn(duration: 0.14)) {
            isOpen = false
        }
        let delay = reduceMotion ? 0 : 0.14
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { onDismiss() }
    }

    private func slug(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}
