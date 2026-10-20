import SwiftUI

/// Creative tools for the camera surface.
///
/// A grid of plates the operator can arm from the top-deck. What used to
/// live here was camera setup (zoom stops, exposure compensation, freeze,
/// flip, flash) — useful, but not what this app is for. The camera surface
/// is the canvas, so the tools that matter are the ones that change what
/// the operator can see and how the device behaves at the moment of
/// capture: composition guides, exposure aids, format, audio coupling.
///
/// Layout: a single 2-column grid of plates. Each plate is a small
/// instrument — icon, label, state. States are read once from the camera
/// runtime so the grid reflects live values without polling.
struct CameraControlsView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var cameraRuntime: CameraRuntime
    @EnvironmentObject private var audioRuntime: AudioReactiveRuntime
    @EnvironmentObject private var preferences: GVPreferences
    /// Same latch the workspace toolbar writes through, so arming audio here
    /// is not undone by the next composition edit.
    @EnvironmentObject private var audioArmPolicy: GVAudioArmPolicy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var format: CaptureSetupDraft.Resolution = .ultraHD
    @State private var aspect: CaptureSetupDraft.AspectRatio = .native

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 7),
        GridItem(.flexible(), spacing: 7)
    ]

    var body: some View {
        VStack(spacing: 7) {
            header
            LazyVGrid(columns: columns, spacing: 7) {
                tool(symbol: "squareshape.split.3x3", label: "Grid", active: preferences.gridEnabled) {
                    preferences.gridEnabled.toggle()
                }
                .accessibilityIdentifier("workspace.tool.grid")

                tool(symbol: "chart.bar.xaxis", label: "Histogram", active: preferences.histogramEnabled) {
                    preferences.histogramEnabled.toggle()
                }
                .accessibilityIdentifier("workspace.tool.histogram")

                tool(
                    symbol: preferences.peakingEnabled ? "scope" : "circle.dashed",
                    label: "Focus Peak",
                    active: preferences.peakingEnabled
                ) {
                    preferences.peakingEnabled.toggle()
                }
                .accessibilityIdentifier("workspace.tool.peaking")

                formatTool
                aspectTool

                tool(
                    symbol: preferences.zebraEnabled ? "line.diagonal" : "line.diagonal.fill",
                    label: "Zebra",
                    active: preferences.zebraEnabled
                ) {
                    preferences.zebraEnabled.toggle()
                }
                .accessibilityIdentifier("workspace.tool.zebra")

                tool(
                    symbol: preferences.reticleEnabled ? "plus.viewfinder" : "viewfinder",
                    label: "Reticle",
                    active: preferences.reticleEnabled
                ) {
                    preferences.reticleEnabled.toggle()
                }
                .accessibilityIdentifier("workspace.tool.reticle")

                tool(
                    symbol: audioRuntime.isEnabled ? "waveform.badge.mic" : "waveform",
                    label: "Audio Reactive",
                    active: audioRuntime.isEnabled,
                    tint: audioRuntime.isEnabled ? .white : nil
                ) {
                    Task { @MainActor in
                        if audioRuntime.isEnabled {
                            audioArmPolicy.setManualArm(false)
                        } else {
                            audioArmPolicy.setManualArm(true)
                            await audioRuntime.start()
                        }
                    }
                }
                .accessibilityIdentifier("workspace.tool.audio")

                tool(
                    symbol: preferences.ndShutterEnabled ? "camera.aperture" : "camera.metering.matrix",
                    label: "Shutter",
                    active: preferences.ndShutterEnabled
                ) {
                    preferences.ndShutterEnabled.toggle()
                }
                .accessibilityIdentifier("workspace.tool.shutter")

                tool(
                    symbol: "arrow.triangle.2.circlepath.camera",
                    label: "Flip Camera",
                    active: false
                ) {
                    appModel.switchCameraPosition()
                }
                .accessibilityIdentifier("workspace.tool.flip")

                tool(
                    symbol: cameraRuntime.snapshot.torchEnabled ? "bolt.fill" : "bolt",
                    label: "Torch",
                    active: cameraRuntime.snapshot.torchEnabled,
                    enabled: cameraRuntime.snapshot.torchAvailable
                ) {
                    cameraRuntime.pulseTorch()
                }
                .accessibilityIdentifier("workspace.tool.flash")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .onAppear {
            format = appModel.setup.resolution
            aspect = appModel.setup.aspectRatio
        }
        .accessibilityIdentifier("workspace.camera.controls")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Camera Tools · \(deviceLabel.capitalized)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(GVTheme.bone.opacity(0.85))
            Spacer(minLength: 0)
        }
        .padding(.bottom, 1)
    }

    /// Friendly label for the active device. The raw `AVCaptureDevice.DeviceType`
    /// value is verbose ("com.apple.avfoundation.avcapturedevice.built-in-dual-camera")
    /// so the controls read a short form.
    private var deviceLabel: String {
        if cameraRuntime.snapshot.position == .front {
            return "Front"
        }
        let raw = cameraRuntime.snapshot.deviceType.lowercased()
        if raw.contains("dual-wide") {
            return "Dual Wide"
        }
        if raw.contains("dual") {
            return "Dual"
        }
        if raw.contains("triple") {
            return "Triple"
        }
        return "Wide"
    }

    // MARK: - Format and aspect tools

    /// Cycles through the curated capture resolutions: 4K → 1080P → 720P → 4K.
    /// Stardust variant — darker, only for codec selection.
    private var formatTool: some View {
        Button {
            cycleResolution()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "4k.tv")
                    .font(.system(size: 15, weight: .medium))
                Text(format.rawValue)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Color.white.opacity(0.92))
            .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(GVStardustButtonStyle(active: false))
        .accessibilityLabel("Capture resolution \(format.rawValue)")
        .accessibilityIdentifier("workspace.tool.format")
    }

    /// Cycles through the curated aspect ratios — stardust darker variant.
    private var aspectTool: some View {
        Button {
            cycleAspect()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: aspectIcon)
                    .font(.system(size: 15, weight: .medium))
                Text(aspect.shortLabel)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Color.white.opacity(0.92))
            .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(GVStardustButtonStyle(active: false))
        .accessibilityLabel("Aspect ratio \(aspect.shortLabel)")
        .accessibilityIdentifier("workspace.tool.aspect")
    }

    private func cycleResolution() {
        let order: [CaptureSetupDraft.Resolution] = [.ultraHD, .fullHD, .hd720]
        let current = order.firstIndex(of: format) ?? 0
        let next = order[(current + 1) % order.count]
        format = next
        appModel.setup.resolution = next
    }

    private func cycleAspect() {
        let order: [CaptureSetupDraft.AspectRatio] = [.native, .ratio_4_3, .ratio_16_9, .ratio_1_1]
        let current = order.firstIndex(of: aspect) ?? 0
        let next = order[(current + 1) % order.count]
        aspect = next
        appModel.setup.aspectRatio = next
    }

    private var aspectIcon: String {
        switch aspect {
        case .native: "rectangle"
        case .ratio_4_3: "rectangle.portrait"
        case .ratio_16_9: "rectangle.fill"
        case .ratio_1_1: "square"
        }
    }

    // MARK: - Generic tool

    @ViewBuilder
    private func tool(
        symbol: String,
        label: String,
        active: Bool,
        enabled: Bool = true,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let glyph: Color = active ? .white : (tint ?? GVTheme.bone.opacity(0.78))
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(glyph)
            .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(GVGlassToolButtonStyle(active: active, tint: tint ?? .white))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.34)
        .animation(GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion), value: active)
        .accessibilityLabel(label)
        .accessibilityValue(active ? "active" : "inactive")
    }
}

private struct GVGlassToolButtonStyle: ButtonStyle {
    let active: Bool
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .gvGlassChip(radius: 12, active: active || configuration.isPressed, tint: tint)
            .frame(maxWidth: .infinity, minHeight: 46)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.98 : 1))
            .animation(GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}
