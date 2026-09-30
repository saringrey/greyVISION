@testable import GreyVision
import XCTest

/// The render stack as a data structure.
///
/// `CameraEffectStackParameters` shipped with ordered, individually identified
/// slots and no way to address one. Every read and write went through the
/// effect-keyed subscript, which resolves to the first slot carrying that
/// effect — so `duplicate` produced a second node that could never hold
/// different settings from the first, and reordering had no caller at all.
///
/// These cover the slot-addressed path the parameter deck now edits through.
final class CameraEffectStackTests: XCTestCase {
    func testDuplicatedSlotsTuneIndependently() throws {
        var stack = CameraEffectStackParameters()
        stack.reset(.datamosh)
        let original = try XCTUnwrap(stack.firstSlotID(for: .datamosh))
        let copy = try XCTUnwrap(stack.duplicate(original))
        XCTAssertNotEqual(original, copy)

        var edited = try XCTUnwrap(stack[slot: copy])
        edited.primary = 0.11
        stack[slot: copy] = edited

        XCTAssertEqual(stack[slot: copy]?.primary, 0.11)
        XCTAssertEqual(
            stack[slot: original]?.primary,
            WorkspaceAdjustableEffect.datamosh.defaultCameraParameters.primary,
            "editing a duplicate must not write through to the original"
        )
        XCTAssertEqual(stack.orderedSlots.count, 2)
    }

    /// The effect-keyed subscript is still the API almost everything uses, and
    /// it has to keep meaning "the first slot for this effect" — otherwise the
    /// renderer and the presets would start disagreeing about which node they
    /// are describing.
    func testEffectSubscriptStillResolvesToTheFirstSlot() throws {
        var stack = CameraEffectStackParameters()
        stack.reset(.trails)
        let original = try XCTUnwrap(stack.firstSlotID(for: .trails))
        let copy = try XCTUnwrap(stack.duplicate(original))

        var edited = try XCTUnwrap(stack[slot: copy])
        edited.primary = 0.93
        stack[slot: copy] = edited

        XCTAssertEqual(stack[.trails].primary, stack[slot: original]?.primary)
        XCTAssertNotEqual(stack[.trails].primary, 0.93)
    }

    func testRenderPositionFollowsOrder() {
        var stack = CameraEffectStackParameters()
        stack.reset(.pixelate)
        stack.reset(.grain)
        let slots = stack.orderedSlots
        XCTAssertEqual(slots.count, 2)
        XCTAssertEqual(stack.renderPosition(of: slots[0].id), 1)
        XCTAssertEqual(stack.renderPosition(of: slots[1].id), 2)

        stack.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(stack.renderPosition(of: slots[0].id), 2, "moving a slot must change where it renders")
        XCTAssertEqual(stack.renderPosition(of: slots[1].id), 1)
    }

    /// Reset keeps the slot powered as it was. Resetting a live node back to
    /// defaults and having it silently switch off would read as a crash of the
    /// effect rather than as a parameter change.
    func testResettingASlotPreservesItsPowerState() throws {
        var stack = CameraEffectStackParameters()
        stack.reset(.echo)
        let slot = try XCTUnwrap(stack.firstSlotID(for: .echo))
        var parameters = try XCTUnwrap(stack[slot: slot])
        parameters.primary = 0.02
        parameters.isEnabled = false
        stack[slot: slot] = parameters

        stack.reset(slot: slot)
        XCTAssertEqual(stack[slot: slot]?.primary, WorkspaceAdjustableEffect.echo.defaultCameraParameters.primary)
        XCTAssertEqual(stack[slot: slot]?.isEnabled, false)
    }

    func testRemovingASlotLeavesTheOthers() throws {
        var stack = CameraEffectStackParameters()
        stack.reset(.vhs)
        stack.reset(.grain)
        let first = try XCTUnwrap(stack.firstSlotID(for: .vhs))
        stack.remove(first)

        XCTAssertNil(stack.firstSlotID(for: .vhs))
        XCTAssertNotNil(stack.firstSlotID(for: .grain))
        XCTAssertNil(stack[slot: first])
    }

    /// The scopes are not in the AUDIO family but read the same FFT. If they
    /// do not arm the analyser they draw a flat line and read as broken.
    func testSpectrumScopesArmTheAnalyser() {
        for effect in [WorkspaceAdjustableEffect.spectrumBars, .radialSpectrum, .lissajous] {
            XCTAssertTrue(effect.requiresAudioAnalysis, effect.label)
        }
        // The frame scopes measure the image, not the signal, and must not
        // switch the microphone on to do it.
        for effect in [WorkspaceAdjustableEffect.vectorscope, .waveformMonitor, .rgbParade] {
            XCTAssertFalse(effect.requiresAudioAnalysis, effect.label)
        }
    }
}
