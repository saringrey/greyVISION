import SwiftUI

struct LogoTreatment: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotationInput = CGSize.zero
    @State private var isTouching = false

    var imageName = "OfficialLogo"
    var decay: Float = 0.08
    var interactive = false
    var tilt: CGSize = .zero
    var accessibilityIdentifier = "logo.mark"
    var onActivate: (() -> Void)?

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30, paused: reduceMotion)) { timeline in
            let time = Float(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 120))
            let breathingScale = reduceMotion ? 1 : 1 + sin(Double(time) * 0.82) * 0.009
            let motionYaw = reduceMotion ? 0 : tilt.width * 14
            let motionPitch = reduceMotion ? 0 : -tilt.height * 12
            let yaw = min(max(rotationInput.width / 3.6 + motionYaw, -24), 24)
            let pitch = min(max(-rotationInput.height / 4.2 + motionPitch, -20), 20)
            let edgeX = -yaw / 22
            let edgeY = pitch / 18

            ZStack {
                logo(time: time)
                    .blur(radius: 12)
                    .opacity(0.10)
                    .blendMode(.screen)

                ForEach((1 ... 2).reversed(), id: \.self) { layer in
                    logo(time: time)
                        .saturation(0.24)
                        .brightness(-0.24)
                        .opacity(0.18)
                        .offset(
                            x: edgeX * CGFloat(layer) * 1.15,
                            y: edgeY * CGFloat(layer) * 1.15
                        )
                }

                logo(time: time)

                RadialGradient(
                    colors: [.clear, .black.opacity(0.06), .black.opacity(0.58)],
                    center: .center,
                    startRadius: 46,
                    endRadius: 210
                )
                .mask(
                    Image(imageName)
                        .resizable()
                        .scaledToFit()
                )
                .blendMode(.multiply)
                .allowsHitTesting(false)
            }
            .rotation3DEffect(.degrees(Double(pitch)), axis: (x: 1, y: 0, z: 0), perspective: 0.68)
            .rotation3DEffect(.degrees(Double(yaw)), axis: (x: 0, y: 1, z: 0), perspective: 0.68)
            .scaleEffect((isTouching ? 1.025 : 1) * breathingScale)
            // Keep the composed mark genuinely unclipped. The logo is scaled by
            // the splash layer above this view, so a frame-sized mask here would
            // become a visible box as the gesture grows the artwork past its
            // original bounds. Contrast comes from the silhouette halo behind
            // the mark, not from fading the mark itself at a geometric edge.
        }
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .allowsHitTesting(interactive)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(imageName == "CreatorMark" ? "Grey creator artwork" : "grey VISION rabbit mark")
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
        Image(imageName)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .colorEffect(
                ShaderLibrary.logoSignal(
                    .float(time),
                    .float(0)
                )
            )
            .distortionEffect(
                ShaderLibrary.logoDisintegration(
                    .float(time),
                    .float(0)
                ),
                maxSampleOffset: CGSize(width: 5, height: 2)
            )
            .shadow(color: .black.opacity(0.24), radius: 6)
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
