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
        XCTAssertEqual(EffectCatalog.canonicalEffects([.kaleido6, .kaleidoscope, .flowField]), [.kaleidoscope, .flowField])
        XCTAssertEqual(EffectCatalog.variants(for: .kaleido6), [.kaleidoscope, .kaleido6])
        XCTAssertEqual(EffectCatalog.search("POINT-CLOUD SMEAR"), [.pointCloudSmear])
    }

    /// A retired effect's name still finds the look that replaced it, and a
    /// recipe that names one decodes onto that replacement instead of failing.
    func testRetiredEffectsResolveToTheirReplacementEverywhere() throws {
        XCTAssertEqual(EffectCatalog.search("opticalFlowLiquid"), [.liquidMosh])
        XCTAssertEqual(EffectCatalog.search("bokeh"), [.tiltShift])
        for (retired, replacement) in WorkspaceAdjustableEffect.retiredReplacements {
            XCTAssertNil(WorkspaceAdjustableEffect(rawValue: retired), "\(retired) is still a live case")
            XCTAssertEqual(WorkspaceAdjustableEffect.resolving(retired), replacement)
            let decoded = try JSONDecoder().decode(WorkspaceAdjustableEffect.self, from: JSONEncoder().encode(retired))
            XCTAssertEqual(decoded, replacement)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(WorkspaceAdjustableEffect.self, from: JSONEncoder().encode("neverAnEffect")))
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
        editor.effectStack.reset(.kaleido6, enabled: false)
        let slot = try XCTUnwrap(editor.effectStack.firstSlotID(for: .kaleido6))
        editor.selectFamily(.kaleidoscope)
        XCTAssertEqual(editor.focusedSlot, slot)
        XCTAssertEqual(editor.selectedEffect, .kaleido6)
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
        stack.reset(.trails)
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
        XCTAssertTrue(ids.contains(WorkspaceAdjustableEffect.liquidMosh.rawValue))
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
        XCTAssertFalse(WorkspaceDockCategory.browsable.contains(.lidar))
        for shelf in EffectCatalog.shelves {
            XCTAssertFalse(shelf.effects.isEmpty, shelf.id)
            XCTAssertEqual(shelf.effects.count, Set(shelf.effects).count, shelf.id)
            XCTAssertTrue(shelf.effects.contains(shelf.hero), "\(shelf.id) previews an effect it does not hold")
        }
    }

    /// Eight families, named for what they do, and a catalogue small enough
    /// that every effect in it earns its place. The depth modes are scanner
    /// reads, never a catalogue shelf.
    func testFamiliesAreFewAndTheCatalogueStaysTight() {
        XCTAssertEqual(EffectCatalog.shelves.map(\.label),
                       ["GLITCH", "TIME", "ANALOG", "LOOK", "LENS", "WARP", "GENERATIVE", "AUDIO"])
        XCTAssertLessThanOrEqual(WorkspaceAdjustableEffect.allCases.count, 80)
        let datamosh = Set(EffectCatalog.effects(in: "glitch"))
        XCTAssertTrue(datamosh.isSuperset(of: [.datamosh, .liquidMosh, .heavyMosh]))
        XCTAssertFalse(WorkspaceDockCategory.browsable.filter(\.isShelf).contains(.spatial))
        XCTAssertTrue(WorkspaceDockCategory.spatial.displayLabel == "Depth")
        XCTAssertFalse(WorkspaceDockCategory.spatial.isShelf, "Depth modes are not catalogue effects")
        for group in WorkspaceAdjustableEffect.curatedCategoryEffectGroups {
            for effect in group {
                XCTAssertTrue(group.contains(EffectCatalog.canonical(effect)),
                              "\(effect.rawValue) canonicalises into another family")
            }
        }
    }

    /// Every retired name still opens: it resolves to a survivor, never to
    /// another retired name.
    func testEveryRetiredNameResolvesToASurvivor() {
        for (name, replacement) in WorkspaceAdjustableEffect.retiredReplacements {
            XCTAssertNil(WorkspaceAdjustableEffect(rawValue: name), "\(name) is retired but still a case")
            XCTAssertNotNil(WorkspaceAdjustableEffect(rawValue: replacement.rawValue), name)
            XCTAssertEqual(WorkspaceAdjustableEffect.resolving(name), replacement)
        }
    }

    @MainActor
    func testShippingShaderSamplesRenderDistinctImagesIncludingSimulationsAndHistory() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let renderer = try XCTUnwrap(GVEffectSampleRenderer())
        let reference = try XCTUnwrap(GVEffectThumbnailStore.makeReferenceStill())
        var outputs = Set<Data>()
        for effect in [WorkspaceAdjustableEffect.rgbSplit, .cmykPress,
                       .kaleidoscope, .kaleido6, .cyberGrid, .feedback, .fluid] {
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
