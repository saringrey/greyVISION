import Foundation
import SwiftUI

/// Terminal-glitch presentation for the real runtime telemetry collected by
/// `BootTelemetry`.
///
/// No values are invented here: the strings arrive from live Metal, camera,
/// depth, audio and thermal probes. This type only decides how a line resolves
/// on screen — character substitution, a dropped glyph that fills back in, and
/// a one-frame horizontal displacement.
enum GVBootTelemetry {
    /// Deterministic per-line seed so a given line always corrupts the same way.
    static func seed(for line: String, index: Int) -> UInt64 {
        line.unicodeScalars.reduce(UInt64(index &* 2_654_435_761) &+ 1) { partial, scalar in
            (partial ^ UInt64(scalar.value)) &* 1_099_511_628_211
        }
    }

    /// Resolves a line at `progress` (0 = just appeared, 1 = fully settled).
    static func resolved(_ line: String, progress: Double, seed: UInt64) -> String {
        guard progress < 1 else { return line }
        var characters = Array(line)
        let eligible = characters.indices.filter { characters[$0] != " " && characters[$0] != "." }
        guard !eligible.isEmpty else { return line }

        let symbols = Array("#/01<>*+%")
        let corruptionCount = progress < 0.45 ? 3 : progress < 0.8 ? 2 : 1
        for step in 0 ..< corruptionCount {
            let mixed = seed &* UInt64(step &+ 7) &+ UInt64(step) &* 131
            let target = eligible[Int(mixed % UInt64(eligible.count))]
            characters[target] = step == 0 && progress < 0.35
                ? " "
                : symbols[Int((mixed &>> 11) % UInt64(symbols.count))]
        }
        return String(characters)
    }

    /// One-frame horizontal displacement applied while a line settles.
    static func displacement(progress: Double, seed: UInt64) -> CGFloat {
        guard progress < 0.72 else { return 0 }
        let sign: CGFloat = (seed & 1) == 0 ? 1 : -1
        return sign * CGFloat(1 - progress) * 2.6
    }

    /// Phosphor bloom that fades as the line locks in.
    static func bloom(progress: Double) -> Double {
        guard progress < 1 else { return 0 }
        return (1 - progress) * 0.9
    }

    /// How long a single line takes to stop glitching.
    static let settleDuration = 0.22

    // MARK: - Typing

    /// Per-character interval. Fast enough that ten lines still assemble inside
    /// the discovery phase.
    static let typingSpeed = 0.018

    static func typingDuration(_ text: String) -> Double {
        Double(text.count) * typingSpeed
    }

    /// The prefix visible at `elapsed`, with a slight human unevenness so it
    /// does not read as a metronome.
    static func typedPrefix(_ text: String, elapsed: Double) -> String {
        guard elapsed > 0 else { return "" }
        let exact = elapsed / typingSpeed
        // A small wobble on the rate, bounded so it never runs backwards.
        let wobble = sin(elapsed * 21) * 0.6
        let count = Int(max(exact + wobble, 0))
        guard count < text.count else { return text }
        return String(text.prefix(count))
    }

    /// Block cursor: solid while typing, blinking briefly after the line lands,
    /// then gone so the finished console is not a wall of carets.
    static func cursor(elapsed: Double, text: String) -> String {
        let duration = typingDuration(text)
        if elapsed < duration {
            return "\u{2588}"
        }
        let after = elapsed - duration
        guard after < 0.9 else { return "" }
        return after.truncatingRemainder(dividingBy: 0.4) < 0.2 ? "\u{2588}" : " "
    }
}

/// A telemetry line that assembles with terminal corruption instead of a
/// character-by-character typewriter.
struct GVBootTelemetryLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String
    let index: Int
    let isRevealed: Bool
    let revealDate: Date
    /// Re-corrupts an already-resolved line for a moment.
    var isGlitching = false
    var size: CGFloat = 9.2
    var tracking: CGFloat = 0.82

    var body: some View {
        Group {
            if reduceMotion || !isRevealed {
                staticLine(isRevealed ? "> \(text)" : placeholder, revealed: isRevealed)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { timeline in
                    let elapsed = max(timeline.date.timeIntervalSince(revealDate), 0)

                    // The line types itself in first, then settles out of its
                    // corruption. Typing before resolving means the glitch only
                    // ever touches characters that have actually arrived.
                    let typed = GVBootTelemetry.typedPrefix(text, elapsed: elapsed)
                    let isTyping = typed.count < text.count

                    let settleElapsed = max(elapsed - GVBootTelemetry.typingDuration(text), 0)
                    let settled = min(settleElapsed / GVBootTelemetry.settleDuration, 1)
                    let progress = isGlitching ? min(settled, 0.45) : settled
                    let seed = GVBootTelemetry.seed(for: text, index: index)
                    let resolved = isTyping
                        ? typed
                        : GVBootTelemetry.resolved(text, progress: progress, seed: seed)

                    // Cursor rides the end of the line while it is being typed
                    // and blinks for a beat once the line lands.
                    let cursor = GVBootTelemetry.cursor(elapsed: elapsed, text: text)

                    staticLine("> \(resolved)\(cursor)", revealed: true)
                        .offset(x: GVBootTelemetry.displacement(progress: progress, seed: seed))
                        .shadow(
                            color: GVTheme.violet.opacity(GVBootTelemetry.bloom(progress: progress)),
                            radius: 4
                        )
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }

    private var placeholder: String {
        "· " + String(repeating: "·", count: min(text.count, 30))
    }

    private func staticLine(_ value: String, revealed: Bool) -> some View {
        Text(value)
            .gvMono(size, .medium)
            .tracking(tracking)
            .foregroundStyle(revealed ? GVTheme.bone : GVTheme.faint)
    }
}

// MARK: - Element decay

/// Momentary signal decay applied to a single splash element.
///
/// Deliberately cheap — an offset, a chromatic smear and a brightness dip.
/// Anything heavier would cost more than the effect is worth on a screen that
/// only exists for a few seconds.
struct GVElementDecay: ViewModifier {
    let isActive: Bool
    var seed: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            let displacement = isActive ? CGFloat(sin(seed * 12.9898) * 4.5) : 0
            content
                .offset(x: displacement)
                .overlay {
                    if isActive {
                        content
                            .foregroundStyle(GVTheme.violet)
                            .offset(x: -displacement * 0.7)
                            .blendMode(.screen)
                            .opacity(0.55)
                            .allowsHitTesting(false)
                    }
                }
                .brightness(isActive ? -0.18 : 0)
                .animation(.linear(duration: 0.06), value: isActive)
        }
    }
}

extension View {
    /// Applies transient decay when this element is the one currently glitching.
    func gvDecay(_ isActive: Bool, seed: Double = 0) -> some View {
        modifier(GVElementDecay(isActive: isActive, seed: seed))
    }
}
