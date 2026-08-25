import SwiftUI

struct SyntheticCameraSurface: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let bars: [Color] = [
        Color(red: 0.74, green: 0.74, blue: 0.74),
        Color(red: 0.73, green: 0.73, blue: 0.08),
        Color(red: 0.08, green: 0.70, blue: 0.70),
        Color(red: 0.08, green: 0.66, blue: 0.12),
        Color(red: 0.68, green: 0.09, blue: 0.68),
        Color(red: 0.66, green: 0.08, blue: 0.10),
        Color(red: 0.08, green: 0.10, blue: 0.68)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 60, paused: reduceMotion)) { timeline in
            Canvas(opaque: true, colorMode: .linear, rendersAsynchronously: true) { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                drawColorBars(context: &context, size: size)
                drawResolutionTargets(context: &context, size: size)
                drawMotionReference(context: &context, size: size, date: timeline.date)
            }
        }
        .overlay(alignment: .topTrailing) {
            Text("SIM SOURCE // DETERMINISTIC V1")
                .gvMono(7, .black)
                .tracking(1.0)
                .foregroundStyle(.black)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(GVTheme.acid)
                .padding(10)
                .accessibilityIdentifier("camera.synthetic.preview")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Deterministic simulator camera source with color bars and motion target")
    }

    private func drawColorBars(context: inout GraphicsContext, size: CGSize) {
        let topHeight = size.height * 0.58
        let barWidth = size.width / CGFloat(bars.count)
        for (index, color) in bars.enumerated() {
            let rect = CGRect(x: CGFloat(index) * barWidth, y: 0, width: barWidth + 1, height: topHeight)
            context.fill(Path(rect), with: .color(color))
        }

        let lowerY = topHeight
        let lowerHeight = size.height - lowerY
        let lowerColors: [Color] = [.black, Color(white: 0.18), .white, Color(white: 0.08), GVTheme.violetDeep, .black]
        let lowerWidth = size.width / CGFloat(lowerColors.count)
        for (index, color) in lowerColors.enumerated() {
            let rect = CGRect(
                x: CGFloat(index) * lowerWidth,
                y: lowerY,
                width: lowerWidth + 1,
                height: lowerHeight
            )
            context.fill(Path(rect), with: .color(color))
        }
    }

    private func drawResolutionTargets(context: inout GraphicsContext, size: CGSize) {
        let cell = max(4, min(size.width, size.height) / 70)
        let targetRect = CGRect(
            x: size.width * 0.05,
            y: size.height * 0.66,
            width: size.width * 0.22,
            height: size.height * 0.23
        )
        var y = targetRect.minY
        var row = 0
        while y < targetRect.maxY {
            var x = targetRect.minX
            var column = 0
            while x < targetRect.maxX {
                let isLight = (row + column).isMultiple(of: 2)
                let rect = CGRect(x: x, y: y, width: cell, height: cell)
                context.fill(Path(rect), with: .color(isLight ? .white : .black))
                x += cell
                column += 1
            }
            y += cell
            row += 1
        }

        var target = Path()
        target.addEllipse(in: CGRect(
            x: size.width * 0.76,
            y: size.height * 0.68,
            width: size.width * 0.17,
            height: size.width * 0.17
        ))
        context.stroke(target, with: .color(.white.opacity(0.84)), lineWidth: 1)
    }

    private func drawMotionReference(context: inout GraphicsContext, size: CGSize, date: Date) {
        let phase = reduceMotion ? 0.5 : date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4
        let travel = size.width * 0.46
        let originX = size.width * 0.30 + travel * phase
        let rect = CGRect(
            x: originX,
            y: size.height * 0.46,
            width: max(26, size.width * 0.08),
            height: max(26, size.width * 0.08)
        )
        context.fill(Path(rect), with: .color(GVTheme.violet.opacity(0.90)))
        context.stroke(Path(rect.insetBy(dx: 5, dy: 5)), with: .color(.black), lineWidth: 1)

        var vector = Path()
        vector.move(to: CGPoint(x: size.width * 0.30, y: rect.midY))
        vector.addLine(to: CGPoint(x: size.width * 0.76, y: rect.midY))
        context.stroke(vector, with: .color(.white.opacity(0.72)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }
}
