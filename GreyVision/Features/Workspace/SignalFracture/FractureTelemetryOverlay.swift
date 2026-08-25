import SwiftUI

/// Microscopic diagnostics drawn over the fracture.
///
/// Deliberately small and monospaced: a hairline signal line between the two
/// contacts, a short readout at the midpoint, and partially corrupted age
/// labels beside the exposed temporal layers.
struct FractureTelemetryOverlay: View {
    let telemetry: SignalFractureTelemetry
    /// Age of each exposed layer, derived from the live capture frame rate.
    let layerAges: [Int]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let pointA = resolve(telemetry.pointA, in: size)
            let pointB = resolve(telemetry.pointB, in: size)
            let midpoint = resolve(telemetry.midpoint, in: size)

            ZStack(alignment: .topLeading) {
                if telemetry.phase == .locked || telemetry.phase == .tearing {
                    signalLine(from: pointA, to: pointB)
                    readout(at: midpoint, size: size)
                    ageLabels(from: pointA, to: pointB, size: size)
                }

                if telemetry.phase == .broken {
                    Text("NO SIGNAL")
                        .gvMono(GVMetrics.textValue, .black)
                        .tracking(3.4)
                        .foregroundStyle(GVTheme.bone)
                        .shadow(color: GVTheme.violet.opacity(0.54), radius: 5)
                        .frame(width: size.width, height: size.height)
                }

                if telemetry.showsRestored {
                    Text("SIGNAL // RESTORED")
                        .gvMono(GVMetrics.textSmall, .black)
                        .tracking(1.8)
                        .foregroundStyle(GVTheme.violet)
                        .position(x: midpoint.x, y: midpoint.y)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.14), value: telemetry.showsRestored)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func signalLine(from pointA: CGPoint, to pointB: CGPoint) -> some View {
        Path { path in
            path.move(to: pointA)
            path.addLine(to: pointB)
        }
        .stroke(
            GVTheme.violet.opacity(0.34 + telemetry.openness * 0.28),
            style: StrokeStyle(lineWidth: 0.6, dash: [3, 4])
        )
    }

    private func readout(at midpoint: CGPoint, size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            label("SIGNAL // \(telemetry.phase.label)", weight: .black, opacity: 0.9)
            label(String(format: "Δ %04d", telemetry.delta), weight: .bold, opacity: 0.68)
            label(String(format: "FRAME %06d", telemetry.sampleNumber % 1_000_000), weight: .bold, opacity: 0.52)
        }
        .position(
            x: min(max(midpoint.x + 46, 52), size.width - 52),
            y: min(max(midpoint.y - 18, 22), size.height - 22)
        )
    }

    private func ageLabels(from pointA: CGPoint, to pointB: CGPoint, size: CGSize) -> some View {
        let axis = CGPoint(x: pointB.x - pointA.x, y: pointB.y - pointA.y)
        let length = max(hypot(axis.x, axis.y), 1)
        let unit = CGPoint(x: axis.x / length, y: axis.y / length)
        let normal = CGPoint(x: -unit.y, y: unit.x)
        let midpoint = CGPoint(x: (pointA.x + pointB.x) / 2, y: (pointA.y + pointB.y) / 2)

        return ForEach(Array(layerAges.enumerated()), id: \.offset) { index, age in
            let depth = Double(index + 1) / Double(max(layerAges.count, 1))
            let offset = length * 0.42 * depth * telemetry.openness
            let side: Double = index.isMultiple(of: 2) ? 1 : -1

            label(
                corrupted("T-\(String(format: "%03d", age))MS", seed: index),
                weight: .bold,
                opacity: 0.34 + telemetry.openness * 0.32
            )
            .position(
                x: min(max(midpoint.x + unit.x * offset * side + normal.x * 26, 34), size.width - 34),
                y: min(max(midpoint.y + unit.y * offset * side + normal.y * 26, 18), size.height - 18)
            )
            .opacity(telemetry.openness > 0.08 ? 1 : 0)
        }
    }

    private func label(_ text: String, weight: Font.Weight, opacity: Double) -> some View {
        Text(text)
            .gvMono(GVMetrics.textMicro, weight)
            .tracking(0.9)
            .foregroundStyle(GVTheme.bone.opacity(opacity))
            .shadow(color: .black.opacity(0.8), radius: 2)
            .fixedSize()
    }

    /// Age labels are partially corrupted, matching the buffer they annotate.
    private func corrupted(_ text: String, seed: Int) -> String {
        let tick = Int(telemetry.sampleNumber / 4) &+ seed
        guard tick.isMultiple(of: 5) else { return text }
        var characters = Array(text)
        let index = (abs(tick) &* 7) % characters.count
        characters[index] = "#"
        return String(characters)
    }

    private func resolve(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }
}
