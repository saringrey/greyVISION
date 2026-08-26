// swiftlint:disable file_length
import CoreMedia
import CoreVideo
import MetalKit
import Photos
import QuartzCore
import simd
import SwiftUI
import UIKit

enum CameraMetalShaderNames {
    static let yuvToLinear = "gvCameraYUVToLinear"
    static let syntheticLinear = "gvCameraSyntheticLinear"
    static let rgbSplit = "gvCameraRGBSplit"
    static let styleEffect = "gvCameraStyleEffect"
    static let temporalEffect = "gvCameraTemporalEffect"
    static let flowLuma = "gvFlowLuma"
    static let flowEstimate = "gvFlowEstimate"
    static let flowAccumulate = "gvFlowAccumulate"
    static let historyTap = "gvCameraHistoryTap"
    static let compositeWatermark = "gvCameraCompositeWatermark"
    static let signalFracture = "gvCameraSignalFracture"
    static let bandLuma = "gvCameraBandLuma"
    static let previewVertex = "gvCameraPreviewVertex"
    static let previewFragment = "gvCameraPreviewFragment"
}

/// Live render statistics surfaced to the camera HUD.
struct CameraRenderStats: Sendable, Equatable {
    var frameNumber: UInt64 = 0
    var gpuMilliseconds: Double = 0
    var historyTaps: Int = 0
    var historyMegabytes: Double = 0
    /// How hard the chrome has to work to stay readable over the frame
    /// beneath it, 0...1 — 0 is a dark subject that needs no help, 1 is a
    /// snowfield. The interface is unplated type over the live image; this is
    /// what lets it darken its own ground only when the subject demands it.
    var topChromeLoad: Double = 0
    /// The band the effect parameter deck sits over. Measured separately
    /// because that deck is where the operator reads numbers while an effect is
    /// running — the one place "approximately right" is least acceptable.
    var deckChromeLoad: Double = 0
    var bottomChromeLoad: Double = 0
    /// Effects the frame governor is currently shedding. Non-zero means the
    /// operator's stack is not fully on screen, which they are otherwise left
    /// to infer from the picture.
    var shedEffects: Int = 0

    static let idle = CameraRenderStats()
}

final class CameraRenderStatsMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = CameraRenderStats.idle

    var latest: CameraRenderStats {
        lock.withLock { value }
    }

    func publish(_ stats: CameraRenderStats) {
        lock.withLock { value = stats }
    }

    func clear() {
        lock.withLock { value = .idle }
    }
}

/// Start/stop handshake between the SwiftUI record control and the renderer's
/// per-frame draw loop. Start is a latch the renderer consumes with the real
/// drawable size; active flips once the writer is live so frames are captured.
final class CameraRecordingMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var startRequested = false
    private var active = false
    private var activeSession: GVRealtimeRecordingSession?
    
    private var requestedCodecRawValue: String = AVVideoCodecType.h264.rawValue
    private var requestedFPS: Int = 30
    
    func requestStart(codecRawValue: String, fps: Int) {
        lock.withLock {
            startRequested = true
            requestedCodecRawValue = codecRawValue
            requestedFPS = fps
        }
    }

    func requestStop() {
        lock.withLock {
            startRequested = false
            active = false
            activeSession = nil
        }
    }

    /// Peek, without consuming. The renderer has to know a take is about to
    /// begin *before* it sizes this frame's textures, and consuming the latch
    /// there would start the writer a frame early.
    var isStartPending: Bool {
        lock.withLock { startRequested }
    }

    func consumeStartRequest() -> (Bool, String, Int) {
        lock.withLock {
            defer { startRequested = false }
            return (startRequested, requestedCodecRawValue, requestedFPS)
        }
    }

    func activate(with session: GVRealtimeRecordingSession) {
        lock.withLock {
            active = true
            activeSession = session
        }
    }

    func isActive() -> Bool {
        lock.withLock { active }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.withLock {
            guard active, let session = activeSession else { return }
            session.appendAudio(sampleBuffer: sampleBuffer)
        }
    }
}

/// Recognises simple one-finger sigils from the recorded stroke: resampled to
/// a fixed count, then classified by closure and direction reversals. Circle,
/// star and zigzag unlock the hidden signature sequence.
private enum SigilStrokeClassifier {
    static func classify(_ raw: [SIMD2<Float>]) -> String? {
        guard raw.count >= 10 else { return nil }
        let points = resample(raw, to: 40)
        guard points.count == 40 else { return nil }
        let closed = simd_length(points[0] - points[points.count - 1]) < 0.32
        let reversals = directionReversals(points)
        if closed, reversals <= 3 {
            return "CIRCLE"
        }
        if reversals >= 5 {
            return "STAR"
        }
        if reversals == 1 || reversals == 2 {
            return "ZIGZAG"
        }
        return nil
    }

    private static func resample(_ points: [SIMD2<Float>], to count: Int) -> [SIMD2<Float>] {
        var cumulative: [Float] = [0]
        cumulative.reserveCapacity(points.count)
        for index in 1 ..< points.count {
            cumulative.append(cumulative[index - 1] + simd_length(points[index] - points[index - 1]))
        }
        let total = cumulative.last ?? 0
        guard total > 0.0001 else { return [] }
        var result: [SIMD2<Float>] = []
        result.reserveCapacity(count)
        var targetIndex = 1
        for sample in 0 ..< count {
            let target = total * Float(sample) / Float(count - 1)
            while targetIndex < cumulative.count - 1, cumulative[targetIndex] < target {
                targetIndex += 1
            }
            let segmentStart = cumulative[targetIndex - 1]
            let segmentLength = cumulative[targetIndex] - segmentStart
            let fraction = segmentLength > 0.0001 ? (target - segmentStart) / segmentLength : 0
            result.append(points[targetIndex - 1] + (points[targetIndex] - points[targetIndex - 1]) * fraction)
        }
        return result
    }

    private static func directionReversals(_ points: [SIMD2<Float>]) -> Int {
        guard points.count >= 3 else { return 0 }
        var reversals = 0
        var previousCross: Float = 0
        for index in 1 ..< points.count - 1 {
            let segmentA = points[index] - points[index - 1]
            let segmentB = points[index + 1] - points[index]
            let cross = segmentA.x * segmentB.y - segmentA.y * segmentB.x
            if abs(cross) > 0.0005 {
                if previousCross != 0, (previousCross > 0) != (cross > 0) {
                    reversals += 1
                }
                previousCross = cross
            }
        }
        return reversals
    }
}

/// One-shot latch: the screenshot button requests a capture, the renderer
/// consumes it on the next draw and blits the finished frame into a pixel
/// buffer that becomes the PNG.
final class CameraScreenshotMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    func requestCapture() {
        lock.withLock { requested = true }
    }

    /// Peek, without consuming. Same reason as the recording latch: the
    /// still has to be taken at capture resolution, which is a decision made
    /// before the frame is encoded.
    var isCapturePending: Bool {
        lock.withLock { requested }
    }

    func consumeRequest() -> Bool {
        lock.withLock {
            defer { requested = false }
            return requested
        }
    }
}

struct CameraRGBSplitUniforms {
    var parameters: SIMD4<Float>
}

struct CameraStyleEffectUniforms {
    var mode: SIMD4<UInt32>
    var parameters: SIMD4<Float>
    var viewport: SIMD4<Float>
    var extra: SIMD4<Float>
    var audio: SIMD4<Float>
    var touch: SIMD4<Float>
    var touchImpact: SIMD4<Float>
    var audioDynamics: SIMD4<Float>
    var blob0: SIMD4<Float>
    var blob1: SIMD4<Float>
    var blob2: SIMD4<Float>
    var blob3: SIMD4<Float>
    /// Sixteen log-spaced FFT bands packed four to a vector. Zero while the
    /// analyser is off, which is what makes a scope draw a flat line rather
    /// than garbage when nothing is listening.
    var spectrum0: SIMD4<Float>
    var spectrum1: SIMD4<Float>
    var spectrum2: SIMD4<Float>
    var spectrum3: SIMD4<Float>
    /// Frame-to-frame world reprojection. Identity unless a world-anchored
    /// mode is active and device attitude has primed.
    var worldReprojection: simd_float3x3
}

/// Latest single-finger interaction published by the preview view. Effect
/// kernels read it directly so the chosen effect can react to the finger
/// (water ripples, gravity lenses, ...) without touching SwiftUI state.
struct CameraTouchSnapshot: Equatable, Sendable {
    var position = SIMD2<Float>(repeating: 0.5)
    var velocity = SIMD2<Float>.zero
    var isActive = false
    var impactPosition: SIMD2<Float>?
    var impactTime: TimeInterval?

    static let idle = CameraTouchSnapshot()
}

final class CameraTouchMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = CameraTouchSnapshot.idle

    var latest: CameraTouchSnapshot {
        lock.withLock { value }
    }

    func began(position: SIMD2<Float>, velocity: SIMD2<Float>) {
        lock.withLock {
            value.position = position
            value.velocity = velocity
            value.isActive = true
            value.impactPosition = position
            value.impactTime = CACurrentMediaTime()
        }
    }

    func moved(position: SIMD2<Float>, velocity: SIMD2<Float>) {
        lock.withLock {
            value.position = position
            value.velocity = velocity
            value.isActive = true
        }
    }

    func ended() {
        lock.withLock {
            value.velocity = .zero
            value.isActive = false
        }
    }

    func clear() {
        lock.withLock {
            value = .idle
        }
    }
}

enum CameraTouchEvent {
    case began(SIMD2<Float>, SIMD2<Float>)
    case moved(SIMD2<Float>, SIMD2<Float>)
    case ended
}

@MainActor
struct CameraMetalSurface: UIViewRepresentable {
    @ObservedObject var runtime: CameraRuntime
    let rgbSplitParameters: RGBSplitEffectParameters
    let effectStack: CameraEffectStackParameters
    let audioSnapshot: AudioReactiveSnapshot
    let audioIntensity: Float
    let blobFields: [SIMD4<Float>]
    let scanlineParameters: ScanlineEffectParameters
    let fracture: SignalFractureController
    /// Live link to the Mac virtual camera, or nil when it is not armed.
    let broadcast: GVBroadcastEngine?
    let statsMailbox: CameraRenderStatsMailbox
    let onPreviewTap: @MainActor @Sendable () -> Void
    let onFocus: @MainActor (CGPoint) -> Void
    let onFailure: @MainActor () -> Void
    let onSigil: @MainActor (String) -> Void
    let sigilsEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            mailbox: runtime.latestFrameMailbox,
            fracture: fracture,
            statsMailbox: statsMailbox,
            recordingMailbox: runtime.recordingMailbox,
            onRecordingStateChange: { [weak runtime] active in
                Task { @MainActor [weak runtime] in
                    runtime?.setRecordingActive(active)
                }
            },
            onRecordingMessage: { [weak runtime] reason in
                Task { @MainActor [weak runtime] in
                    runtime?.setRecordingMessage(reason)
                }
            },
            screenshotMailbox: runtime.screenshotMailbox,
            onScreenshotMessage: { [weak runtime] message in
                Task { @MainActor [weak runtime] in
                    runtime?.setScreenshotMessage(message)
                }
            },
            onSigil: onSigil,
            onPreviewTap: onPreviewTap,
            onFocus: onFocus,
            onFailure: onFailure
        )
    }

    func makeUIView(context: Context) -> CameraMetalView {
        let view = CameraMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.backgroundColor = .black
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.autoResizeDrawable = true
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Metal camera preview. Tap to focus."
        view.accessibilityIdentifier = "camera.metal.preview"
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: CameraMetalView, context: Context) {
        view.sigilsEnabled = sigilsEnabled
        context.coordinator.renderer?.setBroadcastEngine(broadcast)
        context.coordinator.renderer?.update(
            rgbSplitParameters: rgbSplitParameters,
            effectStack: effectStack,
            isSynthetic: runtime.snapshot.isSynthetic,
            audioSnapshot: audioSnapshot,
            audioIntensity: audioIntensity,
            blobFields: blobFields,
            scanlineParameters: scanlineParameters,
            screenScale: Float(view.contentScaleFactor)
        )
        view.accessibilityLabel = runtime.snapshot.isSynthetic
            ? "Deterministic Metal simulator camera source"
            : "Metal camera preview. Tap to focus."
        view.preferredFramesPerSecond = min(max(runtime.snapshot.framesPerSecond, 30), 120)
        view.isPaused = runtime.snapshot.state != .running
    }

    static func dismantleUIView(_ view: CameraMetalView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
        view.onTap = nil
        view.onHoldChanged = nil
        view.onFracture = nil
        coordinator.fracture.reset()
        coordinator.statsMailbox.clear()
        coordinator.renderer?.setBroadcastEngine(nil)
        coordinator.renderer?.shutdown()
        coordinator.renderer = nil
    }

    @MainActor
    final class Coordinator {
        let mailbox: LatestCapturedFrameMailbox
        let fracture: SignalFractureController
        let statsMailbox: CameraRenderStatsMailbox
        let touchMailbox: CameraTouchMailbox
        let recordingMailbox: CameraRecordingMailbox
        let onRecordingStateChange: @Sendable (Bool) -> Void
        let onRecordingMessage: @Sendable (String) -> Void
        let screenshotMailbox: CameraScreenshotMailbox
        let onScreenshotMessage: @Sendable (String) -> Void
        let onSigil: @MainActor (String) -> Void
        let onPreviewTap: @MainActor @Sendable () -> Void
        let onFocus: @MainActor (CGPoint) -> Void
        let onFailure: @MainActor () -> Void
        fileprivate var renderer: CameraMetalRenderer?

        init(
            mailbox: LatestCapturedFrameMailbox,
            fracture: SignalFractureController,
            statsMailbox: CameraRenderStatsMailbox,
            recordingMailbox: CameraRecordingMailbox,
            onRecordingStateChange: @escaping @Sendable (Bool) -> Void,
            onRecordingMessage: @escaping @Sendable (String) -> Void,
            screenshotMailbox: CameraScreenshotMailbox,
            onScreenshotMessage: @escaping @Sendable (String) -> Void,
            onSigil: @escaping @MainActor (String) -> Void,
            onPreviewTap: @escaping @MainActor @Sendable () -> Void,
            onFocus: @escaping @MainActor (CGPoint) -> Void,
            onFailure: @escaping @MainActor () -> Void
        ) {
            self.mailbox = mailbox
            self.fracture = fracture
            self.statsMailbox = statsMailbox
            touchMailbox = CameraTouchMailbox()
            self.recordingMailbox = recordingMailbox
            self.onRecordingStateChange = onRecordingStateChange
            self.onRecordingMessage = onRecordingMessage
            self.screenshotMailbox = screenshotMailbox
            self.onScreenshotMessage = onScreenshotMessage
            self.onSigil = onSigil
            self.onPreviewTap = onPreviewTap
            self.onFocus = onFocus
            self.onFailure = onFailure
        }

        func attach(to view: CameraMetalView) {
            guard let device = view.device,
                  let renderer = CameraMetalRenderer(
                      device: device,
                      colorPixelFormat: view.colorPixelFormat,
                      mailbox: mailbox,
                      fractureMailbox: fracture.mailbox,
                      statsMailbox: statsMailbox,
                      touchMailbox: touchMailbox,
                      recordingMailbox: recordingMailbox,
                      onRecordingStateChange: onRecordingStateChange,
                      onRecordingMessage: onRecordingMessage,
                      screenshotMailbox: screenshotMailbox,
                      onScreenshotMessage: onScreenshotMessage
                  )
            else {
                GVLog.rendering.error("Camera Metal renderer initialization failed")
                Task { @MainActor [onFailure] in
                    await Task.yield()
                    onFailure()
                }
                return
            }

            self.renderer = renderer
            view.delegate = renderer
            view.onTap = { [weak self, weak renderer, touchMailbox] point, size in
                guard let self,
                      let devicePoint = renderer?.captureDevicePoint(
                          for: point,
                          viewportSize: size
                      )
                else {
                    return
                }
                // A tap is also an impact: water-style effects ring outward
                // from the touched point even without a drag.
                if size.width > 0, size.height > 0 {
                    let normalized = SIMD2<Float>(
                        Float(min(max(point.x / size.width, 0), 1)),
                        Float(min(max(point.y / size.height, 0), 1))
                    )
                    touchMailbox.began(position: normalized, velocity: .zero)
                    touchMailbox.ended()
                }
                onPreviewTap()
                onFocus(devicePoint)
            }
            view.onHoldChanged = { [weak renderer] isHolding in
                renderer?.setTemporalHoldActive(isHolding)
            }
            view.onFracture = { [fracture] event in
                switch event {
                case let .began(pointA, pointB):
                    fracture.began(a: pointA, b: pointB)
                case let .moved(pointA, pointB):
                    fracture.moved(a: pointA, b: pointB)
                case .ended:
                    fracture.ended()
                case .cancelled:
                    fracture.cancelled()
                }
            }
            view.onSigil = { [onSigil] kind in
                Task { @MainActor in
                    onSigil(kind)
                }
            }
            view.onTouchChanged = { [touchMailbox] event in
                switch event {
                case let .began(position, velocity):
                    touchMailbox.began(position: position, velocity: velocity)
                case let .moved(position, velocity):
                    touchMailbox.moved(position: position, velocity: velocity)
                case .ended:
                    touchMailbox.ended()
                }
            }
        }
    }
}

/// Events emitted by the two-finger membrane gesture.
enum CameraFractureEvent {
    case began(CGPoint, CGPoint)
    case moved(CGPoint, CGPoint)
    case ended
    case cancelled
}

@MainActor
final class CameraMetalView: MTKView {
    var onTap: ((CGPoint, CGSize) -> Void)?
    var onHoldChanged: ((Bool) -> Void)?
    var onFracture: ((CameraFractureEvent) -> Void)?
    var onTouchChanged: ((CameraTouchEvent) -> Void)?
    /// Fired when a drawn sigil is recognised; carries the sigil kind.
    var onSigil: ((String) -> Void)?
    /// Operator preference from the settings deck. When off, strokes are still
    /// tracked for touch-reactive effects but never classified.
    var sigilsEnabled = false
    private var isHolding = false
    private var sigilStroke: [SIMD2<Float>] = []

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.minimumPressDuration = 0.12
        hold.allowableMovement = 96
        hold.cancelsTouchesInView = false
        addGestureRecognizer(hold)
        let fracture = SignalFractureGestureRecognizer(
            target: self,
            action: #selector(handleFracture(_:))
        )
        fracture.cancelsTouchesInView = false
        addGestureRecognizer(fracture)
        let touch = UIPanGestureRecognizer(target: self, action: #selector(handleTouchPan(_:)))
        touch.minimumNumberOfTouches = 1
        touch.maximumNumberOfTouches = 1
        touch.cancelsTouchesInView = false
        addGestureRecognizer(touch)
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("CameraMetalView does not support Interface Builder")
    }

    @objc
    private func handleTap(_ recognizer: UITapGestureRecognizer) {
        onTap?(recognizer.location(in: self), bounds.size)
    }

    @objc
    private func handleHold(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            guard !isHolding else { return }
            isHolding = true
            onHoldChanged?(true)
        case .ended, .cancelled, .failed:
            guard isHolding else { return }
            isHolding = false
            onHoldChanged?(false)
        default:
            break
        }
    }

    @objc
    private func handleFracture(_ recognizer: SignalFractureGestureRecognizer) {
        switch recognizer.state {
        case .began:
            // A second finger supersedes any in-flight press-and-hold.
            if isHolding {
                isHolding = false
                onHoldChanged?(false)
            }
            onFracture?(.began(recognizer.normalizedA, recognizer.normalizedB))
        case .changed:
            onFracture?(.moved(recognizer.normalizedA, recognizer.normalizedB))
        case .ended:
            onFracture?(.ended)
        case .cancelled, .failed:
            onFracture?(.cancelled)
        default:
            break
        }
    }

    @objc
    private func handleTouchPan(_ recognizer: UIPanGestureRecognizer) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let location = recognizer.location(in: self)
        let normalized = SIMD2<Float>(
            Float(min(max(location.x / bounds.width, 0), 1)),
            Float(min(max(location.y / bounds.height, 0), 1))
        )
        let velocity = recognizer.velocity(in: self)
        let normalizedVelocity = SIMD2<Float>(
            Float(velocity.x / bounds.width),
            Float(velocity.y / bounds.height)
        )
        // Sigil strokes are only recorded while a press-and-hold is active.
        // A plain tap or drag must stay a focus/touch interaction — otherwise
        // ordinary use keeps tripping the hidden sequence.
        switch recognizer.state {
        case .began:
            sigilStroke = isHolding ? [normalized] : []
            onTouchChanged?(.began(normalized, normalizedVelocity))
        case .changed:
            if isHolding {
                sigilStroke.append(normalized)
            } else {
                // Hold was never established, or was released mid-drag: discard
                // the partial stroke rather than classifying half of one.
                sigilStroke.removeAll(keepingCapacity: true)
            }
            onTouchChanged?(.moved(normalized, normalizedVelocity))
        case .ended, .cancelled, .failed:
            if isHolding, sigilsEnabled, let kind = SigilStrokeClassifier.classify(sigilStroke) {
                onSigil?(kind)
            }
            sigilStroke = []
            onTouchChanged?(.ended)
        default:
            break
        }
    }
}

private struct CameraConversionUniforms {
    var source: SIMD4<UInt32>
    var tuning: SIMD4<Float>
}

private struct CameraPreviewUniforms {
    var viewport: SIMD4<Float>
    var scanlines: SIMD4<Float>
    var scanlineFlags: SIMD4<Float>
}

private struct CameraFractureUniforms {
    var anchors: SIMD4<Float>
    var geometry: SIMD4<Float>
    var timing: SIMD4<Float>
    var viewport: SIMD4<Float>
    var options: SIMD4<UInt32>
}

private extension [(WorkspaceAdjustableEffect, CameraEffectParameters)] {
    /// Returns the stack with the `count` most expensive effects removed,
    /// keeping the render order of everything that remains.
    ///
    /// Most expensive, not cheapest. This only runs once the frame budget is
    /// already blown, and shedding the cheap nodes recovers almost nothing
    /// while still visibly changing the picture — the operator pays the whole
    /// cost of the drop and gets none of the milliseconds back.
    ///
    /// Ties break toward the later slot so the effect placed first survives,
    /// and at least one effect always remains: a stack that empties itself
    /// under load reads as a crash, not as degradation.
    func droppingMostExpensive(count: Int) -> [Element] {
        let limit = Swift.min(count, self.count - 1)
        guard limit > 0 else { return self }
        let shed = Set(
            enumerated()
                .sorted {
                    $0.element.0.estimatedCost == $1.element.0.estimatedCost
                        ? $0.offset > $1.offset
                        : $0.element.0.estimatedCost > $1.element.0.estimatedCost
                }
                .prefix(limit)
                .map(\.offset)
        )
        return enumerated()
            .filter { !shed.contains($0.offset) }
            .map(\.element)
    }
}

private struct CameraRenderSettings {
    let rgbSplit: RGBSplitEffectParameters
    let effectStack: CameraEffectStackParameters
    let isSynthetic: Bool
    let temporalHoldActive: Bool
    let audio: SIMD4<Float>
    let blobs: [SIMD4<Float>]
    let scanlines: ScanlineEffectParameters
}

private struct CameraSourceGeometry {
    var width = 1
    var height = 1
    var orientation = CapturedFrameOrientation.portrait
    var isMirrored = false
}

private final class CameraFrameTextureLease: @unchecked Sendable {
    let frame: CapturedFrame
    let luma: MTLTexture
    let chroma: MTLTexture
    let leases: [CVMetalTexture]

    init(
        frame: CapturedFrame,
        luma: MTLTexture,
        chroma: MTLTexture,
        leases: [CVMetalTexture]
    ) {
        self.frame = frame
        self.luma = luma
        self.chroma = chroma
        self.leases = leases
    }
}

// swiftlint:disable:next type_body_length
/// How large the effect chain runs.
///
/// Split out of the renderer, which is file-private, so the decision can be
/// asserted in a test rather than eyeballed on a device that is not in the room.
enum CameraChainResolution {
    static func resolve(
        sourceWidth: Int,
        sourceHeight: Int,
        drawablePixels: Double,
        fullResolution: Bool
    ) -> (width: Int, height: Int) {
        let sourcePixels = Double(sourceWidth * sourceHeight)
        guard !fullResolution, drawablePixels > 0, sourcePixels > drawablePixels else {
            return (sourceWidth, sourceHeight)
        }

        // 1.25x, because aspect-fill crops: the covering scale needs more
        // texels than the drawable's bare area implies.
        let scale = min(1, (drawablePixels * 1.25 / sourcePixels).squareRoot())
        // Even dimensions. Chroma is subsampled and the recorder's encoder
        // rejects odd sizes; keeping the rule everywhere avoids a class of
        // one-pixel bug that only appears at one resolution.
        let width = max(Int((Double(sourceWidth) * scale).rounded()) & ~1, 16)
        let height = max(Int((Double(sourceHeight) * scale).rounded()) & ~1, 16)
        return (width, height)
    }
}

private final class CameraMetalRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private let mailbox: LatestCapturedFrameMailbox
    private let fractureMailbox: SignalFractureMailbox
    private let statsMailbox: CameraRenderStatsMailbox
    private let touchMailbox: CameraTouchMailbox
    private let recordingMailbox: CameraRecordingMailbox
    private let onRecordingStateChange: @Sendable (Bool) -> Void
    private let onRecordingMessage: @Sendable (String) -> Void
    private let screenshotMailbox: CameraScreenshotMailbox
    private let onScreenshotMessage: @Sendable (String) -> Void
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let yuvPipeline: MTLComputePipelineState
    private let syntheticPipeline: MTLComputePipelineState
    private let rgbSplitPipeline: MTLComputePipelineState
    private let styleEffectPipeline: MTLComputePipelineState
    private let temporalEffectPipeline: MTLComputePipelineState
    private let historyTapPipeline: MTLComputePipelineState
    private let compositeWatermarkPipeline: MTLComputePipelineState
    private let flowLumaPipeline: MTLComputePipelineState
    private let flowEstimatePipeline: MTLComputePipelineState
    private let flowAccumulatePipeline: MTLComputePipelineState
    /// Optional: a device that cannot build it loses adaptive chrome, not the
    /// camera. Everything else in this init is a hard requirement.
    private let bandLumaPipeline: MTLComputePipelineState?
    /// Three buffers, cycled. The completion handler for frame N runs while the
    /// GPU is already executing N+1, so a single buffer would be cleared out
    /// from under the read.
    private let bandLumaBuffers: [MTLBuffer]
    /// Shared optical flow. One estimator feeds every motion-aware effect.
    private let flowField: CameraFlowField
    /// Device attitude, for world-anchored accumulation.
    private let worldPoseMailbox = CameraWorldPoseMailbox()
    private lazy var worldAnchor = CameraWorldAnchor(mailbox: worldPoseMailbox)
    private var worldReprojection = CameraWorldReprojection()
    /// Timestamped history, addressed in seconds. Runs alongside the fixed
    /// four-tap ring rather than replacing it, so the damage effects built on
    /// taps keep working while new effects move to age-based sampling.
    private let temporalEngine: CameraTemporalEngine
    private var isWorldAnchorRunning = false
    private let fracturePipeline: MTLComputePipelineState
    private let previewPipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private let temporalFrames: TemporalFrameBuffer
    private var temporalPrimed = false
    private let settingsLock = NSLock()
    private let geometryLock = NSLock()
    private let statsLock = NSLock()

    private var gpuMillisecondsAverage: Double = 0
    private var renderedFrameNumber: UInt64 = 0
    private var historyTapSnapshot = 0
    /// How many style effects the governor actually shed this frame. Written
    /// on the render thread, read by the completion handler, so it lives under
    /// `statsLock` with the rest of the published figures.
    private var shedEffectSnapshot = 0
    private var bandLumaFrame = 0
    /// Frames left before the chain may drop back to preview resolution.
    ///
    /// A hold rather than a single frame: resizing the working textures throws
    /// away the temporal history with them, so thrashing between scales would
    /// reset feedback and trails repeatedly. One transition in, one out.
    private var fullResolutionHold = 0
    private var topChromeLoadAverage: Double = 0
    private var deckChromeLoadAverage: Double = 0
    private var bottomChromeLoadAverage: Double = 0
    private var historyMegabyteSnapshot: Double = 0

    private var rgbSplitParameters = RGBSplitEffectParameters()
    private var effectStack = CameraEffectStackParameters()
    private var isSynthetic = false
    private var temporalHoldActive = false
    private var audio = SIMD4<Float>.zero
    private var audioDynamics = SIMD4<Float>.zero
    private var audioSpectrum: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
    private var blobFields: [SIMD4<Float>] = []
    private var scanlineParameters = ScanlineEffectParameters()
    private var screenScale: Float = 3
    private var syntheticTarget: MTLTexture?
    private var temporalLumaTarget: MTLTexture?
    
    /// Live link to the Mac virtual camera. Nil unless the operator armed it.
    private var broadcastEngine: GVBroadcastEngine?
    private let broadcastPool = GVBroadcastFramePool()
    private var recordingSession: GVRealtimeRecordingSession?
    private var recordingStartTime: TimeInterval?
    private var hasFailedSession = false
    private var overBudgetStreak = 0
    private var underBudgetStreak = 0
    private var effectBudgetDrops = 0
    private var sourceGeometry = CameraSourceGeometry()
    private var linearTexture: MTLTexture?
    private var effectTextureA: MTLTexture?
    private var effectTextureB: MTLTexture?
    private var historyTexture: MTLTexture?
    private var hasLinearFrame = false
    private var hasHistoryFrame = false
    /// Built lazily the first time the fluid effect runs; released when it is
    /// switched off so an unused solver holds no grid memory.
    private var fluidSolver: CameraFluidSolver?
    private var lastFluidTime: Double = 0
    private let shaderLibrary: MTLLibrary?

    init?(
        device: MTLDevice,
        colorPixelFormat: MTLPixelFormat,
        mailbox: LatestCapturedFrameMailbox,
        fractureMailbox: SignalFractureMailbox,
        statsMailbox: CameraRenderStatsMailbox,
        touchMailbox: CameraTouchMailbox,
        recordingMailbox: CameraRecordingMailbox,
        onRecordingStateChange: @escaping @Sendable (Bool) -> Void,
        onRecordingMessage: @escaping @Sendable (String) -> Void,
        screenshotMailbox: CameraScreenshotMailbox,
        onScreenshotMessage: @escaping @Sendable (String) -> Void
    ) {
        guard let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let yuvFunction = library.makeFunction(name: CameraMetalShaderNames.yuvToLinear),
              let syntheticFunction = library.makeFunction(name: CameraMetalShaderNames.syntheticLinear),
              let rgbSplitFunction = library.makeFunction(name: CameraMetalShaderNames.rgbSplit),
              let styleEffectFunction = library.makeFunction(name: CameraMetalShaderNames.styleEffect),
              let temporalEffectFunction = library.makeFunction(name: CameraMetalShaderNames.temporalEffect),
              let historyTapFunction = library.makeFunction(name: CameraMetalShaderNames.historyTap),
              let compositeWatermarkFunction = library.makeFunction(name: CameraMetalShaderNames.compositeWatermark),
              let flowLumaFunction = library.makeFunction(name: CameraMetalShaderNames.flowLuma),
              let flowEstimateFunction = library.makeFunction(name: CameraMetalShaderNames.flowEstimate),
              let flowAccumulateFunction = library.makeFunction(name: CameraMetalShaderNames.flowAccumulate),
              let fractureFunction = library.makeFunction(name: CameraMetalShaderNames.signalFracture),
              let previewVertex = library.makeFunction(name: CameraMetalShaderNames.previewVertex),
              let previewFragment = library.makeFunction(name: CameraMetalShaderNames.previewFragment),
              let yuvPipeline = try? device.makeComputePipelineState(function: yuvFunction),
              let syntheticPipeline = try? device.makeComputePipelineState(function: syntheticFunction),
              let rgbSplitPipeline = try? device.makeComputePipelineState(function: rgbSplitFunction),
              let styleEffectPipeline = try? device.makeComputePipelineState(function: styleEffectFunction),
              let temporalEffectPipeline = try? device.makeComputePipelineState(function: temporalEffectFunction),
              let historyTapPipeline = try? device.makeComputePipelineState(function: historyTapFunction),
              let compositeWatermarkPipeline = try? device.makeComputePipelineState(function: compositeWatermarkFunction),
              let flowLumaPipeline = try? device.makeComputePipelineState(function: flowLumaFunction),
              let flowEstimatePipeline = try? device.makeComputePipelineState(function: flowEstimateFunction),
              let flowAccumulatePipeline = try? device.makeComputePipelineState(function: flowAccumulateFunction),
              let fracturePipeline = try? device.makeComputePipelineState(function: fractureFunction)
        else {
            return nil
        }

        let previewDescriptor = MTLRenderPipelineDescriptor()
        previewDescriptor.label = "greyVISION Camera Preview"
        previewDescriptor.vertexFunction = previewVertex
        previewDescriptor.fragmentFunction = previewFragment
        previewDescriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        guard let previewPipeline = try? device.makeRenderPipelineState(descriptor: previewDescriptor) else {
            return nil
        }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache
        else {
            return nil
        }

        self.mailbox = mailbox
        self.fractureMailbox = fractureMailbox
        self.statsMailbox = statsMailbox
        self.touchMailbox = touchMailbox
        self.recordingMailbox = recordingMailbox
        self.onRecordingStateChange = onRecordingStateChange
        self.onRecordingMessage = onRecordingMessage
        self.screenshotMailbox = screenshotMailbox
        self.onScreenshotMessage = onScreenshotMessage
        self.device = device
        shaderLibrary = library
        self.commandQueue = commandQueue
        self.yuvPipeline = yuvPipeline
        self.syntheticPipeline = syntheticPipeline
        self.rgbSplitPipeline = rgbSplitPipeline
        self.styleEffectPipeline = styleEffectPipeline
        self.temporalEffectPipeline = temporalEffectPipeline
        self.historyTapPipeline = historyTapPipeline
        self.compositeWatermarkPipeline = compositeWatermarkPipeline
        self.flowLumaPipeline = flowLumaPipeline
        self.flowEstimatePipeline = flowEstimatePipeline
        self.flowAccumulatePipeline = flowAccumulatePipeline
        bandLumaPipeline = library.makeFunction(name: CameraMetalShaderNames.bandLuma)
            .flatMap { try? device.makeComputePipelineState(function: $0) }
        // Three bands of four uints: sum, count, bright count, pad.
        bandLumaBuffers = (0 ..< 3).compactMap { _ in
            device.makeBuffer(length: MemoryLayout<UInt32>.stride * 12, options: .storageModeShared)
        }
        flowField = CameraFlowField(device: device)
        self.fracturePipeline = fracturePipeline
        self.previewPipeline = previewPipeline
        textureCache = cache
        temporalFrames = TemporalFrameBuffer(device: device, divisor: 3)
        temporalEngine = CameraTemporalEngine(device: device)
        super.init()
        commandQueue.label = "greyVISION Camera Command Queue"
        GVLog.rendering.notice("Camera Metal renderer initialized")
    }

    // swiftlint:disable:next function_parameter_count
    func update(
        rgbSplitParameters: RGBSplitEffectParameters,
        effectStack: CameraEffectStackParameters,
        isSynthetic: Bool,
        audioSnapshot: AudioReactiveSnapshot,
        audioIntensity: Float,
        blobFields: [SIMD4<Float>],
        scanlineParameters: ScanlineEffectParameters,
        screenScale: Float
    ) {
        settingsLock.withLock {
            self.rgbSplitParameters = rgbSplitParameters.sanitized
            self.effectStack = effectStack
            self.isSynthetic = isSynthetic
            let audioGain = min(max(audioIntensity, 0), 1)
            audio = audioSnapshot.metalBands * audioGain
            audioDynamics = audioSnapshot.metalDynamics * audioGain
            let bands = audioSnapshot.metalSpectrum
            audioSpectrum = (
                bands.0 * audioGain,
                bands.1 * audioGain,
                bands.2 * audioGain,
                bands.3 * audioGain
            )
            self.blobFields = blobFields
            self.scanlineParameters = scanlineParameters
            self.screenScale = screenScale
        }
    }

    func setTemporalHoldActive(_ isActive: Bool) {
        settingsLock.withLock {
            temporalHoldActive = isActive
        }
    }

    /// Attaches or detaches the Mac link.
    ///
    /// Not part of `update(...)` because it changes once when the operator
    /// arms the link, not sixty times a second with the rest of the settings.
    func setBroadcastEngine(_ engine: GVBroadcastEngine?) {
        settingsLock.withLock {
            broadcastEngine = engine
            if engine == nil {
                broadcastPool.flush()
            }
        }
    }

    func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func draw(in view: MTKView) {
        guard view.drawableSize.width > 0,
              view.drawableSize.height > 0,
              let drawable = view.currentDrawable,
              let renderPass = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }

        let settings = settingsLock.withLock {
            CameraRenderSettings(
                rgbSplit: rgbSplitParameters,
                effectStack: effectStack,
                isSynthetic: isSynthetic,
                temporalHoldActive: temporalHoldActive,
                audio: audio,
                blobs: blobFields,
                scanlines: scanlineParameters
            )
        }
        let touchState = touchMailbox.latest
        let touchVector = SIMD4<Float>(
            touchState.position.x,
            touchState.position.y,
            min(length(touchState.velocity) * 0.75, 2),
            touchState.isActive ? 1 : 0
        )
        let touchImpactVector: SIMD4<Float>
        if let impactPosition = touchState.impactPosition, let impactTime = touchState.impactTime {
            let age = Float(max(CACurrentMediaTime() - impactTime, 0))
            touchImpactVector = SIMD4<Float>(impactPosition.x, impactPosition.y, age, 1)
        } else {
            touchImpactVector = SIMD4<Float>(0.5, 0.5, 100, 0)
        }
        var frameLease: CameraFrameTextureLease?

        if settings.isSynthetic {
            let size = syntheticTextureSize(for: view.drawableSize)
            guard ensureWorkingTextures(width: size.width, height: size.height),
                  let linearTexture
            else {
                return
            }
            encodeSyntheticFrame(
                into: linearTexture,
                commandBuffer: commandBuffer,
                time: Float(ProcessInfo.processInfo.systemUptime)
            )
            geometryLock.withLock {
                sourceGeometry = CameraSourceGeometry(
                    width: size.width,
                    height: size.height,
                    orientation: .portrait,
                    isMirrored: false
                )
            }
            hasLinearFrame = true
        } else if let frame = mailbox.consumeLatest() {
            guard let textures = makeTextures(frame: frame) else { return }
            frameLease = textures
            let working = workingTextureSize(
                sourceWidth: textures.luma.width,
                sourceHeight: textures.luma.height,
                drawableSize: view.drawableSize
            )
            guard ensureWorkingTextures(width: working.width, height: working.height),
                  let linearTexture
            else {
                return
            }
            encodeYUVFrame(
                textures,
                into: linearTexture,
                commandBuffer: commandBuffer
            )
            geometryLock.withLock {
                sourceGeometry = CameraSourceGeometry(
                    width: textures.luma.width,
                    height: textures.luma.height,
                    orientation: frame.orientation,
                    isMirrored: frame.isMirrored
                )
            }
            hasLinearFrame = true
        }

        guard hasLinearFrame, let linearTexture else { return }
        var presentedTexture = linearTexture
        var writeToFirstTexture = true
        if settings.rgbSplit.isEnabled, let effectTextureA {
            encodeRGBSplit(
                settings.rgbSplit,
                source: linearTexture,
                destination: effectTextureA,
                commandBuffer: commandBuffer
            )
            presentedTexture = effectTextureA
            writeToFirstTexture = false
        }

        let effectTime = Float(ProcessInfo.processInfo.systemUptime)
        let activeEffects = settings.effectStack.activeEffects
        let survivingEffects = activeEffects.droppingMostExpensive(count: adaptiveEffectDropCount())
        // Published so the HUD can say the stack is being shed. Measured from
        // what actually survived rather than from the governor's counter — the
        // counter can ask for three drops on a two-effect stack.
        statsLock.withLock { shedEffectSnapshot = activeEffects.count - survivingEffects.count }
        for (effect, parameters) in survivingEffects {
            guard let destination = writeToFirstTexture ? effectTextureA : effectTextureB else {
                break
            }
            encodeStyleEffect(
                effect,
                parameters: parameters,
                source: presentedTexture,
                destination: destination,
                commandBuffer: commandBuffer,
                time: effectTime,
                audio: settings.audio,
                touch: touchVector,
                touchImpact: touchImpactVector,
                blobs: settings.blobs
            )
            presentedTexture = destination
            writeToFirstTexture.toggle()
        }

        // Fluid runs as its own multi-pass stage rather than as a style mode:
        // it owns persistent velocity/dye/pressure grids that the single-pass
        // style kernel has nowhere to keep.
        let fluidParameters = settings.effectStack[.fluid]
        if fluidParameters.isEnabled {
            if fluidSolver == nil, let library = shaderLibrary {
                fluidSolver = CameraFluidSolver(device: device, library: library)
            }
            if let fluidSolver, let destination = writeToFirstTexture ? effectTextureA : effectTextureB {
                let now = ProcessInfo.processInfo.systemUptime
                // Clamped: a hitch or a backgrounded frame must not advect the
                // field by a huge step and blow the simulation apart.
                let delta = lastFluidTime > 0
                    ? Float(min(max(now - lastFluidTime, 1.0 / 120.0), 1.0 / 20.0))
                    : Float(1.0 / 60.0)
                lastFluidTime = now

                let didRun = fluidSolver.encode(
                    commandBuffer: commandBuffer,
                    source: presentedTexture,
                    destination: destination,
                    touch: touchVector,
                    parameters: CameraFluidParameters(
                        drag: fluidParameters.primary,
                        persistence: fluidParameters.secondary,
                        swirl: fluidParameters.tertiary
                    ),
                    blend: Float(fluidParameters.blend),
                    deltaTime: delta
                )
                if didRun {
                    presentedTexture = destination
                    writeToFirstTexture.toggle()
                }
            }
        } else if fluidSolver != nil {
            fluidSolver?.reset()
            fluidSolver = nil
            lastFluidTime = 0
        }

        // The shared frame ring is prepared before the temporal pass, not
        // after it, so temporal effects can sample genuinely older frames.
        // Ageing still happens at the end of the frame, which preserves the
        // existing guarantee that a tap can never contain this frame's own
        // output. One ring serves the damage effects and the fracture path;
        // there is deliberately no second history system.
        // Optical flow is estimated before the effect chain, from the clean
        // source, so motion is measured on the camera image rather than on
        // whatever the previous effect did to it. Feeding a corrupted frame
        // back into the estimator would make the field chase its own output.
        let flowReady = flowField.prepare(
            sourceWidth: presentedTexture.width,
            sourceHeight: presentedTexture.height
        )
        if flowReady {
            encodeFlow(
                source: presentedTexture,
                settings: settings,
                commandBuffer: commandBuffer
            )
        }

        // Timestamped ring. Recorded from the clean source before effects so
        // history holds the camera image, not the previous frame's corruption
        // fed back into itself.
        let temporalReady = temporalEngine.prepare(
            sourceWidth: presentedTexture.width,
            sourceHeight: presentedTexture.height
        )
        if temporalReady, temporalEngine.shouldRecord() {
            encodeTemporalRecord(source: presentedTexture, commandBuffer: commandBuffer)
        }

        let ringReady = temporalFrames.prepare(
            sourceWidth: presentedTexture.width,
            sourceHeight: presentedTexture.height
        )
        let historyTaps = ringReady ? temporalFrames.textures : []
        let temporalEffects = settings.effectStack.activeTemporalEffects
        // The attitude sensor only runs while a world-anchored mode is armed.
        // Leaving it on for every session would burn power for an effect that
        // is not being used.
        let needsWorld = temporalEffects.contains { $0.0.requiresWorldAnchor }
        if needsWorld, !isWorldAnchorRunning {
            worldAnchor.start()
            isWorldAnchorRunning = true
        } else if !needsWorld, isWorldAnchorRunning {
            worldAnchor.stop()
            worldReprojection.reset()
            isWorldAnchorRunning = false
        }
        let worldMatrix = needsWorld
            ? worldReprojection.update(
                pose: worldPoseMailbox.latest,
                aspect: Float(presentedTexture.width) / Float(max(presentedTexture.height, 1))
            )
            : matrix_identity_float3x3
        let shouldFreezeTemporalHistory = settings.temporalHoldActive &&
            temporalEffects.contains(where: \.0.freezesHistoryOnHold)
        if !temporalEffects.isEmpty, hasHistoryFrame, let historyTexture {
            for (effect, parameters) in temporalEffects {
                guard let destination = writeToFirstTexture ? effectTextureA : effectTextureB else {
                    break
                }
                encodeTemporalEffect(
                    effect,
                    parameters: parameters,
                    source: presentedTexture,
                    history: historyTexture,
                    historyTaps: historyTaps,
                    flow: flowField.persistent,
                    worldMatrix: worldMatrix,
                    ring: temporalReady ? temporalEngine : nil,
                    destination: destination,
                    commandBuffer: commandBuffer,
                    time: effectTime,
                    holdActive: shouldFreezeTemporalHistory && effect.freezesHistoryOnHold,
                    audio: settings.audio,
                    touch: touchVector,
                    touchImpact: touchImpactVector,
                    blobs: settings.blobs
                )
                presentedTexture = destination
                writeToFirstTexture.toggle()
            }
        }

        let shouldWriteHistory = !hasHistoryFrame ||
            (!shouldFreezeTemporalHistory && !temporalEffects.contains(where: { $0.0 == .freeze }))
        if temporalEffects.isEmpty {
            hasHistoryFrame = false
        } else if let historyTexture, shouldWriteHistory {
            encodeHistoryCopy(
                source: presentedTexture,
                destination: historyTexture,
                commandBuffer: commandBuffer
            )
            hasHistoryFrame = true
        }

        // SIGNAL FRACTURE. The ring is read first and aged afterwards, so the
        // exposed layers are genuinely older frames and the tear can never feed
        // on its own output.
        let historySource = presentedTexture
        let hasHistory = ringReady
        publishHistoryFootprint()
        let fractureState = resolvedFractureState()
        let fractureDestination = writeToFirstTexture ? effectTextureA : effectTextureB
        if hasHistory, fractureState.phase.isEngaged, let destination = fractureDestination {
            encodeSignalFracture(
                fractureState,
                source: presentedTexture,
                destination: destination,
                drawableSize: view.drawableSize,
                commandBuffer: commandBuffer
            )
            presentedTexture = destination
            writeToFirstTexture.toggle()
        }
        if hasHistory {
            encodeHistoryTaps(source: historySource, commandBuffer: commandBuffer)
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else {
            return
        }
        let scanlineValues = scanlineUniformValues(settings: settings, time: effectTime)
        var previewUniforms = CameraPreviewUniforms(
            viewport: SIMD4<Float>(
                Float(view.drawableSize.width),
                Float(view.drawableSize.height),
                Float(presentedTexture.width),
                Float(presentedTexture.height)
            ),
            scanlines: scanlineValues.0,
            scanlineFlags: scanlineValues.1
        )
        encoder.label = "greyVISION Camera Preview"
        encoder.setRenderPipelineState(previewPipeline)
        encoder.setFragmentTexture(presentedTexture, index: 0)
        encoder.setFragmentBytes(
            &previewUniforms,
            length: MemoryLayout<CameraPreviewUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        // Camera recording: the effect stack output is blitted into the
        // writer's pixel-buffer pool, then appended once the GPU finishes.
        // Pay the history-ring allocation on frame ONE, not mid-take when the
        // first temporal effect arms.
        if !temporalPrimed {
            temporalPrimed = true
            _ = temporalFrames.prepare(sourceWidth: presentedTexture.width,
                                       sourceHeight: presentedTexture.height)
        }

        let (shouldStart, codecRawValue, fps) = recordingMailbox.consumeStartRequest()
        if shouldStart, recordingSession == nil {
            startRecording(
                size: CGSize(
                    width: CGFloat(presentedTexture.width),
                    height: CGFloat(presentedTexture.height)
                ),
                codecRawValue: codecRawValue,
                fps: fps
            )
        }
        var screenshotLease: CameraScreenshotLease?
        if screenshotMailbox.consumeRequest() {
            if let lease = makeScreenshotLease(
                width: drawable.texture.width,
                height: drawable.texture.height
            ), let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.label = "greyVISION Screenshot Copy"
                blit.copy(
                    from: drawable.texture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: .init(x: 0, y: 0, z: 0),
                    sourceSize: .init(
                        width: drawable.texture.width,
                        height: drawable.texture.height,
                        depth: 1
                    ),
                    to: lease.texture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: .init(x: 0, y: 0, z: 0)
                )
                blit.endEncoding()
                screenshotLease = lease
            }
        }
        var recordLease: CameraRecordLease?
        let recordTimestamp = ProcessInfo.processInfo.systemUptime
        if let session = recordingSession, recordingMailbox.isActive() {
            if recordingStartTime == nil {
                recordingStartTime = recordTimestamp
            }
            if let lease = makeRecordLease(recording: session, texture: presentedTexture) {
                if let encoder = commandBuffer.makeComputeCommandEncoder() {
                    encoder.label = "greyVISION Record Copy"
                    encoder.setComputePipelineState(historyTapPipeline)
                    encoder.setTexture(presentedTexture, index: 0)
                    encoder.setTexture(lease.texture, index: 1)
                    dispatch(encoder, pipeline: historyTapPipeline, texture: lease.texture)
                    
                    encoder.endEncoding()
                }
                recordLease = lease
            }
        } else if recordingSession != nil {
            stopRecording()
        }

        // The link copies the same finished frame the recorder would, from the
        // same texture, through the same copy kernel. It gets its own buffer
        // because the two consumers read on different clocks — the recorder
        // when the writer is ready, the encoder immediately.
        var broadcastLease: CameraBroadcastLease?
        if let lease = makeBroadcastLease(texture: presentedTexture) {
            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.label = "greyVISION Broadcast Copy"
                encoder.setComputePipelineState(historyTapPipeline)
                encoder.setTexture(presentedTexture, index: 0)
                encoder.setTexture(lease.texture, index: 1)
                dispatch(encoder, pipeline: historyTapPipeline, texture: lease.texture)
                encoder.endEncoding()
                broadcastLease = lease
            }
        }

        let bandSlot = encodeBandLuma(source: presentedTexture, commandBuffer: commandBuffer)

        let retainedLease = frameLease
        let retainedRecordLease = recordLease
        let retainedBroadcastLease = broadcastLease
        let retainedScreenshotLease = screenshotLease
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] buffer in
            _ = retainedLease
            if let bandSlot {
                self?.readBandLuma(slot: bandSlot)
            }
            self?.recordCompletion(buffer)
            if let screenshot = retainedScreenshotLease {
                self?.finalizeScreenshot(screenshot)
            }
            // Submitted from the completion handler, not from the encode
            // above: the pixels do not exist until the GPU has finished with
            // them, and handing VideoToolbox a buffer the copy has not written
            // yet encodes the previous frame's contents.
            if let broadcast = retainedBroadcastLease {
                broadcast.engine.submit(broadcast.pixelBuffer, hostTime: recordTimestamp)
            }
            guard let pixelBuffer = retainedRecordLease?.pixelBuffer else { return }
            retainedRecordLease?.session.append(pixelBuffer, timestamp: recordTimestamp)
        }
        commandBuffer.commit()
    }

    /// Wraps a fresh CPU-visible pixel buffer for a screenshot. The lease must
    /// stay alive until the command completes.
    private struct CameraScreenshotLease: @unchecked Sendable {
        let cacheLease: CVMetalTexture
        let texture: MTLTexture
        let pixelBuffer: CVPixelBuffer
    }

    private func makeScreenshotLease(width: Int, height: Int) -> CameraScreenshotLease? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }
        var lease: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm_srgb,
            width,
            height,
            0,
            &lease
        )
        guard result == kCVReturnSuccess,
              let lease,
              let texture = CVMetalTextureGetTexture(lease)
        else {
            return nil
        }
        return CameraScreenshotLease(cacheLease: lease, texture: texture, pixelBuffer: pixelBuffer)
    }

    /// Runs in the command-buffer completion handler: pulls the captured frame
    /// off the GPU once, writes a PNG, and exports it to the photo library.
    private func finalizeScreenshot(_ lease: CameraScreenshotLease) {
        CVPixelBufferLockBaseAddress(lease.pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(lease.pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(lease.pixelBuffer) else {
            onScreenshotMessage("SCREENSHOT // READ FAILED")
            return
        }
        let width = CVPixelBufferGetWidth(lease.pixelBuffer)
        let height = CVPixelBufferGetHeight(lease.pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(lease.pixelBuffer)
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ), let image = context.makeImage(), let png = UIImage(cgImage: image).pngData() else {
            onScreenshotMessage("SCREENSHOT // ENCODE FAILED")
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("greyvision-shot-\(Int(Date().timeIntervalSince1970)).png")
        do {
            try png.write(to: url)
        } catch {
            onScreenshotMessage("SCREENSHOT // WRITE FAILED")
            return
        }
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
        } completionHandler: { [onScreenshotMessage] success, error in
            if success {
                onScreenshotMessage("SCREENSHOT // SAVED TO PHOTOS")
            } else {
                onScreenshotMessage("SCREENSHOT // SAVE FAILED")
                GVLog.recording.error("Screenshot save failed: \(error?.localizedDescription ?? "unknown")")
            }
        }
    }

    /// Keeps the recording pixel buffer's texture cache lease alive until the
    /// command buffer completes and the encoder has consumed the pixels; it is
    /// handed to the command-buffer completion handler, and only that handler
    /// reads the pixels afterwards.
    private struct CameraRecordLease: @unchecked Sendable {
        let session: GVRealtimeRecordingSession
        let cacheLease: CVMetalTexture
        let texture: MTLTexture
        let pixelBuffer: CVPixelBuffer
    }

    /// Same lease discipline as recording: the texture-cache lease and the
    /// pixel buffer must both outlive the command buffer that writes them.
    private struct CameraBroadcastLease: @unchecked Sendable {
        let engine: GVBroadcastEngine
        let cacheLease: CVMetalTexture
        let texture: MTLTexture
        let pixelBuffer: CVPixelBuffer
    }

    /// Prepares a pooled pixel buffer for the link, or nil when nothing is
    /// attached or the pool is exhausted because the encoder is behind.
    private func makeBroadcastLease(texture source: MTLTexture) -> CameraBroadcastLease? {
        guard let engine = settingsLock.withLock({ broadcastEngine }), engine.isConnected,
              let pixelBuffer = broadcastPool.buffer(width: source.width, height: source.height),
              let textures = makeRecordingTexture(pixelBuffer: pixelBuffer)
        else {
            return nil
        }
        return CameraBroadcastLease(
            engine: engine,
            cacheLease: textures.0,
            texture: textures.1,
            pixelBuffer: pixelBuffer
        )
    }

    /// Prepares a recording pool pixel buffer for the finished effect frame,
    /// or nil when recording is inactive, the size changed, or the encoder is
    /// backed up.
    private func makeRecordLease(
        recording: GVRealtimeRecordingSession,
        texture source: MTLTexture
    ) -> CameraRecordLease? {
        guard recording.size == CGSize(width: CGFloat(source.width), height: CGFloat(source.height)),
              let pixelBuffer = recording.nextPixelBuffer(),
              let textures = makeRecordingTexture(pixelBuffer: pixelBuffer)
        else {
            return nil
        }
        return CameraRecordLease(
            session: recording,
            cacheLease: textures.0,
            texture: textures.1,
            pixelBuffer: pixelBuffer
        )
    }

    private func makeRecordingTexture(
        pixelBuffer: CVPixelBuffer
    ) -> (CVMetalTexture, MTLTexture)? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var lease: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &lease
        )
        guard result == kCVReturnSuccess,
              let lease,
              let texture = CVMetalTextureGetTexture(lease)
        else {
            return nil
        }
        return (lease, texture)
    }

    private func startRecording(size: CGSize, codecRawValue: String, fps: Int) {
        guard size.width > 0, size.height > 0 else { return }
        
        let codec = AVVideoCodecType(rawValue: codecRawValue)
        let ext = codecRawValue.lowercased().contains("hevc") || codecRawValue.lowercased().contains("hvc1") ? "mov" : "mov" // All mov
        let timestamp = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("greyvision-camera-\(timestamp).\(ext)")
        let session = GVRealtimeRecordingSession(outputURL: url, size: size, saveToPhotos: true, codec: codec)
        guard session.start(withAudio: true) else {
            GVLog.recording.error("Camera recording writer setup failed")
            recordingMailbox.requestStop()
            onRecordingMessage("WRITER UNAVAILABLE")
            return
        }
        
        recordingStartTime = ProcessInfo.processInfo.systemUptime
        

        recordingSession = session
        recordingMailbox.activate(with: session)
        onRecordingStateChange(true)
        GVLog.recording.notice("Camera recording started: \(codecRawValue) \(Int(size.width))x\(Int(size.height))")
    }

    private func stopRecording() {
        guard let session = recordingSession else { return }
        recordingSession = nil
        recordingMailbox.requestStop()
        // Clear the control state now, not in the completion handler. The
        // writer's finish callback is the wrong place for it: if the export
        // fails, stalls, or Photos authorisation is refused, the callback may
        // arrive late or never, and the button stays latched on with no way to
        // stop. Recording has already ended by this line; saving is a separate
        // outcome and is reported separately.
        onRecordingStateChange(false)
        session.finish { [weak self] result in
            switch result {
            case .success:
                GVLog.recording.notice("Camera recording saved to Photos")
                self?.onRecordingMessage("RECORD // SAVED TO PHOTOS")
            case let .failure(error):
                GVLog.recording.error("Camera recording finalize failed: \(error.localizedDescription)")
                self?.onRecordingMessage(error.localizedDescription.uppercased())
            }
        }
    }

    /// Adaptive quality: how many of the cheapest stacked effects to skip this
    /// frame. Uses the same EMA of GPU time as `adaptiveTapCount`, with
    /// hysteresis so an effect never flickers in and out frame to frame: a
    /// drop is armed only after sustained over-budget frames and restored only
    /// after a longer stretch under budget.
    private func adaptiveEffectDropCount() -> Int {
        let average = statsLock.withLock { gpuMillisecondsAverage }
        if average > 16.6 {
            overBudgetStreak += 1
            underBudgetStreak = 0
            if overBudgetStreak >= 6, effectBudgetDrops < 3 {
                effectBudgetDrops += 1
                overBudgetStreak = 0
                GVLog.rendering.notice("Adaptive quality: dropping \(self.effectBudgetDrops) stacked effect(s)")
            }
        } else if average < 12.0 {
            underBudgetStreak += 1
            overBudgetStreak = 0
            if underBudgetStreak >= 30, effectBudgetDrops > 0 {
                effectBudgetDrops -= 1
                underBudgetStreak = 0
                GVLog.rendering.notice("Adaptive quality: restoring \(self.effectBudgetDrops + 1) stacked effect(s)")
            }
        }
        return effectBudgetDrops
    }

    /// Packs the scanline overlay into preview uniforms in drawable pixel
    /// space, mirroring the SwiftUI canvas coordinates it replaces. Phase and
    /// spacing are folded by the screen scale so the lines sit exactly where
    /// the canvas drew them.
    private func scanlineUniformValues(
        settings: CameraRenderSettings,
        time: Float
    ) -> (SIMD4<Float>, SIMD4<Float>) {
        guard settings.scanlines.isEnabled, settings.scanlines.intensity > 0.001 else {
            return (.zero, .zero)
        }
        let scale = screenScale
        let spacing = max(2.2, 100.0 / max(Float(settings.scanlines.frequency), 1.0)) * scale
        let phase = (time * Float(settings.scanlines.speed) * 34.0 * scale)
            .truncatingRemainder(dividingBy: spacing)
        let direction: Float = switch settings.scanlines.direction {
        case .horizontal: 0
        case .vertical: 1
        case .diagonal: 2
        }
        return (
            SIMD4<Float>(
                spacing,
                phase,
                max(0.5, 0.5 * scale),
                Float(settings.scanlines.intensity)
            ),
            SIMD4<Float>(direction, 0, 0, 0)
        )
    }

    /// Adaptive quality: the number of temporal taps sampled inside the tear
    /// falls back as GPU time rises, rather than dropping the whole effect.
    private var adaptiveTapCount: Int {
        let average = statsLock.withLock { gpuMillisecondsAverage }
        return switch average {
        case ..<9.0: TemporalFrameBuffer.strides.count
        case ..<12.5: 3
        default: 2
        }
    }

    private func recordCompletion(_ buffer: MTLCommandBuffer) {
        let elapsed = max(buffer.gpuEndTime - buffer.gpuStartTime, 0) * 1000
        let stats: CameraRenderStats = statsLock.withLock {
            renderedFrameNumber &+= 1
            gpuMillisecondsAverage = gpuMillisecondsAverage == 0
                ? elapsed
                : gpuMillisecondsAverage * 0.9 + elapsed * 0.1
            return CameraRenderStats(
                frameNumber: renderedFrameNumber,
                gpuMilliseconds: gpuMillisecondsAverage,
                historyTaps: historyTapSnapshot,
                historyMegabytes: historyMegabyteSnapshot,
                topChromeLoad: topChromeLoadAverage,
                deckChromeLoad: deckChromeLoadAverage,
                bottomChromeLoad: bottomChromeLoadAverage,
                shedEffects: shedEffectSnapshot
            )
        }
        statsMailbox.publish(stats)
    }

    /// Measures how bright the frame is under the top and bottom chrome.
    ///
    /// One 64x64 dispatch, whatever the source resolution — the chrome needs to
    /// know "is it bright under here", not the frame's histogram. Returns the
    /// buffer slot the result will land in, or nil if the device could not
    /// build the pipeline.
    private func encodeBandLuma(source: MTLTexture, commandBuffer: MTLCommandBuffer) -> Int? {
        guard let bandLumaPipeline, !bandLumaBuffers.isEmpty else { return nil }
        let slot = bandLumaFrame % bandLumaBuffers.count
        bandLumaFrame &+= 1
        let buffer = bandLumaBuffers[slot]

        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.fill(buffer: buffer, range: 0 ..< buffer.length, value: 0)
        blit.endEncoding()

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(bandLumaPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        // Band edges as fractions of the frame: the top shell ends at 0.16,
        // the parameter deck runs 0.58 to 0.74, the dock takes the rest. Fixed
        // rather than driven from SwiftUI layout — a measurement that depends
        // on what the interface is currently showing is a feedback loop, and
        // the deck's region does not move when it is open.
        //
        // w is the perceptual level above which a sample counts as bright
        // enough to cost legibility.
        var uniforms = SIMD4<Float>(0.16, 0.58, 0.74, 0.62)
        encoder.setBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: 64, height: 64, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)
        )
        encoder.endEncoding()
        return slot
    }

    /// Reads the previous frame's band measurement and folds it into a running
    /// average.
    ///
    /// Heavily smoothed on purpose. The chrome must not flicker its own plate
    /// while the operator pans across a window frame — this is a lighting
    /// condition, not a per-frame signal.
    private func readBandLuma(slot: Int) {
        guard slot < bandLumaBuffers.count else { return }
        let bins = bandLumaBuffers[slot].contents().bindMemory(to: UInt32.self, capacity: 12)
        let top = chromeLoad(sum: bins[0], count: bins[1], bright: bins[2])
        let deck = chromeLoad(sum: bins[4], count: bins[5], bright: bins[6])
        let bottom = chromeLoad(sum: bins[8], count: bins[9], bright: bins[10])
        statsLock.withLock {
            topChromeLoadAverage = topChromeLoadAverage * 0.92 + top * 0.08
            deckChromeLoadAverage = deckChromeLoadAverage * 0.92 + deck * 0.08
            bottomChromeLoadAverage = bottomChromeLoadAverage * 0.92 + bottom * 0.08
        }
    }

    /// Turns one band's measurement into how hard the scrim should work.
    ///
    /// Two independent reasons the chrome can lose: the whole band is bright,
    /// or part of it is. Taking the larger of the two covers both — an evenly
    /// lit grey wall and a black room with one window each raise the scrim,
    /// and a night shot raises neither.
    private func chromeLoad(sum: UInt32, count: UInt32, bright: UInt32) -> Double {
        guard count > 0 else { return 0 }
        let mean = Double(sum) / Double(count) / 65535.0
        let brightFraction = Double(bright) / Double(count)
        return max(
            Self.ramp(mean, from: 0.34, to: 0.74),
            Self.ramp(brightFraction, from: 0.06, to: 0.38)
        )
    }

    /// Smoothstep between two thresholds, so neither end steps visibly.
    private static func ramp(_ value: Double, from: Double, to: Double) -> Double {
        let normalized = min(max((value - from) / (to - from), 0), 1)
        return normalized * normalized * (3 - 2 * normalized)
    }

    /// Snapshots the ring footprint on the render thread so the completion
    /// handler never touches `TemporalFrameBuffer` concurrently.
    private func publishHistoryFootprint() {
        let taps = temporalFrames.tapCount
        let megabytes: Double
        if let first = temporalFrames.textures.first {
            let bytes = first.width * first.height * 8 * taps
            megabytes = Double(bytes) / (1024 * 1024)
        } else {
            megabytes = 0
        }
        statsLock.withLock {
            historyTapSnapshot = taps
            historyMegabyteSnapshot = megabytes
        }
    }

    /// Fails safe: if the gesture pipeline stops publishing while a tear is
    /// open (interruption, backgrounding, view teardown) the renderer forces
    /// the state back to idle instead of staying fractured.
    private func resolvedFractureState() -> SignalFractureState {
        let state = fractureMailbox.latest
        guard state.phase.isEngaged else { return state }
        guard fractureMailbox.age < 1.5 else {
            fractureMailbox.reset()
            return .idle
        }
        return state
    }

    /// Uniform block for the three flow kernels.
    private struct FlowUniforms {
        var viewport: SIMD4<Float>
        var controls: SIMD4<Float>
        var flags: SIMD4<UInt32>
    }

    /// Estimates this frame's motion and folds it into the persistent field.
    ///
    /// Three passes: downsample luma, block-match against the previous luma,
    /// then accumulate. All at the flow working resolution, all GPU-resident,
    /// no readback.
    private func encodeFlow(
        source: MTLTexture,
        settings: CameraRenderSettings,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let currentLuma = flowField.currentLuma,
              let previousLuma = flowField.previousLuma,
              let current = flowField.current,
              let previous = flowField.previous,
              let persistent = flowField.persistent,
              let frozen = flowField.frozen,
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return
        }

        let (width, height) = flowField.size
        var uniforms = FlowUniforms(
            viewport: SIMD4<Float>(
                Float(width),
                Float(height),
                1 / Float(max(width, 1)),
                1 / Float(max(height, 1))
            ),
            // Search radius, persistence, decay, gain. These are the engine
            // defaults; per-effect controls scale the field where it is read
            // rather than here, so one accumulation serves every consumer.
            controls: SIMD4<Float>(6, 0.82, 0.10, 1.0),
            flags: SIMD4<UInt32>(settings.temporalHoldActive ? 1 : 0, 0, 0, 0)
        )

        encoder.label = "greyVISION Optical Flow"

        encoder.setComputePipelineState(flowLumaPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(currentLuma, index: 1)
        dispatch(encoder, pipeline: flowLumaPipeline, texture: currentLuma)

        // Only estimate once a reference frame exists. On the very first frame
        // the previous luma is undefined, and matching against it would seed
        // the persistent field with noise that then takes seconds to decay.
        if flowField.isPrimed {
            encoder.setComputePipelineState(flowEstimatePipeline)
            encoder.setTexture(currentLuma, index: 0)
            encoder.setTexture(previousLuma, index: 1)
            encoder.setTexture(previous, index: 2)
            encoder.setTexture(current, index: 3)
            encoder.setBytes(&uniforms, length: MemoryLayout<FlowUniforms>.stride, index: 0)
            dispatch(encoder, pipeline: flowEstimatePipeline, texture: current)

            encoder.setComputePipelineState(flowAccumulatePipeline)
            encoder.setTexture(current, index: 0)
            encoder.setTexture(persistent, index: 1)
            encoder.setTexture(frozen, index: 2)
            encoder.setTexture(persistent, index: 3)
            encoder.setBytes(&uniforms, length: MemoryLayout<FlowUniforms>.stride, index: 0)
            dispatch(encoder, pipeline: flowAccumulatePipeline, texture: persistent)
        }

        encoder.endEncoding()

        // MOTION HOLD captures on the rising edge. Copying the field once, at
        // the moment the finger lands, is what lets the held motion keep
        // driving displacement while live frames continue to arrive.
        if settings.temporalHoldActive, !flowField.hasSnapshot {
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.label = "greyVISION Flow Snapshot"
                blit.copy(from: persistent, to: frozen)
                blit.endEncoding()
            }
            flowField.markSnapshot()
        } else if !settings.temporalHoldActive, flowField.hasSnapshot {
            flowField.clearSnapshot()
        }

        flowField.advance()
    }

    /// Placeholder array texture, for frames where the ring is not allocated.
    ///
    /// Metal requires every declared texture argument to be bound, and a null
    /// binding is a hard fault rather than a sampled zero. One 1x1 slice costs
    /// nothing and removes an entire class of launch-order crash.
    private var emptyRingTexture: MTLTexture?
    private var emptyTimestamps: MTLBuffer?

    private func fallbackRingTexture(like destination: MTLTexture) -> MTLTexture {
        if let emptyRingTexture { return emptyRingTexture }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .bgra8Unorm
        descriptor.width = 1
        descriptor.height = 1
        descriptor.arrayLength = 1
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = "greyVISION Temporal Ring Placeholder"
        emptyRingTexture = texture
        return texture ?? destination
    }

    private func fallbackTimestampBuffer() -> MTLBuffer {
        if let emptyTimestamps { return emptyTimestamps }
        let buffer = device.makeBuffer(
            length: MemoryLayout<Float>.stride,
            options: .storageModeShared
        )
        // Stamped far in the past so any age search rejects it.
        buffer?.contents().bindMemory(to: Float.self, capacity: 1).pointee = -1e9
        emptyTimestamps = buffer
        return buffer!
    }

    /// Copies the clean source into the ring's write slice.
    ///
    /// A blit rather than a compute pass: this is a straight resize-free copy
    /// into a slice, and the blit engine does it without occupying the shader
    /// cores the effect chain needs.
    private func encodeTemporalRecord(source: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let ring = temporalEngine.texture,
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return
        }
        encoder.label = "greyVISION Temporal Record"
        encoder.setComputePipelineState(historyTapPipeline)
        encoder.setTexture(source, index: 0)
        // A slice view, so the existing single-texture tap kernel can write
        // into the array without needing an array-aware variant.
        guard let slice = ring.makeTextureView(
            pixelFormat: ring.pixelFormat,
            textureType: .type2D,
            levels: 0 ..< 1,
            slices: temporalEngine.writeSlice ..< (temporalEngine.writeSlice + 1)
        ) else {
            encoder.endEncoding()
            return
        }
        encoder.setTexture(slice, index: 1)
        dispatch(encoder, pipeline: historyTapPipeline, texture: slice)
        encoder.endEncoding()
        temporalEngine.commitWrite()
    }

    private func encodeHistoryTaps(source: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let due = temporalFrames.dueTaps()
        guard !due.isEmpty, let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "greyVISION Temporal Frame Ring"
        encoder.setComputePipelineState(historyTapPipeline)
        for index in due {
            let destination = temporalFrames.textures[index]
            encoder.setTexture(source, index: 0)
            encoder.setTexture(destination, index: 1)
            dispatch(encoder, pipeline: historyTapPipeline, texture: destination)
        }
        encoder.endEncoding()
    }

    private func encodeSignalFracture(
        _ state: SignalFractureState,
        source: MTLTexture,
        destination: MTLTexture,
        drawableSize: CGSize,
        commandBuffer: MTLCommandBuffer
    ) {
        guard temporalFrames.textures.count == TemporalFrameBuffer.strides.count,
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return
        }

        let now = CACurrentMediaTime()
        let elapsed = max(now - state.phaseStart, 0)
        let repair: Float
        let seam: Float
        let breakProgress: Float

        switch state.phase {
        case .repairing:
            repair = Float(min(elapsed / SignalFractureTiming.repairSeconds, 1))
            let overrun = elapsed - SignalFractureTiming.repairSeconds
            seam = overrun >= 0
                ? Float(max(1 - overrun / SignalFractureTiming.seamSeconds, 0))
                : 0
            breakProgress = 0
        case .broken:
            repair = 0
            seam = 0
            breakProgress = Float(min(elapsed / SignalFractureTiming.breakSeconds, 1))
        default:
            repair = 0
            seam = 0
            breakProgress = 0
        }

        let anchorA = textureCoordinate(
            state.pointA,
            drawableSize: drawableSize,
            textureWidth: source.width,
            textureHeight: source.height
        )
        let anchorB = textureCoordinate(
            state.pointB,
            drawableSize: drawableSize,
            textureWidth: source.width,
            textureHeight: source.height
        )

        var uniforms = CameraFractureUniforms(
            anchors: SIMD4<Float>(anchorA.x, anchorA.y, anchorB.x, anchorB.y),
            geometry: SIMD4<Float>(state.openness, state.rotation, state.velocity, state.stillness),
            timing: SIMD4<Float>(
                Float(ProcessInfo.processInfo.systemUptime.truncatingRemainder(dividingBy: 3600)),
                repair,
                breakProgress,
                seam
            ),
            viewport: SIMD4<Float>(
                Float(destination.width),
                Float(destination.height),
                1 / Float(max(destination.width, 1)),
                1 / Float(max(destination.height, 1))
            ),
            options: SIMD4<UInt32>(
                UInt32(adaptiveTapCount),
                state.phase.rawValue,
                UInt32(state.sampleNumber % 1_000_000),
                0
            )
        )

        encoder.label = "greyVISION Signal Fracture"
        encoder.setComputePipelineState(fracturePipeline)
        encoder.setTexture(source, index: 0)
        for index in temporalFrames.textures.indices {
            encoder.setTexture(temporalFrames.textures[index], index: 1 + index)
        }
        encoder.setTexture(destination, index: 5)
        encoder.setBytes(
            &uniforms,
            length: MemoryLayout<CameraFractureUniforms>.stride,
            index: 0
        )
        dispatch(encoder, pipeline: fracturePipeline, texture: destination)
        encoder.endEncoding()
    }

    /// Maps a normalised preview coordinate into texture space using the same
    /// aspect-fill crop `gvCameraPreviewFragment` applies, so the tear opens
    /// exactly under the fingers.
    private func textureCoordinate(
        _ point: SIMD2<Float>,
        drawableSize: CGSize,
        textureWidth: Int,
        textureHeight: Int
    ) -> SIMD2<Float> {
        let viewportAspect = Float(drawableSize.width / max(drawableSize.height, 1))
        let sourceAspect = Float(textureWidth) / Float(max(textureHeight, 1))
        var result = point
        if sourceAspect > viewportAspect {
            result.x = (result.x - 0.5) * (viewportAspect / sourceAspect) + 0.5
        } else {
            result.y = (result.y - 0.5) * (sourceAspect / viewportAspect) + 0.5
        }
        return result
    }

    func captureDevicePoint(for point: CGPoint, viewportSize: CGSize) -> CGPoint? {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        let geometry = geometryLock.withLock { sourceGeometry }
        guard geometry.width > 0, geometry.height > 0 else { return nil }

        let sourceSize = CGSize(width: geometry.width, height: geometry.height)
        let scale = max(
            viewportSize.width / sourceSize.width,
            viewportSize.height / sourceSize.height
        )
        let displayedSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let cropX = max(0, (displayedSize.width - viewportSize.width) * 0.5)
        let cropY = max(0, (displayedSize.height - viewportSize.height) * 0.5)
        var viewUV = CGPoint(
            x: (point.x + cropX) / displayedSize.width,
            y: (point.y + cropY) / displayedSize.height
        )
        viewUV.x = min(max(viewUV.x, 0), 1)
        viewUV.y = min(max(viewUV.y, 0), 1)
        if geometry.isMirrored {
            viewUV.x = 1 - viewUV.x
        }

        return switch geometry.orientation {
        case .portrait:
            CGPoint(x: viewUV.y, y: 1 - viewUV.x)
        case .portraitUpsideDown:
            CGPoint(x: 1 - viewUV.y, y: viewUV.x)
        case .landscapeLeft:
            viewUV
        case .landscapeRight:
            CGPoint(x: 1 - viewUV.x, y: 1 - viewUV.y)
        }
    }

    func shutdown() {
        if recordingSession != nil {
            stopRecording()
        }
        mailbox.clear()
        fractureMailbox.reset()
        statsMailbox.clear()
        touchMailbox.clear()
        temporalFrames.release()
        linearTexture = nil
        effectTextureA = nil
        effectTextureB = nil
        historyTexture = nil
        flowField.reset()
        temporalEngine.reset()
        emptyRingTexture = nil
        emptyTimestamps = nil
        worldAnchor.stop()
        worldReprojection.reset()
        isWorldAnchorRunning = false
        hasLinearFrame = false
        hasHistoryFrame = false
        CVMetalTextureCacheFlush(textureCache, 0)
        GVLog.rendering.notice("Camera Metal renderer stopped")
    }

    /// The resolution the effect chain actually runs at.
    ///
    /// The chain used to run at capture resolution — 3840x2160 or better,
    /// because the format filter rejects anything smaller. The preview is a
    /// 1320x2868 drawable, so every effect kernel was dispatching over 8.3M
    /// pixels to fill 3.8M. Three stacked effects at 60fps is about 1.5 billion
    /// invocations a second to show something that needs a third of that.
    ///
    /// Sized by pixel budget rather than by geometry: the preview aspect-fills
    /// and the frame may be rotated for display, so a width-to-width comparison
    /// is wrong in one orientation and a height-to-height comparison is wrong
    /// in the other. Area with headroom for the crop is right in both.
    ///
    /// Never upscales. The extra sampling this adds is not new — the preview
    /// fragment was already resolving 4K to the drawable with a linear sampler
    /// every frame. This does the same reduction earlier, once, and every
    /// kernel after it gets cheaper.
    ///
    /// Recording and stills take the full frame. A take is what the resolution
    /// was for.
    private func workingTextureSize(
        sourceWidth: Int,
        sourceHeight: Int,
        drawableSize: CGSize
    ) -> (width: Int, height: Int) {
        if recordingSession != nil || recordingMailbox.isStartPending || screenshotMailbox.isCapturePending {
            // Held for a moment after, so a burst of stills does not resize the
            // chain — and the history with it — once per press.
            fullResolutionHold = 24
        } else if fullResolutionHold > 0 {
            fullResolutionHold -= 1
        }

        return CameraChainResolution.resolve(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            drawablePixels: Double(drawableSize.width * drawableSize.height),
            fullResolution: fullResolutionHold > 0
        )
    }

    private func ensureWorkingTextures(width: Int, height: Int) -> Bool {
        let texturesMatch = linearTexture?.width == width &&
            linearTexture?.height == height &&
            effectTextureA?.width == width &&
            effectTextureA?.height == height &&
            effectTextureB?.width == width &&
            effectTextureB?.height == height &&
            historyTexture?.width == width &&
            historyTexture?.height == height
        if texturesMatch {
            return true
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let linearTexture = device.makeTexture(descriptor: descriptor),
              let effectTextureA = device.makeTexture(descriptor: descriptor),
              let effectTextureB = device.makeTexture(descriptor: descriptor),
              let historyTexture = device.makeTexture(descriptor: descriptor)
        else {
            return false
        }
        linearTexture.label = "greyVISION Linear Camera Frame"
        effectTextureA.label = "greyVISION Effect Ping"
        effectTextureB.label = "greyVISION Effect Pong"
        historyTexture.label = "greyVISION Temporal History"
        self.linearTexture = linearTexture
        self.effectTextureA = effectTextureA
        self.effectTextureB = effectTextureB
        self.historyTexture = historyTexture
        hasLinearFrame = false
        hasHistoryFrame = false
        return true
    }

    private func encodeYUVFrame(
        _ textures: CameraFrameTextureLease,
        into destination: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        var uniforms = conversionUniforms(for: textures.frame)
        encoder.label = "greyVISION YUV to Linear"
        encoder.setComputePipelineState(yuvPipeline)
        encoder.setTexture(textures.luma, index: 0)
        encoder.setTexture(textures.chroma, index: 1)
        encoder.setTexture(destination, index: 2)
        encoder.setBytes(
            &uniforms,
            length: MemoryLayout<CameraConversionUniforms>.stride,
            index: 0
        )
        dispatch(encoder, pipeline: yuvPipeline, texture: destination)
        encoder.endEncoding()
    }

    private func encodeSyntheticFrame(
        into destination: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        time: Float
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        var uniforms = CameraConversionUniforms(
            source: SIMD4<UInt32>(UInt32(destination.width), UInt32(destination.height), 1, 1),
            tuning: SIMD4<Float>(1, time, 0, 0)
        )
        encoder.label = "greyVISION Synthetic Linear Feed"
        encoder.setComputePipelineState(syntheticPipeline)
        encoder.setTexture(destination, index: 0)
        encoder.setBytes(
            &uniforms,
            length: MemoryLayout<CameraConversionUniforms>.stride,
            index: 0
        )
        dispatch(encoder, pipeline: syntheticPipeline, texture: destination)
        encoder.endEncoding()
    }

    private func encodeRGBSplit(
        _ parameters: RGBSplitEffectParameters,
        source: MTLTexture,
        destination: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        let radians = Float(parameters.angleDegrees * .pi / 180)
        var uniforms = CameraRGBSplitUniforms(
            parameters: SIMD4<Float>(
                Float(parameters.amount),
                cos(radians),
                sin(radians),
                Float(parameters.mix)
            )
        )
        encoder.label = "greyVISION RGB Split"
        encoder.setComputePipelineState(rgbSplitPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(
            &uniforms,
            length: MemoryLayout<CameraRGBSplitUniforms>.stride,
            index: 0
        )
        dispatch(encoder, pipeline: rgbSplitPipeline, texture: destination)
        encoder.endEncoding()
    }

    // swiftlint:disable:next function_parameter_count
    private func encodeStyleEffect(
        _ effect: WorkspaceAdjustableEffect,
        parameters: CameraEffectParameters,
        source: MTLTexture,
        destination: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        time: Float,
        audio: SIMD4<Float>,
        touch: SIMD4<Float>,
        touchImpact: SIMD4<Float>,
        blobs: [SIMD4<Float>]
    ) {
        guard let mode = effect.styleMode,
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return
        }
        let values = parameters.sanitized
        var uniforms = CameraStyleEffectUniforms(
            mode: SIMD4<UInt32>(mode, 0, 0, 0),
            parameters: SIMD4<Float>(
                Float(values.primary),
                Float(values.secondary),
                Float(values.tertiary),
                time
            ),
            viewport: SIMD4<Float>(
                Float(destination.width),
                Float(destination.height),
                1 / Float(max(destination.width, 1)),
                1 / Float(max(destination.height, 1))
            ),
            extra: SIMD4<Float>(Float(values.blend), 0, 0, 0),
            audio: audio,
            touch: touch,
            touchImpact: touchImpact,
            audioDynamics: audioDynamics,
            blob0: !blobs.isEmpty ? blobs[0] : .zero,
            blob1: blobs.count > 1 ? blobs[1] : .zero,
            blob2: blobs.count > 2 ? blobs[2] : .zero,
            blob3: blobs.count > 3 ? blobs[3] : .zero,
            spectrum0: audioSpectrum.0,
            spectrum1: audioSpectrum.1,
            spectrum2: audioSpectrum.2,
            spectrum3: audioSpectrum.3,
            // Style passes are stateless per frame and never accumulate, so
            // there is nothing for a world anchor to hold on to.
            worldReprojection: matrix_identity_float3x3
        )
        encoder.label = "greyVISION \(effect.label)"
        encoder.setComputePipelineState(styleEffectPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(
            &uniforms,
            length: MemoryLayout<CameraStyleEffectUniforms>.stride,
            index: 0
        )
        dispatch(encoder, pipeline: styleEffectPipeline, texture: destination)
        encoder.endEncoding()
    }

    // swiftlint:disable:next function_parameter_count
    private func encodeTemporalEffect(
        _ effect: WorkspaceAdjustableEffect,
        parameters: CameraEffectParameters,
        source: MTLTexture,
        history: MTLTexture,
        historyTaps: [MTLTexture],
        flow: MTLTexture?,
        worldMatrix: simd_float3x3,
        ring: CameraTemporalEngine?,
        destination: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        time: Float,
        holdActive: Bool,
        audio: SIMD4<Float>,
        touch: SIMD4<Float>,
        touchImpact: SIMD4<Float>,
        blobs: [SIMD4<Float>]
    ) {
        guard let mode = effect.temporalMode,
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return
        }
        let values = parameters.sanitized
        var uniforms = CameraStyleEffectUniforms(
            mode: SIMD4<UInt32>(mode, 0, 0, 0),
            parameters: SIMD4<Float>(
                Float(values.primary),
                Float(values.secondary),
                Float(values.tertiary),
                time
            ),
            viewport: SIMD4<Float>(
                Float(destination.width),
                Float(destination.height),
                1 / Float(max(destination.width, 1)),
                1 / Float(max(destination.height, 1))
            ),
            extra: SIMD4<Float>(
                Float(values.blend),
                holdActive ? 1 : 0,
                // Guards every flow read. Without it the first frames after a
                // resolution change displace against an unwritten texture.
                flow != nil && flowField.isPrimed ? 1 : 0,
                0
            ),
            audio: audio,
            touch: touch,
            touchImpact: touchImpact,
            audioDynamics: audioDynamics,
            blob0: !blobs.isEmpty ? blobs[0] : .zero,
            blob1: blobs.count > 1 ? blobs[1] : .zero,
            blob2: blobs.count > 2 ? blobs[2] : .zero,
            blob3: blobs.count > 3 ? blobs[3] : .zero,
            spectrum0: audioSpectrum.0,
            spectrum1: audioSpectrum.1,
            spectrum2: audioSpectrum.2,
            spectrum3: audioSpectrum.3,
            worldReprojection: worldMatrix
        )
        encoder.label = "greyVISION Temporal \(effect.label)"
        encoder.setComputePipelineState(temporalEffectPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(history, index: 1)
        encoder.setTexture(destination, index: 2)
        // Taps 3-6 are the aged ring. Metal requires every declared texture to
        // be bound even when a mode never reads it, so the single-frame
        // history stands in whenever the ring has not primed yet — that keeps
        // the first few frames after a resolution change valid rather than
        // sampling a null texture.
        for index in 0 ..< TemporalFrameBuffer.strides.count {
            let tap = index < historyTaps.count ? historyTaps[index] : history
            encoder.setTexture(tap, index: 3 + index)
        }
        // Slot 7 is the persistent motion field. Bound every frame; the
        // history texture stands in before flow has primed so the binding is
        // never null, and the shader gates on `extra.z` rather than on the
        // texture's contents.
        encoder.setTexture(flow ?? history, index: 7)
        // Slot 8 plus buffers 1 and 2 are the timestamped ring. Bound every
        // frame; `ringInfo.validCount` is what gates use, so a shader can read
        // it safely before any frame has been recorded.
        var ringInfo = ring?.uniforms ?? TemporalRingUniforms(
            slotCount: 0, head: 0, validCount: 0, isPrimed: 0,
            currentTime: 0, historySpan: 0, padding: .zero
        )
        if let ring, let ringTexture = ring.texture, let stamps = ring.timestampBuffer {
            encoder.setTexture(ringTexture, index: 8)
            encoder.setBuffer(stamps, offset: 0, index: 1)
        } else {
            // Metal requires the binding to exist even when unused.
            encoder.setTexture(fallbackRingTexture(like: destination), index: 8)
            encoder.setBuffer(fallbackTimestampBuffer(), offset: 0, index: 1)
        }
        encoder.setBytes(&ringInfo, length: MemoryLayout<TemporalRingUniforms>.stride, index: 2)
        encoder.setBytes(
            &uniforms,
            length: MemoryLayout<CameraStyleEffectUniforms>.stride,
            index: 0
        )
        dispatch(encoder, pipeline: temporalEffectPipeline, texture: destination)
        encoder.endEncoding()
    }

    private func encodeHistoryCopy(
        source: MTLTexture,
        destination: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else { return }
        encoder.label = "greyVISION Temporal History Update"
        encoder.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: .init(x: 0, y: 0, z: 0),
            sourceSize: .init(width: source.width, height: source.height, depth: 1),
            to: destination,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: .init(x: 0, y: 0, z: 0)
        )
        encoder.endEncoding()
    }

    private func dispatch(
        _ encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        texture: MTLTexture
    ) {
        let width = max(1, pipeline.threadExecutionWidth)
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: texture.width, height: texture.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
        )
    }

    private func makeTextures(frame: CapturedFrame) -> CameraFrameTextureLease? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer),
              CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
              let lumaLease = makeTexture(
                  pixelBuffer: pixelBuffer,
                  pixelFormat: .r8Unorm,
                  plane: 0,
                  width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                  height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
              ),
              let chromaLease = makeTexture(
                  pixelBuffer: pixelBuffer,
                  pixelFormat: .rg8Unorm,
                  plane: 1,
                  width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                  height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
              )
        else {
            return nil
        }
        return CameraFrameTextureLease(
            frame: frame,
            luma: lumaLease.1,
            chroma: chromaLease.1,
            leases: [lumaLease.0, chromaLease.0]
        )
    }

    private func makeTexture(
        pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        plane: Int,
        width: Int,
        height: Int
    ) -> (CVMetalTexture, MTLTexture)? {
        var lease: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            plane,
            &lease
        )
        guard result == kCVReturnSuccess,
              let lease,
              let texture = CVMetalTextureGetTexture(lease)
        else {
            return nil
        }
        return (lease, texture)
    }

    private func conversionUniforms(for frame: CapturedFrame) -> CameraConversionUniforms {
        let pixelBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer)
        let pixelFormat = pixelBuffer.map(CVPixelBufferGetPixelFormatType) ?? 0
        let fullRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        return CameraConversionUniforms(
            source: SIMD4<UInt32>(
                UInt32(max(frame.dimensions.width, 1)),
                UInt32(max(frame.dimensions.height, 1)),
                fullRange ? 1 : 0,
                matrixKind(for: frame)
            ),
            tuning: SIMD4<Float>(Float(transferKind(for: frame)), 0, 0, 0)
        )
    }

    private func matrixKind(for frame: CapturedFrame) -> UInt32 {
        let value = formatExtension(kCVImageBufferYCbCrMatrixKey, frame: frame)
        if value == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String {
            return 0
        }
        if value == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String {
            return 2
        }
        return 1
    }

    private func transferKind(for frame: CapturedFrame) -> UInt32 {
        let value = formatExtension(kCVImageBufferTransferFunctionKey, frame: frame)
        return value == kCVImageBufferTransferFunction_sRGB as String ? 1 : 0
    }

    private func formatExtension(_ key: CFString, frame: CapturedFrame) -> String? {
        guard let format = CMSampleBufferGetFormatDescription(frame.sampleBuffer),
              let formatExtensions = CMFormatDescriptionGetExtensions(format)
        else {
            return nil
        }
        let extensions = formatExtensions as NSDictionary
        return extensions[key as String] as? String
    }

    private func syntheticTextureSize(for drawableSize: CGSize) -> (width: Int, height: Int) {
        let drawableWidth = max(Int(drawableSize.width.rounded()), 1)
        let drawableHeight = max(Int(drawableSize.height.rounded()), 1)
        let longestSide = max(drawableWidth, drawableHeight)
        let scale = min(1, 1280.0 / Double(longestSide))
        return (
            max(1, Int(Double(drawableWidth) * scale)),
            max(1, Int(Double(drawableHeight) * scale))
        )
    }
}

// swiftlint:enable file_length
