import SwiftUI

/// How a line of splash text resolves.
///
/// The point is that no two rows behave alike. A terminal with failing memory
/// does not redraw uniformly — one line comes back clean, another fills in
/// backwards, another keeps flickering between two readings because whatever
/// is feeding it cannot decide.
enum GVDecayMode: Sendable {
    /// Characters resolve left to right.
    case forward
    /// Characters resolve right to left.
    case reverse
    /// Resolves forward, then one word keeps cycling through corrupt variants.
    case cycling
    /// Fully resolved but periodically drops characters and recovers.
    case dropout
}

/// A single decaying terminal line.
///
/// Timing derives from `revealDate` inside a `TimelineView`, so this costs one
/// timer per visible line and never publishes per-frame state.
struct GVDecayText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String
    let mode: GVDecayMode
    let revealDate: Date
    var size: CGFloat = 10
    var weight: Font.Weight = .bold
    var tracking: CGFloat = 1.0
    var color: Color = GVTheme.ash
    var seed: Int = 0

    /// Glyphs a failing display substitutes in. Deliberately restricted to
    /// characters that occupy the same visual weight as the originals, so the
    /// line does not visibly change width while it resolves.
    private static let noise = Array("!<>-_\\/[]{}—=+*^?#01")

    private var settleDuration: Double { 0.55 }

    var body: some View {
        if reduceMotion {
            line(text)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 24, paused: false)) { timeline in
                let elapsed = max(timeline.date.timeIntervalSince(revealDate), 0)
                line(resolved(at: elapsed))
            }
        }
    }

    private func line(_ value: String) -> some View {
        Text(value)
            .gvMono(size, weight)
            .tracking(tracking)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    private func resolved(at elapsed: Double) -> String {
        let characters = Array(text)
        let progress = min(elapsed / settleDuration, 1)

        if progress >= 1 {
            return settled(characters, elapsed: elapsed)
        }

        let count = characters.count
        let resolvedCount = Int(Double(count) * progress)

        return String(characters.enumerated().map { index, character -> Character in
            guard character != " " else { return character }
            let isResolved = switch mode {
            case .reverse: index >= count - resolvedCount
            default: index < resolvedCount
            }
            if isResolved { return character }
            let roll = abs((index &* 31) &+ Int(elapsed * 40) &+ seed)
            return Self.noise[roll % Self.noise.count]
        })
    }

    /// Post-settle behaviour. `forward` and `reverse` simply stay put; the
    /// other two keep failing on a slow cycle.
    private func settled(_ characters: [Character], elapsed: Double) -> String {
        switch mode {
        case .forward, .reverse:
            return text

        case .cycling:
            // One word keeps flipping, as though its source never committed.
            let words = text.split(separator: " ", omittingEmptySubsequences: false)
            guard words.count > 1 else { return text }
            let target = seed % words.count
            let tick = Int(elapsed * 3) + seed
            guard tick % 4 == 0 else { return text }
            let corrupted = String(words[target].map { character in
                character == " " ? character : Self.noise[(tick &* 7 &+ Int(character.asciiValue ?? 0)) % Self.noise.count]
            })
            var rebuilt = words.map(String.init)
            rebuilt[target] = corrupted
            return rebuilt.joined(separator: " ")

        case .dropout:
            // Periodically loses a run of characters, then recovers.
            let cycle = Int(elapsed * 2) + seed
            guard cycle % 5 == 0 else { return text }
            let start = (cycle &* 13) % max(characters.count - 3, 1)
            return String(characters.enumerated().map { index, character in
                index >= start && index < start + 3 && character != " " ? " " : character
            })
        }
    }
}

/// Title treatment for `grey//VISION`.
///
/// A travelling specular band plus a steady violet bloom. This is the only
/// element on the splash allowed continuous emission — everything else is
/// dim and decaying, which is what makes the title read unambiguously as the
/// name of the application rather than another status row.
struct GVTitleShimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String
    var size: CGFloat = 40
    var tracking: CGFloat = 6.8

    var body: some View {
        base
            .overlay {
                if !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 3.6) / 3.6
                        base
                            .foregroundStyle(.white)
                            .mask(
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: max(phase - 0.16, 0)),
                                        .init(color: .white, location: phase),
                                        .init(color: .clear, location: min(phase + 0.16, 1))
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .blendMode(.plusLighter)
                    }
                }
            }
            .shadow(color: GVTheme.violet.opacity(0.42), radius: 7)
            .shadow(color: GVTheme.violetDeep.opacity(0.40), radius: 22)
            .accessibilityAddTraits(.isHeader)
    }

    private var base: some View {
        // Cycles a glyph roughly once a second underneath the shimmer, so the
        // title never sits completely still.
        TimelineView(.animation(minimumInterval: reduceMotion ? 2 : 1 / 8, paused: reduceMotion)) { timeline in
            let tick = reduceMotion ? 0 : Int(timeline.date.timeIntervalSinceReferenceDate)
            Text(Self.mutated(text, tick: tick))
                .gvMono(size, .black)
                .tracking(tracking)
                .foregroundStyle(GVTheme.bone)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }

    private static func mutated(_ text: String, tick: Int) -> String {
        guard tick != 0 else { return text }
        var characters = Array(text)
        let eligible = characters.indices.filter { characters[$0].isLetter }
        guard !eligible.isEmpty else { return text }
        let seed = UInt64(bitPattern: Int64(tick)) &* 2_654_435_761
        guard seed % 3 != 0 else { return text }
        let symbols = Array("#/01<>[]*+")
        characters[eligible[Int(seed % UInt64(eligible.count))]] =
            symbols[Int((seed &>> 8) % UInt64(symbols.count))]
        return String(characters)
    }
}

/// The `grey//VISION` wordmark as it appears in the workspace header.
///
/// Cycles one or two characters roughly once a second so the title reads as a
/// live signal rather than static chrome. Deliberately draws **no** offset
/// ghost copies — `GVTerminalText` renders displaced duplicates behind the
/// glyphs, which at title weight looked like a second string sitting behind
/// the first rather than like emission.
struct GVCyclingWordmark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String
    var size: CGFloat = 14
    var tracking: CGFloat = 0.34
    var glow = true

    private static let symbols = Array("#/01<>[]*+")

    var body: some View {
        if reduceMotion {
            glyphs(text)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 12, paused: false)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                glyphs(mutated(tick: Int(time)))
            }
        }
    }

    private func glyphs(_ value: String) -> some View {
        Text(value)
            .gvMono(size, .black)
            .tracking(tracking)
            .foregroundStyle(GVTheme.bone)
            .lineLimit(1)
            .minimumScaleFactor(0.58)
            .shadow(color: .black.opacity(0.9), radius: 3, y: 1)
            .shadow(color: glow ? GVTheme.violet.opacity(0.5) : .clear, radius: 7)
    }

    /// Swaps one or two glyphs per whole second. The tick is the seed, so the
    /// substitution holds steady for the full second instead of strobing.
    private func mutated(tick: Int) -> String {
        var characters = Array(text)
        let eligible = characters.indices.filter { characters[$0].isLetter }
        guard !eligible.isEmpty else { return text }

        let seed = UInt64(bitPattern: Int64(tick)) &* 2_654_435_761
        // Three seconds in four the title is clean; corruption should punctuate.
        guard seed % 4 != 0 else { return text }

        let first = eligible[Int(seed % UInt64(eligible.count))]
        characters[first] = Self.symbols[Int((seed &>> 8) % UInt64(Self.symbols.count))]
        if eligible.count > 6, seed % 3 == 0 {
            let second = eligible[Int((seed &>> 16) % UInt64(eligible.count))]
            characters[second] = Self.symbols[Int((seed &>> 24) % UInt64(Self.symbols.count))]
        }
        return String(characters)
    }
}
