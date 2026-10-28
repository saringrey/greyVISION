import Foundation

/// The cold-start terminal's choreography as a pure function of time.
///
/// Every value the view, the CRT shader and the sound cues read is derived
/// from elapsed time here, so the sequence costs one animation clock,
/// publishes nothing per frame, and can be reasoned about (and tested)
/// without a screen.
///
///     dot      a lone phosphor dot at centre, three POST beeps
///     power    dot → line → raster
///     post     the boot log types out, [ OK ] on each line
///     loading  a Win95-style setup dialog loads "codec drivers", stalls
///     crash    it corrupts into a fatal-exception screen
///     decay    the raster breaks into blocks and the splash shows through
///
/// A tap skips straight to the decay.
struct GVTerminalBootTimeline {
    static let beepTimes = [0.4, 0.95, 1.5]
    static let beepFlash = 0.16
    static let powerStart = 1.95
    static let powerDuration = 0.42
    static let lineGap = 0.26
    static let charactersPerSecond = 80.0
    static let promptHold = 0.45
    static let loadDuration = 1.9
    /// Fraction of the load at which the bar stops moving for good.
    static let stallAt = 0.62
    static let stallProgress = 0.87
    static let crashHold = 1.7
    static let decayDuration = 0.7

    enum Phase: Equatable { case dot, post, loading, crash }

    let lineCount: Int
    /// Elapsed time of a tap, if the operator skipped.
    var skippedAt: Double?

    var firstLine: Double { Self.powerStart + Self.powerDuration + 0.12 }
    var loadStart: Double { firstLine + Double(lineCount) * Self.lineGap + Self.promptHold }
    var crashStart: Double { loadStart + Self.loadDuration }

    var decayStart: Double {
        let natural = crashStart + Self.crashHold
        guard let skippedAt else { return natural }
        return min(natural, skippedAt)
    }

    var end: Double { decayStart + Self.decayDuration }

    struct Frame: Equatable {
        var phase: Phase
        var power: Double
        /// Centre-dot brightness before the raster opens.
        var dot: Double
        /// Beeps fired so far; a change is a cue to sound one.
        var beeps: Int
        var tear: Double
        var decay: Double
        /// Glyph-level corruption on the crash screen, 0...1.
        var corruption: Double
        /// Characters revealed per line; `Int.max` once a line is complete.
        var revealed: [Int]
        /// Lines whose status token is showing.
        var statusCount: Int
        var cursorOn: Bool
        /// The setup dialog's bar, 0...1.
        var load: Double
        /// 0...1 boot progress for the HUD bar.
        var progress: Double
        var opacity: Double
    }

    func frame(at time: Double, lineLengths: [Int]) -> Frame {
        let decay = clamp((time - decayStart) / Self.decayDuration)
        let phase: Phase = time < Self.powerStart ? .dot
            : time < loadStart ? .post
            : time < crashStart ? .loading
            : .crash

        var dot = 0.0
        var beeps = 0
        for beep in Self.beepTimes where time >= beep {
            beeps += 1
            let since = time - beep
            dot = max(dot, since < Self.beepFlash ? 1 : 0.28)
        }
        if time < Self.powerStart, beeps == 0 {
            // The dot warms up before the first beep.
            dot = clamp((time - 0.12) / 0.25) * 0.28
        }

        var revealed: [Int] = []
        var statusCount = 0
        var lastStatusAt = -Double.infinity
        for (index, length) in lineLengths.enumerated() {
            let start = firstLine + Double(index) * Self.lineGap
            let typed = max(Int((time - start) * Self.charactersPerSecond), 0)
            revealed.append(typed >= length ? .max : typed)
            let statusAt = start + Double(length) / Self.charactersPerSecond + 0.03
            if time >= statusAt {
                statusCount += 1
                lastStatusAt = statusAt
            }
        }

        let load = loadProgress(at: time)
        let tear = tearAmount(at: time, phase: phase, lastStatusAt: lastStatusAt)
        let crashAge = time - crashStart
        return Frame(
            phase: phase,
            power: easeOut(clamp((time - Self.powerStart) / Self.powerDuration)),
            dot: dot,
            beeps: beeps,
            tear: decay > 0 ? max(tear, decay) : tear,
            decay: decay,
            corruption: phase == .crash ? clamp(crashAge / Self.crashHold) * 0.3 : 0,
            revealed: revealed,
            statusCount: statusCount,
            cursorOn: Int(time * 3.2) % 2 == 0,
            load: load,
            progress: clamp(time / decayStart),
            opacity: 1 - smoothstep(0.5, 1, decay)
        )
    }

    /// The setup bar fills in uneven steps, then stalls short of the end.
    private func loadProgress(at time: Double) -> Double {
        let t = clamp((time - loadStart) / Self.loadDuration)
        let moving = clamp(t / Self.stallAt)
        // Chunky, uneven steps: a driver at a time, not a smooth fill.
        let steps = 9.0
        let stepped = (moving * steps).rounded(.down) / steps
        let jitter = Self.hash(stepped * 31) * 0.05
        return min(stepped * Self.stallProgress + (stepped > 0 ? jitter : 0), Self.stallProgress)
    }

    private func tearAmount(at time: Double, phase: Phase, lastStatusAt: Double) -> Double {
        // Burst tears: rare, short, seeded by the 14 Hz tick so they look
        // random but replay identically for the same time.
        let tick = (time * 14).rounded(.down)
        let roll = Self.hash(tick)
        switch phase {
        case .dot:
            return 0
        case .post:
            let burst = roll > 0.9 ? 0.5 : 0
            // Each [ OK ] lands with a jolt that settles in 90 ms.
            let jolt = max(0, 1 - (time - lastStatusAt) / 0.09) * 0.4
            return min(0.04 + burst + jolt, 1)
        case .loading:
            // Calm until the bar stalls, then the signal starts to go.
            let stalled = clamp((time - loadStart - Self.loadDuration * Self.stallAt) / (Self.loadDuration * (1 - Self.stallAt)))
            let burst = roll > 0.93 - stalled * 0.35 ? 0.35 + stalled * 0.5 : 0
            return min(0.03 + stalled * 0.25 + burst, 1)
        case .crash:
            let age = time - crashStart
            // The switch to the crash screen is the hardest hit of all.
            let impact = max(0, 1 - age / 0.22)
            let creeping = clamp(age / Self.crashHold)
            let burst = roll > 0.9 - creeping * 0.3 ? 0.3 + creeping * 0.4 : 0
            return min(0.04 + impact + burst, 1)
        }
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
