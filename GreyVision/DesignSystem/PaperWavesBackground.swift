import SwiftUI

/// 1-bit dithered flow field, driven by the `ditheredFlow` Metal shader.
///
/// Pure black and white with an ordered dither at the boundaries — no palette
/// and no midtones. Reacts to touch and, when a tilt source is supplied, to
/// how the device is held.
struct PaperWavesBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Multiplies the field's internal rates.
    var speed: Double = 1
    /// Overall opacity, so a caller can sit the field further back.
    var opacity: Double = 1
    /// Dither cluster size in points. 1 reads as grain; 3-4 reads as pattern.
    var blockSize: Double = 3
    /// How hard the field is pushed to the two tones before thresholding.
    var contrast: Double = 3.4
    /// Device tilt, normalised. Supplied by the caller so this view does not
    /// start a second motion manager alongside whatever is already running.
    var tilt: CGSize = .zero

    /// Current contact point in view coordinates, or nil.
    ///
    /// Sent to the shader as a negative x when absent: the alternative is a
    /// separate "isTouching" float, and one sentinel is cheaper than an extra
    /// uniform on a full-screen pass.
    @State private var touch: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size

            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
                // Reduce Motion gets a fixed, non-zero instant rather than a
                // paused clock at t=0 — a still composition, not a blank one.
                let t = reduceMotion
                    ? 18.0
                    : timeline.date.timeIntervalSinceReferenceDate * speed

                let contact = touch ?? CGPoint(x: -1_000, y: -1_000)

                Rectangle()
                    .colorEffect(
                        ShaderLibrary.ditheredFlow(
                            .float(Float(t.truncatingRemainder(dividingBy: 3_600))),
                            .float2(Float(size.width), Float(size.height)),
                            .float(Float(blockSize)),
                            .float(Float(contrast)),
                            .float2(Float(contact.x), Float(contact.y)),
                            .float2(Float(tilt.width), Float(tilt.height))
                        )
                    )
            }
            .frame(width: size.width, height: size.height)
            // Contact tracking only. `minimumDistance: 0` so a tap registers,
            // and the gesture is deliberately non-blocking — see below.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in touch = value.location }
                    .onEnded { _ in touch = nil }
            )
        }
        .opacity(opacity)
        // Hit testing stays ON so the drag above can see touches, but this view
        // is always the backdrop: it is placed behind the content it sits
        // under, so anything interactive in front still receives its own taps
        // first. Only touches that would otherwise fall on empty background
        // reach here.
        .accessibilityHidden(true)
        .ignoresSafeArea()
    }
}
