import SwiftUI

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
