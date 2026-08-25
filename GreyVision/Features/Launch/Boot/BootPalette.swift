import SwiftUI

/// The splash's own light.
///
/// The app-wide theme retired violet as a UI accent (`GVTheme.violet` now
/// resolves to white), but the boot sequence was composed around a coloured
/// energy field. Reaching for the shared accents here is what made the startup
/// read as a white-grey wash instead of an instrument powering up.
///
/// This palette restores the field: darker than the old ramp so the screen
/// stays a black instrument, but more saturated at the hot end so the spark,
/// bloom and storm pop against it. Splash-only — workspace chrome must keep
/// using `GVTheme`.
enum BootPalette {
    /// Hot core. Sparks, lightning, scanner beams, anything "live".
    static let glow = Color(red: 0.62, green: 0.24, blue: 1.00)

    /// Deep end of the ramp. Ambient fields, wide blooms, cloud bodies.
    static let deep = Color(red: 0.17, green: 0.05, blue: 0.44)

    /// Magenta edge. Rare, and only where two fields overlap.
    static let ember = Color(red: 1.00, green: 0.20, blue: 0.72)

    /// Cold counterpoint. One aurora ribbon and nothing else.
    static let ion = Color(red: 0.26, green: 0.82, blue: 0.95)
}
