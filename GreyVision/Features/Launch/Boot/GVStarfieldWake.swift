import CoreMotion
import SwiftUI

/// Progressive sensor-discovery star field.
///
/// Rather than fading a field in globally, points are woken in deterministic
/// clusters: two or three isolated returns first, then a nearby cluster, then
/// increasingly distant contacts. Individual points blink once, drift, streak
/// vertically, drop out and reappear elsewhere.
///
/// Everything is drawn in a single `Canvas` pass and the whole view is removed
/// once the boot sequence completes, so no GPU work survives the splash.
struct GVStarfieldWake: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 0 = void, 1 = the field is fully awake.
    let progress: Double
    /// Elapsed seconds since the wake phase began, for per-point behaviour.
    let elapsed: Double
    /// Normalised device tilt, when motion is available.
    var tilt = CGSize.zero

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            guard progress > 0, size.width > 0, size.height > 0 else { return }

            for point in GVStarfieldWake.points {
                let wake = point.wakeThreshold
                guard progress >= wake else { continue }

                let local = min((progress - wake) / max(1 - wake, 0.0001), 1)
                let life = elapsed * point.rate + point.phase

                // Points drop out and re-acquire somewhere else.
                let cycle = life.truncatingRemainder(dividingBy: 1)
                let acquired = cycle < point.duty
                guard acquired || reduceMotion else { continue }

                let reacquisitions = floor(life)
                let jump = reduceMotion
                    ? 0
                    : GVStarfieldWake.hash(point.seed &+ UInt64(max(reacquisitions, 0)))
                let x = ((point.x + jump * 0.31).truncatingRemainder(dividingBy: 1)) * size.width
                let drift = reduceMotion ? 0 : sin(life * 1.7 + point.phase) * point.drift
                let y = (point.y * size.height + drift * size.height)
                    .truncatingRemainder(dividingBy: size.height)

                let parallax = CGSize(
                    width: tilt.width * point.depth * 9,
                    height: tilt.height * point.depth * 7
                )

                // A single blink as the point is first acquired.
                let blink = local < 0.22 ? (local < 0.11 ? 0.25 : 1.35) : 1
                let fade = acquired ? min(cycle / max(point.duty, 0.0001) * 4, 1) : 1
                let alpha = min(point.brightness * local * blink * fade, 1)
                guard alpha > 0.01 else { continue }

                let dimension = point.size
                let streaking = !reduceMotion && point.streaks && cycle > point.duty * 0.62
                let height = streaking ? dimension * 9 : dimension

                let rect = CGRect(
                    x: x + parallax.width,
                    y: y + parallax.height,
                    width: dimension,
                    height: height
                )
                context.fill(
                    Path(rect),
                    with: .color(point.isViolet
                        ? GVTheme.violet.opacity(alpha * 0.82)
                        : Color.white.opacity(alpha))
                )
            }
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func hash(_ value: UInt64) -> Double {
        let mixed = (value &* 6_364_136_223_846_793_005) &+ 1_442_695_040_888_963_407
        return Double((mixed >> 33) % 100_000) / 100_000
    }

    fileprivate struct Point: Sendable {
        let x: Double
        let y: Double
        let size: CGFloat
        let brightness: Double
        let wakeThreshold: Double
        let rate: Double
        let phase: Double
        let duty: Double
        let drift: Double
        let depth: Double
        let streaks: Bool
        let isViolet: Bool
        let seed: UInt64
    }

    /// Deterministic field. Density is intentionally restrained — 46 points.
    fileprivate static let points: [Point] = {
        var generator = GVWakeGenerator(seed: 0x5645_4E47_4956_0001)
        return (0 ..< 46).map { index in
            // The first three contacts wake almost immediately and in isolation,
            // the next cluster shortly after, then the distant field.
            let threshold = switch index {
            case 0 ..< 3: 0.02 + Double(index) * 0.03
            case 3 ..< 11: 0.20 + generator.next() * 0.14
            default: 0.38 + generator.next() * 0.60
            }
            let depth = generator.next()
            return Point(
                x: generator.next(),
                y: generator.next(),
                size: CGFloat(0.8 + depth * 1.5),
                brightness: 0.22 + depth * 0.62,
                wakeThreshold: min(threshold, 0.99),
                rate: 0.06 + generator.next() * 0.16,
                phase: generator.next() * 6.28,
                duty: 0.62 + generator.next() * 0.3,
                drift: (generator.next() - 0.5) * 0.03,
                depth: depth,
                streaks: generator.next() > 0.86,
                isViolet: generator.next() > 0.78,
                seed: UInt64(index &* 7919 &+ 13)
            )
        }
    }()
}

/// PHASE 0 — a single phosphor pixel powering on in a dead frame.
///
/// Deliberately tiny. The `GV.BOOT` legend that follows it stays on screen as
/// the header for the discovery console rather than reading as a title card.
struct GVPhosphorPixel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let start: Date
    let isActive: Bool
    /// Fades the whole element once the identity block takes over.
    let retire: Double

    var body: some View {
        Group {
            if reduceMotion {
                legend(pixel: 1, text: 1)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 60, paused: !isActive)) { timeline in
                    let elapsed = max(timeline.date.timeIntervalSince(start), 0)
                    legend(
                        pixel: GVPhosphorPixel.pixelIntensity(elapsed),
                        text: min(max((elapsed - 0.34) / 0.24, 0), 1)
                    )
                }
            }
        }
        .opacity(1 - retire)
        .accessibilityHidden(true)
    }

    private func legend(pixel: Double, text: Double) -> some View {
        HStack(spacing: 5) {
            Rectangle()
                .fill(GVTheme.violet.opacity(pixel))
                .frame(width: 2, height: 2)
                .shadow(color: GVTheme.violet.opacity(pixel * 0.9), radius: 3 + pixel * 4)
                .shadow(color: GVTheme.violetDeep.opacity(pixel * 0.5), radius: 9)

            Text("GV.BOOT")
                .gvMono(7.4, .black)
                .tracking(1.8)
                .foregroundStyle(GVTheme.ash.opacity(text))
        }
    }

    /// dim -> bright -> dim -> stable
    static func pixelIntensity(_ elapsed: Double) -> Double {
        switch elapsed {
        case ..<0.18: 0
        case ..<0.27: 0.26
        case ..<0.34: 1.0
        case ..<0.42: 0.30
        default: 0.78
        }
    }
}

/// The atmospheric bloom that forms behind the mark before it materialises.
struct GVAtmosphericBloom: View {
    let progress: Double
    /// Falls back dramatically once the mark is stable.
    let falloff: Double

    var body: some View {
        let energy = max(progress * (1 - falloff * 0.82), 0)
        RadialGradient(
            stops: [
                .init(color: GVTheme.violet.opacity(0.20 * energy), location: 0),
                .init(color: GVTheme.violet.opacity(0.14 * energy), location: 0.18),
                .init(color: GVTheme.violetDeep.opacity(0.075 * energy), location: 0.38),
                .init(color: GVTheme.violetDeep.opacity(0.032 * energy), location: 0.58),
                .init(color: GVTheme.violetDeep.opacity(0.010 * energy), location: 0.78),
                .init(color: .clear, location: 1)
            ],
            center: .center,
            startRadius: 4,
            endRadius: 300 + 120 * energy
        )
        // Feathered tail: three tight stops put a visible rim on the bloom's
        // edge against pure black; the long whisper stop plus one blur pass
        // makes it read as air lighting up instead of a drawn circle.
        .blur(radius: 16)
        .blendMode(.screen)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Optional device-motion parallax for the wake field.
///
/// Started only for the duration of the splash and stopped in `stop()`; if the
/// device exposes no motion the field simply renders without parallax.
@MainActor
final class GVBootMotion: ObservableObject {
    @Published private(set) var tilt = CGSize.zero

    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1 / 20
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let roll = min(max(motion.attitude.roll, -0.7), 0.7) / 0.7
            let pitch = min(max(motion.attitude.pitch + 0.6, -0.7), 0.7) / 0.7
            tilt = CGSize(width: roll, height: pitch)
        }
    }

    /// Motion updates are stopped explicitly by `BootView` when the sequence
    /// finishes or the view disappears; there is no nonisolated teardown path.
    func stop() {
        guard manager.isDeviceMotionActive else { return }
        manager.stopDeviceMotionUpdates()
        tilt = .zero
    }
}

private struct GVWakeGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> Double {
        state = (state &* 6_364_136_223_846_793_005) &+ 1_442_695_040_888_963_407
        return Double((state >> 33) % 1_000_000) / 1_000_000
    }
}
