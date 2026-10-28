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
///     loading  a Win95-style setup dialog loads codec drivers, stalls
///     fail     the dialog quietly reports it cannot continue
///     crash    the tube switches off: raster collapses to a line, a dot,
///              then nothing — five seconds of dead black
///     fade     the black lifts onto the codec selection splash
///
/// Deliberately calm. Constant tearing and colour fringing read as an
/// effect laid over a fake; a real machine boots cleanly, fails quietly and
/// dies all at once. A tap skips straight to the fade.
struct GVTerminalBootTimeline {
    static let beepTimes = [0.4, 0.95, 1.5]
    static let beepFlash = 0.16
    static let powerStart = 1.95
    static let powerDuration = 0.42
    static let lineGap = 0.26
    static let charactersPerSecond = 80.0
    static let promptHold = 0.45
    /// Long on purpose: a real setup bar is something you sit and watch.
    static let loadDuration = 7.0
    /// Fraction of the load at which the bar stops moving for good.
    static let stallAt = 0.8
    static let stallProgress = 0.87
    static let failHold = 1.1
    /// The power-off collapse, raster to dot.
    static let collapseDuration = 0.22
    /// The dot's afterglow once the raster has gone.
    static let afterglowDuration = 0.45
    /// Dead screen between the crash and the fade.
    static let blackHold = 5.0
    static let fadeDuration = 1.0

    enum Phase: Equatable { case dot, post, loading, fail, crash }

    let lineCount: Int
    /// Elapsed time of a tap, if the operator skipped.
    var skippedAt: Double?

    var firstLine: Double { Self.powerStart + Self.powerDuration + 0.12 }
    var loadStart: Double { firstLine + Double(lineCount) * Self.lineGap + Self.promptHold }
    var failStart: Double { loadStart + Self.loadDuration }
    var crashStart: Double { failStart + Self.failHold }

    var fadeStart: Double {
        let natural = crashStart + Self.blackHold
        guard let skippedAt else { return natural }
        return min(natural, skippedAt)
    }

    var end: Double { fadeStart + Self.fadeDuration }

    struct Frame: Equatable {
        var phase: Phase
        var power: Double
        /// Centre-dot brightness before the raster opens.
        var dot: Double
        /// Beeps fired so far; a change is a cue to sound one.
        var beeps: Int
        /// 0...1 through the closing fade onto the splash.
        var fade: Double
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
        let fade = clamp((time - fadeStart) / Self.fadeDuration)
        let phase: Phase = time < Self.powerStart ? .dot
            : time < loadStart ? .post
            : time < failStart ? .loading
            : time < crashStart ? .fail
            : .crash

        var dot = 0.0
        var beeps = 0
        for beep in Self.beepTimes where time >= beep {
            beeps += 1
            dot = max(dot, time - beep < Self.beepFlash ? 1 : 0.28)
        }
        if time < Self.powerStart, beeps == 0 {
            // The dot warms up before the first beep.
            dot = clamp((time - 0.12) / 0.25) * 0.28
        }
        var power = easeOut(clamp((time - Self.powerStart) / Self.powerDuration))
        if phase == .crash {
            // Power-off: the raster folds to a line and then a dot, which
            // glows on briefly the way a tube's phosphor does, then dies.
            let collapse = clamp((time - crashStart) / Self.collapseDuration)
            power = 1 - collapse * collapse
            dot = 1 - clamp((time - crashStart - Self.collapseDuration) / Self.afterglowDuration)
        }

        var revealed: [Int] = []
        var statusCount = 0
        for (index, length) in lineLengths.enumerated() {
            let start = firstLine + Double(index) * Self.lineGap
            let typed = max(Int((time - start) * Self.charactersPerSecond), 0)
            revealed.append(typed >= length ? .max : typed)
            if time >= start + Double(length) / Self.charactersPerSecond + 0.03 {
                statusCount += 1
            }
        }

        return Frame(
            phase: phase,
            power: power,
            dot: dot,
            beeps: beeps,
            fade: fade,
            revealed: revealed,
            statusCount: statusCount,
            cursorOn: Int(time * 3.2) % 2 == 0,
            load: loadProgress(at: time),
            progress: clamp(time / crashStart),
            opacity: 1 - smoothstep(0, 1, fade)
        )
    }

    /// The setup bar fills a driver at a time. Each step takes its own,
    /// uneven share of the time — some files fly past, some hang — and the
    /// bar stalls for good short of the end.
    private func loadProgress(at time: Double) -> Double {
        let t = clamp((time - loadStart) / Self.loadDuration)
        let moving = clamp(t / Self.stallAt)
        guard moving > 0 else { return 0 }
        var elapsed = moving * Self.stepWeightTotal
        var completed = 0
        for weight in Self.stepWeights {
            guard elapsed >= weight - 1e-9 else { break }
            elapsed -= weight
            completed += 1
        }
        let stepped = Double(completed) / Double(Self.stepWeights.count)
        return min(stepped * Self.stallProgress, Self.stallProgress)
    }

    /// Relative durations of the bar's steps, seeded so every boot hangs in
    /// the same places.
    private static let stepWeights: [Double] = (0 ..< 18).map { 0.35 + pow(hash(Double($0) * 7.3), 2.5) * 2.4 }
    private static let stepWeightTotal = stepWeights.reduce(0, +)

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
