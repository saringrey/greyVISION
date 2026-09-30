import SwiftUI

/// CRT-style scanline reveal animation for boot sequence Phase 2.
///
/// Implements a scanline effect that sweeps from top to bottom over 600ms with
/// linear timing. The effect creates a classic CRT monitor synchronization aesthetic.
///
/// **Visual Characteristics:**
/// - Horizontal scanline traveling vertically
/// - Purple/white beam with glow effect
/// - Linear timing for mechanical feel
/// - Reveals content progressively
///
/// **Accessibility:**
/// - Static scanline mode for `reduceMotion`
/// - No disruptive motion for accessibility users
///
/// **Requirements:** 3.4 (CRT scanline effect), 3.7 (Accessibility)
struct CRTScanlineOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Progress through the scanline animation [0, 1]
    let progress: CGFloat

    /// Whether the effect is active
    let isActive: Bool

    /// Scanline thickness in points
    private let scanlineThickness: CGFloat = 2.0

    /// Leading edge gradient height
    private let leadingEdgeHeight: CGFloat = 120

    var body: some View {
        if reduceMotion {
            // Static scanline for reduced motion (Requirement 3.7)
            staticScanline
        } else {
            // Animated scanline reveal (Requirement 3.4)
            animatedScanline
        }
    }

    // MARK: - Static Scanline (Reduced Motion)

    private var staticScanline: some View {
        GeometryReader { _ in
            ZStack {
                // Static horizontal scanlines across the entire screen
                Canvas { context, size in
                    let lineSpacing: CGFloat = 4
                    let lineCount = Int(size.height / lineSpacing)

                    for i in 0 ..< lineCount {
                        let y = CGFloat(i) * lineSpacing
                        let opacity = isActive ? 0.08 : 0.0

                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))

                        context.stroke(
                            path,
                            with: .color(GVTheme.violetDeep.opacity(opacity)),
                            lineWidth: 0.5
                        )
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Animated Scanline

    private var animatedScanline: some View {
        GeometryReader { geometry in
            let height = geometry.size.height

            // Linear progress (Requirement 3.4: 600ms linear timing)
            let scanlineY = height * progress

            ZStack(alignment: .top) {
                // Leading edge: subtle brightness lift ahead of the beam
                LinearGradient(
                    colors: [
                        .clear,
                        Color.white.opacity(0.04 * (isActive ? 1 : 0)),
                        Color.white.opacity(0.08 * (isActive ? 1 : 0)),
                        Color.white.opacity(0.04 * (isActive ? 1 : 0)),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: leadingEdgeHeight)
                .offset(y: max(scanlineY - leadingEdgeHeight * 0.8, -leadingEdgeHeight))
                .blendMode(.screen)

                // Main scanline beam (purple-white gradient)
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                GVTheme.violet.opacity(0.85),
                                Color.white.opacity(0.95),
                                GVTheme.violet.opacity(0.85),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: scanlineThickness)
                    .shadow(color: GVTheme.violet.opacity(0.48), radius: 5, y: 0)
                    .shadow(color: GVTheme.violetDeep.opacity(0.5), radius: 16, y: 0)
                    .offset(y: scanlineY)
                    .opacity(isActive && progress < 1 ? 1 : 0)

                // Trailing glow fade
                LinearGradient(
                    colors: [
                        GVTheme.violetDeep.opacity(0.15 * (isActive ? 1 : 0)),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 60)
                .offset(y: max(scanlineY + scanlineThickness, 0))
                .blendMode(.screen)

                // Reveal mask effect: content brightens after scanline passes
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.03),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: scanlineY)
                .blendMode(.screen)
                .opacity(isActive ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - CRT Scanline Lines Effect

/// Static scanline texture overlay for CRT aesthetic
///
/// Can be layered on top of content for persistent CRT effect.
/// This is separate from the animated reveal scanline.
struct CRTScanlinesTexture: View {
    let opacity: CGFloat
    let lineSpacing: CGFloat

    init(opacity: CGFloat = 0.1, lineSpacing: CGFloat = 4) {
        self.opacity = opacity
        self.lineSpacing = lineSpacing
    }

    var body: some View {
        GeometryReader { _ in
            Canvas { context, size in
                let lineCount = Int(size.height / lineSpacing)

                for i in 0 ..< lineCount {
                    let y = CGFloat(i) * lineSpacing
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))

                    // Alternate slightly between two shades for more texture
                    let lineOpacity = i % 2 == 0 ? opacity : opacity * 0.7

                    context.stroke(
                        path,
                        with: .color(Color.black.opacity(lineOpacity)),
                        lineWidth: 0.5
                    )
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Preview

#Preview("CRT Scanline Animation") {
    ZStack {
        // Background
        Color.black.ignoresSafeArea()

        // Some content to reveal
        VStack(spacing: 20) {
            Text("SYSTEM ONLINE")
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .foregroundColor(.white)

            Text("INITIALIZING CAMERA")
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundColor(.gray)
        }

        // Animated scanline
        TimelineView(.animation) { timeline in
            let seconds = timeline.date.timeIntervalSinceReferenceDate
            let progress = CGFloat((seconds.truncatingRemainder(dividingBy: 1.5)) / 1.5)

            CRTScanlineOverlay(
                progress: progress,
                isActive: true
            )
        }
    }
}

#Preview("CRT Scanline Static") {
    ZStack {
        Color.black.ignoresSafeArea()

        Text("SYSTEM READY")
            .font(.system(size: 32, weight: .bold, design: .monospaced))
            .foregroundColor(.white)

        // `accessibilityReduceMotion` is read-only in the environment; drive the
        // reduced path from the simulator's accessibility settings instead.
        CRTScanlineOverlay(
            progress: 0.5,
            isActive: true
        )
    }
}

#Preview("CRT Scanlines Texture") {
    ZStack {
        LinearGradient(
            colors: [.blue, .purple],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        CRTScanlinesTexture(opacity: 0.15, lineSpacing: 3)
    }
}

// MARK: - Global CRT glass

/// The tube the splash display field is seen through.
///
/// Composited above the atmosphere and interface, but below the foreground
/// logo so scanlines, vignette and phosphor tint never degrade the mark.
///
/// Kept to two cheap `Canvas` passes plus static gradients — this runs for the
/// few seconds of boot and must not compete with camera warm-up for GPU.
struct GVBootCRTGlass: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30, paused: reduceMotion)) { timeline in
            let time = reduceMotion
                ? 0
                : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 60)

            ZStack {
                // Fine scanlines, drifting slowly so the tube feels live.
                Canvas { context, size in
                    let spacing: CGFloat = 3
                    let drift = CGFloat(time.truncatingRemainder(dividingBy: 1)) * spacing
                    var y = -drift
                    while y < size.height {
                        context.fill(
                            Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                            with: .color(.black.opacity(0.34))
                        )
                        y += spacing
                    }
                }
                .blendMode(.multiply)

                // Aperture-grille tint: alternating vertical RGB bias. Very low
                // opacity — at full strength this reads as a novelty filter.
                Canvas { context, size in
                    let pitch: CGFloat = 3
                    var x: CGFloat = 0
                    var index = 0
                    while x < size.width {
                        let tint: Color = switch index % 3 {
                        case 0: .red
                        case 1: .green
                        default: .blue
                        }
                        context.fill(
                            Path(CGRect(x: x, y: 0, width: pitch, height: size.height)),
                            with: .color(tint.opacity(0.055))
                        )
                        x += pitch
                        index += 1
                    }
                }
                .blendMode(.screen)

                // Tube curvature falloff — darkens and desaturates the corners
                // so nothing terminates on a hard screen edge.
                RadialGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.52),
                        .init(color: .black.opacity(0.34), location: 0.82),
                        .init(color: .black.opacity(0.72), location: 1)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 620
                )

                // Slow phosphor brightness breathing across the whole tube.
                Color.white
                    .opacity(reduceMotion ? 0 : 0.012 + 0.012 * sin(time * 1.7))
                    .blendMode(.plusLighter)
            }
        }
    }
}
