@testable import GreyVision
import Combine
import Metal
import UIKit
import XCTest

final class EffectCatalogTests: XCTestCase {
    func testEveryEffectDefaultsToFullBlendWithoutOverwritingSavedMix() throws {
        XCTAssertEqual(CameraEffectParameters().blend, 1)
        for effect in WorkspaceAdjustableEffect.allCases {
            XCTAssertEqual(effect.defaultCameraParameters.blend, 1, effect.rawValue)
            var stack = CameraEffectStackParameters()
            stack.reset(effect)
            XCTAssertEqual(stack[effect].blend, 1, effect.rawValue)
        }
        let saved = CameraEffectParameters(blend: 0.37)
        let restored = try JSONDecoder().decode(CameraEffectParameters.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored.blend, 0.37)
    }

    func testEveryEffectRemainsReachableFromVisibleShelves() {
        let reachable = Set(EffectCatalog.shelves.flatMap(\.effects).flatMap { EffectCatalog.variants(for: $0) })
        let missing = Set(WorkspaceAdjustableEffect.allCases).subtracting(reachable)
        XCTAssertTrue(missing.isEmpty, "Missing effects: \(missing.map(\.rawValue).sorted())")
    }

    func testFamilyBrowsingDeduplicatesWithoutLosingLegacyIdentity() {
        XCTAssertEqual(EffectCatalog.canonicalEffects([.kaleido6, .kaleidoscope, .curlWarp, .flowField]), [.kaleidoscope, .flowField])
        XCTAssertEqual(EffectCatalog.variants(for: .kaleido6), [.kaleidoscope, .kaleido6])
        XCTAssertEqual(EffectCatalog.search("OPTICAL-FLOW LIQUID"), [.opticalFlowLiquid])
        XCTAssertEqual(EffectCatalog.search("OBJECT SORT"), [.objectSort])
    }

    @MainActor
    func testFamilySelectionFocusesExistingDuplicateWithoutDisablingIt() throws {
        let editor = EffectEditingSession()
        editor.effectStack.reset(.kaleido6)
        let original = try XCTUnwrap(editor.effectStack.firstSlotID(for: .kaleido6))
        let duplicate = try XCTUnwrap(editor.effectStack.duplicate(original))
        editor.focus(.kaleido6)
        editor.focusedSlot = duplicate
        let before = editor.effectStack
        editor.selectFamily(.kaleidoscope)
        XCTAssertEqual(editor.effectStack, before)
        XCTAssertEqual(editor.focusedSlot, duplicate)
        XCTAssertEqual(editor.selectedEffect, .kaleido6)
    }

    @MainActor
    func testFamilyTapKeepsDisabledSlotIdentityAndPower() throws {
        let editor = EffectEditingSession()
        editor.effectStack.reset(.curlWarp, enabled: false)
        let slot = try XCTUnwrap(editor.effectStack.firstSlotID(for: .curlWarp))
        editor.selectFamily(.flowField)
        XCTAssertEqual(editor.focusedSlot, slot)
        XCTAssertEqual(editor.selectedEffect, .curlWarp)
        XCTAssertFalse(try XCTUnwrap(editor.effectStack[slot: slot]).isEnabled)
        XCTAssertEqual(editor.effectStack.orderedSlots.count, 1)
    }

    @MainActor
    func testVariantReplacementPreservesSlotAndRestoresTuningAndUndo() throws {
        let editor = EffectEditingSession()
        editor.select(.kaleido6)
        let id = try XCTUnwrap(editor.focusedSlot)
        var tuned = try XCTUnwrap(editor.effectStack[slot: id])
        tuned.primary = 0.13
        tuned.blend = 0.47
        tuned.isEnabled = false
        editor.effectStack[slot: id] = tuned
        editor.recordHistory()
        editor.changeVariant(to: .kaleidoscope)
        XCTAssertEqual(editor.focusedSlot, id)
        XCTAssertEqual(editor.effectStack.slot(id)?.effect, .kaleidoscope)
        XCTAssertEqual(editor.effectStack[slot: id]?.blend, 0.47)
        XCTAssertEqual(editor.effectStack[slot: id]?.isEnabled, false)
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.effectStack.slot(id)?.effect, .kaleido6)
        XCTAssertEqual(editor.selectedEffect, .kaleido6)
        editor.changeVariant(to: .kaleidoscope)
        editor.changeVariant(to: .kaleido6)
        XCTAssertEqual(editor.effectStack[slot: id]?.primary, 0.13)
        XCTAssertEqual(editor.effectStack.orderedSlots.count, 1)
    }

    @MainActor
    func testPreviewDoesNotEnterUndoHistoryAndCancelRestoresSelection() {
        let editor = EffectEditingSession()
        editor.select(.grain)
        editor.recordHistory()
        let before = editor.snapshot
        let slot = editor.focusedSlot
        var other = CameraEffectStackParameters()
        other.reset(.datamosh)
        editor.beginPreview(CompositionSnapshot(stack: other, rgb: .init()))
        editor.recordHistory()
        XCTAssertTrue(editor.isPreviewing)
        editor.endPreview()
        XCTAssertEqual(editor.snapshot, before)
        XCTAssertEqual(editor.focusedSlot, slot)
        XCTAssertEqual(editor.selectedEffect, .grain)
        XCTAssertTrue(editor.undo())
        XCTAssertTrue(editor.effectStack.orderedSlots.isEmpty)
    }

    func testTemporalOnlyPresetHasAnAccurateSummaryAndRoundTrips() throws {
        var stack = CameraEffectStackParameters()
        stack.reset(.datamosh)
        stack.reset(.opticalFlowLiquid)
        let preset = GVPreset(name: "LEGACY", codecRaw: "hvc1", frameRate: 60, resolutionRaw: "4K", rgbSplit: .init(), stack: stack)
        XCTAssertNotEqual(preset.summary, "EMPTY PLATE")
        XCTAssertTrue(preset.summary.contains(WorkspaceAdjustableEffect.datamosh.label))
        let restored = try JSONDecoder().decode(GVPreset.self, from: JSONEncoder().encode(preset))
        XCTAssertEqual(restored.stack, stack)
        XCTAssertEqual(restored.stack.orderedSlots.map(\.id), stack.orderedSlots.map(\.id))
    }

    func testBroadcastKeepsLegacyDescriptorsEvenWhenShelvesAreCurated() {
        let surface = GVBroadcastControlCatalog.makeSurface(isAudioAvailable: true)
        let ids = Set(surface.effects.map(\.id))
        XCTAssertTrue(ids.contains(WorkspaceAdjustableEffect.opticalFlowLiquid.rawValue))
        XCTAssertTrue(ids.contains(WorkspaceAdjustableEffect.kaleido6.rawValue))
        for family in surface.families {
            XCTAssertTrue(Set(family.effectIDs).isSubset(of: ids))
            XCTAssertEqual(family.effectIDs.count, Set(family.effectIDs).count)
        }
    }

    func testFamiliesPartitionEveryEffectExactlyOnce() {
        let groups = WorkspaceAdjustableEffect.curatedCategoryEffectGroups
        XCTAssertEqual(groups.count, EffectCatalog.shelves.count)
        XCTAssertTrue(WorkspaceAdjustableEffect.repeatedCuratedCategoryEffects.isEmpty)
        let grouped = groups.flatMap(\.self)
        XCTAssertEqual(grouped.count, Set(grouped).count, "A curated effect appears in two families")
        XCTAssertEqual(Set(grouped), Set(WorkspaceAdjustableEffect.allCases), "Every effect in exactly one family")
        for effect in WorkspaceAdjustableEffect.allCases {
            XCTAssertNotNil(effect.curatedFamily, "\(effect.rawValue) has no curated family")
        }
    }

    func testConsolidatedCategoryMenuRetainsEveryShelf() {
        let categories = WorkspaceDockCategory.browsable.filter(\.isShelf)
        XCTAssertEqual(categories.map(\.rawValue), EffectCatalog.shelves.map(\.id))
        XCTAssertTrue(categories.contains(.experimental))
        XCTAssertTrue(categories.contains(.developer))
        XCTAssertFalse(WorkspaceDockCategory.browsable.contains(.lidar))
        for shelf in EffectCatalog.shelves {
            XCTAssertFalse(shelf.effects.isEmpty, shelf.id)
            XCTAssertEqual(shelf.effects.count, Set(shelf.effects).count, shelf.id)
        }
    }

    /// Families are named for what they contain. This locks in the split so a
    /// future edit cannot quietly fold the moshes back into the sorts, or
    /// leave the depth-named luma sorts filed as though they were LiDAR.
    func testFamiliesAreNamedForTheirContentsAndSeparateRealDepth() {
        let datamosh = EffectCatalog.effects(in: "datamosh")
        XCTAssertEqual(Set(datamosh), [.datamosh, .liquidMosh, .heavyMosh])
        // `canonicalEffects` collapses a variant onto its family's first entry and
        // that entry supplies the caption. A variant filed under a different
        // shelf than its canonical would therefore render the other shelf's
        // name, so every effect's canonical representative must live in the
        // same group it is filed under.
        for group in WorkspaceAdjustableEffect.curatedCategoryEffectGroups {
            for effect in group {
                let canonical = EffectCatalog.canonical(effect)
                XCTAssertTrue(
                    group.contains(canonical),
                    "\(effect.rawValue) canonicalises to \(canonical.rawValue), which is filed elsewhere"
                )
            }
        }

        let sort = Set(EffectCatalog.effects(in: "sort"))
        for expected in [WorkspaceAdjustableEffect.sort, .depthSort, .objectSort, .radialSort] {
            XCTAssertTrue(sort.contains(expected), expected.rawValue)
        }
        XCTAssertFalse(datamosh.contains(.sort), "A sort is not a mosh")

        let history = Set(EffectCatalog.effects(in: "time"))
        XCTAssertTrue(history.contains(.rollingTime))
        XCTAssertTrue(history.contains(.frameHoldSmear))
        XCTAssertTrue(Set(datamosh).isDisjoint(with: history))
        XCTAssertTrue(Set(datamosh).isDisjoint(with: sort))

        // Depth-named effects are luma/edge sorts, not scanner reads. They must
        // never be presented as the real depth modes.
        XCTAssertTrue(sort.contains(.depthSort))
        XCTAssertTrue(sort.contains(.pointCloudSmear))
        XCTAssertFalse(WorkspaceDockCategory.browsable.filter(\.isShelf).contains(.spatial))
        XCTAssertTrue(WorkspaceDockCategory.spatial.displayLabel == "Depth")
        XCTAssertFalse(WorkspaceDockCategory.spatial.isShelf, "Depth modes are not catalogue effects")

        let labels = EffectCatalog.shelves.map(\.label)
        XCTAssertEqual(labels, ["TONAL", "DATAMOSH", "SORT", "HISTORY", "MOTION", "DECAY",
                                "ANALOG", "LENS", "GEOMETRY", "GENERATIVE", "SPECTRUM",
                                "INSTRUMENTS", "SOLVERS", "RESEARCH"])
    }

    @MainActor
    func testShippingShaderSamplesRenderDistinctImagesIncludingSimulationsAndHistory() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let renderer = try XCTUnwrap(GVEffectSampleRenderer())
        let reference = try XCTUnwrap(GVEffectThumbnailStore.makeReferenceStill())
        var outputs = Set<Data>()
        for effect in [WorkspaceAdjustableEffect.rgbSplit, .cmykPress, .spectralDiffraction,
                       .kaleidoscope, .kaleido6, .cyberGrid, .feedback, .fluid, .reactionGarden] {
            let sample = try XCTUnwrap(renderer.render(effect, over: reference), effect.rawValue)
            XCTAssertEqual(sample.cgImage?.width, GVEffectThumbnailStore.side, effect.rawValue)
            XCTAssertEqual(sample.cgImage?.height, GVEffectThumbnailStore.side, effect.rawValue)
            let data = try XCTUnwrap(sample.pngData())
            XCTAssertTrue(outputs.insert(data).inserted, "Duplicate preview: \(effect.rawValue)")
        }
    }

    @MainActor
    func testThumbnailCompletionPublishesAndRepeatedRequestsUseCache() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let store = GVEffectThumbnailStore.shared
        let effect = WorkspaceAdjustableEffect.cmykPress
        let published = expectation(description: "thumbnail cache invalidates the browser")
        let token = store.objectWillChange.sink { published.fulfill() }
        if store.image(for: effect) == nil {
            store.request(effect)
            store.request(effect)
            await fulfillment(of: [published], timeout: 15)
        }
        let image = try XCTUnwrap(store.image(for: effect))
        store.request(effect)
        XCTAssertTrue(store.image(for: effect) === image)
        withExtendedLifetime(token) {}
    }
}
