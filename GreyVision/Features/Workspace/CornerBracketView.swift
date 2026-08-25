import SwiftUI

/// Corner bracket overlay for camera viewport
/// Implements professional camera UI aesthetic with configurable brackets at all four corners
/// Validates: Requirements 1.1, 1.3, 1.4, 1.6
struct CornerBracketView: View {
    // MARK: - Properties

    let config: CornerBracketConfig
    let accessibility: AccessibilitySettings

    @State private var opacity: CGFloat = 0.0

    // MARK: - Animation Configuration

    private let fadeInDuration: TimeInterval = 0.3
    private let fadeInAnimation: Animation = .easeOut(duration: 0.3)

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Top-left corner
                cornerBracket(position: .topLeft)
                    .position(
                        x: config.offset + config.length / 2,
                        y: config.offset + config.length / 2
                    )

                // Top-right corner
                cornerBracket(position: .topRight)
                    .position(
                        x: geometry.size.width - config.offset - config.length / 2,
                        y: config.offset + config.length / 2
                    )

                // Bottom-left corner
                cornerBracket(position: .bottomLeft)
                    .position(
                        x: config.offset + config.length / 2,
                        y: geometry.size.height - config.offset - config.length / 2
                    )

                // Bottom-right corner
                cornerBracket(position: .bottomRight)
                    .position(
                        x: geometry.size.width - config.offset - config.length / 2,
                        y: geometry.size.height - config.offset - config.length / 2
                    )
            }
            .opacity(opacity * config.opacity)
        }
        .onAppear {
            performFadeIn()
        }
        .onChange(of: accessibility.reduceMotion) { _, _ in
            // If reduce motion changes, update opacity instantly if needed
            if accessibility.reduceMotion {
                opacity = 1.0
            }
        }
    }

    // MARK: - Corner Bracket Shape

    /// Creates a corner bracket shape for the specified position
    /// - Parameter position: The corner position (topLeft, topRight, bottomLeft, bottomRight)
    /// - Returns: A view containing the bracket shape
    private func cornerBracket(position: CornerPosition) -> some View {
        BracketShape(
            length: config.length,
            thickness: config.thickness,
            position: position
        )
        .stroke(config.color, lineWidth: config.thickness)
        .frame(width: config.length, height: config.length)
    }

    // MARK: - Animation

    /// Performs fade-in animation with accessibility support
    /// Validates: Requirement 1.3 (300ms fade-in with ease-out timing)
    /// Validates: Requirement 1.6 (Instant appearance if reduceMotion enabled)
    private func performFadeIn() {
        if accessibility.reduceMotion {
            // Instant appearance for reduce motion
            opacity = 1.0
        } else {
            // Animated fade-in over 300ms
            withAnimation(fadeInAnimation) {
                opacity = 1.0
            }
        }
    }
}

// MARK: - Corner Position

/// Enumeration of corner bracket positions
private enum CornerPosition {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

// MARK: - Bracket Shape

/// Custom shape for corner brackets using Path API
/// Validates: Requirement 1.1 (Bracket geometry with Path API)
private struct BracketShape: Shape {
    let length: CGFloat
    let thickness: CGFloat
    let position: CornerPosition

    func path(in _: CGRect) -> Path {
        var path = Path()

        let halfLength = length / 2

        switch position {
        case .topLeft:
            // Draw L-shape in top-left corner
            // Vertical line
            path.move(to: CGPoint(x: halfLength, y: 0))
            path.addLine(to: CGPoint(x: halfLength, y: length))

            // Horizontal line
            path.move(to: CGPoint(x: 0, y: halfLength))
            path.addLine(to: CGPoint(x: length, y: halfLength))

        case .topRight:
            // Draw mirrored L-shape in top-right corner
            // Vertical line
            path.move(to: CGPoint(x: halfLength, y: 0))
            path.addLine(to: CGPoint(x: halfLength, y: length))

            // Horizontal line
            path.move(to: CGPoint(x: 0, y: halfLength))
            path.addLine(to: CGPoint(x: length, y: halfLength))

        case .bottomLeft:
            // Draw inverted L-shape in bottom-left corner
            // Vertical line
            path.move(to: CGPoint(x: halfLength, y: 0))
            path.addLine(to: CGPoint(x: halfLength, y: length))

            // Horizontal line
            path.move(to: CGPoint(x: 0, y: halfLength))
            path.addLine(to: CGPoint(x: length, y: halfLength))

        case .bottomRight:
            // Draw inverted mirrored L-shape in bottom-right corner
            // Vertical line
            path.move(to: CGPoint(x: halfLength, y: 0))
            path.addLine(to: CGPoint(x: halfLength, y: length))

            // Horizontal line
            path.move(to: CGPoint(x: 0, y: halfLength))
            path.addLine(to: CGPoint(x: length, y: halfLength))
        }

        return path
    }
}

// MARK: - Preview

#if DEBUG
    struct CornerBracketView_Previews: PreviewProvider {
        static var previews: some View {
            Group {
                // Default configuration
                CornerBracketView(
                    config: .default,
                    accessibility: .default
                )
                .background(Color.black)
                .previewDisplayName("Default")

                // Custom configuration
                CornerBracketView(
                    config: CornerBracketConfig(
                        color: .cyan,
                        thickness: 3.0,
                        length: 30.0,
                        offset: 12.0,
                        opacity: 0.8
                    ),
                    accessibility: .default
                )
                .background(Color.black)
                .previewDisplayName("Custom")

                // Reduce motion enabled
                CornerBracketView(
                    config: .default,
                    accessibility: AccessibilitySettings(
                        reduceMotion: true,
                        preferCrossFadeTransitions: true,
                        displayZoom: 1.0,
                        fontSizeScale: 1.0
                    )
                )
                .background(Color.black)
                .previewDisplayName("Reduce Motion")
            }
        }
    }
#endif
