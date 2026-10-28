import SwiftUI

/// A dithered/halftone phosphor wave field that reacts to device tilt orientation.
/// Shifts its gravity well, wave phase, and dot aperture as the operator tilts the phone.
struct GVDitheredSplash: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// Normalised device tilt, -1...1 per axis.
    var tilt: CGSize = .zero

    private static let bayer4x4: [[Double]] = [
        [0.0 / 16.0,  8.0 / 16.0,  2.0 / 16.0, 10.0 / 16.0],
        [12.0 / 16.0, 4.0 / 16.0, 14.0 / 16.0,  6.0 / 16.0],
        [3.0 / 16.0, 11.0 / 16.0,  1.0 / 16.0,  9.0 / 16.0],
        [15.0 / 16.0, 7.0 / 16.0, 13.0 / 16.0,  5.0 / 16.0]
    ]

    var body: some View {
        TimelineView(GVAmbientClock.ambient(hertz: reduceMotion ? 1 : 30, scenePhase: scenePhase)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas(rendersAsynchronously: true) { context, size in
                guard size.width > 0, size.height > 0 else { return }

                let columns = 28
                let spacing = size.width / CGFloat(columns)
                let rows = Int(ceil(size.height / spacing))
                let tiltMagnitude = min(hypot(tilt.width, tilt.height), 1.4)

                // Focal center shifts across the display with phone attitude
                let focusX = size.width * (0.5 + tilt.width * 0.34)
                let focusY = size.height * (0.48 + tilt.height * 0.30)
                let maxSpan = max(size.width, size.height) * 0.72

                let driftX = tilt.width * spacing * 0.85
                let driftY = tilt.height * spacing * 0.85

                var dimPath = Path()
                var brightPath = Path()
                var corePath = Path()

                for row in 0 ..< rows {
                    for col in 0 ..< columns {
                        let baseX = (CGFloat(col) + 0.5) * spacing + driftX
                        let baseY = (CGFloat(row) + 0.5) * spacing + driftY

                        let dx = (baseX - focusX) / maxSpan
                        let dy = (baseY - focusY) / maxSpan
                        let dist = hypot(dx, dy)

                        // Travelling ripple steered by phone tilt vector
                        let directional = Double(dx * tilt.width + dy * tilt.height) * 4.5
                        let wave = 0.5 + 0.5 * sin(Double(dist) * 10.5 - time * 2.2 + directional)
                        let falloff = max(0.0, 1.0 - Double(dist) * 1.08)
                        let energy = falloff * (0.38 + 0.62 * wave) * (0.55 + 0.45 * Double(tiltMagnitude))

                        let threshold = Self.bayer4x4[row & 3][col & 3] * 0.72
                        guard energy > threshold else { continue }

                        let normalized = min((energy - threshold) / max(1.0 - threshold, 0.001), 1.0)
                        let radius = spacing * CGFloat(0.08 + normalized * 0.22)
                        let rect = CGRect(
                            x: baseX - radius,
                            y: baseY - radius,
                            width: radius * 2,
                            height: radius * 2
                        )

                        if normalized > 0.74 {
                            corePath.addEllipse(in: rect)
                        } else if normalized > 0.38 {
                            brightPath.addEllipse(in: rect)
                        } else {
                            dimPath.addEllipse(in: rect)
                        }
                    }
                }

                context.fill(dimPath, with: .color(BootPalette.deep.opacity(0.22)))
                context.fill(brightPath, with: .color(BootPalette.ember.opacity(0.32)))
                context.fill(corePath, with: .color(BootPalette.glow.opacity(0.48)))

                // Tilt-steered horizon ring / specular field
                let ringRadius = min(size.width, size.height) * (0.28 + CGFloat(tiltMagnitude) * 0.06)
                let ringRect = CGRect(
                    x: focusX - ringRadius,
                    y: focusY - ringRadius,
                    width: ringRadius * 2,
                    height: ringRadius * 2
                )
                context.fill(
                    Path(ellipseIn: ringRect),
                    with: .radialGradient(
                        Gradient(colors: [
                            BootPalette.glow.opacity(0.10 + Double(tiltMagnitude) * 0.08),
                            BootPalette.deep.opacity(0.05),
                            .clear
                        ]),
                        center: CGPoint(x: focusX, y: focusY),
                        startRadius: 0,
                        endRadius: ringRadius
                    )
                )
            }
        }
        .blendMode(.screen)
        .opacity(reduceMotion ? 0.25 : 0.85)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
