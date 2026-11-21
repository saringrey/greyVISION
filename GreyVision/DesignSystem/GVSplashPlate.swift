import SwiftUI

/// One palette feeds the nebula, ASCII highlights, and control borders.
///
/// Porcelain highlights falling off into the splash film's cobalt.
enum GVSplashPalette {
    /// The glowing white of dithered highlights, borders and the wordmark.
    static let glowRGB = SIMD3<Float>(0.95, 0.945, 0.925)
    /// The neutral grey the field falls off into.
    static let shadeRGB = SIMD3<Float>(0.30, 0.40, 0.72)
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

