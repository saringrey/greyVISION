import SwiftUI

/// The splash's own light.
///
/// The splash is a black-and-white instrument: every colour that used to live
/// here (violet glow, magenta ember, cyan ion) has been retired to greys. The
/// ramp still has the same shape — a hot core, a deep ambient end and two
/// supporting tones — so the bloom, spark and storm keep their contrast, just
/// without hue.
///
/// Splash-only — workspace chrome must keep using `GVTheme`.
enum BootPalette {
    /// Hot core. Sparks, lightning, scanner beams, anything "live".
    static let glow = Color(white: 1.00)

    /// Deep end of the ramp. Ambient fields, wide blooms, cloud bodies.
    static let deep = Color(white: 0.42)

    /// Edge tone where two fields overlap.
    static let ember = Color(white: 0.78)

    /// Counterpoint ribbon. One aurora and nothing else.
    static let ion = Color(white: 0.60)
}
