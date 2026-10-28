import Foundation

/// The cold-start terminal's choreography as a pure function of time.
///
/// Every value the view and the CRT shader read is derived from elapsed time
/// here, so the sequence costs one animation clock, publishes nothing per
/// frame, and can be reasoned about (and tested) without a screen.
///
///     0.00  power-on: dot → line → raster
///     0.36  boot log types out, one line every 0.16 s, [ OK ] on each
///     …     prompt, cursor blinks
///     +0.5  digital decay: tears ramp, blocks drop, the splash shows through
///
/// A tap skips straight to the decay.
struct GVTerminalBootTimeline {
    static let powerDuration = 0.34
    static let firstLine = 0.36
    static let lineGap = 0.16
    static let charactersPerSecond = 120.0
    static let promptHold = 0.5
    static let decayDuration = 0.62

    let lineCount: Int
    /// Elapsed time of a tap, if the operator skipped.
    var skippedAt: Double?

    var promptStart: Double { Self.firstLine + Double(lineCount) * Self.lineGap }

    var decayStart: Double {
        let natural = promptStart + Self.promptHold
        guard let skippedAt else { return natural }
        return min(natural, skippedAt)
    }

    var end: Double { decayStart + Self.decayDuration }

    struct Frame: Equatable {
        var power: Double
        var tear: Double
        var decay: Double
        /// Characters revealed per line; `Int.max` once a line is complete.
        var revealed: [Int]
        /// Lines whose status token is showing.
        var statusCount: Int
        var promptVisible: Bool
        var cursorOn: Bool
        /// 0...1 boot progress for the HUD bar.
        var progress: Double
        var opacity: Double
    }

    func frame(at time: Double, lineLengths: [Int]) -> Frame {
        let decay = clamp((time - decayStart) / Self.decayDuration)
        var revealed: [Int] = []
        var statusCount = 0
        var lastStatusAt = -Double.infinity
        for (index, length) in lineLengths.enumerated() {
            let start = Self.firstLine + Double(index) * Self.lineGap
            let typed = max(Int((time - start) * Self.charactersPerSecond), 0)
            revealed.append(typed >= length ? .max : typed)
            let statusAt = start + Double(length) / Self.charactersPerSecond + 0.03
            if time >= statusAt {
                statusCount += 1
                lastStatusAt = statusAt
            }
        }
        // Burst tears: rare, short, seeded by the 14 Hz tick so they look
        // random but replay identically for the same time.
        let tick = (time * 14).rounded(.down)
        let burst = Self.hash(tick) > 0.88 ? 0.55 : 0
        // Each [ OK ] lands with a jolt that settles in 90 ms.
        let jolt = max(0, 1 - (time - lastStatusAt) / 0.09) * 0.4
        let tear = min(0.04 + burst + jolt + decay * 0.9, 1)
        return Frame(
            power: easeOut(clamp(time / Self.powerDuration)),
            tear: decay > 0 ? max(tear, decay) : tear,
            decay: decay,
            revealed: revealed,
            statusCount: statusCount,
            promptVisible: time >= promptStart,
            cursorOn: Int(time * 3.2) % 2 == 0,
            progress: clamp(time / decayStart),
            opacity: 1 - smoothstep(0.5, 1, decay)
        )
    }

    private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

    private func easeOut(_ value: Double) -> Double { 1 - pow(1 - value, 3) }

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        let t = clamp((value - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }

    static func hash(_ value: Double) -> Double {
        let s = sin(value * 12.9898 + 78.233) * 43_758.5453
        return s - s.rounded(.down)
    }
}
