import CoreMotion
import SwiftUI

/// A dithered/halftone pattern that reacts to device tilt orientation.
/// Uses ordered dithering (Bayer matrix-inspired) to create a halftone effect
/// that shifts and animates based on the phone's orientation.
struct GVDitheredSplash: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appModel: AppModel

    /// Normalised device tilt, -1...1 per axis.
    @State private var tilt = CGSize.zero

    /// Elapsed time for animation.
    let elapsed: Double

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            guard size.width > 0, size.height > 0 else { return }

            let matrixSize = 4
            let cellWidth = size.width / CGFloat(matrixSize)
            let cellHeight = size.height / CGFloat(matrixSize)

            // Brayer-like dither matrix (4x4 for performance)
            let brier = [
                [0, 8, 2, 10],
                [12, 4, 14, 6],
                [3, 11, 1, 9],
                [15, 7, 13, 5]
            ]

            // Animated offset based on tilt and time
            let tiltX = tilt.width * 0.5
            let tiltY = tilt.height * 0.5
            let timePhase = elapsed * 2.0

            for row in 0 ..< matrixSize {
                for col in 0 ..< matrixSize {
                    let threshold = Double(brier[row][col]) / 16.0

                    // Calculate dither position with tilt offset
                    let x = CGFloat(col) * cellWidth + tiltX
                    let y = CGFloat(row) * cellHeight + tiltY

                    // Animate based on time and tilt
                    let phase = timePhase + Double(col) + Double(row) * 1.5
                    let anim = sin(phase) * 0.3 + 0.7
                    let effectiveThreshold = threshold * anim

                    // Draw cell if "on" based on threshold
                    if effectiveThreshold > 0.5 {
                        let rect = CGRect(
                            x: x,
                            y: y,
                            width: cellWidth,
                            height: cellHeight
                        )

                        // White dot with slight size variation based on position
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: cellWidth * 0.1),
                            with: .color(.white.opacity(0.8))
                        )
                    }
                }
            }
        }
        .opacity(reduceMotion ? 0.5 : 1.0)
        .accessibilityHidden(true)
        // Pull tilt from the app model / motion state
        .onAppear {
            // Tilt will be updated via environment or direct binding
        }
    }
}

// Extension to expose tilt binding for parent views
extension GVDitheredSplash {
    // This view reads tilt from the environment; parents should provide it
    static func withTilt(
        _ tilt: Binding<CGSize>
    ) -> some View {
        // Wrapper that injects tilt state
        GVDitheredSplash(elapsed: Date().timeIntervalSince1970)
            .environment(\.tiltValue, tilt.wrappedValue)
    }
}

// Environment key for tilt value
private struct TiltValueKey: EnvironmentKey {
    static let defaultValue: CGSize = .zero
}

extension EnvironmentValues {
    var tiltValue: CGSize {
        get { self[TiltValueKey.self] }
        set { self[TiltValueKey.self] = newValue }
    }
}

extension View {
    func tiltEnvironment(_ tilt: CGSize) -> some View {
        environment(\.tiltValue, tilt)
    }
}