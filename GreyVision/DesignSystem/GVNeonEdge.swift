import SwiftUI

/// A neon tube pinned to one edge of the frame, glowing inward.
///
/// Native equivalent of the React Bits `neon-reveal` bar: a bright core line, a
/// hotspot sweeping along it, and a falloff that decays inward. The glow depth
/// is bounded by `reach` so it dies before it crosses the viewport — it only
/// ever lights the panel it sits behind.
///
/// Flicker and glitch are driven from a hash of the current time slice, so the
/// tube stutters and tears at irregular intervals rather than on a loop.
struct GVNeonEdge: View {
    enum Edge {
        case top
        case bottom
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let edge: Edge
    /// How far the glow penetrates, in points.
    var reach: CGFloat = 96
    var tint = GVTheme.violet
    /// Overall strength, 0...1.
    var intensity: Double = 1

    var body: some View {
        Group {
            if reduceMotion {
                tube(flicker: 0.85, sweep: 0.5, tear: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    tube(
                        flicker: GVNeonEdge.flicker(at: time, seed: edge == .top ? 3 : 91),
                        sweep: GVNeonEdge.sweep(at: time, edge: edge),
                        tear: GVNeonEdge.tear(at: time, seed: edge == .top ? 17 : 53)
                    )
                }
            }
        }
        .frame(height: reach)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func tube(flicker: Double, sweep: Double, tear: Double) -> some View {
        let energy = intensity * flicker

        return ZStack(alignment: edge == .top ? .top : .bottom) {
            // Inward falloff. Clear at the far end so it never reaches the
            // opposite side of the viewport.
            LinearGradient(
                stops: [
                    .init(color: tint.opacity(0.30 * energy), location: 0.00),
                    .init(color: tint.opacity(0.14 * energy), location: 0.16),
                    .init(color: tint.opacity(0.055 * energy), location: 0.38),
                    .init(color: tint.opacity(0.016 * energy), location: 0.62),
                    .init(color: .clear, location: 1.00)
                ],
                startPoint: edge == .top ? .top : .bottom,
                endPoint: edge == .top ? .bottom : .top
            )

            // Travelling hotspot along the tube.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: max(sweep - 0.30, 0)),
                    .init(color: tint.opacity(0.34 * energy), location: sweep),
                    .init(color: .clear, location: min(sweep + 0.30, 1))
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: reach * 0.55)
            .blur(radius: 12)
            .frame(maxHeight: .infinity, alignment: edge == .top ? .top : .bottom)

            // The tube itself.
            core(energy: energy, sweep: sweep)
                .offset(x: tear * 14)
        }
        .compositingGroup()
        .blendMode(.screen)
    }

    private func core(energy: Double, sweep: Double) -> some View {
        ZStack(alignment: edge == .top ? .top : .bottom) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            tint.opacity(0.30 * energy),
                            .white.opacity(0.85 * energy),
                            tint.opacity(0.30 * energy)
                        ],
                        startPoint: UnitPoint(x: max(sweep - 0.5, 0), y: 0.5),
                        endPoint: UnitPoint(x: min(sweep + 0.5, 1), y: 0.5)
                    )
                )
                .frame(height: 1.4)
                .shadow(color: tint.opacity(0.75 * energy), radius: 7)
                .shadow(color: tint.opacity(0.35 * energy), radius: 16)
        }
        .frame(maxHeight: .infinity, alignment: edge == .top ? .top : .bottom)
    }

    // MARK: - Behaviour

    /// Mains-style flicker: mostly lit, with brief brownouts and the occasional
    /// full dropout.
    static func flicker(at time: TimeInterval, seed: Int) -> Double {
        let slice = Int(time * 18) &+ seed
        let roll = hash(slice)
        if roll > 0.985 {
            return 0.15
        }
        if roll > 0.94 {
            return 0.55
        }
        // Gentle mains hum so it is never perfectly steady.
        return 0.88 + sin(time * 7.3 + Double(seed)) * 0.12
    }

    /// Hotspot position, 0...1. The two edges travel in opposite directions.
    static func sweep(at time: TimeInterval, edge: Edge) -> Double {
        let period = edge == .top ? 7.4 : 9.1
        let phase = (time / period).truncatingRemainder(dividingBy: 1)
        let travel = edge == .top ? phase : 1 - phase
        return min(max(travel, 0), 1)
    }

    /// Occasional lateral tear, -1...1. Zero almost all of the time.
    static func tear(at time: TimeInterval, seed: Int) -> Double {
        let slice = Int(time * 12) &+ seed
        let roll = hash(slice)
        guard roll > 0.965 else { return 0 }
        return (hash(slice &* 7) - 0.5) * 2
    }

    private static func hash(_ value: Int) -> Double {
        let mixed = UInt64(bitPattern: Int64(value)) &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double((mixed >> 33) % 100_000) / 100_000
    }
}
