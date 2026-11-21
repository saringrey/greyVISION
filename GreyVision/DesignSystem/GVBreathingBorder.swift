import SwiftUI

/// Ambient light sampled from the renderer's existing statistics mailbox.
///
/// The sampler has an explicit workspace lifecycle. It performs no work before
/// `activate(mailbox:)`, stops immediately at `deactivate()`, and only publishes
/// when the visible result can change. This avoids making every material redraw
/// for identical 8–10 Hz timer ticks.
@MainActor
final class GVAmbientLight: ObservableObject {
    static let shared = GVAmbientLight()
    static let samplingInterval = Duration.milliseconds(250)
    static let meaningfulDelta = 0.02

    @Published private(set) var level: Double = 0.52
    /// The scene's dominant colour, lifted to a usable accent. The chrome
    /// takes its tint from this, so the interface wears what the camera sees.
    @Published private(set) var hue: Color = GVAccent.shared.color
    @Published private(set) var hueRGB = GVAccent.restingRGB
    private var hueTask: Task<Void, Never>?

    private weak var mailbox: CameraRenderStatsMailbox?
    private var samplingTask: Task<Void, Never>?
    private var lastFrameNumber: UInt64?

    private init() {}

    /// Starts the 4 Hz sampler used by the telemetry strip. Repeated calls with
    /// the same mailbox are intentionally idempotent.
    func activate(mailbox: CameraRenderStatsMailbox) {
        guard self.mailbox !== mailbox || samplingTask == nil else { return }
        deactivate()
        self.mailbox = mailbox
        sampleCurrentFrame()
        samplingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.samplingInterval)
                guard !Task.isCancelled else { return }
                self?.sampleCurrentFrame()
            }
        }
        // The accent follows the camera. Sample several times a second and
        // apply with a short ease, so a new colour in frame reaches the chrome
        // in well under a quarter of a second instead of several seconds.
        hueTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // A 24×24 reduction of a 320px tap: well under a millisecond.
                if let frame = await GVSourceFrameTap.shared.nextFrame(timeout: .milliseconds(400)),
                   let rgb = Self.dominantColor(of: frame) {
                    self?.publishHue(rgb)
                }
                try? await Task.sleep(for: Self.hueInterval)
            }
        }
    }

    /// How often the accent re-samples the live frame.
    static let hueInterval = Duration.milliseconds(110)

    private func publishHue(_ rgb: SIMD3<Double>) {
        let delta = abs(rgb.x - hueRGB.x) + abs(rgb.y - hueRGB.y) + abs(rgb.z - hueRGB.z)
        guard delta > 0.025 else { return }
        withAnimation(.easeOut(duration: 0.14)) {
            hueRGB = rgb
            hue = Color(red: rgb.x, green: rgb.y, blue: rgb.z)
            GVAccent.shared.set(rgb)
        }
    }

    /// The frame's most characterful colour: pixels are weighted by how
    /// saturated and lit they are, so a red mug on a grey desk wins over the
    /// desk. The result is pushed to a clear, mid-bright accent; a grey scene
    /// falls back to the theme's cobalt.
    nonisolated static func dominantColor(of image: CGImage) -> SIMD3<Double>? {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var sum = SIMD3<Double>(0, 0, 0)
        var weight = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let c = SIMD3<Double>(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2])) / 255
            let maxC = max(c.x, c.y, c.z), minC = min(c.x, c.y, c.z)
            let sat = maxC > 0 ? (maxC - minC) / maxC : 0
            let w = pow(sat, 2) * sqrt(maxC)
            sum += c * w
            weight += w
        }
        guard weight > 4 else { return GVAccent.restingRGB }
        let avg = sum / weight
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(red: avg.x, green: avg.y, blue: avg.z, alpha: 1).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let accent = UIColor(hue: h, saturation: min(max(s * 1.5, 0.45), 0.85), brightness: 0.95, alpha: 1)
        var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0
        accent.getRed(&r, green: &g, blue: &bl, alpha: &a)
        return SIMD3(Double(r), Double(g), Double(bl))
    }

    /// Stops all polling and releases the render mailbox. The current level is
    /// retained so chrome does not flash when it is shown again.
    func deactivate() {
        samplingTask?.cancel()
        samplingTask = nil
        hueTask?.cancel()
        hueTask = nil
        mailbox = nil
        lastFrameNumber = nil
    }

    private func sampleCurrentFrame() {
        guard let mailbox else { return }
        let stats = mailbox.latest
        guard stats.frameNumber != lastFrameNumber else { return }
        lastFrameNumber = stats.frameNumber

        let next = Self.resolvedLevel(
            stats: stats,
            screenBrightness: Double(UIScreen.main.brightness)
        )
        guard Self.isMeaningfulChange(from: level, to: next) else { return }
        level = next
    }

    static func resolvedLevel(
        stats: CameraRenderStats,
        screenBrightness: Double
    ) -> Double {
        let screen = min(max(screenBrightness, 0), 1)
        guard stats.frameNumber > 0 else {
            return min(max(screen * 0.55 + 0.22, 0), 1)
        }

        let camera = (
            stats.topChromeLoad
                + stats.deckChromeLoad
                + stats.bottomChromeLoad
        ) / 3
        return min(max(screen * 0.30 + camera * 0.70, 0), 1)
    }

    static func isMeaningfulChange(
        from oldValue: Double,
        to newValue: Double,
        threshold: Double = meaningfulDelta
    ) -> Bool {
        abs(oldValue - newValue) >= threshold
    }
}

/// Light-reactive hairline overlay — opacity scales with ambient light 0…1.
/// Bright scene → more present border, dark scene → hairline retreats. Real-time via GVAmbientLight.
struct GVLightReactiveBorderOverlay: ViewModifier {
    var radius: CGFloat
    var baseOpacity: Double
    var lightLevel: Double
    var lineWidth: CGFloat = 0.5
    var color: Color = .white

    @ObservedObject private var ambient = GVAmbientLight.shared

    func body(content: Content) -> some View {
        content.overlay {
            let live = ambient.level
            let reactive = baseOpacity * (0.60 + live * 0.85)
            let opacity = min(max(reactive, 0.015), 0.32)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(color.opacity(opacity), lineWidth: lineWidth)
                .allowsHitTesting(false)
        }
    }
}

/// Compatibility styling for existing borders. A stable hairline avoids a
/// separate animation clock for every control over the live camera.
private func borderOpacity(base: Double) -> Double {
    min(max(base, 0.015), 0.18)
}

// MARK: - Reusable modifier

struct GVBreathingBorder: ViewModifier {
    var radius: CGFloat
    var baseOpacity: Double = 0.05
    var lineWidth: CGFloat = GVMetrics.hairline
    var clipped: Bool = false
    var speed: Double = 0.42
    var seed: Double = 0

    func body(content: Content) -> some View {
        content.overlay {
            shape
                .stroke(
                    Color.white.opacity(borderOpacity(base: baseOpacity)),
                    lineWidth: lineWidth
                )
                .allowsHitTesting(false)
        }
    }

    private var shape: AnyShape {
        if clipped {
            AnyShape(GVClippedRectangle(cut: radius + 3))
        } else {
            AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

extension View {
    /// Overlays a stable white hairline; legacy timing arguments remain source compatible.
    ///
    /// - Parameters:
    ///   - radius: Corner radius to match the container.
    ///   - baseOpacity: Midpoint opacity (≈ 0.06–0.14 reads as subtle on black frosted glass).
    ///   - lineWidth: Hairline by default; pass 1 for emphasized surfaces.
    ///   - speed: Retained for source compatibility.
    ///   - seed: Retained for source compatibility.
    func gvBreathingBorder(
        radius: CGFloat = GVMetrics.radiusPanel,
        baseOpacity: Double = 0.05,
        lineWidth: CGFloat = GVMetrics.hairline,
        clipped: Bool = false,
        speed: Double = 0.42,
        seed: Double = 0
    ) -> some View {
        modifier(GVBreathingBorder(
            radius: radius,
            baseOpacity: baseOpacity,
            lineWidth: lineWidth,
            clipped: clipped,
            speed: speed,
            seed: seed
        ))
    }

    /// Compatibility wrapper for elevated surfaces.
    func gvBreathingGlowBorder(
        radius: CGFloat = GVMetrics.radiusPanel,
        baseOpacity: Double = 0.06,
        lineWidth: CGFloat = GVMetrics.hairline,
        seed: Double = 0
    ) -> some View {
        modifier(GVBreathingBorder(
            radius: radius,
            baseOpacity: baseOpacity,
            lineWidth: lineWidth,
            speed: 0.38,
            seed: seed
        ))
    }
}

// MARK: - Breathing stroke shape helper (for direct use inside glass modifiers)
