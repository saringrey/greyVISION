import CoreGraphics
import CoreText
import Foundation
import simd

/// The tracking overlay as data: strokes, fills, glows and labels in
/// surface coordinates.
///
/// One builder, two players. The live overlay plays the list into a SwiftUI
/// `GraphicsContext`; the recorder plays the same list into the Core Graphics
/// context over each written frame. So a take carries exactly the marks the
/// operator framed with — the overlay used to be SwiftUI-only and every
/// recording came out without them.
struct GVTrackingDisplayList {
    enum Op {
        case stroke(CGPath, GVRGBA, width: CGFloat, dash: [CGFloat])
        case gradientStroke(CGPath, from: GVRGBA, to: GVRGBA, start: CGPoint, end: CGPoint, width: CGFloat, dash: [CGFloat])
        case fill(CGPath, GVRGBA)
        /// A soft halo under a mark: the path stroked wide and blurred.
        case glow(CGPath, GVRGBA, width: CGFloat, blur: CGFloat)
        /// Monospaced text, top-left anchored, optionally on a dark plate.
        case label(String, at: CGPoint, size: CGFloat, color: GVRGBA, plate: Bool)
    }

    private(set) var ops: [Op] = []

    mutating func append(_ op: Op) {
        ops.append(op)
    }
}

/// Straight RGBA, 0...1.
struct GVRGBA: Equatable, Sendable {
    var r: Double, g: Double, b: Double, a: Double

    func opacity(_ factor: Double) -> GVRGBA {
        GVRGBA(r: r, g: g, b: b, a: a * factor)
    }

    static let bone = GVRGBA(r: 0.941, g: 0.937, b: 0.925, a: 1)
    static let plate = GVRGBA(r: 0, g: 0, b: 0, a: 0.55)
}

/// What a frame of tracking looks like, independent of where it is drawn.
///
/// `displayed` is where the analysed frame sits on the surface — an
/// aspect-fill rect on the preview, the visible region inside the full frame
/// on a recording — and `scale` multiplies stroke widths and type, so marks
/// keep their weight on a 4K frame.
struct GVTrackingCanvas {
    let parameters: BlobTrackingParameters
    let surface: CGSize
    let displayed: CGRect
    let scale: CGFloat
    /// Seconds since the analysed frame, for prediction.
    let elapsed: Double

    /// Monospaced advance per point of type, for laying labels out the same
    /// way in both players without measuring text.
    static let advance: CGFloat = 0.62

    init(parameters: BlobTrackingParameters, surface: CGSize, displayed: CGRect, scale: CGFloat = 1, elapsed: Double) {
        self.parameters = parameters
        self.surface = surface
        self.displayed = displayed
        self.scale = scale
        self.elapsed = elapsed
    }

    /// The preview: the analysis frame aspect-filled into the view.
    static func aspectFill(source: CGSize, into viewport: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0 else { return CGRect(origin: .zero, size: viewport) }
        let fill = max(viewport.width / source.width, viewport.height / source.height)
        let size = CGSize(width: source.width * fill, height: source.height * fill)
        return CGRect(x: (viewport.width - size.width) / 2, y: (viewport.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// Everything for one frame, back to front.
    func build(blobs: [TrackedBlob], mask: GVTrackingMask?, hud: [String]) -> GVTrackingDisplayList {
        var list = GVTrackingDisplayList()
        if parameters.showMask, let mask { appendMask(mask, to: &list) }
        appendLinks(blobs, to: &list)
        for blob in blobs {
            append(blob, to: &list)
        }
        appendHUD(hud, to: &list)
        return list
    }

    // MARK: Mapping

    func point(_ normalized: CGPoint) -> CGPoint {
        CGPoint(x: displayed.minX + normalized.x * displayed.width, y: displayed.minY + normalized.y * displayed.height)
    }

    /// Where a subject is drawn now: its filtered position carried forward on
    /// its velocity, plus a short look-ahead set by the prediction control.
    func rect(for blob: TrackedBlob) -> CGRect {
        let lead = (elapsed + 0.06) * parameters.prediction
        let shifted = blob.rect.offsetBy(dx: blob.velocity.dx * lead, dy: blob.velocity.dy * lead)
        let origin = point(shifted.origin)
        return CGRect(x: origin.x, y: origin.y,
                      width: shifted.width * displayed.width, height: shifted.height * displayed.height)
    }

    func tint(for blob: TrackedBlob) -> GVRGBA {
        switch parameters.palette {
        case .mono:
            return .bone
        case .spectrum:
            let hue = Double(blob.id) * 0.618_034
            return Self.hsv(hue - floor(hue), 0.75, 1)
        case .field:
            // The subject's own colour, lifted so a dark field still draws a
            // visible mark.
            let color = blob.color
            let peak = Double(max(color.x, max(color.y, color.z), 0.001))
            let lift = min(1 / peak, 4)
            return GVRGBA(r: min(Double(color.x) * lift, 1), g: min(Double(color.y) * lift, 1),
                          b: min(Double(color.z) * lift, 1), a: 1)
        }
    }

    // MARK: Marks

    private func append(_ blob: TrackedBlob, to list: inout GVTrackingDisplayList) {
        let tint = tint(for: blob)
        let rect = rect(for: blob)
        let weight = CGFloat(parameters.lineWidth) * scale
        let opacity = blob.isCoasting ? 0.45 : 1.0
        let dash: [CGFloat] = blob.isCoasting ? [4 * scale, 4 * scale] : []

        appendTrail(blob, tint: tint, to: &list)
        appendSkeleton(blob, tint: tint, to: &list)

        let mark = markPath(style: parameters.style, rect: rect, age: blob.age)
        if parameters.glow > 0.01 {
            list.append(.glow(mark, tint.opacity(parameters.glow * opacity), width: weight * 2.5,
                              blur: (3 + CGFloat(parameters.glow) * 9) * scale))
        }
        if parameters.style == .box {
            list.append(.fill(CGPath(roundedRect: rect, cornerWidth: 3 * scale, cornerHeight: 3 * scale, transform: nil),
                              tint.opacity(0.08 * opacity)))
        }
        if parameters.style == .dot {
            list.append(.fill(mark, tint.opacity(opacity)))
        } else {
            list.append(.stroke(mark, tint.opacity(opacity), width: weight, dash: dash))
        }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        if parameters.showCentroids, parameters.style != .dot, parameters.style != .crosshair {
            let arm = 3 * scale
            let cross = CGMutablePath()
            cross.move(to: CGPoint(x: center.x - arm, y: center.y))
            cross.addLine(to: CGPoint(x: center.x + arm, y: center.y))
            cross.move(to: CGPoint(x: center.x, y: center.y - arm))
            cross.addLine(to: CGPoint(x: center.x, y: center.y + arm))
            list.append(.stroke(cross, tint.opacity(opacity), width: scale, dash: []))
        }
        if parameters.showVectors {
            appendVector(blob, from: center, tint: tint, to: &list)
        }
        appendLabel(blob, rect: rect, tint: tint, opacity: opacity, to: &list)
    }

    func markPath(style: GVTrackingStyle, rect: CGRect, age: Double) -> CGPath {
        let path = CGMutablePath()
        switch style {
        case .brackets:
            let arm = max(min(rect.width, rect.height) * 0.24, 6 * scale)
            for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0),
                                     (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                     (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0),
                                     (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)]
            {
                path.move(to: CGPoint(x: corner.x + arm * dx, y: corner.y))
                path.addLine(to: corner)
                path.addLine(to: CGPoint(x: corner.x, y: corner.y + arm * dy))
            }
        case .box:
            path.addRoundedRect(in: rect, cornerWidth: 3 * scale, cornerHeight: 3 * scale)
        case .crosshair:
            let center = CGPoint(x: rect.midX, y: rect.midY)
            // Capped: a reticle on a field the size of the sky is a line
            // across the screen, not a crosshair.
            let reach = min(max(rect.width, rect.height) * 0.5, 44 * scale) + 10 * scale
            let gap = min(max(min(rect.width, rect.height) * 0.18, 4 * scale), 10 * scale)
            for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
                path.move(to: CGPoint(x: center.x + gap * dx, y: center.y + gap * dy))
                path.addLine(to: CGPoint(x: center.x + reach * dx, y: center.y + reach * dy))
            }
            path.addEllipse(in: CGRect(x: center.x - gap, y: center.y - gap, width: gap * 2, height: gap * 2))
        case .ring:
            let radius = max(rect.width, rect.height) / 2
            path.addEllipse(in: CGRect(x: rect.midX - radius, y: rect.midY - radius, width: radius * 2, height: radius * 2))
        case .target:
            let radius = max(rect.width, rect.height) / 2
            let center = CGPoint(x: rect.midX, y: rect.midY)
            path.addEllipse(in: CGRect(x: center.x - radius * 0.55, y: center.y - radius * 0.55,
                                       width: radius * 1.1, height: radius * 1.1))
            // A slowly turning outer ring of four arcs, so a lock reads as live.
            let spin = age * 1.4
            for quadrant in 0 ..< 4 {
                let start = spin + (Double(quadrant) * 90 + 12) * .pi / 180
                path.move(to: CGPoint(x: center.x + cos(start) * radius, y: center.y + sin(start) * radius))
                path.addArc(center: center, radius: radius, startAngle: start,
                            endAngle: start + 66 * .pi / 180, clockwise: false)
                let tick = start + .pi / 4
                path.move(to: CGPoint(x: center.x + cos(tick) * radius * 1.12, y: center.y + sin(tick) * radius * 1.12))
                path.addLine(to: CGPoint(x: center.x + cos(tick) * radius * 1.3, y: center.y + sin(tick) * radius * 1.3))
            }
        case .dot:
            let radius = (3 + CGFloat(parameters.lineWidth) * 1.5) * scale
            path.addEllipse(in: CGRect(x: rect.midX - radius, y: rect.midY - radius, width: radius * 2, height: radius * 2))
        case .lockOn:
            // Corner ticks outside the box, so the subject itself stays clear.
            let pad = 4 * scale
            let box = rect.insetBy(dx: -pad, dy: -pad)
            let arm = max(min(box.width, box.height) * 0.18, 5 * scale)
            for (corner, dx, dy) in [(CGPoint(x: box.minX, y: box.minY), 1.0, 1.0),
                                     (CGPoint(x: box.maxX, y: box.minY), -1.0, 1.0),
                                     (CGPoint(x: box.minX, y: box.maxY), 1.0, -1.0),
                                     (CGPoint(x: box.maxX, y: box.maxY), -1.0, -1.0)]
            {
                path.move(to: CGPoint(x: corner.x + arm * dx, y: corner.y))
                path.addLine(to: corner)
                path.addLine(to: CGPoint(x: corner.x, y: corner.y + arm * dy))
            }
            // Hairlines across the picture, broken where they would cross
            // the subject.
            let center = CGPoint(x: box.midX, y: box.midY)
            path.move(to: CGPoint(x: displayed.minX, y: center.y))
            path.addLine(to: CGPoint(x: box.minX - pad, y: center.y))
            path.move(to: CGPoint(x: box.maxX + pad, y: center.y))
            path.addLine(to: CGPoint(x: displayed.maxX, y: center.y))
            path.move(to: CGPoint(x: center.x, y: displayed.minY))
            path.addLine(to: CGPoint(x: center.x, y: box.minY - pad))
            path.move(to: CGPoint(x: center.x, y: box.maxY + pad))
            path.addLine(to: CGPoint(x: center.x, y: displayed.maxY))
        }
        return path
    }

    // MARK: Extras

    private func appendTrail(_ blob: TrackedBlob, tint: GVRGBA, to list: inout GVTrackingDisplayList) {
        guard blob.trail.count > 1 else { return }
        let points = blob.trail.map(point)
        for index in 1 ..< points.count {
            let segment = CGMutablePath()
            segment.move(to: points[index - 1])
            segment.addLine(to: points[index])
            let fade = Double(index) / Double(points.count)
            list.append(.stroke(segment, tint.opacity(fade * 0.8),
                                width: CGFloat(parameters.lineWidth) * (0.5 + CGFloat(fade)) * scale, dash: []))
        }
    }

    private func appendSkeleton(_ blob: TrackedBlob, tint: GVRGBA, to list: inout GVTrackingDisplayList) {
        guard !blob.joints.isEmpty else { return }
        let lead = (elapsed + 0.06) * parameters.prediction
        let shift = CGVector(dx: blob.velocity.dx * lead, dy: blob.velocity.dy * lead)
        let joints = blob.joints.map { joint -> CGPoint? in
            joint == GVVisionDetector.missing ? nil : point(CGPoint(x: joint.x + shift.dx, y: joint.y + shift.dy))
        }
        let bones = CGMutablePath()
        for bone in blob.bones where bone.count == 2 && bone[0] < joints.count && bone[1] < joints.count {
            guard let from = joints[bone[0]], let to = joints[bone[1]] else { continue }
            bones.move(to: from)
            bones.addLine(to: to)
        }
        list.append(.stroke(bones, tint.opacity(0.85), width: CGFloat(parameters.lineWidth) * 1.4 * scale, dash: []))
        let dots = CGMutablePath()
        let radius = (blob.bones.isEmpty ? 1.2 : 2.6) * scale
        for joint in joints.compactMap(\.self) {
            dots.addEllipse(in: CGRect(x: joint.x - radius, y: joint.y - radius, width: radius * 2, height: radius * 2))
        }
        list.append(.fill(dots, tint))
    }

    private func appendVector(_ blob: TrackedBlob, from center: CGPoint, tint: GVRGBA, to list: inout GVTrackingDisplayList) {
        let vector = CGVector(dx: blob.velocity.dx * displayed.width * 0.25, dy: blob.velocity.dy * displayed.height * 0.25)
        guard hypot(vector.dx, vector.dy) > 4 * scale else { return }
        let tip = CGPoint(x: center.x + vector.dx, y: center.y + vector.dy)
        let angle = atan2(vector.dy, vector.dx)
        let arrow = CGMutablePath()
        arrow.move(to: center)
        arrow.addLine(to: tip)
        for side in [-1.0, 1.0] {
            arrow.move(to: tip)
            arrow.addLine(to: CGPoint(x: tip.x - cos(angle + side * 0.45) * 7 * scale,
                                      y: tip.y - sin(angle + side * 0.45) * 7 * scale))
        }
        list.append(.stroke(arrow, tint, width: CGFloat(parameters.lineWidth) * scale, dash: []))
    }

    private func appendLabel(_ blob: TrackedBlob, rect: CGRect, tint: GVRGBA, opacity: Double,
                             to list: inout GVTrackingDisplayList)
    {
        let text: String
        switch parameters.labels {
        case .none: return
        case .designation: text = blob.label
        case .identifier: text = String(format: "#%02d", blob.id % 100)
        case .coordinates: text = String(format: "X%.2f Y%.2f", blob.rect.midX, blob.rect.midY)
        case .telemetry:
            let speed = hypot(blob.velocity.dx, blob.velocity.dy)
            text = String(format: "%@ %d%% · %.2fv · %.1fs", parameters.mode.noun, Int(blob.confidence * 100), speed, blob.age)
        }
        let size = 9.5 * scale
        let width = CGFloat(text.count) * size * Self.advance
        let height = size * 1.25
        var anchor = parameters.style == .dot || parameters.style == .crosshair
            ? CGPoint(x: rect.midX + 10 * scale, y: rect.midY - 14 * scale)
            : CGPoint(x: rect.minX, y: rect.minY - height - 4 * scale)
        // Kept on the surface: flipped under the mark when there is no room
        // above, and pulled in from the right edge rather than clipped.
        if anchor.y < 4 * scale { anchor.y = rect.maxY + 4 * scale }
        anchor.x = min(max(anchor.x, 4 * scale), surface.width - width - 6 * scale)
        list.append(.label(text, at: anchor, size: size, color: tint.opacity(opacity), plate: true))
    }

    private func appendLinks(_ blobs: [TrackedBlob], to list: inout GVTrackingDisplayList) {
        guard parameters.links != .none, blobs.count > 1 else { return }
        let centers = blobs.map { blob -> CGPoint in
            let rect = rect(for: blob)
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        func distance(_ a: Int, _ b: Int) -> CGFloat {
            hypot(centers[a].x - centers[b].x, centers[a].y - centers[b].y)
        }
        var pairs: [(Int, Int)] = []
        switch parameters.links {
        case .none:
            break
        case .chain:
            // Ordered by identity, so the chain keeps its shape as subjects move.
            let order = blobs.indices.sorted { blobs[$0].id < blobs[$1].id }
            pairs = zip(order, order.dropFirst()).map { ($0, $1) }
        case .nearest:
            for index in centers.indices {
                if let nearest = centers.indices.filter({ $0 != index }).min(by: { distance($0, index) < distance($1, index) }) {
                    pairs.append((index, nearest))
                }
            }
        case .web:
            let reach = max(surface.width, surface.height) * 0.45
            for a in centers.indices {
                for b in centers.indices where b > a && distance(a, b) < reach {
                    pairs.append((a, b))
                }
            }
        }
        for (a, b) in pairs {
            let line = CGMutablePath()
            line.move(to: centers[a])
            line.addLine(to: centers[b])
            list.append(.gradientStroke(line, from: tint(for: blobs[a]).opacity(0.7), to: tint(for: blobs[b]).opacity(0.7),
                                        start: centers[a], end: centers[b],
                                        width: CGFloat(parameters.lineWidth) * 0.8 * scale, dash: [2 * scale, 3 * scale]))
        }
    }

    /// The raw detection grid as dithered cells — what the detector actually
    /// sees, for tuning thresholds against the picture.
    private func appendMask(_ mask: GVTrackingMask, to list: inout GVTrackingDisplayList) {
        let cell = CGSize(width: displayed.width / CGFloat(mask.columns), height: displayed.height / CGFloat(mask.rows))
        let dot = min(cell.width, cell.height) * 0.62
        let path = CGMutablePath()
        for row in 0 ..< mask.rows {
            for column in 0 ..< mask.columns where mask.cells[row * mask.columns + column] != 0 {
                path.addRect(CGRect(x: displayed.minX + (CGFloat(column) + 0.5) * cell.width - dot / 2,
                                    y: displayed.minY + (CGFloat(row) + 0.5) * cell.height - dot / 2,
                                    width: dot, height: dot))
            }
        }
        list.append(.fill(path, GVRGBA.bone.opacity(0.32)))
    }

    /// The tracking HUD: mode, lock count and analysis rate, down the left edge.
    private func appendHUD(_ lines: [String], to list: inout GVTrackingDisplayList) {
        var y = surface.height * 0.36
        for line in lines {
            list.append(.label(line, at: CGPoint(x: 14 * scale, y: y), size: 9 * scale,
                               color: GVRGBA.bone.opacity(0.85), plate: false))
            y += 12 * scale
        }
    }

    static func hudLines(mode: GVTrackingMode, locks: Int, maxTracks: Double, rate: Double) -> [String] {
        ["TRK // \(mode.label.uppercased())", "\(locks)/\(Int(maxTracks)) LOCK", "\(Int(rate.rounded())) HZ"]
    }

    private static func hsv(_ h: Double, _ s: Double, _ v: Double) -> GVRGBA {
        let sector = h * 6
        let index = Int(sector) % 6
        let f = sector - floor(sector)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        let (r, g, b): (Double, Double, Double) = switch index {
        case 0: (v, t, p)
        case 1: (q, v, p)
        case 2: (p, v, t)
        case 3: (p, q, v)
        case 4: (t, p, v)
        default: (v, p, q)
        }
        return GVRGBA(r: r, g: g, b: b, a: 1)
    }
}

// MARK: - Core Graphics player

extension GVTrackingDisplayList {
    /// Plays the list into a bitmap context over a written frame.
    ///
    /// The list is in top-left coordinates. Paths are mapped into Quartz's
    /// bottom-left space point by point rather than by flipping the CTM — a
    /// flipped CTM mirrors glyphs, which is exactly how the recording overlay
    /// once burned its text in backwards.
    func play(in context: CGContext, height: CGFloat) {
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        func mapped(_ path: CGPath) -> CGPath {
            path.copy(using: &flip) ?? path
        }
        func cg(_ color: GVRGBA) -> CGColor {
            CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a)
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for op in ops {
            switch op {
            case let .stroke(path, color, width, dash):
                context.addPath(mapped(path))
                context.setStrokeColor(cg(color))
                context.setLineWidth(width)
                context.setLineDash(phase: 0, lengths: dash)
                context.strokePath()
            case let .gradientStroke(path, from, _, _, _, width, dash):
                // A two-stop gradient along a dashed hairline is not worth a
                // clip-and-shade pass per frame on the writer queue; the start
                // colour carries it.
                context.addPath(mapped(path))
                context.setStrokeColor(cg(from))
                context.setLineWidth(width)
                context.setLineDash(phase: 0, lengths: dash)
                context.strokePath()
            case let .fill(path, color):
                context.addPath(mapped(path))
                context.setFillColor(cg(color))
                context.fillPath()
            case let .glow(path, color, width, blur):
                context.saveGState()
                context.setShadow(offset: .zero, blur: blur, color: cg(color))
                context.addPath(mapped(path))
                context.setStrokeColor(cg(color.opacity(0.6)))
                context.setLineWidth(width)
                context.setLineDash(phase: 0, lengths: [])
                context.strokePath()
                context.restoreGState()
            case let .label(text, origin, size, color, plate):
                drawLabel(text, at: origin, size: size, color: cg(color), plate: plate, in: context, height: height)
            }
        }
    }

    private func drawLabel(_ text: String, at origin: CGPoint, size: CGFloat, color: CGColor, plate: Bool,
                           in context: CGContext, height: CGFloat)
    {
        let font = CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let lineHeight = size * 1.25
        if plate {
            let rect = CGRect(x: origin.x - 3, y: height - origin.y - lineHeight - 1,
                              width: bounds.width + 6, height: lineHeight + 2)
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.55))
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil))
            context.fillPath()
        }
        // Baseline in Quartz space: the label's top-left, dropped by its ascent.
        context.textPosition = CGPoint(x: origin.x, y: height - origin.y - size)
        CTLineDraw(line, context)
    }
}

// MARK: - Burn-in

/// What the recorder needs to draw tracking onto a frame: the latest result
/// and the setup it was drawn with. Published by the runtime into the feed.
struct GVTrackingSnapshot: Sendable {
    let parameters: BlobTrackingParameters
    let blobs: [TrackedBlob]
    let mask: GVTrackingMask?
    /// The analysed region within the full working frame.
    let region: CGRect
    let passRate: Double
    /// Uptime the analysed frame was rendered.
    let timestamp: Double

    /// Draws this snapshot over a full working frame of `width` × `height`
    /// pixels: subjects, links, labels and the HUD, scaled for the frame.
    func burn(into context: CGContext, width: Int, height: Int, now: Double) {
        let size = CGSize(width: width, height: height)
        let displayed = CGRect(x: region.minX * size.width, y: region.minY * size.height,
                               width: region.width * size.width, height: region.height * size.height)
        // Marks are designed in points on a phone; a frame is pixels, so they
        // scale with the frame's long edge against a ~852 pt screen.
        let scale = max(size.width, size.height) / 852
        let canvas = GVTrackingCanvas(parameters: parameters, surface: size, displayed: displayed, scale: scale,
                                      elapsed: min(max(now - timestamp, 0), 0.25))
        let hud = GVTrackingCanvas.hudLines(mode: parameters.mode, locks: blobs.count,
                                            maxTracks: parameters.maxTracks, rate: passRate)
        canvas.build(blobs: blobs, mask: mask, hud: hud).play(in: context, height: size.height)
    }
}
