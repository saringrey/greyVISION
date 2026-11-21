import SwiftUI

/// The splash's own light.
///
/// Sampled from the splash film's still lifes: porcelain core, cobalt
/// lattice depth, a vermilion sphere for the ember and terminal green for
/// the counterpoint.
///
/// Splash-only — workspace chrome must keep using `GVTheme`.
enum BootPalette {
    /// Hot core. Sparks, lightning, scanner beams, anything "live".
    static let glow = Color(red: 0.95, green: 0.945, blue: 0.925)

    /// Deep end of the ramp. Ambient fields, wide blooms, cloud bodies.
    static let deep = Color(red: 0.24, green: 0.32, blue: 0.62)

    /// Edge tone where two fields overlap.
    static let ember = Color(red: 0.90, green: 0.36, blue: 0.24)

    /// Counterpoint ribbon. One aurora and nothing else.
    static let ion = Color(red: 0.42, green: 0.82, blue: 0.56)
}
