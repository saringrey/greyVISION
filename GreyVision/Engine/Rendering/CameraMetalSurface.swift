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
    static let styleEffectGeneric = "gvCameraStyleEffectGeneric"
    static let temporalEffect = "gvCameraTemporalEffect"
    static let flowLuma = "gvFlowLuma"
    static let flowEstimate = "gvFlowEstimate"
    static let flowAccumulate = "gvFlowAccumulate"
    static let flowClear = "gvFlowClear"
    static let historyTap = "gvCameraHistoryTap"
    static let compositeWatermark = "gvCameraCompositeWatermark"
    static let signalFracture = "gvCameraSignalFracture"
    static let moshClearState = "gvMoshClearState"
    static let bandLuma = "gvCameraBandLuma"
    static let previewVertex = "gvCameraPreviewVertex"
    static let previewFragment = "gvCameraPreviewFragment"
    static let styleModeFunctionConstantIndex = 0
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
    var reducedDetail = false

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
    private var requestedBurnHUD = false

    func requestStart(codecRawValue: String, fps: Int, burnHUD: Bool = false) {
        lock.withLock {
            startRequested = true
            requestedCodecRawValue = codecRawValue
            requestedFPS = fps
            requestedBurnHUD = burnHUD
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

    func consumeStartRequest() -> (Bool, String, Int, Bool) {
        lock.withLock {
            defer { startRequested = false }
            return (startRequested, requestedCodecRawValue, requestedFPS, requestedBurnHUD)
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
    /// Raw drag vector: xy = pointer velocity in screen fractions per second,
    /// w = 1 while the finger is down and moving. Must sit right after
    /// `touchImpact` to mirror GVCameraEffectUniforms in CameraShaders.metal.
    var touchDrag: SIMD4<Float>
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
    case ended(SIMD2<Float>)
}

enum CameraOverlayPinchEvent {
    case began(CGFloat)
    case changed(CGFloat)
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
    var overlays: SIMD4<Float> = .zero
    let fracture: SignalFractureController
    /// Live link to the Mac virtual camera, or nil when it is not armed.
    let broadcast: GVBroadcastEngine?
    let statsMailbox: CameraRenderStatsMailbox
    let onPreviewTap: @MainActor @Sendable () -> Void
    let onFocus: @MainActor (CGPoint) -> Void
    let onSpectrumOverlayDrag: @MainActor @Sendable (SIMD2<Float>) -> Void
    let onSpectrumOverlayPinch: @MainActor @Sendable (CameraOverlayPinchEvent) -> Void
    /// True when a preview drag or pinch on a spectrum overlay starts, false
    /// when it ends. Lets the editor bracket the gesture as one undo step.
    let onOverlayGesturePhase: @MainActor @Sendable (Bool) -> Void
    let onFailure: @MainActor () -> Void
    /// Recording transaction for lifecycle callbacks from the renderer.
    let recordingTransaction: GVRecordingTransaction?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            mailbox: runtime.latestFrameMailbox,
            fracture: fracture,
            statsMailbox: statsMailbox,
            recordingMailbox: runtime.recordingMailbox,
            onRecordingStateChange: { [weak recordingTransaction, weak runtime] active in
                Task { @MainActor [weak recordingTransaction, weak runtime] in
                    // The runtime's isRecording is what isTakeLive reads, so
                    // without this the UI never enters the take state and the
                    // record toggle can never reach stop() — the writer runs
                    // unfinalized and no video is ever saved.
                    runtime?.setRecordingActive(active)
                    recordingTransaction?.handleRecordingStateChange(active)
                }
            },
            onRecordingMessage: { [weak recordingTransaction] reason in
                Task { @MainActor [weak recordingTransaction] in
                    recordingTransaction?.handleRecordingMessage(reason)
                }
            },
            screenshotMailbox: runtime.screenshotMailbox,
            onScreenshotMessage: { [weak recordingTransaction] message in
                Task { @MainActor [weak recordingTransaction] in
                    recordingTransaction?.handleScreenshotMessage(message)
                }
            },
            onPreviewTap: onPreviewTap,
            onFocus: onFocus,
            onSpectrumOverlayDrag: onSpectrumOverlayDrag,
            onSpectrumOverlayPinch: onSpectrumOverlayPinch,
            onOverlayGesturePhase: onOverlayGesturePhase,
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
        context.coordinator.renderer?.setBroadcastEngine(broadcast)
        context.coordinator.renderer?.setTemporalHoldActive(runtime.isFrameFrozen)
        context.coordinator.renderer?.update(
            rgbSplitParameters: rgbSplitParameters,
            effectStack: effectStack,
            isSynthetic: runtime.snapshot.isSynthetic,
            sourceIdentifier: runtime.snapshot.deviceID ?? "camera",
            audioSnapshot: audioSnapshot,
            audioIntensity: audioIntensity,
            blobFields: blobFields,
            scanlineParameters: scanlineParameters,
            overlays: overlays,
            screenScale: Float(view.contentScaleFactor)
        )
        view.accessibilityLabel = runtime.snapshot.isSynthetic
            ? "Deterministic Metal simulator camera source"
            : "Metal camera preview. Tap to focus."
        let sessionRate = min(max(runtime.snapshot.framesPerSecond, 30), 120)
        view.preferredFramesPerSecond = min(sessionRate, GVRenderQuality.resolve(
            runtime.renderQuality,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        ).maximumFramesPerSecond)
        coordinator.renderer?.setRenderQuality(runtime.renderQuality)
        view.isPaused = runtime.snapshot.state != .running
    }

    static func dismantleUIView(_ view: CameraMetalView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
        view.onTap = nil
        view.onFracture = nil
        view.onTouchChanged = nil
        view.onOverlayPinch = nil
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
        let onPreviewTap: @MainActor @Sendable () -> Void
        let onFocus: @MainActor (CGPoint) -> Void
        let onSpectrumOverlayDrag: @MainActor @Sendable (SIMD2<Float>) -> Void
        let onSpectrumOverlayPinch: @MainActor @Sendable (CameraOverlayPinchEvent) -> Void
        let onOverlayGesturePhase: @MainActor @Sendable (Bool) -> Void
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
            onPreviewTap: @escaping @MainActor @Sendable () -> Void,
            onFocus: @escaping @MainActor (CGPoint) -> Void,
            onSpectrumOverlayDrag: @escaping @MainActor @Sendable (SIMD2<Float>) -> Void,
            onSpectrumOverlayPinch: @escaping @MainActor @Sendable (CameraOverlayPinchEvent) -> Void,
            onOverlayGesturePhase: @escaping @MainActor @Sendable (Bool) -> Void,
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
            self.onPreviewTap = onPreviewTap
            self.onFocus = onFocus
            self.onSpectrumOverlayDrag = onSpectrumOverlayDrag
            self.onSpectrumOverlayPinch = onSpectrumOverlayPinch
            self.onOverlayGesturePhase = onOverlayGesturePhase
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
            view.onTouchChanged = { [touchMailbox, onSpectrumOverlayDrag, onOverlayGesturePhase] event in
                switch event {
                case let .began(position, velocity):
                    // Bracket the drag so the editor records one undo entry
                    // for the whole move rather than one per frame.
                    onOverlayGesturePhase(true)
                    touchMailbox.began(position: position, velocity: velocity)
                    onSpectrumOverlayDrag(position)
                case let .moved(position, velocity):
                    touchMailbox.moved(position: position, velocity: velocity)
                    onSpectrumOverlayDrag(position)
                case let .ended(position):
                    touchMailbox.ended()
                    onSpectrumOverlayDrag(position)
                    onOverlayGesturePhase(false)
                }
            }
            view.onOverlayPinch = onSpectrumOverlayPinch
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
    var onFracture: ((CameraFractureEvent) -> Void)?
    var onTouchChanged: ((CameraTouchEvent) -> Void)?
    var onOverlayPinch: ((CameraOverlayPinchEvent) -> Void)?

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
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
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handleOverlayPinch(_:)))
        pinch.cancelsTouchesInView = false
        addGestureRecognizer(pinch)
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
    private func handleFracture(_ recognizer: SignalFractureGestureRecognizer) {
        switch recognizer.state {
        case .began:
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
        switch recognizer.state {
        case .began:
            onTouchChanged?(.began(normalized, normalizedVelocity))
        case .changed:
            onTouchChanged?(.moved(normalized, normalizedVelocity))
        case .ended, .cancelled, .failed:
            onTouchChanged?(.ended(normalized))
        default:
            break
        }
    }

    @objc
    private func handleOverlayPinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            onOverlayPinch?(.began(recognizer.scale))
        case .changed:
            onOverlayPinch?(.changed(recognizer.scale))
        case .ended, .cancelled, .failed:
            onOverlayPinch?(.ended)
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
    var overlays: SIMD4<Float>
}

private struct CameraFractureUniforms {
    var anchors: SIMD4<Float>
    var geometry: SIMD4<Float>
    var timing: SIMD4<Float>
    var viewport: SIMD4<Float>
    var options: SIMD4<UInt32>
}

private typealias CameraAudioSpectrum = (
    SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>
)

private struct CameraRenderSettings {
    let rgbSplit: RGBSplitEffectParameters
    let effectStack: CameraEffectStackParameters
    let isSynthetic: Bool
    let sourceIdentifier: String
    let temporalHoldActive: Bool
    let audio: SIMD4<Float>
    let audioDynamics: SIMD4<Float>
    let audioSpectrum: CameraAudioSpectrum
    let blobs: [SIMD4<Float>]
    let scanlines: ScanlineEffectParameters
    let overlays: SIMD4<Float>
}

private struct CameraSourceGeometry: Equatable {
    var width = 1
    var height = 1
    var orientation = CapturedFrameOrientation.portrait
    var isMirrored = false
}

/// Identity of the frame source for the purposes of resetting accumulated
/// state. A comparable value rather than an interpolated string: the renderer
/// used to build a `String` every frame just to compare it with the previous
/// one, which is an allocation and a full string comparison at display rate.
private struct CameraSourceSignature: Equatable {
    let identifier: String
    let isSynthetic: Bool
    let width: Int
    let height: Int
    let orientation: CapturedFrameOrientation
    let isMirrored: Bool

    init(identifier: String, isSynthetic: Bool, geometry: CameraSourceGeometry) {
        self.identifier = identifier
        self.isSynthetic = isSynthetic
        width = geometry.width
        height = geometry.height
        orientation = geometry.orientation
        isMirrored = geometry.isMirrored
    }
}

/// Derives a per-frame value from the composition only when the composition
/// has actually changed.
///
/// The renderer needs two derived facts every frame: which temporal effects
/// are live, and what the graph as a whole requires. Both are pure functions
/// of the slot list, and the slot list only changes when the operator edits
/// something — so deriving them per frame was two array allocations and a
/// union fold sixty to a hundred and twenty times a second for a constant.
private struct CameraCompositionCache<Value> {
    private var revision: UInt64 = .min
    private var value: Value

    init(defaultValue: Value) {
        value = defaultValue
    }

    mutating func resolve(for stack: CameraEffectStackParameters, using make: (CameraEffectStackParameters) -> Value) -> Value {
        if stack.revision != revision {
            revision = stack.revision
            value = make(stack)
        }
        return value
    }
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
    /// - Parameter renderScale: the governor's longest-edge multiplier. Below
    ///   1 the whole chain is rendered smaller and the final blit scales it
    ///   back up. This is the only lever the governor is allowed to pull that
    ///   does not change *which* effects run — skipping a visible slot would
    ///   hand the operator a different image than the one they composed.
    static func resolve(
        sourceWidth: Int,
        sourceHeight: Int,
        drawablePixels: Double,
        fullResolution: Bool,
        renderScale: Double = 1
    ) -> (width: Int, height: Int) {
        let sourcePixels = Double(sourceWidth * sourceHeight)
        guard !fullResolution, drawablePixels > 0, sourcePixels > drawablePixels else {
            return scaled(sourceWidth, sourceHeight, by: renderScale)
        }

        // 1.25x, because aspect-fill crops: the covering scale needs more
        // texels than the drawable's bare area implies.
        let fit = min(1, (drawablePixels * 1.25 / sourcePixels).squareRoot())
        return scaled(
            sourceWidth,
            sourceHeight,
            by: min(fit, max(renderScale, 0.5))
        )
    }

    /// Applies the governor's scale, keeping both edges even. Chroma is
    /// subsampled and the recorder's encoder rejects odd sizes; keeping the
    /// rule in one place avoids a class of one-pixel bug that only appears at
    /// one resolution.
    private static func scaled(_ sourceWidth: Int, _ sourceHeight: Int, by scale: Double) -> (width: Int, height: Int) {
        guard scale < 1 else { return (sourceWidth, sourceHeight) }
        let width = max(Int((Double(sourceWidth) * scale).rounded()) & ~1, 16)
        let height = max(Int((Double(sourceHeight) * scale).rounded()) & ~1, 16)
        return (width, height)
    }
}

private enum CameraRenderGraphStage: Equatable {
    case rgbSplit
    case style(WorkspaceAdjustableEffect)
    case fluid
    case reactionDiffusion
    case temporal(WorkspaceAdjustableEffect)
}

private struct CameraRenderGraphFrameState {
    let settings: CameraRenderSettings
    let time: Float
    let deltaTime: Float
    let holdSeconds: Float
    let touch: SIMD4<Float>
    let touchImpact: SIMD4<Float>
    let touchDrag: SIMD4<Float>
    let historyTaps: [MTLTexture]
    let worldMatrix: simd_float3x3
    let temporalRing: CameraTemporalEngine?
    let shouldFreezeTemporalHistory: Bool
    /// The quality rung the governor settled on this frame. Read by the
    /// simulation nodes so a downshift actually changes the solve rather than
    /// only the field edges.
    let quality: GVRenderQuality
}

private final class CameraRenderGraphNode: RenderEffect {
    let identifier: String
    weak var owner: CameraMetalRenderer?
    var stage = CameraRenderGraphStage.rgbSplit
    var isEnabled = true
    var mix: Float = 1
    var parameterDefinitions: [ParameterDefinition] = []
    var parameterState = EffectParameterState()
    var mask = EffectMaskInput.none
    var cameraParameters = CameraEffectParameters()
    var rgbSplitParameters: RGBSplitEffectParameters?
    var fluidSolver: CameraFluidSolver?
    var reactionSolver: CameraReactionDiffusion?
    var lastFluidTime: TimeInterval = 0
    /// Stateful mosh data belongs to the Slot, not to the renderer. A shared
    /// pair made DATAMOSH, LIQUID MOSH and duplicate Slots overwrite one
    /// another's vectors whenever they appeared in the same Composition.
    var moshStateA: MTLTexture?
    var moshStateB: MTLTexture?
    var moshStateReadsA = true
    /// Previous output of this specific Slot. The renderer-wide history is the
    /// previous final Composition and makes stacked mosh Slots feed one
    /// another; differential transport needs its own prediction surface.
    var moshHistory: MTLTexture?
    var moshHistoryNeedsSeed = true

    var displayName: String {
        switch stage {
        case .rgbSplit: "RGB Split"
        case let .style(effect), let .temporal(effect): effect.rawValue
        case .fluid: "Fluid"
        case .reactionDiffusion: "Reaction Garden"
        }
    }

    var kind: RenderEffectKind {
        switch stage {
        case .rgbSplit, .style: .stateless
        case .fluid, .reactionDiffusion: .composite
        case .temporal: .temporal
        }
    }

    init(identifier: String, owner: CameraMetalRenderer) {
        self.identifier = identifier
        self.owner = owner
    }

    func configure(
        stage: CameraRenderGraphStage,
        parameters: CameraEffectParameters,
        rgbSplit: RGBSplitEffectParameters?,
        mix: Float
    ) {
        if self.stage != stage {
            releaseResources()
        }
        self.stage = stage
        cameraParameters = parameters
        rgbSplitParameters = rgbSplit
        self.mix = min(max(mix.isFinite ? mix : 0, 0), 1)
        isEnabled = true
    }

    func prepare(_: RenderPreparationContext) throws {}

    func process(_ request: EffectRenderRequest) throws {
        guard let owner else {
            throw RenderEffectError.unavailable("Camera renderer released")
        }
        try owner.processGraphNode(self, request: request)
    }

    func reset(reason _: EffectResetReason) {
        fluidSolver?.reset()
        reactionSolver?.reset()
        lastFluidTime = 0
        moshStateA = nil
        moshStateB = nil
        moshStateReadsA = true
        moshHistory = nil
        moshHistoryNeedsSeed = true
    }

    func releaseResources() {
        fluidSolver?.reset()
        reactionSolver?.reset()
        fluidSolver = nil
        reactionSolver = nil
        lastFluidTime = 0
        moshStateA = nil
        moshStateB = nil
        moshStateReadsA = true
        moshHistory = nil
        moshHistoryNeedsSeed = true
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
    private let renderTexturePool: TexturePool
    private let renderTemporalBuffers: TemporalBufferBank
    private let renderMotionField: MotionField
    private let renderGraph: RenderGraph
    private let yuvPipeline: MTLComputePipelineState
    private let syntheticPipeline: MTLComputePipelineState
    private let rgbSplitPipeline: MTLComputePipelineState
    /// Generic, uniform-switched fallback. It renders the correct mode while a
    /// function-constant specialization is compiling off the render thread.
    private let styleEffectPipeline: MTLComputePipelineState
    private let stylePipelineCacheLock = NSLock()
    private var styleEffectPipelines: [UInt32: MTLComputePipelineState] = [:]
    private var pendingStylePipelineModes = Set<UInt32>()
    private var failedStylePipelineModes = Set<UInt32>()
    private let stylePipelineCompilationQueue = DispatchQueue(
        label: "greyvision.camera.style-pipelines",
        qos: .userInitiated
    )
    private let temporalEffectPipeline: MTLComputePipelineState
    private let historyTapPipeline: MTLComputePipelineState
    private let moshClearStatePipeline: MTLComputePipelineState
    private let compositeWatermarkPipeline: MTLComputePipelineState
    private let flowLumaPipeline: MTLComputePipelineState
    private let flowEstimatePipeline: MTLComputePipelineState
    private let flowAccumulatePipeline: MTLComputePipelineState
    private let flowClearPipeline: MTLComputePipelineState
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
    private let settingsLock = NSLock()
    private let geometryLock = NSLock()
    private let statsLock = NSLock()

    private var gpuMillisecondsAverage: Double = 0
    private var effectQuality = CameraEffectQuality()
    /// The operator's pinned tier, written on the main thread and adopted by
    /// the governor on the render thread before it runs.
    private var requestedQuality: GVRenderQuality = .automatic
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
    private var sourceIdentifier = "camera"
    private var temporalHoldActive = false
    private var audio = SIMD4<Float>.zero
    private var audioDynamics = SIMD4<Float>.zero
    private var audioSpectrum: CameraAudioSpectrum = (.zero, .zero, .zero, .zero)
    private var blobFields: [SIMD4<Float>] = []
    private var scanlineParameters = ScanlineEffectParameters()
    private var overlays = SIMD4<Float>.zero
    private var screenScale: Float = 3
    private var syntheticTarget: MTLTexture?
    private var temporalLumaTarget: MTLTexture?

    /// Live link to the Mac virtual camera. Nil unless the operator armed it.
    private var broadcastEngine: GVBroadcastEngine?
    private let broadcastPool = GVBroadcastFramePool()
    private var recordingSession: GVRealtimeRecordingSession?
    private var recordingStartTime: TimeInterval?
    private var hasFailedSession = false
    private var sourceGeometry = CameraSourceGeometry()
    private var temporalSourceSignature: CameraSourceSignature?
    private var temporalEffectCache = CameraCompositionCache<[(
        WorkspaceAdjustableEffect,
        CameraEffectParameters
    )]>(defaultValue: [])
    private var requirementCache = CameraCompositionCache<CameraEffectResourceRequirements>(defaultValue: [])
    private var linearTexture: MTLTexture?
    private var effectTextureA: MTLTexture?
    private var effectTextureB: MTLTexture?
    private var historyTexture: MTLTexture?
    private var hasLinearFrame = false
    private var hasHistoryFrame = false
    private var graphNodes: [UUID: CameraRenderGraphNode] = [:]
    private lazy var rgbGraphNode = CameraRenderGraphNode(
        identifier: "camera.rgbSplit",
        owner: self
    )
    private var renderFrameIndex: UInt64 = 0
    private var previousRenderTime: TimeInterval?
    private var temporalHoldBeganAt: TimeInterval?
    private var graphFrameState: CameraRenderGraphFrameState?
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
              let styleEffectFunction = library.makeFunction(name: CameraMetalShaderNames.styleEffectGeneric),
              let temporalEffectFunction = library.makeFunction(name: CameraMetalShaderNames.temporalEffect),
              let historyTapFunction = library.makeFunction(name: CameraMetalShaderNames.historyTap),
              let moshClearStateFunction = library.makeFunction(name: CameraMetalShaderNames.moshClearState),
              let compositeWatermarkFunction = library.makeFunction(name: CameraMetalShaderNames.compositeWatermark),
              let flowLumaFunction = library.makeFunction(name: CameraMetalShaderNames.flowLuma),
              let flowEstimateFunction = library.makeFunction(name: CameraMetalShaderNames.flowEstimate),
              let flowAccumulateFunction = library.makeFunction(name: CameraMetalShaderNames.flowAccumulate),
              let flowClearFunction = library.makeFunction(name: CameraMetalShaderNames.flowClear),
              let fractureFunction = library.makeFunction(name: CameraMetalShaderNames.signalFracture),
              let previewVertex = library.makeFunction(name: CameraMetalShaderNames.previewVertex),
              let previewFragment = library.makeFunction(name: CameraMetalShaderNames.previewFragment),
              let yuvPipeline = try? device.makeComputePipelineState(function: yuvFunction),
              let syntheticPipeline = try? device.makeComputePipelineState(function: syntheticFunction),
              let rgbSplitPipeline = try? device.makeComputePipelineState(function: rgbSplitFunction),
              let styleEffectPipeline = try? device.makeComputePipelineState(function: styleEffectFunction),
              let temporalEffectPipeline = try? device.makeComputePipelineState(function: temporalEffectFunction),
              let historyTapPipeline = try? device.makeComputePipelineState(function: historyTapFunction),
              let moshClearStatePipeline = try? device.makeComputePipelineState(function: moshClearStateFunction),
              let compositeWatermarkPipeline = try? device.makeComputePipelineState(function: compositeWatermarkFunction),
              let flowLumaPipeline = try? device.makeComputePipelineState(function: flowLumaFunction),
              let flowEstimatePipeline = try? device.makeComputePipelineState(function: flowEstimateFunction),
              let flowAccumulatePipeline = try? device.makeComputePipelineState(function: flowAccumulateFunction),
              let flowClearPipeline = try? device.makeComputePipelineState(function: flowClearFunction),
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
        let renderTexturePool = TexturePool(device: device)
        self.renderTexturePool = renderTexturePool
        renderTemporalBuffers = TemporalBufferBank(device: device)
        renderMotionField = MotionField()
        renderGraph = RenderGraph(texturePool: renderTexturePool)
        self.yuvPipeline = yuvPipeline
        self.syntheticPipeline = syntheticPipeline
        self.rgbSplitPipeline = rgbSplitPipeline
        self.styleEffectPipeline = styleEffectPipeline
        self.temporalEffectPipeline = temporalEffectPipeline
        self.historyTapPipeline = historyTapPipeline
        self.moshClearStatePipeline = moshClearStatePipeline
        self.compositeWatermarkPipeline = compositeWatermarkPipeline
        self.flowLumaPipeline = flowLumaPipeline
        self.flowEstimatePipeline = flowEstimatePipeline
        self.flowAccumulatePipeline = flowAccumulatePipeline
        self.flowClearPipeline = flowClearPipeline
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
        renderGraph.failurePolicy = .bypass
        renderGraph.onFailure = { identifier, message in
            GVLog.rendering.error("Render graph bypassed \(identifier): \(message)")
        }
        commandQueue.label = "greyVISION Camera Command Queue"
        GVLog.rendering.notice("Camera Metal renderer initialized")
    }

    // swiftlint:disable:next function_parameter_count
    func update(
        rgbSplitParameters: RGBSplitEffectParameters,
        effectStack: CameraEffectStackParameters,
        isSynthetic: Bool,
        sourceIdentifier: String,
        audioSnapshot: AudioReactiveSnapshot,
        audioIntensity: Float,
        blobFields: [SIMD4<Float>],
        scanlineParameters: ScanlineEffectParameters,
        overlays: SIMD4<Float> = .zero,
        screenScale: Float
    ) {
        let activeStyleModes = effectStack.orderedSlots.compactMap { slot -> UInt32? in
            guard slot.parameters.sanitized.isEnabled else { return nil }
            return slot.effect.styleMode
        }
        settingsLock.withLock {
            self.rgbSplitParameters = rgbSplitParameters.sanitized
            self.effectStack = effectStack
            self.isSynthetic = isSynthetic
            self.sourceIdentifier = sourceIdentifier
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
            self.overlays = overlays
            self.screenScale = screenScale
        }
        // Never compile a 140-arm specialization on the main or render thread.
        // The generic kernel remains correct until this cache entry is ready.
        for mode in Set(activeStyleModes) {
            scheduleStylePipelineSpecialization(for: mode)
        }
    }

    func setTemporalHoldActive(_ isActive: Bool) {
        settingsLock.withLock {
            temporalHoldActive = isActive
        }
    }

    /// The tier the operator pinned in the workspace settings.
    ///
    /// Separate from `update(...)` for the same reason the broadcast engine
    /// is: it changes when the operator chooses, not sixty times a second.
    /// Without it the setting is written to preferences and shown in the badge
    /// while the chain keeps rendering on the governor's own idea of quality.
    func setRenderQuality(_ quality: GVRenderQuality) {
        settingsLock.withLock {
            requestedQuality = quality
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
                sourceIdentifier: sourceIdentifier,
                temporalHoldActive: temporalHoldActive,
                audio: audio,
                audioDynamics: audioDynamics,
                audioSpectrum: audioSpectrum,
                blobs: blobFields,
                scanlines: scanlineParameters,
                overlays: overlays
            )
        }
        let touchState = touchMailbox.latest
        let touchVector = SIMD4<Float>(
            touchState.position.x,
            touchState.position.y,
            min(length(touchState.velocity) * 0.75, 2),
            touchState.isActive ? 1 : 0
        )
        let touchDragVector = SIMD4<Float>(
            touchState.velocity.x,
            touchState.velocity.y,
            0,
            touchState.isActive && length(touchState.velocity) > 0.001 ? 1 : 0
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
            if !settings.temporalHoldActive || !hasLinearFrame {
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
            }
        } else if settings.temporalHoldActive && hasLinearFrame {
            // Frame is held/frozen: reuse the existing linearTexture and geometry,
            // continuing to run effects and interactive shaders on top of the frozen capture.
            _ = mailbox.consumeLatest() // Clear queue so we don't build backlog
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

        guard hasLinearFrame, let linearTexture,
              let effectTextureA, let effectTextureB
        else { return }

        let renderTime = ProcessInfo.processInfo.systemUptime
        let effectTime = Float(renderTime)
        let deltaTime = min(max(renderTime - (previousRenderTime ?? renderTime - 1 / 60), 1 / 240), 0.25)
        previousRenderTime = renderTime
        let holdSeconds: Float
        if settings.temporalHoldActive {
            if temporalHoldBeganAt == nil {
                temporalHoldBeganAt = renderTime
            }
            holdSeconds = Float(max(renderTime - (temporalHoldBeganAt ?? renderTime), 0))
        } else {
            temporalHoldBeganAt = nil
            holdSeconds = 0
        }
        renderFrameIndex &+= 1

        // Reset memory when source geometry changes even if working texture
        // dimensions happen to stay equal (rotation or front/back switching).
        let geometry = geometryLock.withLock { sourceGeometry }
        // Compared as a value, not as a string. This used to interpolate a
        // `\(sourceIdentifier)-\(isSynthetic)-\(width)x\(height)-...`
        // signature every frame and compare it against a stored `String?` —
        // a heap allocation and a full string comparison at 60–120 Hz, purely
        // to notice that the camera had not rotated since last frame.
        let sourceSignature = CameraSourceSignature(
            identifier: settings.sourceIdentifier,
            isSynthetic: settings.isSynthetic,
            geometry: geometry
        )
        if let previous = temporalSourceSignature, previous != sourceSignature {
            graphNodes.values.forEach { $0.reset(reason: .sourceChanged) }
            flowField.reset()
            temporalEngine.reset()
            temporalFrames.release()
            hasHistoryFrame = false
        }
        temporalSourceSignature = sourceSignature
        // Both of these walk the slot list, and both are derived purely from
        // the composition. Recomputing them every frame meant two array
        // allocations and a union fold per frame for a value that only changes
        // when the operator edits something. Cached against the stack's own
        // revision, which every mutation advances.
        let temporalEffects = temporalEffectCache.resolve(for: settings.effectStack) { stack in
            stack.activeTemporalEffects.filter { $0.1.blend > 0 }
        }
        let requirements = requirementCache.resolve(for: settings.effectStack) { stack in
            stack.orderedSlots.reduce(into: CameraEffectResourceRequirements()) { result, slot in
                if slot.parameters.isEnabled, slot.parameters.blend > 0 {
                    result.formUnion(slot.effect.cameraResourceRequirements)
                }
            }
        }
        let needsSharedHistory = temporalEffects.contains { !$0.0.cameraResourceRequirements.contains(.slotHistory) }
        if needsSharedHistory {
            if historyTexture?.width != linearTexture.width || historyTexture?.height != linearTexture.height {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                          width: linearTexture.width, height: linearTexture.height, mipmapped: false)
                descriptor.storageMode = .private
                descriptor.usage = [.shaderRead, .shaderWrite]
                historyTexture = device.makeTexture(descriptor: descriptor)
                historyTexture?.label = "greyVISION Temporal History"
                hasHistoryFrame = false
            }
        } else {
            historyTexture = nil
            hasHistoryFrame = false
        }
        let fractureState = resolvedFractureState()
        let needsFlow = requirements.contains(.opticalFlow)
        let needsRing = requirements.contains(.timestampedHistory)
        let needsTaps = requirements.contains(.legacyHistoryTaps) || fractureState.phase.isEngaged
        if !needsFlow, flowField.current != nil { flowField.reset() }
        if !needsRing, temporalEngine.texture != nil { temporalEngine.reset() }
        if !needsTaps, !temporalFrames.textures.isEmpty { temporalFrames.release() }
        let thermal = ProcessInfo.processInfo.thermalState
        // Adopt the pinned tier before the governor runs, so a pinned choice is
        // the rung the governor starts from rather than something it undoes.
        effectQuality.applyRequestedTier(settingsLock.withLock { requestedQuality })
        effectQuality.update(stats: statsMailbox.latest, fps: view.preferredFramesPerSecond,
                             thermalPressure: thermal == .serious || thermal == .critical)
        // Shared inputs are estimated once from the clean camera image.
        let flowReady = needsFlow && flowField.prepare(
            sourceWidth: linearTexture.width,
            sourceHeight: linearTexture.height,
            maximumEdge: effectQuality.flowEdge
        )
        // The flow field needs the OR of every mosh-style mode's hold bits
        // so MOTION LOCK is set when any of them are running while frozen.
        let freezeEffectBits = temporalEffects.reduce(into: UInt32(0)) { acc, slot in
            guard slot.0.freezesHistoryOnHold, slot.0.temporalMode != nil else { return }
            acc |= holdStyle(for: slot.0, freezeActive: settings.temporalHoldActive)
        }
        if flowReady {
            encodeFlow(
                source: linearTexture,
                settings: settings,
                holdStyle: freezeEffectBits,
                holdSeconds: holdSeconds,
                commandBuffer: commandBuffer
            )
        }
        renderMotionField.bindPrimaryVectorTexture(flowReady ? flowField.persistent : nil)
        renderMotionField.setVector(touchState.velocity, for: .touch)
        renderMotionField.update(deltaTime: deltaTime)

        // Timestamped ring. Recorded from the clean source before effects so
        // history holds the camera image, not the previous frame's corruption
        // fed back into itself.
        let temporalReady = needsRing && temporalEngine.prepare(
            sourceWidth: linearTexture.width,
            sourceHeight: linearTexture.height
        )
        if temporalReady, temporalEngine.shouldRecord() {
            encodeTemporalRecord(source: linearTexture, commandBuffer: commandBuffer)
        }

        let ringReady = needsTaps && temporalFrames.prepare(
            sourceWidth: linearTexture.width,
            sourceHeight: linearTexture.height
        )
        if ringReady, !temporalFrames.isPrimed {
            encodeHistoryTaps(source: linearTexture, commandBuffer: commandBuffer)
        }
        let historyTaps = ringReady ? temporalFrames.textures : []
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
                aspect: Float(linearTexture.width) / Float(max(linearTexture.height, 1))
            )
            : matrix_identity_float3x3
        let shouldFreezeTemporalHistory = settings.temporalHoldActive &&
            temporalEffects.contains(where: \.0.freezesHistoryOnHold)

        let effectDimensions = RenderDimensions(width: linearTexture.width, height: linearTexture.height)
        let frame = FrameContext(
            frameIndex: renderFrameIndex,
            timestamp: renderTime,
            deltaTime: deltaTime,
            sourceTexture: linearTexture,
            previousSourceTexture: nil,
            resolutions: RenderResolutionSet(
                capture: RenderDimensions(width: max(geometry.width, 1), height: max(geometry.height, 1)),
                preview: RenderDimensions(
                    width: max(Int(view.drawableSize.width), 1),
                    height: max(Int(view.drawableSize.height), 1)
                ),
                effects: effectDimensions,
                output: effectDimensions
            ),
            orientation: RenderOrientationState(
                source: geometry.orientation,
                render: geometry.orientation,
                display: geometry.orientation,
                record: geometry.orientation,
                isMirrored: geometry.isMirrored
            ),
            colorPipeline: .cameraSDR,
            cameraMetadata: CameraFrameMetadata(
                presentationTime: CMTime(seconds: renderTime, preferredTimescale: 600),
                exposureDurationSeconds: nil,
                iso: nil,
                lensPosition: nil,
                whiteBalanceTemperature: nil,
                sourceIdentifier: settings.isSynthetic ? "synthetic" : "camera"
            ),
            temporalBuffers: renderTemporalBuffers,
            motionField: renderMotionField.snapshot(),
            interaction: RenderInteractionState(
                position: touchState.position,
                velocity: touchState.velocity,
                drag: touchState.velocity,
                impactPosition: touchState.impactPosition,
                impactAge: touchState.impactTime.map { max(renderTime - $0, 0) },
                isActive: touchState.isActive
            ),
            modulation: .empty,
            commandBuffer: commandBuffer
        )
        graphFrameState = CameraRenderGraphFrameState(
            settings: settings,
            time: effectTime,
            deltaTime: Float(deltaTime),
            holdSeconds: holdSeconds,
            touch: touchVector,
            touchImpact: touchImpactVector,
            touchDrag: touchDragVector,
            historyTaps: historyTaps,
            worldMatrix: worldMatrix,
            temporalRing: temporalReady ? temporalEngine : nil,
            shouldFreezeTemporalHistory: shouldFreezeTemporalHistory,
            quality: effectQuality.resolvedTier
        )
        configureRenderGraph(
            settings: settings,
            includeTemporalEffects: hasHistoryFrame && historyTexture != nil
        )
        // A Composition is authoritative. Never skip visible Slots as a
        // performance tradeoff; optimisation must not alter the image.
        statsLock.withLock { shedEffectSnapshot = 0 }
        let graphResult = renderGraph.process(
            input: linearTexture,
            frame: frame,
            scratchTextures: (effectTextureA, effectTextureB)
        )
        var presentedTexture = graphResult.texture

        let shouldWriteHistory = !hasHistoryFrame ||
            (!shouldFreezeTemporalHistory && !temporalEffects.contains(where: { $0.0 == WorkspaceAdjustableEffect.freeze }))
        if !needsSharedHistory {
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
        let fractureDestination = ObjectIdentifier(presentedTexture) == ObjectIdentifier(effectTextureA)
            ? effectTextureB
            : effectTextureA
        if hasHistory, fractureState.phase.isEngaged {
            encodeSignalFracture(
                fractureState,
                source: presentedTexture,
                destination: fractureDestination,
                drawableSize: view.drawableSize,
                commandBuffer: commandBuffer
            )
            presentedTexture = fractureDestination
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
            scanlineFlags: scanlineValues.1,
            overlays: settings.overlays
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
        let (shouldStart, codecRawValue, fps, burnHUD) = recordingMailbox.consumeStartRequest()
        if shouldStart, recordingSession == nil {
            startRecording(
                size: CGSize(
                    width: CGFloat(presentedTexture.width),
                    height: CGFloat(presentedTexture.height)
                ),
                codecRawValue: codecRawValue,
                fps: fps,
                burnHUD: burnHUD
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
        let reducedDetail = effectQuality.reducedDetail
        commandBuffer.addCompletedHandler { [weak self] buffer in
            _ = retainedLease
            if let bandSlot {
                self?.readBandLuma(slot: bandSlot)
            }
            self?.recordCompletion(buffer, reducedDetail: reducedDetail)
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

    private func configureRenderGraph(
        settings: CameraRenderSettings,
        includeTemporalEffects: Bool
    ) {
        var effects: [any RenderEffect] = []
        var activeSlotIDs = Set<UUID>()

        if settings.rgbSplit.isEnabled {
            rgbGraphNode.configure(
                stage: .rgbSplit,
                parameters: CameraEffectParameters(),
                rgbSplit: settings.rgbSplit,
                mix: Float(settings.rgbSplit.mix)
            )
            effects.append(rgbGraphNode)
        }

        for slot in settings.effectStack.orderedSlots {
            let parameters = slot.parameters.sanitized
            guard parameters.isEnabled, parameters.blend > 0 else { continue }

            let stage: CameraRenderGraphStage
            if slot.effect == .fluid {
                stage = .fluid
            } else if slot.effect == .reactionGarden {
                stage = .reactionDiffusion
            } else if slot.effect.styleMode != nil {
                stage = .style(slot.effect)
            } else if slot.effect.temporalMode != nil, includeTemporalEffects || slot.effect.cameraResourceRequirements.contains(.slotHistory) {
                stage = .temporal(slot.effect)
            } else {
                continue
            }

            activeSlotIDs.insert(slot.id)
            let node: CameraRenderGraphNode
            if let existing = graphNodes[slot.id] {
                node = existing
            } else {
                node = CameraRenderGraphNode(identifier: "slot.\(slot.id.uuidString)", owner: self)
                graphNodes[slot.id] = node
            }
            node.configure(
                stage: stage,
                parameters: parameters,
                rgbSplit: nil,
                mix: Float(parameters.blend)
            )
            effects.append(node)
        }

        let staleSlotIDs = graphNodes.keys.filter { !activeSlotIDs.contains($0) }
        for id in staleSlotIDs {
            graphNodes.removeValue(forKey: id)?.releaseResources()
        }
        renderGraph.replaceEffects(effects)
    }

    fileprivate func processGraphNode(
        _ node: CameraRenderGraphNode,
        request: EffectRenderRequest
    ) throws {
        guard let state = graphFrameState else {
            throw RenderEffectError.processingFailed("Missing camera graph frame state")
        }

        switch node.stage {
        case .rgbSplit:
            guard let parameters = node.rgbSplitParameters else {
                throw RenderEffectError.processingFailed("Missing RGB split parameters")
            }
            encodeRGBSplit(
                parameters,
                source: request.input,
                destination: request.output,
                commandBuffer: request.frame.commandBuffer
            )

        case let .style(effect):
            encodeStyleEffect(
                effect,
                parameters: node.cameraParameters,
                source: request.input,
                destination: request.output,
                commandBuffer: request.frame.commandBuffer,
                time: state.time,
                audio: state.settings.audio,
                audioDynamics: state.settings.audioDynamics,
                audioSpectrum: state.settings.audioSpectrum,
                touch: state.touch,
                touchImpact: state.touchImpact,
                touchDrag: state.touchDrag,
                blobs: state.settings.blobs
            )

        case .fluid:
            if node.fluidSolver == nil, let shaderLibrary {
                node.fluidSolver = CameraFluidSolver(device: device, library: shaderLibrary)
            }
            guard let solver = node.fluidSolver else {
                throw RenderEffectError.unavailable("Fluid solver unavailable")
            }
            let now = request.frame.timestamp
            let delta = node.lastFluidTime > 0
                ? Float(min(max(now - node.lastFluidTime, 1.0 / 120.0), 1.0 / 20.0))
                : Float(1.0 / 60.0)
            node.lastFluidTime = now
            let parameters = node.cameraParameters
            guard solver.encode(
                commandBuffer: request.frame.commandBuffer,
                source: request.input,
                destination: request.output,
                touch: state.touch,
                parameters: CameraFluidParameters(
                    drag: parameters.primary,
                    persistence: parameters.secondary,
                    swirl: parameters.tertiary
                ),
                blend: Float(parameters.blend),
                deltaTime: delta,
                quality: state.quality
            ) else {
                throw RenderEffectError.processingFailed("Fluid solver did not encode")
            }

        case .reactionDiffusion:
            if node.reactionSolver == nil, let shaderLibrary {
                node.reactionSolver = CameraReactionDiffusion(device: device, library: shaderLibrary)
            }
            guard let solver = node.reactionSolver,
                  solver.encode(commandBuffer: request.frame.commandBuffer,
                                source: request.input, destination: request.output,
                                parameters: node.cameraParameters, touch: state.touch,
                                time: request.frame.timestamp, held: state.settings.temporalHoldActive,
                                maximumEdge: effectQuality.simulationEdge)
            else {
                throw RenderEffectError.processingFailed("Reaction Garden did not encode")
            }

        case let .temporal(effect):
            // Mosh slots seed and own their recursive image; other temporal
            // algorithms share the composition history allocated on demand.
            let historyTexture = historyTexture ?? request.input
            let freezeForEffect = state.shouldFreezeTemporalHistory && effect.freezesHistoryOnHold
            let modeValue = effect.temporalMode ?? 0
            let requiresMoshState = isMoshMode(modeValue)
            let moshState = requiresMoshState
                ? prepareMoshState(
                    for: node,
                    width: request.output.width,
                    height: request.output.height,
                    commandBuffer: request.frame.commandBuffer
                )
                : nil
            if requiresMoshState, moshState == nil {
                // Never bind full-resolution image history as the writeable
                // block-state fallback: that aliases a sampled texture and
                // corrupts the very reference the effect is trying to carry.
                throw RenderEffectError.resourceAllocationFailed("Mosh Slot state unavailable")
            }
            let moshHistory = requiresMoshState
                ? prepareMoshHistory(
                    for: node,
                    width: request.output.width,
                    height: request.output.height
                )
                : nil
            if requiresMoshState, moshHistory == nil {
                throw RenderEffectError.resourceAllocationFailed("Mosh Slot history unavailable")
            }
            if let moshHistory, node.moshHistoryNeedsSeed {
                encodeHistoryCopy(
                    source: request.input,
                    destination: moshHistory,
                    commandBuffer: request.frame.commandBuffer
                )
                node.moshHistoryNeedsSeed = false
            }
            encodeTemporalEffect(
                effect,
                parameters: node.cameraParameters,
                source: request.input,
                history: moshHistory ?? historyTexture,
                historyTaps: state.historyTaps,
                flow: request.frame.motionField.vectorTexture,
                worldMatrix: state.worldMatrix,
                ring: state.temporalRing,
                destination: request.output,
                commandBuffer: request.frame.commandBuffer,
                time: state.time,
                holdActive: freezeForEffect,
                holdStyle: holdStyle(for: effect, freezeActive: freezeForEffect),
                holdSeconds: state.holdSeconds,
                deltaTime: state.deltaTime,
                audio: state.settings.audio,
                audioDynamics: state.settings.audioDynamics,
                audioSpectrum: state.settings.audioSpectrum,
                touch: state.touch,
                touchImpact: state.touchImpact,
                touchDrag: state.touchDrag,
                moshState: moshState,
                blobs: state.settings.blobs
            )
            // Mosh modes write into the output half of the ping-pong pair; swap
            // so the next frame reads what this one just produced.
            if moshState != nil {
                node.moshStateReadsA.toggle()
            }
            if let moshHistory {
                // Capture this Slot's output after its kernel, before a later
                // Slot mutates the Composition. Command encoders are ordered
                // within the buffer, so no second full-frame ping-pong pair is
                // necessary here.
                encodeHistoryCopy(
                    source: request.output,
                    destination: moshHistory,
                    commandBuffer: request.frame.commandBuffer
                )
            }
        }
    }

    /// Bitmask the mosh engine reads as `holdStyle` while a hold is active.
    /// Each mosh variant opts into a subset of the four behaviours encoded in
    /// the shader: motion lock, feedback runaway, frame starvation, and vector
    /// drift. The defaults were tuned against the same sliders as the live
    /// paths so the held state is the same image family at a different clock.
    private func holdStyle(for effect: WorkspaceAdjustableEffect, freezeActive: Bool) -> UInt32 {
        guard freezeActive else { return 0 }
        switch effect {
        case .datamosh, .heavyMosh, .vectorCodebook, .motionTransplant, .bitplaneLatch:
            // MOTION LOCK keeps vectors on their captured course; FEEDBACK
            // RUNAWAY pulls refresh chance toward zero so a held frame
            // consumes itself.
            return 0b0010 | 0b0100
        case .liquidMosh:
            return 0b0100
        case .moshBrush, .predictionDrift:
            // VECTOR DRIFT lets the frozen prediction field keep mutating, so
            // the smear does not collapse to a single displacement.
            return 0b0100 | 0b10000
        default:
            return 0
        }
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
        ), let image = context.makeImage() else {
            onScreenshotMessage("SCREENSHOT // ENCODE FAILED")
            return
        }
        GVScreenCapture.save(UIImage(cgImage: image)) { [onScreenshotMessage] message in
            onScreenshotMessage(message)
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

    /// Prepares a Full HD bounded-size pooled pixel buffer for the link. The local
    /// preview may be 4K/60, but copying and encoding a second 4K frame stream
    /// can saturate the shared GPU/video path and stall the phone interface.
    private func makeBroadcastLease(texture source: MTLTexture) -> CameraBroadcastLease? {
        let longEdge = max(source.width, source.height)
        let scale = min(1.0, 1920.0 / Double(longEdge))
        let width = max(2, (Int(Double(source.width) * scale) / 2) * 2)
        let height = max(2, (Int(Double(source.height) * scale) / 2) * 2)

        guard let engine = settingsLock.withLock({ broadcastEngine }), engine.isConnected,
              let pixelBuffer = broadcastPool.buffer(width: width, height: height),
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
        let metalFormat: MTLPixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_64RGBAHalf
            ? .rgba16Float
            : .bgra8Unorm
        var lease: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            metalFormat,
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

    private func startRecording(size: CGSize, codecRawValue: String, fps _: Int, burnHUD: Bool) {
        guard size.width > 0, size.height > 0 else { return }

        // Capture current orientation from source geometry
        let geometry = geometryLock.withLock { sourceGeometry }
        let videoOrientation: CGImagePropertyOrientation
        let isMirrored = geometry.isMirrored
        switch geometry.orientation {
        case .portrait:
            videoOrientation = isMirrored ? .upMirrored : .up
        case .portraitUpsideDown:
            videoOrientation = isMirrored ? .downMirrored : .down
        case .landscapeLeft:
            videoOrientation = isMirrored ? .leftMirrored : .left
        case .landscapeRight:
            videoOrientation = isMirrored ? .rightMirrored : .right
        }

        let codec = AVVideoCodecType(rawValue: codecRawValue)
        let ext = codecRawValue.lowercased().contains("hevc") || codecRawValue.lowercased().contains("hvc1") ? "mov" : "mov" // All mov
        let timestamp = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("greyvision-camera-\(timestamp).\(ext)")
        let session = GVRealtimeRecordingSession(
            outputURL: url,
            size: size,
            saveToPhotos: true,
            codec: codec,
            burnHUD: burnHUD
        )
        session.videoOrientation = videoOrientation
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

    /// Signal Fracture always samples its complete temporal ring; reducing the
    /// tap count would alter an active Composition.
    private var adaptiveTapCount: Int {
        TemporalFrameBuffer.strides.count
    }

    private func recordCompletion(_ buffer: MTLCommandBuffer, reducedDetail: Bool) {
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
                shedEffects: shedEffectSnapshot,
                reducedDetail: reducedDetail
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
        holdStyle: UInt32,
        holdSeconds: Float,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let currentLuma = flowField.currentLuma,
              let previousLuma = flowField.previousLuma,
              let current = flowField.current,
              let previous = flowField.previous,
              let persistent = flowField.persistent,
              let persistentOutput = flowField.persistentOutput,
              let frozen = flowField.frozen,
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return
        }

        let (width, height) = flowField.size
        // The flow field needs the same `holdStyle` / `holdSeconds` pair the
        // mosh engine consumes, so the persistent motion vector can either
        // stay locked to its captured course (MOTION LOCK) or bleed away
        // under an exponential decay. Without these the field would either
        // snap to zero or repeat the same vector forever on every held frame.
        let packedHoldSeconds = UInt32(min(max(holdSeconds, 0) * 65536.0, 4294967295.0))
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
            //
            // Search radius was 6, bumped to 9 so the first step of the
            // three-step log search covers a wider area; the seed is the
            // previous frame's motion and a fast pan can outrun a 6-texel
            // radius, leaving the search locked to a stale vector.
            //
            // Persistence was 0.82, dropped to 0.55 so the persistent field
            // tracks the live estimate on the same frame the estimate
            // changes. The effect is that datamosh / motion hold / motion
            // transplant follow the camera instead of trailing it by a frame.
            controls: SIMD4<Float>(9, 0.55, 0.10, 1.0),
            flags: SIMD4<UInt32>(
                // The rising-edge frame still accumulates live flow, then
                // snapshots that finished result below. Reading `frozen`
                // before the snapshot used undefined private-texture memory.
                settings.temporalHoldActive && flowField.hasSnapshot ? 1 : 0,
                0,
                holdStyle,
                packedHoldSeconds
            )
        )

        encoder.label = "greyVISION Optical Flow"

        if flowField.needsClear {
            encoder.setComputePipelineState(flowClearPipeline)
            for texture in [current, previous, persistent, persistentOutput, frozen] {
                encoder.setTexture(texture, index: 0)
                dispatch(encoder, pipeline: flowClearPipeline, texture: texture)
            }
            flowField.markCleared()
        }

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
            encoder.setTexture(persistentOutput, index: 3)
            encoder.setBytes(&uniforms, length: MemoryLayout<FlowUniforms>.stride, index: 0)
            dispatch(encoder, pipeline: flowAccumulatePipeline, texture: persistentOutput)
        }

        encoder.endEncoding()

        let accumulatedFlow = flowField.isPrimed
        if accumulatedFlow {
            // Consumers bind `persistent`, so rotate the completed write into
            // that role before the temporal graph is encoded.
            flowField.advancePersistent()
        }

        // MOTION HOLD captures on the rising edge. Copying the field once, at
        // the moment the finger lands, is what lets the held motion keep
        // driving displacement while live frames continue to arrive.
        if settings.temporalHoldActive, !flowField.hasSnapshot, accumulatedFlow {
            if let captured = flowField.persistent,
               let blit = commandBuffer.makeBlitCommandEncoder()
            {
                blit.label = "greyVISION Flow Snapshot"
                blit.copy(from: captured, to: frozen)
                blit.endEncoding()
                flowField.markSnapshot()
            }
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
        renderGraph.effects.forEach { $0.releaseResources() }
        renderGraph.replaceEffects([])
        graphNodes.removeAll(keepingCapacity: false)
        rgbGraphNode.releaseResources()
        renderTexturePool.purgeAvailable()
        renderTemporalBuffers.reset(reason: .renderRestarted)
        renderMotionField.reset()
        graphFrameState = nil
        previousRenderTime = nil
        temporalSourceSignature = nil
        temporalHoldBeganAt = nil
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
        let isHoldingFullResolution = recordingSession != nil
            || recordingMailbox.isStartPending
            || screenshotMailbox.isCapturePending
        if isHoldingFullResolution {
            // Held for a moment after, so a burst of stills does not resize the
            // chain — and the history with it — once per press.
            fullResolutionHold = 24
        } else if fullResolutionHold > 0 {
            fullResolutionHold -= 1
        }
        // A take in progress outranks the governor. The recorded file has to
        // match what the operator was looking at, not whatever rung the
        // preview happened to have settled on when they hit record.
        effectQuality.setFullResolutionHold(fullResolutionHold > 0)

        return CameraChainResolution.resolve(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            drawablePixels: Double(drawableSize.width * drawableSize.height),
            fullResolution: fullResolutionHold > 0,
            renderScale: effectQuality.renderScale
        )
    }

    private func ensureWorkingTextures(width: Int, height: Int) -> Bool {
        let texturesMatch = linearTexture?.width == width &&
            linearTexture?.height == height &&
            effectTextureA?.width == width &&
            effectTextureA?.height == height &&
            effectTextureB?.width == width &&
            effectTextureB?.height == height
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
              let effectTextureB = device.makeTexture(descriptor: descriptor)
        else {
            return false
        }
        linearTexture.label = "greyVISION Linear Camera Frame"
        effectTextureA.label = "greyVISION Effect Ping"
        effectTextureB.label = "greyVISION Effect Pong"
        self.linearTexture = linearTexture
        self.effectTextureA = effectTextureA
        self.effectTextureB = effectTextureB
        historyTexture = nil
        renderGraph.effects.forEach { $0.reset(reason: .formatChanged) }
        renderTemporalBuffers.reset(reason: .renderRestarted)
        renderMotionField.reset()
        hasLinearFrame = false
        hasHistoryFrame = false
        return true
    }

    private func prepareMoshState(
        for node: CameraRenderGraphNode,
        width: Int,
        height: Int,
        commandBuffer: MTLCommandBuffer
    ) -> (input: MTLTexture, output: MTLTexture)? {
        let stateWidth = max((width + 7) / 8, 1)
        let stateHeight = max((height + 7) / 8, 1)
        let matches = node.moshStateA?.width == stateWidth &&
            node.moshStateA?.height == stateHeight &&
            node.moshStateB?.width == stateWidth &&
            node.moshStateB?.height == stateHeight

        if !matches {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,
                width: stateWidth,
                height: stateHeight,
                mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            guard let stateA = device.makeTexture(descriptor: descriptor),
                  let stateB = device.makeTexture(descriptor: descriptor),
                  let encoder = commandBuffer.makeComputeCommandEncoder()
            else {
                return nil
            }
            stateA.label = "\(node.identifier) Mosh State A"
            stateB.label = "\(node.identifier) Mosh State B"
            encoder.label = "greyVISION Slot Mosh State Clear"
            encoder.setComputePipelineState(moshClearStatePipeline)
            encoder.setTexture(stateA, index: 0)
            dispatch(encoder, pipeline: moshClearStatePipeline, texture: stateA)
            encoder.setTexture(stateB, index: 0)
            dispatch(encoder, pipeline: moshClearStatePipeline, texture: stateB)
            encoder.endEncoding()
            node.moshStateA = stateA
            node.moshStateB = stateB
            node.moshStateReadsA = true
        }

        guard let stateA = node.moshStateA, let stateB = node.moshStateB else { return nil }
        return node.moshStateReadsA ? (stateA, stateB) : (stateB, stateA)
    }

    private func prepareMoshHistory(
        for node: CameraRenderGraphNode,
        width: Int,
        height: Int
    ) -> MTLTexture? {
        if let history = node.moshHistory,
           history.width == width,
           history.height == height
        {
            return history
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let history = device.makeTexture(descriptor: descriptor) else { return nil }
        history.label = "\(node.identifier) Mosh History"
        node.moshHistory = history
        node.moshHistoryNeedsSeed = true
        return history
    }

    private func isMoshMode(_ mode: UInt32) -> Bool {
        switch mode {
        case 4, 39, 40, 41, 43, 44, 45, 46:
            true
        default:
            false
        }
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
        audioDynamics: SIMD4<Float>,
        audioSpectrum: CameraAudioSpectrum,
        touch: SIMD4<Float>,
        touchImpact: SIMD4<Float>,
        touchDrag: SIMD4<Float>,
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
            // `extra.yz` are intentionally reserved for freeform scope
            // placement. Other style modes leave them unread, while spectrum
            // slots retain their own position when duplicated or recorded.
            extra: SIMD4<Float>(
                Float(values.blend),
                Float(values.overlayX),
                Float(values.overlayY),
                0
            ),
            audio: audio,
            touch: touch,
            touchImpact: touchImpact,
            touchDrag: touchDrag,
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
        let pipeline = stylePipeline(for: mode)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(
            &uniforms,
            length: MemoryLayout<CameraStyleEffectUniforms>.stride,
            index: 0
        )
        dispatch(encoder, pipeline: pipeline, texture: destination)
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
        holdStyle: UInt32,
        holdSeconds: Float,
        deltaTime: Float,
        audio: SIMD4<Float>,
        audioDynamics: SIMD4<Float>,
        audioSpectrum: CameraAudioSpectrum,
        touch: SIMD4<Float>,
        touchImpact: SIMD4<Float>,
        touchDrag: SIMD4<Float>,
        moshState: (input: MTLTexture, output: MTLTexture)?,
        blobs: [SIMD4<Float>]
    ) {
        guard let mode = effect.temporalMode,
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return
        }
        let values = parameters.sanitized
        let packedDelta = UInt32(min(max(deltaTime, 1.0 / 240.0) * 65536.0, 4294967295.0))
        var uniforms = CameraStyleEffectUniforms(
            mode: SIMD4<UInt32>(mode, holdStyle, packedDelta, 0),
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
                max(holdSeconds, 0)
            ),
            audio: audio,
            touch: touch,
            touchImpact: touchImpact,
            touchDrag: touchDrag,
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
        // Slots 9 and 10 are the mosh engine's block-state field. Non-mosh
        // modes never read them, but Metal still requires the bindings to be
        // populated; the history texture stands in so the first frame after a
        // resolution change is still well-defined.
        if let moshState {
            encoder.setTexture(moshState.input, index: 9)
            encoder.setTexture(moshState.output, index: 10)
        } else {
            encoder.setTexture(history, index: 9)
            encoder.setTexture(history, index: 10)
        }
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
        // Filling the hardware maximum produced 32x32 (1,024-thread) groups on
        // current Apple GPUs. Heavy FBM/raymarch kernels then kept too many
        // registers live for a second resident group. Four to eight SIMDgroups
        // is the better occupancy/boundary-efficiency balance for this 2D work.
        let targetThreads = min(256, pipeline.maxTotalThreadsPerThreadgroup)
        let height = max(1, targetThreads / width)
        encoder.dispatchThreads(
            MTLSize(width: texture.width, height: texture.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
        )
    }

    /// Returns a mode-specialized kernel when ready, otherwise the generic
    /// kernel. Every thread in a pass uses one mode, so specialization lets the
    /// compiler dead-strip the giant switch without changing Composition order
    /// or introducing a first-use hitch.
    private func stylePipeline(for mode: UInt32) -> MTLComputePipelineState {
        if let pipeline = stylePipelineCacheLock.withLock({ styleEffectPipelines[mode] }) {
            return pipeline
        }
        scheduleStylePipelineSpecialization(for: mode)
        return styleEffectPipeline
    }

    private func scheduleStylePipelineSpecialization(for mode: UInt32) {
        let shouldCompile = stylePipelineCacheLock.withLock { () -> Bool in
            guard styleEffectPipelines[mode] == nil,
                  !pendingStylePipelineModes.contains(mode),
                  !failedStylePipelineModes.contains(mode)
            else {
                return false
            }
            pendingStylePipelineModes.insert(mode)
            return true
        }
        guard shouldCompile else { return }

        stylePipelineCompilationQueue.async { [weak self] in
            guard let self, let shaderLibrary = self.shaderLibrary else { return }
            var specializedMode = mode
            let constants = MTLFunctionConstantValues()
            constants.setConstantValue(
                &specializedMode,
                type: .uint,
                index: CameraMetalShaderNames.styleModeFunctionConstantIndex
            )
            let function = try? shaderLibrary.makeFunction(
                name: CameraMetalShaderNames.styleEffect,
                constantValues: constants
            )
            let pipeline = function.flatMap {
                try? self.device.makeComputePipelineState(function: $0)
            }

            self.stylePipelineCacheLock.withLock {
                self.pendingStylePipelineModes.remove(mode)
                if let pipeline {
                    self.styleEffectPipelines[mode] = pipeline
                } else {
                    // Keep using the correct generic kernel, but do not turn a
                    // device-specific compiler rejection into a retry every
                    // render frame.
                    self.failedStylePipelineModes.insert(mode)
                }
            }
            if pipeline == nil {
                GVLog.rendering.warning("Style PSO specialization unavailable for mode \(mode)")
            }
        }
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
