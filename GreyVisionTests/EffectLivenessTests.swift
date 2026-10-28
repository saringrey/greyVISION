@testable import GreyVision
import simd
import XCTest

/// The fallbacks that keep effects visibly alive when nothing drives them:
/// the ghost finger for touch-drawn effects and the audio floor for
/// audio-driven ones.
final class EffectLivenessTests: XCTestCase {
    func testGhostFingerDrivesOnlyTouchDrawnEffectsAndYieldsToARealFinger() {
        let untouched = SIMD4<Float>(0.5, 0.5, 0, 0)
        let ghost = GVGhostFinger.resolve(effect: .fluid, touch: untouched, drag: .zero, time: 3)
        XCTAssertEqual(ghost.touch.w, 1, "an untouched fluid is stirred")
        XCTAssertTrue((0 ... 1).contains(ghost.touch.x) && (0 ... 1).contains(ghost.touch.y))

        let real = SIMD4<Float>(0.2, 0.8, 0.4, 1)
        XCTAssertEqual(GVGhostFinger.resolve(effect: .fluid, touch: real, drag: .zero, time: 3).touch, real,
                       "a real finger always wins")
        XCTAssertEqual(GVGhostFinger.resolve(effect: .thermal, touch: untouched, drag: .zero, time: 3).touch, untouched,
                       "effects that merely respond to touch keep their untouched look")

        let later = GVGhostFinger.inputs(at: 4)
        XCTAssertNotEqual(ghost.touch, later.touch, "the ghost moves")
    }

    func testAudioFloorOnlyRaisesAudioLooksAndNeverMasksRealSound() {
        let silence = GVAudioIdle.Signal(bands: .zero, dynamics: .zero, spectrum: (.zero, .zero, .zero, .zero))
        let floored = GVAudioIdle.resolve(effect: .audioRepair, live: silence, time: 1)
        XCTAssertGreaterThan(floored.bands.y, 0.1, "silence still breathes")

        let loud = GVAudioIdle.Signal(bands: SIMD4(1, 1, 1, 1), dynamics: SIMD4(1, 1, 1, 1),
                                      spectrum: (SIMD4(1, 1, 1, 1), SIMD4(1, 1, 1, 1), SIMD4(1, 1, 1, 1), SIMD4(1, 1, 1, 1)))
        XCTAssertEqual(GVAudioIdle.resolve(effect: .audioRepair, live: loud, time: 1).bands, loud.bands)

        XCTAssertEqual(GVAudioIdle.resolve(effect: .spectrumBars, live: silence, time: 1).bands, .zero,
                       "an instrument reports silence as silence")
        XCTAssertEqual(GVAudioIdle.resolve(effect: .thermal, live: silence, time: 1).bands, .zero)
    }

    func testFloatClockKeepsSubMillisecondPrecisionAcrossItsPeriod() {
        // The effect clock wraps at 4096 s. Raw uptime did not: at a week of
        // uptime a Float has no fractional bits left at `time * 12`, which is
        // what silenced every time-hashed effect.
        let wrapped = Float(4095.9)
        XCTAssertLessThan(wrapped.ulp, 0.001)
        let rawUptime = Float(604_800 * 12)
        XCTAssertGreaterThanOrEqual(rawUptime.ulp, 0.5)
    }
}
