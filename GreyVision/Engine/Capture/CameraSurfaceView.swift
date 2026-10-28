import Foundation
import SwiftUI

struct CameraSurfaceView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var preferences: GVPreferences
    @EnvironmentObject private var cameraRuntime: CameraRuntime
    @EnvironmentObject private var depthRuntime: DepthRuntime
    @EnvironmentObject private var objectsRuntime: ARObjectRuntime
    @EnvironmentObject private var audioRuntime: AudioReactiveRuntime
    @EnvironmentObject private var blobRuntime: BlobTrackingRuntime
    @EnvironmentObject private var broadcastRuntime: GVBroadcastRuntime
    @ObservedObject var fracture: SignalFractureController
    let rgbSplitParameters: RGBSplitEffectParameters
    let effectStack: CameraEffectStackParameters
    let statsMailbox: CameraRenderStatsMailbox
    let onPreviewTap: @MainActor @Sendable () -> Void
    /// Forwarded straight to the underlying `CameraMetalSurface` so a tap on
    /// the live preview also focuses the camera at that point. The default is
    /// a no-op so the call site can pass nothing when the view is constructed
    /// inside the camera runtime's environment.
    var onFocus: @MainActor @Sendable (CGPoint) -> Void = { _ in }
    /// Recording transaction for lifecycle callbacks from the renderer.
    var recordingTransaction: GVRecordingTransaction?
    /// Freeform spectrum overlays own preview drags and pinches only while one
    /// is being edited. Other effects continue to receive the normal touch
    /// uniforms without changing their persisted parameters.
    var onSpectrumOverlayDrag: @MainActor @Sendable (SIMD2<Float>) -> Void = { _ in }
    var onSpectrumOverlayPinch: @MainActor @Sendable (CameraOverlayPinchEvent) -> Void = { _ in }
    /// True when a preview drag or pinch on a spectrum overlay starts, false
    /// when it ends, so the editor can record the whole gesture as one undo
    /// step instead of one per frame.
    var onOverlayGesturePhase: @MainActor @Sendable (Bool) -> Void = { _ in }

    @State private var metalFailed = false
    @State private var focusReticlePoint: CGPoint? = nil

    var body: some View {
        Group {
            if appModel.sourceMode == .lidar {
                depthSurface
            } else if appModel.sourceMode == .objects {
                objectsSurface
            } else {
                cameraSurface
            }
        }
        .background(Color.black)
        .overlay {
            if appModel.sourceMode == .camera, cameraRuntime.snapshot.state == .running {
                CameraAssistOverlay(
                    gridEnabled: preferences.gridEnabled,
                    reticleEnabled: preferences.reticleEnabled,
                    histogramEnabled: preferences.histogramEnabled,
                    statsMailbox: statsMailbox
                )
            }
        }
        .onChange(of: cameraRuntime.snapshot.deviceID) { _, _ in
            metalFailed = false
            fracture.reset()
        }
        .onChange(of: cameraRuntime.snapshot) { _, snapshot in
            broadcastRuntime.configureProfile(
                frameRate: snapshot.framesPerSecond,
                requestedCodec: snapshot.requestedVideoCodec.rawValue
            )
        }
        .onAppear {
            broadcastRuntime.configureProfile(
                frameRate: cameraRuntime.snapshot.framesPerSecond,
                requestedCodec: cameraRuntime.snapshot.requestedVideoCodec.rawValue
            )
        }
        .onChange(of: cameraRuntime.snapshot.state) { _, state in
            // Interruption, permission loss or a restart can never leave the
            // renderer stranded mid-tear.
            guard state != .running else { return }
            fracture.reset()
        }
        .onChange(of: appModel.sourceMode) { _, _ in
            fracture.reset()
        }
    }

    @ViewBuilder private var cameraSurface: some View {
        switch cameraRuntime.snapshot.state {
        case .running:
            if metalFailed || rawReferenceRequested {
                rawReferenceSurface
            } else {
                let aspectCode: Float = switch appModel.setup.aspectRatio {
                case .native: appModel.setup.resolution == .openGate ? 4 : 0
                case .ratio_4_3: 1
                case .ratio_16_9: 2
                case .ratio_1_1: 3
                }
                let overlayVector = SIMD4<Float>(
                    preferences.peakingEnabled ? 1 : 0,
                    aspectCode,
                    preferences.zebraEnabled ? 1 : 0,
                    0 // Reticle is preview chrome, not part of the processed image.
                )
                ZStack {
                    CameraMetalSurface(
                        runtime: cameraRuntime,
                        rgbSplitParameters: rgbSplitParameters,
                        effectStack: effectStack,
                        audioMailbox: audioRuntime.snapshotMailbox,
                        audioIntensity: audioRuntime.isEnabled ? Float(audioRuntime.intensity) : 0,
                        blobFields: packedBlobFields(blobRuntime.blobs, region: blobRuntime.region),
                        scanlineParameters: ScanlineEffectParameters(),
                        overlays: overlayVector,
                        fracture: fracture,
                        broadcast: broadcastRuntime.isArmed ? broadcastRuntime.frameSink : nil,
                        trackingFeed: blobRuntime.feed,
                        statsMailbox: statsMailbox,
                        onPreviewTap: onPreviewTap,
                        onFocus: onFocus,
                        onFocusReticle: { point in
                            focusReticlePoint = point
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(1))
                                focusReticlePoint = nil
                            }
                        },
                        onSpectrumOverlayDrag: onSpectrumOverlayDrag,
                        onSpectrumOverlayPinch: onSpectrumOverlayPinch,
                        onOverlayGesturePhase: onOverlayGesturePhase,
                        onFailure: { metalFailed = true },
                        recordingTransaction: recordingTransaction
                    )
                    if let point = focusReticlePoint {
                        Image(systemName: "scope")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(color: .black.opacity(0.8), radius: 2)
                            .position(x: point.x, y: point.y)
                            .transition(.opacity)
                    }
                }
            }
        case .denied:
            statusSurface(
                symbol: "camera.fill",
                title: "CAMERA PERMISSION DENIED",
                detail: "ENABLE CAMERA ACCESS IN SETTINGS",
                actionTitle: "OPEN SETTINGS"
            ) {
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    openURL(settingsURL)
                }
            }
        case .failed:
            statusSurface(
                symbol: "exclamationmark.triangle",
                title: "CAMERA ENGINE FAILED",
                detail: cameraRuntime.snapshot.errorMessage ?? "UNKNOWN FAILURE",
                actionTitle: "RETRY"
            ) {
                appModel.restartEngine()
            }
        case .interrupted:
            statusSurface(
                symbol: "pause.circle",
                title: "CAPTURE INTERRUPTED",
                detail: cameraRuntime.snapshot.interruptionReason ?? "WAITING FOR CAMERA",
                actionTitle: nil,
                action: nil
            )
        default:
            statusSurface(
                symbol: "camera.aperture",
                title: "CAMERA ENGINE // \(cameraRuntime.snapshot.state.label)",
                detail: "NEGOTIATING PERMISSION, SOURCE, AND FORMAT",
                actionTitle: nil,
                action: nil
            )
        }
    }

    @ViewBuilder private var rawReferenceSurface: some View {
        if cameraRuntime.snapshot.isSynthetic {
            SyntheticCameraSurface()
        } else {
            RawCameraPreview(
                session: cameraRuntime.captureSession,
                position: cameraRuntime.snapshot.position,
                onFocus: cameraRuntime.focus
            )
        }
    }

    private var rawReferenceRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--raw-preview")
    }

    @ViewBuilder private var objectsSurface: some View {
        switch objectsRuntime.snapshot.state {
        case .running:
            ARObjectMetalSurface(runtime: objectsRuntime)
        case .unsupported:
            statusSurface(
                symbol: "cube.transparent",
                title: "AR OBJECTS UNAVAILABLE",
                detail: objectsRuntime.capability.reason,
                actionTitle: "RETURN CAMERA"
            ) {
                appModel.deactivateObjectMode()
            }
        case .failed:
            statusSurface(
                symbol: "exclamationmark.triangle",
                title: "AR OBJECTS FAILED",
                detail: objectsRuntime.snapshot.errorMessage ?? "UNKNOWN AR FAILURE",
                actionTitle: "RETURN CAMERA"
            ) {
                appModel.deactivateObjectMode()
            }
        case .interrupted:
            statusSurface(
                symbol: "pause.circle",
                title: "AR OBJECTS INTERRUPTED",
                detail: objectsRuntime.snapshot.errorMessage ?? "WAITING FOR ARKIT",
                actionTitle: nil,
                action: nil
            )
        case .idle, .starting:
            statusSurface(
                symbol: "cube.transparent",
                title: "AR OBJECTS // STARTING",
                detail: "NEGOTIATING WORLD TRACKING, PLANES, AND PROJECTION",
                actionTitle: nil,
                action: nil
            )
        }
    }

    @ViewBuilder private var depthSurface: some View {
        switch depthRuntime.snapshot.state {
        case .running:
            DepthMetalSurface(runtime: depthRuntime)
        case .unsupported:
            statusSurface(
                symbol: "sensor.tag.radiowaves.forward",
                title: "LIDAR UNAVAILABLE",
                detail: depthRuntime.capability.reason,
                actionTitle: "RETURN CAMERA"
            ) {
                appModel.deactivateDepthMode()
            }
        case .failed:
            statusSurface(
                symbol: "exclamationmark.triangle",
                title: "LIDAR ENGINE FAILED",
                detail: depthRuntime.snapshot.errorMessage ?? "UNKNOWN DEPTH FAILURE",
                actionTitle: "RETURN CAMERA"
            ) {
                appModel.deactivateDepthMode()
            }
        case .interrupted:
            statusSurface(
                symbol: "pause.circle",
                title: "LIDAR INTERRUPTED",
                detail: depthRuntime.snapshot.errorMessage ?? "WAITING FOR ARKIT",
                actionTitle: nil,
                action: nil
            )
        case .idle, .starting:
            statusSurface(
                symbol: "sensor.tag.radiowaves.forward",
                title: "LIDAR SCENE DEPTH // STARTING",
                detail: "NEGOTIATING ARKIT, DEPTH, CONFIDENCE, AND INTRINSICS",
                actionTitle: nil,
                action: nil
            )
        }
    }

    private func statusSurface(
        symbol: String,
        title: String,
        detail: String,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        ZStack {
            RadialGradient(
                colors: [GVTheme.violetDeep.opacity(0.14), Color(white: 0.016), .black],
                center: .center,
                startRadius: 12,
                endRadius: 440
            )
            DeterministicStarfield().opacity(0.20)

            VStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .ultraLight))
                    .foregroundStyle(GVTheme.violet)
                Text(title)
                    .gvMono(9, .bold)
                    .tracking(1.6)
                    .foregroundStyle(GVTheme.bone)
                Text(detail.uppercased())
                    .gvMono(7, .medium)
                    .tracking(0.9)
                    .foregroundStyle(GVTheme.ash)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .gvMono(8, .bold)
                        .buttonStyle(.bordered)
                        .tint(GVTheme.violetDeep)
                }
            }
            .padding(24)
        }
    }
}

/// Packs up to four tracked blobs into the shader's blob field: xy = normalized
/// center (top-left analysis space flipped to Metal's bottom-left UV), z = size
/// factor, w = present. Empty slots stay zero so kernels ignore them.
/// The four largest subjects, in the full working frame's coordinates.
/// Tracking analyses only the preview's visible crop, so each centre is mapped
/// back out of that region before it reaches the shaders.
private func packedBlobFields(_ blobs: [TrackedBlob], region: CGRect) -> [SIMD4<Float>] {
    blobs.prefix(4).map { blob in
        let x = region.minX + blob.rect.midX * region.width
        let y = region.minY + blob.rect.midY * region.height
        return SIMD4<Float>(
            Float(min(max(x, 0), 1)),
            Float(min(max(1 - y, 0), 1)),
            Float(min(max(sqrt(blob.area) * 2.2, 0.05), 1)),
            1
        )
    }
}

/// SwiftUI capture aids that do not belong in the image-processing shader.
/// They are intentionally outside the Metal surface, so they remain responsive
/// while the renderer is rebuilding and never consume preview gestures.
private struct CameraAssistOverlay: View {
    let gridEnabled: Bool
    let reticleEnabled: Bool
    let histogramEnabled: Bool
    let statsMailbox: CameraRenderStatsMailbox

    var body: some View {
        ZStack {
            if gridEnabled {
                CameraThirdsGrid()
            }
            if reticleEnabled {
                ZStack {
                    Rectangle().frame(width: 22, height: 1)
                    Rectangle().frame(width: 1, height: 22)
                }
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.85), radius: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if histogramEnabled {
                CameraLumaMeter(statsMailbox: statsMailbox)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(12)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct CameraThirdsGrid: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                for fraction in [CGFloat(1.0 / 3.0), CGFloat(2.0 / 3.0)] {
                    path.move(to: CGPoint(x: geometry.size.width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: geometry.size.width * fraction, y: geometry.size.height))
                    path.move(to: CGPoint(x: 0, y: geometry.size.height * fraction))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height * fraction))
                }
            }
            .stroke(.white.opacity(0.34), lineWidth: 0.75)
            .shadow(color: .black.opacity(0.8), radius: 1)
        }
    }
}

/// A compact, live luminance balance meter. The renderer already samples the
/// top, deck and bottom image bands for adaptive chrome; exposing those values
/// here makes the Histogram control meaningful without a second readback pass.
private struct CameraLumaMeter: View {
    let statsMailbox: CameraRenderStatsMailbox

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let stats = statsMailbox.latest
            let samples = [stats.topChromeLoad, stats.deckChromeLoad, stats.bottomChromeLoad]
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                    Capsule()
                        .fill(GVTheme.bone.opacity(0.72))
                        .frame(width: 3, height: 5 + CGFloat(min(max(sample, 0), 1)) * 24)
                }
            }
            .padding(5)
            .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }
}
