import Foundation
import SwiftUI

struct CameraSurfaceView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var cameraRuntime: CameraRuntime
    @EnvironmentObject private var depthRuntime: DepthRuntime
    @EnvironmentObject private var objectsRuntime: ARObjectRuntime
    @EnvironmentObject private var audioRuntime: AudioReactiveRuntime
    @EnvironmentObject private var blobRuntime: BlobTrackingRuntime
    @EnvironmentObject private var broadcastRuntime: GVBroadcastRuntime
    @ObservedObject var fracture: SignalFractureController
    let onSigil: @MainActor (String) -> Void
    let sigilsEnabled: Bool
    let rgbSplitParameters: RGBSplitEffectParameters
    let effectStack: CameraEffectStackParameters
    let statsMailbox: CameraRenderStatsMailbox
    let onPreviewTap: @MainActor @Sendable () -> Void

    @State private var metalFailed = false

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
        .onChange(of: cameraRuntime.snapshot.deviceID) { _, _ in
            metalFailed = false
            fracture.reset()
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
                CameraMetalSurface(
                    runtime: cameraRuntime,
                    rgbSplitParameters: rgbSplitParameters,
                    effectStack: effectStack,
                    audioSnapshot: audioRuntime.snapshot,
                    audioIntensity: audioRuntime.isEnabled ? Float(audioRuntime.intensity) : 0,
                    blobFields: packedBlobFields(blobRuntime.blobs),
                    scanlineParameters: ScanlineEffectParameters(),
                    fracture: fracture,
                    // Handed over only while the link is armed, so an idle
                    // link costs the render loop nothing at all.
                    broadcast: broadcastRuntime.isArmed ? broadcastRuntime.frameSink : nil,
                    statsMailbox: statsMailbox,
                    onPreviewTap: onPreviewTap,
                    onFocus: cameraRuntime.focus,
                    onFailure: { metalFailed = true },
                    onSigil: onSigil,
                    sigilsEnabled: sigilsEnabled
                )
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
private func packedBlobFields(_ blobs: [TrackedBlob]) -> [SIMD4<Float>] {
    blobs.prefix(4).map { blob in
        SIMD4<Float>(
            Float(min(max(blob.rect.midX, 0), 1)),
            Float(min(max(1 - blob.rect.midY, 0), 1)),
            Float(min(max(sqrt(blob.area) * 2.2, 0.05), 1)),
            1
        )
    }
}
