import SwiftUI

struct LogoTreatment: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotationInput = CGSize.zero
    @State private var isTouching = false

    var decay: Float = 0.08
    var interactive = false
    var accessibilityIdentifier = "logo.mark"
    var onActivate: (() -> Void)?

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30, paused: reduceMotion)) { timeline in
            let time = Float(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 120))
            let breathingScale = reduceMotion ? 1 : 1 + sin(Double(time) * 0.82) * 0.009
            let yaw = min(max(rotationInput.width / 3.6, -24), 24)
            let pitch = min(max(-rotationInput.height / 4.2, -20), 20)
            let edgeX = -yaw / 22
            let edgeY = pitch / 18

            ZStack {
                logo(time: time)
                    .blur(radius: 18)
                    .opacity(0.22)
                    .blendMode(.screen)

                ForEach((1 ... 4).reversed(), id: \.self) { layer in
                    logo(time: time)
                        .saturation(0.24)
                        .brightness(-0.24)
                        .opacity(0.34)
                        .offset(
                            x: edgeX * CGFloat(layer) * 1.15,
                            y: edgeY * CGFloat(layer) * 1.15
                        )
                }

                logo(time: time)

                LogoCRTOverlay(time: time, intensity: reduceMotion ? 0.30 : 0.62)
                    // Masked to the mark's own alpha. Unmasked, this Canvas
                    // fills its whole bounding rect with scanlines, which is
                    // what made the artwork read as a hard-edged square.
                    .mask(
                        Image("OfficialLogo")
                            .resizable()
                            .scaledToFit()
                    )
                    .blendMode(.overlay)
                    .opacity(0.88)

                RadialGradient(
                    colors: [.clear, .black.opacity(0.06), .black.opacity(0.58)],
                    center: .center,
                    startRadius: 46,
                    endRadius: 210
                )
                .mask(
                    Image("OfficialLogo")
                        .resizable()
                        .scaledToFit()
                )
                .blendMode(.multiply)
                .allowsHitTesting(false)

                DecayParticles(time: time, intensity: reduceMotion ? 0 : decay)
            }
            .rotation3DEffect(.degrees(Double(pitch)), axis: (x: 1, y: 0, z: 0), perspective: 0.68)
            .rotation3DEffect(.degrees(Double(yaw)), axis: (x: 0, y: 1, z: 0), perspective: 0.68)
            .scaleEffect((isTouching ? 1.025 : 1) * breathingScale)
            // Feathered falloff so the blurred/offset ghost layers dissolve
            // into the void instead of terminating on the layout bounds.
            //
            // Elliptical, and sized in fractions of the frame rather than in
            // points. The radial version measured its radius against the
            // *longer* side, so on a frame that was not much wider than it was
            // tall the gradient was still around 90% opaque when it reached the
            // top and bottom edges — the artwork was cut from near-full opacity
            // straight to nothing, which is the horizontal seam that showed
            // above the wordmark.
            //
            // An elliptical gradient at `endRadiusFraction` 0.5 reaches its
            // last stop exactly at the edge midpoints on both axes, whatever
            // the aspect ratio, so the falloff always completes inside the
            // bounds and there is nothing left to cut.
            .mask(
                EllipticalGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.74),
                        .init(color: .black.opacity(0.5), location: 0.90),
                        .init(color: .clear, location: 1.0)
                    ],
                    center: .center,
                    startRadiusFraction: 0,
                    endRadiusFraction: 0.5
                )
            )
        }
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .allowsHitTesting(interactive)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("grey VISION rabbit mark")
        .accessibilityHint(
            interactive ? "Press and drag to rotate the mark in depth. Tap to open creator links." : "Brand mark"
        )
        .accessibilityAddTraits(interactive ? .isButton : [])
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityAction {
            guard interactive else { return }
            onActivate?()
        }
    }

    private func logo(time: Float) -> some View {
        Image("OfficialLogo")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .colorEffect(
                ShaderLibrary.logoSignal(
                    .float(time),
                    .float(reduceMotion ? 0.12 : 0.55)
                )
            )
            .distortionEffect(
                ShaderLibrary.logoDisintegration(
                    .float(time),
                    .float(reduceMotion ? 0 : decay)
                ),
                maxSampleOffset: CGSize(width: 5, height: 2)
            )
            .shadow(color: GVTheme.violetDeep.opacity(0.72), radius: 12)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard interactive else { return }
                isTouching = true
                rotationInput = CGSize(
                    width: min(max(value.translation.width, -99), 99),
                    height: min(max(value.translation.height, -94), 94)
                )
            }
            .onEnded { value in
                guard interactive else { return }
                let travel = hypot(value.translation.width, value.translation.height)
                isTouching = false
                withAnimation(.spring(response: 0.48, dampingFraction: 0.74)) {
                    rotationInput = .zero
                }
                if travel < 14 {
                    onActivate?()
                }
            }
    }
}

private struct LogoCRTOverlay: View {
    let time: Float
    let intensity: Double

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let lineSpacing: CGFloat = 5
            let phase = CGFloat(time.truncatingRemainder(dividingBy: 1)) * lineSpacing
            var y = -phase
            while y < size.height {
                let alpha = intensity * 0.22
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                    with: .color(.white.opacity(alpha))
                )
                y += lineSpacing
            }

            let bands = 7
            for index in 0 ..< bands {
                let bandY = size.height * CGFloat(index) / CGFloat(max(bands - 1, 1))
                let hash = sin(Double(index) * 12.9898 + Double(time) * 2.17)
                let offset = CGFloat(hash) * size.width * 0.016
                let rect = CGRect(
                    x: offset,
                    y: bandY,
                    width: size.width,
                    height: max(1, size.height * 0.018)
                )
                context.fill(
                    Path(rect),
                    with: .color(GVTheme.violet.opacity(intensity * 0.09))
                )
            }
        }
        .mask(
            Image("OfficialLogo")
                .resizable()
                .scaledToFit()
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct DecayParticles: View {
    let time: Float
    let intensity: Float

    var body: some View {
        Canvas { context, size in
            guard intensity > 0 else { return }
            let count = 24
            for index in 0 ..< count {
                let phase = Double(index) * 1.618_033_988_75
                let driftBase = Double(time) * (0.025 + Double(index % 5) * 0.004) + phase
                let drift = driftBase.truncatingRemainder(dividingBy: 1)
                let side = index.isMultiple(of: 2) ? 1.0 : -1.0
                let x = size.width * (0.5 + side * (0.12 + drift * 0.42))
                let y = size.height * (0.18 + (phase * 0.37).truncatingRemainder(dividingBy: 0.66))
                let particleSize = CGFloat(0.6 + Double(index % 3) * 0.55)
                let alpha = Double(intensity) * (1 - drift) * 1.8
                context.fill(
                    Path(CGRect(x: x, y: y, width: particleSize, height: particleSize)),
                    with: .color(GVTheme.violet.opacity(alpha))
                )
            }
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
