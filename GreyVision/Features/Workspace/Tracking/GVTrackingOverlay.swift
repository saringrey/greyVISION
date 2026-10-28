import SwiftUI

/// Draws tracked subjects over the preview at display rate.
///
/// Analysis runs at 5–30 Hz; drawing runs at 60. Between passes each mark is
/// carried forward on its filtered velocity — scaled by the prediction control
/// — so marks glide instead of stepping. The marks themselves come from
/// `GVTrackingCanvas`, the same display list the recorder burns into takes,
/// so what is framed here is what is recorded.
struct GVTrackingOverlay: View {
    @ObservedObject var runtime: BlobTrackingRuntime
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(GVAmbientClock.ambient(hertz: 60, scenePhase: scenePhase, isActive: runtime.isEnabled)) { clock in
            Canvas { context, size in
                let now = ProcessInfo.processInfo.systemUptime
                _ = clock.date
                let canvas = GVTrackingCanvas(
                    parameters: runtime.parameters,
                    surface: size,
                    displayed: GVTrackingCanvas.aspectFill(source: runtime.sourceSize, into: size),
                    elapsed: reduceMotion ? 0 : min(max(now - runtime.resultTimestamp, 0), 0.25)
                )
                let hud = GVTrackingCanvas.hudLines(mode: runtime.parameters.mode, locks: runtime.blobs.count,
                                                    maxTracks: runtime.parameters.maxTracks, rate: runtime.passRate)
                canvas.build(blobs: runtime.blobs, mask: runtime.mask, hud: hud).play(in: &context)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - SwiftUI player

extension GVTrackingDisplayList {
    /// Plays the list into a SwiftUI graphics context.
    func play(in context: inout GraphicsContext) {
        for op in ops {
            switch op {
            case let .stroke(path, color, width, dash):
                context.stroke(Path(path), with: .color(color.color),
                               style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))
            case let .gradientStroke(path, from, to, start, end, width, dash):
                context.stroke(Path(path), with: .linearGradient(Gradient(colors: [from.color, to.color]),
                                                                 startPoint: start, endPoint: end),
                               style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
            case let .fill(path, color):
                context.fill(Path(path), with: .color(color.color))
            case let .glow(path, color, width, blur):
                var glow = context
                glow.addFilter(.blur(radius: blur))
                glow.stroke(Path(path), with: .color(color.color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            case let .label(text, origin, size, color, plate):
                let resolved = context.resolve(
                    Text(text)
                        .font(.system(size: size, weight: .semibold, design: .monospaced))
                        .foregroundStyle(color.color)
                )
                if plate {
                    let measured = resolved.measure(in: CGSize(width: 600, height: 40))
                    let rect = CGRect(x: origin.x - 3, y: origin.y - 1, width: measured.width + 6, height: measured.height + 2)
                    context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.black.opacity(0.55 * color.a)))
                }
                context.draw(resolved, at: origin, anchor: .topLeading)
            }
        }
    }
}

private extension GVRGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}
