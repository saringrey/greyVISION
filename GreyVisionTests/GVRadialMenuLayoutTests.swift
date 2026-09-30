@testable import GreyVision
import XCTest

/// Push-through grouping + layout contract for the radial menu.
///
/// Grouping: every family fans out into 2-6 subcategory wedges (small
/// families with no curated groups show effects directly), and no effect
/// may be rail-only — each family effect appears in exactly one wedge.
/// Layout: slots fan around the decoupled menu center (touch + (-72,-128),
/// clamped into the safe rect), never intersect the thumb occlusion / SE
/// corridor, stay inside the safe rect, and keep itemSize+16 spacing.
final class GVRadialMenuLayoutTests: XCTestCase {
    private struct LayoutCase {
        let viewport: CGSize
        let touch: CGPoint
        let itemSize: CGFloat
    }

    /// Bottom-rail touches in portrait + landscape sizes.
    private let cases: [LayoutCase] = [
        LayoutCase(viewport: CGSize(width: 390, height: 844), touch: CGPoint(x: 78, y: 772), itemSize: 84),
        LayoutCase(viewport: CGSize(width: 390, height: 844), touch: CGPoint(x: 312, y: 772), itemSize: 84),
        LayoutCase(viewport: CGSize(width: 390, height: 844), touch: CGPoint(x: 195, y: 800), itemSize: 84),
        LayoutCase(viewport: CGSize(width: 390, height: 844), touch: CGPoint(x: 356, y: 772), itemSize: 64),
        LayoutCase(viewport: CGSize(width: 844, height: 390), touch: CGPoint(x: 766, y: 342), itemSize: 64),
        LayoutCase(viewport: CGSize(width: 844, height: 390), touch: CGPoint(x: 78, y: 342), itemSize: 64),
        LayoutCase(viewport: CGSize(width: 844, height: 390), touch: CGPoint(x: 422, y: 360), itemSize: 84),
    ]

    private func safeRect(viewport: CGSize, itemSize: CGFloat) -> CGRect {
        let inset = itemSize / 2 + 20
        return CGRect(
            x: inset,
            y: inset,
            width: max(0, viewport.width - inset * 2),
            height: max(0, viewport.height - inset * 2)
        )
    }

    /// Every slot count the ring can show: category level (wedge count),
    /// variant level (each wedge's size), and the small-family fallback.
    private func slotCounts() -> [Int] {
        var counts = Set<Int>()
        for shelf in EffectCatalog.shelves {
            let effects = shelf.effects.flatMap(EffectCatalog.variants)
            let groups = EffectCatalog.radialSubcategories(title: shelf.label, effects: effects)
            if groups.isEmpty {
                counts.insert(effects.count)
            } else {
                counts.insert(groups.count)
                for group in groups {
                    counts.insert(group.effects.count)
                }
            }
        }
        return counts.sorted()
    }

    // MARK: - Grouping

    func testWedgeCountIsTwoToSixOrSmallFamilyFallback() {
        for shelf in EffectCatalog.shelves {
            let effects = shelf.effects.flatMap(EffectCatalog.variants)
            let groups = EffectCatalog.radialSubcategories(title: shelf.label, effects: effects)
            if groups.isEmpty {
                XCTAssertLessThanOrEqual(effects.count, 8, "\(shelf.label): fallback only for small families")
            } else {
                XCTAssertGreaterThanOrEqual(groups.count, 2, shelf.label)
                XCTAssertLessThanOrEqual(groups.count, 6, shelf.label)
            }
        }
    }

    func testNoEffectIsRailOnly() {
        for shelf in EffectCatalog.shelves {
            let effects = shelf.effects.flatMap(EffectCatalog.variants)
            let groups = EffectCatalog.radialSubcategories(title: shelf.label, effects: effects)
            guard !groups.isEmpty else { continue }
            let displayed = groups.flatMap(\.effects)
            XCTAssertEqual(Set(displayed), Set(effects), shelf.label)
            XCTAssertEqual(displayed.count, Set(displayed).count, "\(shelf.label): each effect in exactly one wedge")
        }
    }

    func testConsolidatedFamilyWedgeShapes() {
        let wedges: [String: [String]] = Dictionary(uniqueKeysWithValues: EffectCatalog.shelves.map { shelf in
            let effects = shelf.effects.flatMap(EffectCatalog.variants)
            let groups = EffectCatalog.radialSubcategories(title: shelf.label, effects: effects)
            return (shelf.label, groups.map(\.title))
        })
        // Small families show effects directly instead of wedging.
        XCTAssertEqual(wedges["COLOR"], [])
        XCTAssertEqual(wedges["SCOPE"], [])
        XCTAssertEqual(wedges["TIME"], ["MOSH", "SORT", "SMEAR", "TIME", "SARIN"])
        XCTAssertEqual(wedges["MOTION"], ["FEEDBACK", "FLOW", "FLUID"])
        XCTAssertEqual(wedges["DECAY"], ["REBUILD", "DAMAGE", "DECAY"])
        XCTAssertEqual(wedges["SIGNAL"], ["GLITCH", "ANALOG"])
        XCTAssertEqual(wedges["OPTICS"], ["LENS", "LIGHT", "GLASS"])
        XCTAssertEqual(wedges["FORM"], ["GEOMETRY", "FIELD"])
        // Reassigned effects land in their new wedges, not rail-only.
        let time = EffectCatalog.radialSubcategories(title: "TIME", effects: EffectCatalog.effects(in: "time").flatMap(EffectCatalog.variants))
        XCTAssertTrue(time.first { $0.title == "SARIN" }?.effects.contains(.causalSmear) ?? false)
        let motion = EffectCatalog.radialSubcategories(title: "MOTION", effects: EffectCatalog.effects(in: "motion").flatMap(EffectCatalog.variants))
        XCTAssertEqual(motion.first { $0.title == "FLUID" }?.effects, [.fluid])
        let signal = EffectCatalog.radialSubcategories(title: "SIGNAL", effects: EffectCatalog.effects(in: "signal").flatMap(EffectCatalog.variants))
        XCTAssertTrue(signal.first { $0.title == "GLITCH" }?.effects.contains(.dataBend) ?? false)
        let form = EffectCatalog.radialSubcategories(title: "FORM", effects: EffectCatalog.effects(in: "form").flatMap(EffectCatalog.variants))
        XCTAssertTrue(form.first { $0.title == "FIELD" }?.effects.contains(.reactionGarden) ?? false)
        let optics = EffectCatalog.radialSubcategories(title: "OPTICS", effects: EffectCatalog.effects(in: "optics").flatMap(EffectCatalog.variants))
        XCTAssertTrue(optics.flatMap(\.effects).contains(.hologram))
    }

    // MARK: - Layout

    func testSlotFramesNeverIntersectThumbOcclusion() {
        for layoutCase in cases {
            for count in slotCounts() {
                let layout = GVRadialMenuLayout(
                    invocationPoint: layoutCase.touch,
                    viewportSize: layoutCase.viewport,
                    itemSize: layoutCase.itemSize,
                    slotCount: count
                )
                XCTAssertEqual(layout.slotCenters.count, count, "\(layoutCase.touch) \(count)")
                for frame in layout.slotFrames {
                    XCTAssertFalse(
                        frame.intersects(layout.thumbOcclusion),
                        "touch \(layoutCase.touch) count \(count) frame \(frame) hits occlusion \(layout.thumbOcclusion)"
                    )
                }
            }
        }
    }

    func testSlotCentersStayInSafeRectAndOutOfSEQuadrant() {
        for layoutCase in cases {
            let rect = safeRect(viewport: layoutCase.viewport, itemSize: layoutCase.itemSize)
            for count in slotCounts() {
                let layout = GVRadialMenuLayout(
                    invocationPoint: layoutCase.touch,
                    viewportSize: layoutCase.viewport,
                    itemSize: layoutCase.itemSize,
                    slotCount: count
                )
                for center in layout.slotCenters {
                    XCTAssertTrue(rect.contains(center), "touch \(layoutCase.touch) center \(center) outside \(rect)")
                    XCTAssertFalse(
                        center.x > layout.menuCenter.x && center.y > layout.menuCenter.y,
                        "touch \(layoutCase.touch) center \(center) in SE quadrant of \(layout.menuCenter)"
                    )
                }
            }
        }
    }

    func testMinimumSpacingRespected() {
        for layoutCase in cases {
            let spacing = layoutCase.itemSize + 16
            for count in slotCounts() {
                let layout = GVRadialMenuLayout(
                    invocationPoint: layoutCase.touch,
                    viewportSize: layoutCase.viewport,
                    itemSize: layoutCase.itemSize,
                    slotCount: count
                )
                for (index, center) in layout.slotCenters.enumerated() {
                    for other in layout.slotCenters.dropFirst(index + 1) {
                        XCTAssertGreaterThanOrEqual(
                            hypot(center.x - other.x, center.y - other.y),
                            spacing - 1e-6,
                            "touch \(layoutCase.touch) count \(count)"
                        )
                    }
                }
            }
        }
    }

    func testMenuCenterOffsetIsClampedInSafeRectForCornerTouches() {
        XCTAssertEqual(GVRadialMenuLayout.centerOffset.dx, -72, accuracy: 1e-9)
        XCTAssertEqual(GVRadialMenuLayout.centerOffset.dy, -128, accuracy: 1e-9)
        for layoutCase in cases {
            let rect = safeRect(viewport: layoutCase.viewport, itemSize: layoutCase.itemSize)
            let layout = GVRadialMenuLayout(
                invocationPoint: layoutCase.touch,
                viewportSize: layoutCase.viewport,
                itemSize: layoutCase.itemSize,
                slotCount: 4
            )
            let raw = CGPoint(
                x: layoutCase.touch.x + GVRadialMenuLayout.centerOffset.dx,
                y: layoutCase.touch.y + GVRadialMenuLayout.centerOffset.dy
            )
            let expected = CGPoint(
                x: min(max(raw.x, rect.minX), rect.maxX),
                y: min(max(raw.y, rect.minY), rect.maxY)
            )
            XCTAssertEqual(layout.menuCenter.x, expected.x, accuracy: 1e-6, "touch \(layoutCase.touch)")
            XCTAssertEqual(layout.menuCenter.y, expected.y, accuracy: 1e-6, "touch \(layoutCase.touch)")
            XCTAssertTrue(rect.contains(layout.menuCenter), "touch \(layoutCase.touch)")
        }
    }

    // MARK: - Preview hold

    /// The preview hold opens on the root tier, so an empty root would be an
    /// empty ring on device. The coordinator falls back to the largest shelf,
    /// but the invariant is that the curated root itself is never empty.
    func testPreviewRootIsNeverEmpty() {
        let root = GVRadialFamily.previewRoot()
        XCTAssertFalse(root.isEmpty, "previewRoot must always offer the root ring")
        XCTAssertEqual(root.count, 7, "previewRoot covers the 7 umbrella families")
        XCTAssertEqual(root.map(\.title), ["COLOR", "TIME", "MOTION", "SIGNAL", "FORM", "SHADERS", "AUDIO"])
        XCTAssertEqual(
            Set(root.flatMap(\.effects)),
            Set(EffectCatalog.shelves.flatMap(\.effects).flatMap(EffectCatalog.variants)),
            "umbrellas must still cover every effect exactly once"
        )
        for family in root {
            XCTAssertFalse(family.title.isEmpty, "family title")
            XCTAssertFalse(family.effects.isEmpty, "\(family.title) must hold effects")
        }
        XCTAssertNotNil(GVRadialFamily.largestShelfFallback(), "fallback shelf must exist")
        if let fallback = GVRadialFamily.largestShelfFallback() {
            XCTAssertFalse(fallback.effects.isEmpty)
        }
    }

    /// The preview spawns the ring around the finger with a (0,-40) offset
    /// instead of the dock's (-72,-128) clear-the-rail shift. Slots must
    /// still avoid the SE cancel corridor, stay thumb-clear, and keep the
    /// same clamped-center contract.
    func testPreviewOffsetLayoutAvoidsSECorridor() {
        XCTAssertEqual(GVRadialMenuLayout.previewCenterOffset.dx, 0, accuracy: 1e-9)
        XCTAssertEqual(GVRadialMenuLayout.previewCenterOffset.dy, -40, accuracy: 1e-9)
        let slotCount = max(GVRadialFamily.previewRoot().count, 1)
        let touches: [(CGSize, CGPoint)] = [
            (CGSize(width: 390, height: 844), CGPoint(x: 195, y: 420)),
            (CGSize(width: 390, height: 844), CGPoint(x: 90, y: 300)),
            (CGSize(width: 390, height: 844), CGPoint(x: 320, y: 600)),
            (CGSize(width: 844, height: 390), CGPoint(x: 422, y: 195)),
            (CGSize(width: 390, height: 844), CGPoint(x: 356, y: 120)),
        ]
        for (viewport, touch) in touches {
            let layout = GVRadialMenuLayout(
                invocationPoint: touch,
                viewportSize: viewport,
                itemSize: 66,
                slotCount: slotCount,
                centerOffset: GVRadialMenuLayout.previewCenterOffset
            )
            XCTAssertEqual(layout.slotCenters.count, slotCount, "touch \(touch)")
            let inset = 66.0 / 2 + 20
            let rect = CGRect(
                x: inset,
                y: inset,
                width: max(0, viewport.width - inset * 2),
                height: max(0, viewport.height - inset * 2)
            )
            let raw = CGPoint(
                x: touch.x + GVRadialMenuLayout.previewCenterOffset.dx,
                y: touch.y + GVRadialMenuLayout.previewCenterOffset.dy
            )
            let expected = CGPoint(
                x: min(max(raw.x, rect.minX), rect.maxX),
                y: min(max(raw.y, rect.minY), rect.maxY)
            )
            XCTAssertEqual(layout.menuCenter.x, expected.x, accuracy: 1e-6, "touch \(touch)")
            XCTAssertEqual(layout.menuCenter.y, expected.y, accuracy: 1e-6, "touch \(touch)")
            for center in layout.slotCenters {
                XCTAssertTrue(rect.contains(center), "touch \(touch) center \(center) outside \(rect)")
                XCTAssertFalse(
                    center.x > layout.menuCenter.x && center.y > layout.menuCenter.y,
                    "touch \(touch) center \(center) in SE quadrant of \(layout.menuCenter)"
                )
            }
            for frame in layout.slotFrames {
                XCTAssertFalse(
                    frame.intersects(layout.thumbOcclusion),
                    "touch \(touch) frame \(frame) hits occlusion \(layout.thumbOcclusion)"
                )
            }
        }
    }
}
