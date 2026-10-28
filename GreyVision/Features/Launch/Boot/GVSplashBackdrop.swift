import SwiftUI

/// A dithered black-and-white nebula responds to tilt and background touches
/// without audio input.
struct GVSplashBackdrop: View {
    var animated = true
    var tilt: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var touch: CGPoint?
    @State private var releasedAt: Date?

    private var running: Bool { animated && !reduceMotion && scenePhase == .active }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(GVAmbientClock.ambient(hertz: 60, scenePhase: scenePhase, isActive: running)) { clock in
                let input = GVSplashNebulaInput(
                    time: running ? clock.date.timeIntervalSinceReferenceDate : 0,
                    tilt: running ? tilt : .zero,
                    touch: running ? touch : nil,
                    releasedAfter: releasedAt.map { clock.date.timeIntervalSince($0) }
                )
                Rectangle()
                    .visualEffect { content, proxy in
                        content.colorEffect(ShaderLibrary.splashNebula(
                            .float2(proxy.size), .float(input.time),
                            .float2(input.tilt.x, input.tilt.y),
                            .float3(input.touch.x, input.touch.y, input.touch.z), .float(input.touchAge),
                            .float3(GVSplashPalette.glowRGB.x, GVSplashPalette.glowRGB.y, GVSplashPalette.glowRGB.z),
                            .float3(GVSplashPalette.shadeRGB.x, GVSplashPalette.shadeRGB.y, GVSplashPalette.shadeRGB.z)
                        ))
                    }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        touch = CGPoint(
                            x: value.location.x / max(geometry.size.width, 1),
                            y: value.location.y / max(geometry.size.height, 1)
                        )
                        releasedAt = nil
                    }
                    .onEnded { _ in releasedAt = .now },
                including: running ? .all : .none
            )
        }
        .background(GVTheme.void)
        .allowsHitTesting(running)
        .accessibilityHidden(true)
        .onChange(of: running) { _, active in
            if !active { touch = nil; releasedAt = nil }
        }
    }
}

/// One palette feeds the nebula, ASCII highlights, and control borders.
///
/// Black and white only: colour on the splash competed with the codec
/// choices, and a monochrome field makes the white glow read as light.
enum GVSplashPalette {
    /// The glowing white of dithered highlights, borders and the wordmark.
    static let glowRGB = SIMD3<Float>(1.0, 1.0, 1.0)
    /// The neutral grey the field falls off into.
    static let shadeRGB = SIMD3<Float>(0.46, 0.46, 0.48)
    static let glow = Color(red: Double(glowRGB.x), green: Double(glowRGB.y), blue: Double(glowRGB.z))
    static let shade = Color(red: Double(shadeRGB.x), green: Double(shadeRGB.y), blue: Double(shadeRGB.z))
    static let border = LinearGradient(
        colors: [glow.opacity(0.9), shade.opacity(0.55), glow.opacity(0.6)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

struct GVSplashPlate: View {
    var active = false

    var body: some View {
        Rectangle()
            .visualEffect { content, proxy in
                content.colorEffect(ShaderLibrary.splashPlate(
                    .float2(proxy.size), .float(active ? 1 : 0),
                    .float3(GVSplashPalette.glowRGB.x, GVSplashPalette.glowRGB.y, GVSplashPalette.glowRGB.z),
                    .float3(GVSplashPalette.shadeRGB.x, GVSplashPalette.shadeRGB.y, GVSplashPalette.shadeRGB.z)
                ))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct GVSplashBorder: ViewModifier {
    var active = false
    var radius: CGFloat = 12
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(GVSplashPalette.border, lineWidth: active || contrast == .increased ? 1.5 : 0.8)
                .shadow(color: GVSplashPalette.glow.opacity(active ? 0.5 : 0.22), radius: active ? 7 : 3)
                .allowsHitTesting(false)
        }
    }
}

/// Motion input is finite and bounded; time wraps before conversion to Float.
struct GVSplashNebulaInput: Equatable {
    static let timeWrap: Double = 3_600
    static let touchDuration: Double = 1.4
    let time: Float
    let tilt: SIMD2<Float>
    let touch: SIMD3<Float>
    let touchAge: Float

    init(time: TimeInterval, tilt: CGSize, touch: CGPoint? = nil, releasedAfter: TimeInterval? = nil) {
        let wrapped = time.isFinite ? time.truncatingRemainder(dividingBy: Self.timeWrap) : 0
        self.time = Float(wrapped < 0 ? wrapped + Self.timeWrap : wrapped)
        self.tilt = SIMD2(Self.unit(Float(tilt.width)), Self.unit(Float(tilt.height)))
        let age = releasedAfter ?? 0
        let boundedAge = age.isFinite ? min(max(age, 0), Self.touchDuration) : Self.touchDuration
        touchAge = Float(boundedAge)
        if let touch, touch.x.isFinite, touch.y.isFinite {
            self.touch = SIMD3(
                Float(min(max(touch.x, 0), 1)), Float(min(max(touch.y, 0), 1)),
                Float(pow(1 - boundedAge / Self.touchDuration, 2))
            )
        } else {
            self.touch = SIMD3(0.5, 0.5, 0)
        }
    }

    private static func unit(_ value: Float) -> Float {
        value.isFinite ? min(max(value, -1), 1) : 0
    }
}
