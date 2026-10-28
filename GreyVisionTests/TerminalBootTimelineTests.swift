@testable import GreyVision
import XCTest

final class TerminalBootTimelineTests: XCTestCase {
    private let lengths = [12, 40, 30, 20]

    func testPowersOnThenTypesEveryLineBeforeDecaying() {
        let timeline = GVTerminalBootTimeline(lineCount: lengths.count)
        let start = timeline.frame(at: 0, lineLengths: lengths)
        XCTAssertEqual(start.power, 0)
        XCTAssertEqual(start.revealed, [0, 0, 0, 0])

        let typed = timeline.frame(at: timeline.decayStart - 0.01, lineLengths: lengths)
        XCTAssertEqual(typed.power, 1)
        XCTAssertEqual(typed.revealed, Array(repeating: .max, count: lengths.count))
        XCTAssertEqual(typed.statusCount, lengths.count)
        XCTAssertEqual(typed.decay, 0)
        XCTAssertEqual(typed.opacity, 1)

        let gone = timeline.frame(at: timeline.end, lineLengths: lengths)
        XCTAssertEqual(gone.decay, 1)
        XCTAssertEqual(gone.opacity, 0)
    }

    func testATapSkipsStraightToTheDecay() {
        let natural = GVTerminalBootTimeline(lineCount: lengths.count)
        let skipped = GVTerminalBootTimeline(lineCount: lengths.count, skippedAt: 0.5)
        XCTAssertEqual(skipped.decayStart, 0.5)
        XCTAssertLessThan(skipped.end, natural.end)
        // A tap after the decay has begun changes nothing.
        let late = GVTerminalBootTimeline(lineCount: lengths.count, skippedAt: natural.decayStart + 0.2)
        XCTAssertEqual(late.decayStart, natural.decayStart)
    }

    func testTheWholeCeremonyStaysShort() {
        let timeline = GVTerminalBootTimeline(lineCount: 10)
        XCTAssertLessThan(timeline.end, 3.5, "a cold start must not hold the operator hostage")
    }
}
