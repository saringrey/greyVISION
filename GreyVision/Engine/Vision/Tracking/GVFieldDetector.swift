import CoreGraphics
import Foundation
import simd

/// Grid segmentation for the six field modes: colour key, bright, shadow,
/// vivid, motion and skin.
///
/// The analysis frame is averaged into a coarse grid, each cell is classified
/// for the mode, an optional dilation bridges small gaps, and 8-connected
/// components become detections. Coarse on purpose — a 64-cell grid is what
/// makes this run at 30 Hz on the CPU with no allocation churn, and it is far
/// steadier than per-pixel keying, which flickers along every soft edge.
///
/// Not thread-safe: owned by the tracker's serial queue. Motion keeps the
/// previous pass's luma grid and is reset whenever the grid shape changes.
final class GVFieldDetector {
    struct Output {
        let detections: [GVTrackingDetection]
        let mask: GVTrackingMask
    }

    private var previousLuma: [Float] = []
    private var previousShape = (columns: 0, rows: 0)

    func reset() {
        previousLuma = []
        previousShape = (0, 0)
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func detect(_ frame: GVTrackingFrame, parameters: BlobTrackingParameters) -> Output {
        let parameters = parameters.sanitized
        let long = parameters.gridLongEdge
        let landscape = frame.width >= frame.height
        let columns = landscape ? long : max(Int((Double(long) * Double(frame.width) / Double(frame.height)).rounded()), 4)
        let rows = landscape ? max(Int((Double(long) * Double(frame.height) / Double(frame.width)).rounded()), 4) : long
        let count = columns * rows

        // Average the frame into the grid.
        var colors = [SIMD3<Float>](repeating: .zero, count: count)
        for row in 0 ..< rows {
            let y0 = row * frame.height / rows
            let y1 = max((row + 1) * frame.height / rows, y0 + 1)
            for column in 0 ..< columns {
                let x0 = column * frame.width / columns
                let x1 = max((column + 1) * frame.width / columns, x0 + 1)
                var sum = SIMD3<Float>.zero
                for y in y0 ..< min(y1, frame.height) {
                    for x in x0 ..< min(x1, frame.width) {
                        sum += frame.rgb(x, y)
                    }
                }
                colors[row * columns + column] = sum / Float(max((y1 - y0) * (x1 - x0), 1))
            }
        }

        // Classify.
        if previousShape != (columns, rows) {
            previousLuma = []
            previousShape = (columns, rows)
        }
        var luma = [Float](repeating: 0, count: count)
        var active = [Bool](repeating: false, count: count)
        let threshold = Float(parameters.threshold)
        for index in 0 ..< count {
            luma[index] = simd_dot(colors[index], SIMD3(0.2126, 0.7152, 0.0722))
        }
        // Bright and shadow select a slice of *this* frame — the brightest or
        // darkest (1 − threshold) × 30% of it — so a hazy daylight scene does
        // not turn into one field the size of the sky, and a night scene
        // still finds its lights. An absolute floor keeps a flat grey frame
        // from producing noise.
        let sorted = (parameters.mode == .bright || parameters.mode == .shadow) ? luma.sorted() : []
        let slice = Int(Float(count) * (1 - threshold) * 0.3)
        let brightCut = sorted.isEmpty ? 1 : max(sorted[max(count - 1 - slice, 0)], threshold * 0.5)
        let shadowCut = sorted.isEmpty ? 0 : min(sorted[min(slice, count - 1)], 1 - threshold * 0.5)
        let tolerance = Float(parameters.tolerance)
        let targetHue = Float(parameters.hue)
        for index in 0 ..< count {
            let color = colors[index]
            let level = luma[index]
            let hsv = Self.hsv(color)
            switch parameters.mode {
            case .color:
                // A key needs colour to key on: greys sit at hue zero and used
                // to light up as red.
                let hueDelta = min(abs(hsv.x - targetHue), 1 - abs(hsv.x - targetHue))
                active[index] = hsv.y > 0.18 && hsv.z > 0.12 && hueDelta < tolerance * 0.5
            case .bright:
                active[index] = level >= brightCut
            case .shadow:
                active[index] = level <= shadowCut
            case .vivid:
                active[index] = hsv.y * hsv.z > threshold * 0.7
            case .motion:
                if previousLuma.count == count {
                    active[index] = abs(level - previousLuma[index]) > (1 - threshold) * 0.14 + 0.012
                }
            case .skin:
                // Chroma window of the common skin cluster in YCbCr,
                // widened by the tolerance control.
                let cb = -0.168736 * color.x - 0.331264 * color.y + 0.5 * color.z
                let cr = 0.5 * color.x - 0.418688 * color.y - 0.081312 * color.z
                let widen = 0.5 + tolerance
                active[index] = level > 0.12
                    && abs(cb + 0.07) < 0.10 * widen
                    && abs(cr - 0.10) < 0.07 * widen
            case .face, .hand, .body, .salient:
                active[index] = false
            }
        }
        if parameters.mode == .motion {
            previousLuma = luma
        }

        // Bridge gaps.
        var grown = active
        for _ in 0 ..< Int(parameters.merge) {
            var next = grown
            for row in 0 ..< rows {
                for column in 0 ..< columns where !grown[row * columns + column] {
                    let left = column > 0 && grown[row * columns + column - 1]
                    let right = column < columns - 1 && grown[row * columns + column + 1]
                    let up = row > 0 && grown[(row - 1) * columns + column]
                    let down = row < rows - 1 && grown[(row + 1) * columns + column]
                    if left || right || up || down { next[row * columns + column] = true }
                }
            }
            grown = next
        }

        // 8-connected components over the grown field; statistics from the
        // original cells, so dilation joins regions without inflating them.
        var labels = [Int32](repeating: -1, count: count)
        var detections: [GVTrackingDetection] = []
        var stack: [Int] = []
        stack.reserveCapacity(count)
        let minimumCells = Float(count) * Float(parameters.minArea)
        let maximumCells = Float(count) * Float(parameters.maxArea)
        var nextLabel: Int32 = 0
        for start in 0 ..< count where grown[start] && labels[start] < 0 {
            labels[start] = nextLabel
            stack.append(start)
            var cells = 0
            var colorSum = SIMD3<Float>.zero
            var minX = columns, maxX = -1, minY = rows, maxY = -1
            var centroid = SIMD2<Float>.zero
            while let current = stack.popLast() {
                let x = current % columns
                let y = current / columns
                if active[current] {
                    cells += 1
                    colorSum += colors[current]
                    centroid += SIMD2(Float(x), Float(y))
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
                for dy in -1 ... 1 {
                    for dx in -1 ... 1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < columns, ny >= 0, ny < rows else { continue }
                        let neighbour = ny * columns + nx
                        if grown[neighbour], labels[neighbour] < 0 {
                            labels[neighbour] = nextLabel
                            stack.append(neighbour)
                        }
                    }
                }
            }
            nextLabel += 1
            guard cells > 0, Float(cells) >= minimumCells, Float(cells) <= maximumCells else { continue }
            let rect = CGRect(
                x: CGFloat(minX) / CGFloat(columns),
                y: CGFloat(minY) / CGFloat(rows),
                width: CGFloat(maxX - minX + 1) / CGFloat(columns),
                height: CGFloat(maxY - minY + 1) / CGFloat(rows)
            )
            let boxCells = Float((maxX - minX + 1) * (maxY - minY + 1))
            detections.append(GVTrackingDetection(
                rect: rect,
                color: colorSum / Float(cells),
                area: Float(cells) / Float(count),
                confidence: min(Float(cells) / max(boxCells, 1), 1)
            ))
        }
        detections.sort { $0.area > $1.area }
        let mask = GVTrackingMask(columns: columns, rows: rows, cells: active.map { $0 ? 1 : 0 })
        return Output(detections: Array(detections.prefix(48)), mask: mask)
    }

    static func hsv(_ color: SIMD3<Float>) -> SIMD3<Float> {
        let maximum = max(color.x, max(color.y, color.z))
        let minimum = min(color.x, min(color.y, color.z))
        let delta = maximum - minimum
        var hue: Float = 0
        if delta > 0.0001 {
            if maximum == color.x {
                hue = ((color.y - color.z) / delta).truncatingRemainder(dividingBy: 6)
            } else if maximum == color.y {
                hue = (color.z - color.x) / delta + 2
            } else {
                hue = (color.x - color.y) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return SIMD3(hue, maximum > 0.0001 ? delta / maximum : 0, maximum)
    }
}
