import AVFoundation
import CoreImage
import QuartzCore
import SwiftUI
import UIKit
import VideoToolbox

/// Where the operator's finger is over the splash. Not observable on purpose:
/// the stage reads it every frame, so a drag never re-renders SwiftUI.
@MainActor
final class GVSplashPointer {
    var location: CGPoint? {
        didSet { movedAt = CACurrentMediaTime() }
    }
    private(set) var movedAt: CFTimeInterval = 0
}

/// The splash video as an x-ray, with "tracked object" boxes that reveal the
/// true colour underneath. A cursor box follows the finger and drops labelled
/// objects behind it, linked by thin curves, that fade after a few seconds.
/// With no finger down, a ghost cursor wanders the frame instead.
///
/// iOS layers do not run Core Image filters, so the x-ray is rendered per new
/// video frame through one Metal-backed `CIContext`; the colour layer shows the
/// same frame untouched, masked by the boxes.
struct GVSplashStage: UIViewRepresentable {
    let pointer: GVSplashPointer
    let playing: Bool
    let reduceMotion: Bool

    func makeUIView(context: Context) -> StageView {
        StageView(pointer: pointer)
    }

    func updateUIView(_ view: StageView, context: Context) {
        view.reduceMotion = reduceMotion
        view.setPlaying(playing)
    }

    static func dismantleUIView(_ view: StageView, coordinator: ()) {
        view.teardown()
    }

    @MainActor
    final class StageView: UIView {
        var reduceMotion = false
        private let pointer: GVSplashPointer
        private let player = AVPlayer()
        private let output = AVPlayerItemVideoOutput(outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
        ])
        private let ciContext = CIContext(options: [.cacheIntermediates: false])
        private var hasFrame = false
        private var videoSize = CGSize(width: 1320, height: 2868)

        private let xray = CALayer()
        private let color = CALayer()
        private let reveal = CALayer()
        private let hud = CALayer()
        private var tiles: [GVSplashBoxLayers] = []

        private var tracker = GVSplashTracker()
        private var endObserver: NSObjectProtocol?
        private var displayLink: CADisplayLink?

        init(pointer: GVSplashPointer) {
            self.pointer = pointer
            super.init(frame: .zero)
            backgroundColor = .black
            isMultipleTouchEnabled = false

            for media in [xray, color] {
                media.contentsGravity = .resizeAspectFill
                media.masksToBounds = true
            }
            color.mask = reveal
            layer.addSublayer(xray)
            layer.addSublayer(color)
            layer.addSublayer(hud)

            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            player.actionAtItemEnd = .none
            guard let url = Bundle.main.url(forResource: "Splash", withExtension: "mp4") else { return }
            let item = AVPlayerItem(url: url)
            item.add(output)
            player.replaceCurrentItem(with: item)
            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.player.seek(to: .zero) }
            }
            loadPoster(url)
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                displayLink?.invalidate()
                displayLink = nil
            } else if displayLink == nil {
                let link = CADisplayLink(target: GVSplashLinkTarget(self), selector: #selector(GVSplashLinkTarget.step))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        }

        /// The x-ray look: drop the colour, invert, and cool it so the white
        /// studio backdrop goes black and the subject glows like film.
        private func xrayImage(from image: CIImage) -> CIImage {
            image
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.18])
                .applyingFilter("CIColorInvert")
                .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 2.1])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.80, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0.90, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 1.0, w: 0),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0.002, w: 0),
                ])
        }

        /// The first frame, so the stage is never black while the video spins
        /// up or while Reduce Motion keeps it paused.
        private func loadPoster(_ url: URL) {
            Task { [weak self] in
                guard let image = await Self.firstFrame(of: url) else { return }
                guard let self, !self.hasFrame else { return }
                self.videoSize = CGSize(width: image.width, height: image.height)
                self.show(CIImage(cgImage: image), original: image)
            }
        }

        nonisolated private static func firstFrame(of url: URL) async -> CGImage? {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            return try? await generator.image(at: .zero).image
        }

        private func show(_ image: CIImage, original: CGImage) {
            let ray = ciContext.createCGImage(xrayImage(from: image), from: image.extent)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            xray.contents = ray
            color.contents = original
            CATransaction.commit()
        }

        func setPlaying(_ playing: Bool) {
            if playing { player.play() } else { player.pause() }
        }

        func teardown() {
            player.pause()
            displayLink?.invalidate()
            displayLink = nil
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for sub in [xray, color, reveal, hud] { sub.frame = bounds }
            let scale = window?.screen.scale ?? 3
            for tile in tiles { tile.setScale(scale) }
            CATransaction.commit()
        }

        // MARK: Touch

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            pointer.location = touches.first?.location(in: self)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            pointer.location = touches.first?.location(in: self)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            pointer.location = nil
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            pointer.location = nil
        }

        // MARK: Frame

        /// One frame: pull the newest video frame, move the boxes, redraw.
        func tick() {
            guard window != nil else { return }
            let now = CACurrentMediaTime()
            pullFrame(now)
            let resting = now - pointer.movedAt > 2.5
            let target = resting ? nil : pointer.location
            tracker.step(now: now, pointer: target, bounds: bounds.size, reduceMotion: reduceMotion)
            render()
        }

        private func pullFrame(_ now: CFTimeInterval) {
            let time = output.itemTime(forHostTime: now)
            guard output.hasNewPixelBuffer(forItemTime: time),
                  let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
            else { return }
            var original: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &original)
            guard let original else { return }
            hasFrame = true
            videoSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            show(CIImage(cvPixelBuffer: buffer), original: original)
        }

        private func render() {
            let boxes = tracker.visibleBoxes
            let scale = window?.screen.scale ?? 3
            while tiles.count < boxes.count {
                let tile = GVSplashBoxLayers(scale: scale)
                reveal.addSublayer(tile.tile)
                hud.addSublayer(tile.link)
                hud.addSublayer(tile.bracket)
                hud.addSublayer(tile.label)
                tiles.append(tile)
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (index, tile) in tiles.enumerated() {
                guard index < boxes.count else { tile.hide(); continue }
                let box = boxes[index]
                let next = index + 1 < boxes.count ? boxes[index + 1].rect : nil
                tile.show(box, linkTo: next, text: label(for: box))
            }
            CATransaction.commit()
        }

        private func label(for box: GVSplashTracker.Box) -> String {
            guard let id = box.id else { return "CURSOR" }
            // Coordinates in source-video pixels, under aspect-fill.
            let fill = max(bounds.width / videoSize.width, bounds.height / videoSize.height)
            let originX = (bounds.width - videoSize.width * fill) / 2
            let originY = (bounds.height - videoSize.height * fill) / 2
            let x = Int(((box.rect.midX - originX) / fill).rounded())
            let y = Int(((box.rect.midY - originY) / fill).rounded())
            return "OBJ \(id)  X\(x) Y\(y)"
        }
    }
}

/// Breaks the display link's retain on the view.
@MainActor
private final class GVSplashLinkTarget: NSObject {
    weak var view: GVSplashStage.StageView?
    init(_ view: GVSplashStage.StageView) { self.view = view }
    @objc func step() { view?.tick() }
}

/// Moves the cursor box and spawns, ages and retires the object boxes.
/// Rects are in top-left-origin view points.
@MainActor
private struct GVSplashTracker {
    struct Box {
        /// nil for the cursor box.
        var id: Int?
        var rect: CGRect
        var alpha: Double
    }

    private struct Object {
        let id: Int
        let rect: CGRect
        let born: CFTimeInterval
        let life: CFTimeInterval
    }

    private(set) var visibleBoxes: [Box] = []
    private var objects: [Object] = []
    private var center: CGPoint?
    private var cursorAlpha = 0.0
    private var lastDrop: CGPoint?
    private var lastStep: CFTimeInterval?
    private var nextID = 18
    private let cursorSize = CGSize(width: 120, height: 120)

    mutating func step(now: CFTimeInterval, pointer: CGPoint?, bounds: CGSize, reduceMotion: Bool) {
        let dt = lastStep.map { min(0.05, now - $0) } ?? 0
        lastStep = now
        guard bounds.width > 0, bounds.height > 0 else { visibleBoxes = []; return }

        // With no finger down, a ghost cursor wanders a slow Lissajous loop.
        var target = pointer
        if target == nil, !reduceMotion {
            target = CGPoint(x: bounds.width * (0.5 + 0.27 * sin(now * 0.31)),
                             y: bounds.height * (0.52 + 0.24 * sin(now * 0.47 + 1.1)))
        }

        if let target {
            if let current = center, !reduceMotion {
                let k = min(1, dt * (pointer == nil ? 3 : 11))
                center = CGPoint(x: current.x + (target.x - current.x) * k,
                                 y: current.y + (target.y - current.y) * k)
            } else {
                center = target
            }
        }
        cursorAlpha += ((target == nil ? 0 : 1) - cursorAlpha) * (reduceMotion ? 1 : min(1, dt * 6))

        if !reduceMotion, let center, target != nil {
            if let lastDrop {
                if hypot(center.x - lastDrop.x, center.y - lastDrop.y) > 140 { drop(at: center, now: now) }
            } else {
                self.lastDrop = center
            }
        }
        if reduceMotion { objects.removeAll() }
        objects.removeAll { now - $0.born > $0.life }

        visibleBoxes = objects.map { object in
            let age = now - object.born
            let grow = min(1, age / 0.25)
            let ease = 1 - pow(1 - grow, 3)
            let fade = min(1, (object.life - age) / 0.7)
            let s = 0.82 + 0.18 * ease
            let rect = object.rect.insetBy(dx: object.rect.width * (1 - s) / 2, dy: object.rect.height * (1 - s) / 2)
            return Box(id: object.id, rect: rect, alpha: ease * fade)
        }
        if let center, cursorAlpha > 0.01 {
            let rect = CGRect(x: center.x - cursorSize.width / 2, y: center.y - cursorSize.height / 2,
                              width: cursorSize.width, height: cursorSize.height)
            visibleBoxes.append(Box(id: nil, rect: rect, alpha: cursorAlpha))
        }
    }

    private mutating func drop(at point: CGPoint, now: CFTimeInterval) {
        lastDrop = point
        let size = CGSize(width: .random(in: 100...180), height: .random(in: 90...160))
        let rect = CGRect(x: point.x - size.width * .random(in: 0.35...0.65),
                          y: point.y - size.height * .random(in: 0.35...0.65),
                          width: size.width, height: size.height)
        objects.append(Object(id: nextID, rect: rect, born: now, life: .random(in: 3.0...4.4)))
        nextID = nextID >= 29 ? 18 : nextID + 1
        if objects.count > 6 { objects.removeFirst() }
    }
}

/// The Core Animation layers for one box: its reveal tile in the colour mask,
/// its corner brackets, its tag, and the curve to the next box. UIKit layers
/// are top-left origin, so no flip is needed.
@MainActor
private final class GVSplashBoxLayers {
    static let lime = UIColor(red: 0.89, green: 0.96, blue: 0.36, alpha: 1)
    let tile = CALayer()
    let bracket = CAShapeLayer()
    let link = CAShapeLayer()
    let label = CALayer()
    private let text = CATextLayer()
    private static let font = UIFont.monospacedSystemFont(ofSize: 9, weight: .medium)

    init(scale: CGFloat) {
        tile.backgroundColor = UIColor.white.cgColor
        for shape in [bracket, link] {
            shape.fillColor = nil
            shape.strokeColor = Self.lime.cgColor
            shape.lineCap = .square
        }
        bracket.lineWidth = 1
        link.lineWidth = 0.75
        link.strokeColor = Self.lime.withAlphaComponent(0.6).cgColor
        label.backgroundColor = Self.lime.cgColor
        text.font = Self.font
        text.fontSize = 9
        text.foregroundColor = UIColor.black.cgColor
        text.alignmentMode = .left
        label.addSublayer(text)
        setScale(scale)
        hide()
    }

    func setScale(_ scale: CGFloat) {
        text.contentsScale = scale
        for layer in [tile, bracket, link, label] { layer.contentsScale = scale }
    }

    func hide() {
        for layer in [tile, bracket, link, label] { layer.isHidden = true }
    }

    func show(_ box: GVSplashTracker.Box, linkTo next: CGRect?, text string: String) {
        let rect = box.rect.integral
        let alpha = Float(box.alpha)

        tile.isHidden = false
        tile.frame = rect
        tile.opacity = alpha

        let path = CGMutablePath()
        let arm = min(18, rect.width / 4, rect.height / 4)
        if box.id == nil { path.addRect(rect.insetBy(dx: 0.5, dy: 0.5)) }
        for corner in [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0),
                       (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0)] {
            let (x, y, sx, sy) = corner
            path.move(to: CGPoint(x: x + sx * arm, y: y))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + sy * arm))
        }
        bracket.isHidden = false
        bracket.path = path
        bracket.opacity = box.id == nil ? alpha * 0.85 : alpha

        if let next {
            let a = CGPoint(x: rect.midX, y: rect.midY), b = CGPoint(x: next.midX, y: next.midY)
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let bend = 0.28
            let control = CGPoint(x: mid.x - (b.y - a.y) * bend, y: mid.y + (b.x - a.x) * bend)
            let curve = CGMutablePath()
            curve.move(to: a)
            curve.addQuadCurve(to: b, control: control)
            link.path = curve
            link.isHidden = false
            link.opacity = alpha
        } else {
            link.isHidden = true
        }

        text.string = string
        let width = ceil((string as NSString).size(withAttributes: [.font: Self.font]).width) + 8
        label.isHidden = false
        // Tag hangs off the box's top-left corner, above it.
        label.frame = CGRect(x: rect.minX, y: rect.minY - 13, width: width, height: 13)
        text.frame = CGRect(x: 4, y: 0.5, width: width - 6, height: 12)
        label.opacity = alpha
    }
}
