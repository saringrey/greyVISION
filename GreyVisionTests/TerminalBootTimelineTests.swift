@testable import GreyVision
import XCTest

final class TerminalBootTimelineTests: XCTestCase {
    private let lengths = [12, 40, 30, 20]

    func testPowersOnThenTypesEveryLineBeforeDecaying() {
        let timeline = GVTerminalBootTimeline(lineCount: lengths.count)
        let start = timeline.frame(at: 0, lineLengths: lengths)
        XCTAssertEqual(start.phase, .dot)
        XCTAssertEqual(start.power, 0)
        XCTAssertEqual(start.revealed, [0, 0, 0, 0])

        let beeped = timeline.frame(at: GVTerminalBootTimeline.powerStart - 0.01, lineLengths: lengths)
        XCTAssertEqual(beeped.beeps, 3, "three POST beeps before the raster opens")
        XCTAssertEqual(beeped.power, 0)

        let typed = timeline.frame(at: timeline.loadStart - 0.01, lineLengths: lengths)
        XCTAssertEqual(typed.phase, .post)
        XCTAssertEqual(typed.power, 1)
        XCTAssertEqual(typed.revealed, Array(repeating: .max, count: lengths.count))
        XCTAssertEqual(typed.statusCount, lengths.count)
        XCTAssertEqual(typed.fade, 0)
        XCTAssertEqual(typed.opacity, 1)

        let stalled = timeline.frame(at: timeline.failStart - 0.01, lineLengths: lengths)
        XCTAssertEqual(stalled.phase, .loading)
        XCTAssertEqual(stalled.load, GVTerminalBootTimeline.stallProgress, accuracy: 0.001, "setup never finishes")

        let failed = timeline.frame(at: timeline.crashStart - 0.01, lineLengths: lengths)
        XCTAssertEqual(failed.phase, .fail)
        XCTAssertEqual(failed.power, 1, "the failure is shown cleanly")

        let decaying = timeline.frame(at: timeline.crashStart + GVTerminalBootTimeline.decayDuration / 2, lineLengths: lengths)
        XCTAssertGreaterThan(decaying.decay, 0, "the picture decays before it goes")
        XCTAssertLessThan(decaying.decay, 1)
        XCTAssertEqual(decaying.power, 1)

        let dead = timeline.frame(at: timeline.crashStart + GVTerminalBootTimeline.decayDuration + 0.5, lineLengths: lengths)
        XCTAssertEqual(dead.phase, .crash)
        XCTAssertEqual(dead.power, 0, "then it is gone, no collapse")
        XCTAssertEqual(dead.dot, 0, "and no afterglow")
        XCTAssertEqual(dead.opacity, 1, "the screen stays black until the fade")
        XCTAssertEqual(timeline.fadeStart - timeline.crashStart,
                       GVTerminalBootTimeline.decayDuration + 1, accuracy: 0.001, "one second of black")
        XCTAssertGreaterThanOrEqual(GVTerminalBootTimeline.fadeDuration, 2, "the UI fades in slowly")
        XCTAssertTrue((6 ... 8.5).contains(timeline.crashStart - timeline.loadStart), "the setup box holds 6–8 s")

        let gone = timeline.frame(at: timeline.end, lineLengths: lengths)
        XCTAssertEqual(gone.fade, 1)
        XCTAssertEqual(gone.opacity, 0)
    }

    func testATapSkipsStraightToTheFade() {
        let natural = GVTerminalBootTimeline(lineCount: lengths.count)
        let skipped = GVTerminalBootTimeline(lineCount: lengths.count, skippedAt: 0.5)
        XCTAssertEqual(skipped.fadeStart, 0.5)
        XCTAssertLessThan(skipped.end, natural.end)
        // A tap after the fade has begun changes nothing.
        let late = GVTerminalBootTimeline(lineCount: lengths.count, skippedAt: natural.fadeStart + 0.2)
        XCTAssertEqual(late.fadeStart, natural.fadeStart)
    }

    func testTheCeremonyIsLongEnoughToReadButBounded() {
        let timeline = GVTerminalBootTimeline(lineCount: 10)
        XCTAssertGreaterThan(timeline.failStart - timeline.loadStart, 6.5, "the setup bar is something you sit and watch")
        XCTAssertLessThan(timeline.end, 21, "a cold start must not hold the operator hostage; a tap skips it")
    }
}
