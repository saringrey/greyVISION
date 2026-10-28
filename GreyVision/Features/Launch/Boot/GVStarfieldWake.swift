import CoreMotion
import SwiftUI

/// The splash star field.
///
/// Previously this modelled *sensor contacts* rather than stars: 46 points
/// drawn as rectangles, each blinking out on a duty cycle and teleporting to a
/// new column when it re-acquired. That reads as a radar sweep, which is what
/// it was written to be — it never read as a sky.
///
/// It is a star field now. Points hold their position for the whole sequence,
/// are drawn as round dots with a halo on the brightest few, and twinkle by
/// modulating brightness rather than by disappearing. Density is up from 46 to
/// 240, which is what actually makes it read as depth rather than as scattered
/// marks.
///
/// Everything is still one `Canvas` pass, still deterministic, and the whole
/// view is still removed once the boot sequence completes, so no GPU work
/// survives the splash.
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

            for star in GVStarfieldWake.points {
                // Stars arrive in waves so the sky fills in rather than
                // switching on, but once a star is out it stays out.
                guard progress >= star.wakeThreshold else { continue }
                let local = min((progress - star.wakeThreshold) / max(1 - star.wakeThreshold, 0.0001), 1)

                // Twinkle modulates brightness between roughly half and full.
                // The old duty cycle dropped points to nothing, which is what
                // made the field flicker instead of shimmer.
                let twinkle = reduceMotion
                    ? 1
                    : 0.72 + 0.28 * sin(elapsed * star.twinkleRate + star.phase)

                let alpha = min(star.brightness * local * twinkle, 1)
                guard alpha > 0.012 else { continue }

                // Parallax halved again — near star ~1.8pt at full tilt.
                let x = star.x * size.width + tilt.width * star.depth * 1.8
                let y = star.y * size.height + tilt.height * star.depth * 1.4
                let diameter = star.size

                let rect = CGRect(
                    x: x - diameter / 2,
                    y: y - diameter / 2,
                    width: diameter,
                    height: diameter
                )

                // Halo on the nearest, brightest few. Drawn under the core so
                // the dot keeps a hard centre inside a soft bloom.
                if star.hasHalo {
                    let haloDiameter = diameter * 4.5
                    let halo = CGRect(
                        x: x - haloDiameter / 2,
                        y: y - haloDiameter / 2,
                        width: haloDiameter,
                        height: haloDiameter
                    )
                    context.fill(
                        Path(ellipseIn: halo),
                        with: .radialGradient(
                            Gradient(colors: [
                                star.tint.opacity(alpha * 0.30),
                                star.tint.opacity(0)
                            ]),
                            center: CGPoint(x: x, y: y),
                            startRadius: 0,
                            endRadius: haloDiameter / 2
                        )
                    )
                }

                context.fill(Path(ellipseIn: rect), with: .color(star.tint.opacity(alpha)))
            }
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    fileprivate struct Star: Sendable {
        let x: Double
        let y: Double
        let size: CGFloat
        let brightness: Double
        let wakeThreshold: Double
        let twinkleRate: Double
        let phase: Double
        let depth: Double
        let hasHalo: Bool
        let tint: Color
    }

    /// Deterministic sky.
    fileprivate static let points: [Star] = {
        var generator = GVWakeGenerator(seed: 0x5645_4E47_4956_0001)
        return (0 ..< 240).map { _ in
            // Depth drives size, brightness and parallax together, so near
            // stars are big, bright and move most — the one correlation that
            // makes a flat point cloud read as a volume.
            let depth = generator.next()
            let near = depth > 0.93

            // A handful of violet stars, matching the splash palette. Kept
            // rare: a two-tone sky stops looking like a sky.
            let isViolet = generator.next() > 0.93

            return Star(
                x: generator.next(),
                y: generator.next(),
                size: CGFloat(0.7 + depth * depth * 2.6),
                brightness: 0.16 + depth * 0.74,
                // Front-loaded so a scatter of stars is already out early and
                // the rest fill in behind them.
                wakeThreshold: min(pow(generator.next(), 1.6) * 0.92, 0.95),
                twinkleRate: 0.5 + generator.next() * 2.1,
                phase: generator.next() * 6.28,
                depth: depth,
                hasHalo: near,
                tint: isViolet ? GVTheme.violet : .white
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
    /// Smoothed tilt — raw deviceMotion jitters and would make the shader
    /// shiver. A simple lerp keeps the field fluid without adding a filter
    /// that lags behind a deliberate tip.
    @Published private(set) var smoothedTilt = CGSize.zero

    private let manager = CMMotionManager()
    private var displayLink: CADisplayLink?

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        let availableFrames = CMMotionManager.availableAttitudeReferenceFrames()
        let frame: CMAttitudeReferenceFrame = availableFrames.contains(.xArbitraryCorrectedZVertical)
            ? .xArbitraryCorrectedZVertical
            : .xArbitraryZVertical
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(using: frame, to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let roll = min(max(motion.attitude.roll, -0.65), 0.65) / 0.65
            let pitch = min(max(motion.attitude.pitch + 0.55, -0.65), 0.65) / 0.65
            let target = CGSize(width: roll, height: pitch)
            tilt = target
            smoothedTilt = CGSize(
                width: smoothedTilt.width * 0.80 + target.width * 0.20,
                height: smoothedTilt.height * 0.80 + target.height * 0.20
            )
        }
    }

    /// Motion updates are stopped explicitly by `BootView` when the sequence
    /// departs or the view disappears; there is no nonisolated teardown path.
    /// Stopping on `isReady` was too early — the splash is still visible and
    /// the shader would freeze while the operator is still looking at it.
    func stop() {
        guard manager.isDeviceMotionActive else { return }
        manager.stopDeviceMotionUpdates()
        displayLink?.invalidate()
        displayLink = nil
        withAnimation(.easeOut(duration: 0.6)) {
            tilt = .zero
            smoothedTilt = .zero
        }
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
