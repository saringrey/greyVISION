import SwiftUI

/// The wordmark rendered as live ASCII.
///
/// This is a native port of the React Bits `ASCIIText` idea: the source text is
/// rasterised once into a small luminance grid, then every frame that grid is
/// resampled with a travelling wave and emitted as a single monospaced string.
/// The React component is Three.js + WebGL + a DOM `<pre>`; none of that exists
/// here, so the same result is produced with one offscreen raster and one
/// `Text` per frame — far cheaper than a GL context on the splash.
///
/// Touch drags the sampling origin, which reads as the plane tilting under the
/// finger the way the original's mouse-driven mesh rotation does.
struct GVASCIIWordmark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String
    /// Glyph size for the ASCII overlay.
    var glyphSize: CGFloat = 7.5
    /// Columns in the ASCII grid. Rows follow from the text aspect.
    var columns: Int = 74
    var enableWaves = true
    var tint = GVTheme.bone
    /// Bright glyphs pick this up, so the mark reads as lit rather than flat
    /// grey. The gradient runs across the block, not per character, which keeps
    /// it cheap — still one `Text` per frame.
    var accent = GVTheme.violet
    /// When the mark starts materialising. Cells resolve on a left-to-right
    /// front with per-cell jitter, so the block assembles out of noise instead
    /// of being switched on.
    var revealStart: Date = .distantPast
    var revealDuration: Double = 2.6

    @State private var mask: GVGlyphMask?
    @State private var touch: CGPoint?

    /// Dark to light. Index 0 is empty space.
    /// The reference component's ramp, dark to light. A long ramp resolves the
    /// antialiased edge of a letterform into a gradient of glyph weights, which
    /// is what makes the mark legible; a 10-step ramp quantises every stroke to
    /// the same character and the shape disappears.
    private static let charset = Array(
        " .'`^\",:;Il!i~+_-?][}{1)(|/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$"
    )

    var body: some View {
        Group {
            if let mask {
                if reduceMotion {
                    asciiText(mask.render(time: 0, tilt: .zero, waves: false, reveal: 1))
                } else {
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { timeline in
                        let time = timeline.date.timeIntervalSinceReferenceDate
                        asciiText(
                            mask.render(
                                time: time,
                                tilt: tiltVector,
                                waves: enableWaves,
                                reveal: reveal(at: timeline.date)
                            )
                        )
                        .shadow(color: accent.opacity(0.35 + 0.2 * sin(time * 1.8)), radius: 4)
                        .offset(y: enableWaves ? sin(time * 1.2) * 1.5 : 0)
                    }
                }
            } else {
                // Nothing legible until the raster exists; the splash reveals
                // this block late anyway.
                Color.clear
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in touch = value.location }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) {
                        touch = nil
                    }
                }
        )
        .task(id: text) {
            mask = await GVGlyphMask.make(text: text, columns: columns)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private func reveal(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(revealStart)
        guard elapsed > 0 else { return 0 }
        return min(elapsed / revealDuration, 1)
    }

    /// Normalised drag offset from the centre, -1...1 on each axis.
    private var tiltVector: CGVector {
        guard let touch else { return .zero }
        return CGVector(
            dx: min(max((touch.x / 200) - 1, -1), 1),
            dy: min(max((touch.y / 60) - 1, -1), 1)
        )
    }

    private func asciiText(_ value: String) -> some View {
        Text(value)
            .font(.system(size: glyphSize, weight: .bold, design: .monospaced))
            .monospaced()
            .lineSpacing(0)
            .kerning(0)
            .foregroundStyle(
                LinearGradient(
                    colors: [accent, tint, .white, tint, accent],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .shadow(color: accent.opacity(0.65), radius: 6)
            .shadow(color: accent.opacity(0.35), radius: 14)
            .fixedSize()
            .allowsHitTesting(false)
    }
}

/// A rasterised luminance grid for one string.
///
/// Built once off the main render path. Sampling is pure arithmetic afterwards,
/// so a frame costs one string build and no image work.
struct GVGlyphMask: Sendable {
    let columns: Int
    let rows: Int
    /// Row-major luminance, 0...1.
    let samples: [Float]

    /// The reference component's ramp, dark to light. A long ramp resolves the
    /// antialiased edge of a letterform into a gradient of glyph weights, which
    /// is what makes the mark legible; a 10-step ramp quantises every stroke to
    /// the same character and the shape disappears.
    private static let charset = Array(
        " .'`^\",:;Il!i~+_-?][}{1)(|/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$"
    )

    @MainActor
    static func make(text: String, columns: Int) async -> GVGlyphMask? {
        let renderer = ImageRenderer(
            content: Text(text)
                .font(.system(size: 160, weight: .black, design: .monospaced))
                .kerning(6)
                .foregroundStyle(.white)
                .padding(6)
                .background(.black)
        )
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }

        // Monospaced glyph cells are roughly twice as tall as wide, so halve the
        // row count to keep the wordmark's proportions.
        let aspect = Double(image.height) / Double(max(image.width, 1))
        let rows = max(Int((Double(columns) * aspect * 0.62).rounded()), 5)

        let width = columns
        let height = rows
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        return GVGlyphMask(
            columns: width,
            rows: height,
            samples: bytes.map { Float($0) / 255 }
        )
    }

    /// Resamples the grid with a travelling wave plus a tilt offset and returns
    /// the finished ASCII block.
    func render(time: TimeInterval, tilt: CGVector, waves: Bool, reveal: Double) -> String {
        var output = String()
        output.reserveCapacity((columns + 1) * rows)

        let wave = waves ? 1.0 : 0.0
        let phase = time * 2.4

        for row in 0 ..< rows {
            let rowFraction = Double(row) / Double(max(rows - 1, 1))
            // Horizontal displacement per row: the wave travels down the mark.
            let shift = (sin(phase + rowFraction * 5.2) * 1.9 + tilt.dx * 3.4) * wave
                + tilt.dx * 2.0

            for column in 0 ..< columns {
                let columnFraction = Double(column) / Double(max(columns - 1, 1))
                // Vertical displacement per column, so the plane also ripples.
                let lift = (cos(phase * 0.8 + columnFraction * 4.1) * 0.55 + tilt.dy * 1.1) * wave
                    + tilt.dy * 0.8

                let sourceX = Int((Double(column) + shift).rounded())
                let sourceY = Int((Double(row) + lift).rounded())
                output.append(character(x: sourceX, y: sourceY, time: time, reveal: reveal))
            }
            output.append("\n")
        }
        return output
    }

    private func character(x: Int, y: Int, time: TimeInterval, reveal: Double) -> Character {
        guard x >= 0, x < columns, y >= 0, y < rows else { return " " }
        var luminance = Double(samples[y * columns + x])

        // Materialisation front. Each cell gets a threshold from its column
        // plus a stable hash, so the front is ragged rather than a clean wipe,
        // and cells fade up through the ramp instead of popping in.
        if reveal < 1 {
            let columnFraction = Double(x) / Double(max(columns - 1, 1))
            let jitter = (sin(Double(x) * 91.7 + Double(y) * 47.3) + 1) * 0.5
            let threshold = columnFraction * 0.66 + jitter * 0.3
            let local = (reveal - threshold) / 0.22
            guard local > 0 else { return " " }
            luminance *= min(local, 1)
        }

        // Fully transparent cells are space, exactly as the reference treats
        // alpha 0. Everything else maps across the whole ramp.
        guard luminance > 0.04 else { return " " }

        // Gentle animated shimmer, far below the step between ramp entries so
        // it never dissolves a stroke.
        let noise = sin((Double(x) * 12.9898 + Double(y) * 78.233) + time * 2.2) * 0.02
        let value = min(max(luminance + noise, 0), 1)

        // `invert: true` in the reference: bright pixels take dense glyphs.
        let index = Int(value * Double(GVGlyphMask.charset.count - 1))
        return GVGlyphMask.charset[min(max(index, 0), GVGlyphMask.charset.count - 1)]
    }
}
