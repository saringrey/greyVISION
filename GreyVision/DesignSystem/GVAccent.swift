import Observation
import SwiftUI

/// The instrument's one accent colour, live.
///
/// Everything else in the chrome is near-black and porcelain type; this is
/// the only colour that carries identity, and it follows the camera: the
/// workspace samples the dominant colour of the live frame several times a
/// second and pushes it here (see `GVAmbientLight`).
///
/// It is `@Observable`, so any view whose body reads `GVTheme.violet`,
/// `GVTheme.violetDeep` or `GVSplashDock.lime` re-renders the moment it
/// changes, with no `@ObservedObject` plumbing at the call site. That is what
/// keeps the change near-instant everywhere instead of only on the few views
/// that happened to observe the sampler.
@Observable
final class GVAccent: @unchecked Sendable {
    static let shared = GVAccent()

    /// Resting accent, used on the splash and whenever the scene has no
    /// usable colour: a muted version of the splash tracker's lime.
    static let restingRGB = SIMD3<Double>(0.80, 0.84, 0.66)

    /// Written on the main actor only (by `GVAmbientLight`).
    private(set) var rgb: SIMD3<Double> = GVAccent.restingRGB

    private init() {}

    var color: Color {
        Color(red: rgb.x, green: rgb.y, blue: rgb.z)
    }

    /// The deep end of the accent: glows and gradient tails.
    var deep: Color {
        Color(red: rgb.x * 0.38, green: rgb.y * 0.38, blue: rgb.z * 0.38)
    }

    var floatRGB: SIMD3<Float> {
        SIMD3<Float>(Float(rgb.x), Float(rgb.y), Float(rgb.z))
    }

    @MainActor
    func set(_ value: SIMD3<Double>) {
        guard value != rgb else { return }
        rgb = value
    }
}
