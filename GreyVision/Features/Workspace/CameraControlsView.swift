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
/// Layout: a console of two sections, guides and capture, four keys across.
/// States are read from the camera runtime and preferences, so the keys
/// reflect live values without polling.
struct CameraControlsView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var cameraRuntime: CameraRuntime
    @EnvironmentObject private var audioRuntime: AudioReactiveRuntime
    @EnvironmentObject private var preferences: GVPreferences
    /// Same latch the workspace toolbar writes through, so arming audio here
    /// is not undone by the next composition edit.
    @EnvironmentObject private var audioArmPolicy: GVAudioArmPolicy

    @State private var format: CaptureSetupDraft.Resolution = .ultraHD
    @State private var aspect: CaptureSetupDraft.AspectRatio = .native

    var body: some View {
        GVConsolePanel(title: "CAMERA", status: deviceLabel.uppercased()) {
            GVConsoleSection(label: "GUIDES") {
                GVConsoleKey(symbol: "squareshape.split.3x3", label: "Grid", active: preferences.gridEnabled) {
                    preferences.gridEnabled.toggle()
                }
                .accessibilityIdentifier("workspace.tool.grid")

                GVConsoleKey(symbol: preferences.reticleEnabled ? "plus.viewfinder" : "viewfinder",
                             label: "Reticle", active: preferences.reticleEnabled) {
                    preferences.reticleEnabled.toggle()
                }
                .accessibilityIdentifier("workspace.tool.reticle")

                GVConsoleKey(symbol: "scope", label: "Peaking", active: preferences.peakingEnabled) {
                    preferences.peakingEnabled.toggle()
                }
                .accessibilityIdentifier("workspace.tool.peaking")

                GVConsoleKey(symbol: "line.diagonal", label: "Zebra", active: preferences.zebraEnabled) {
                    preferences.zebraEnabled.toggle()
                }
                .accessibilityIdentifier("workspace.tool.zebra")

                GVConsoleKey(symbol: "chart.bar.xaxis", label: "Histogram", active: preferences.histogramEnabled) {
                    preferences.histogramEnabled.toggle()
                }
                .accessibilityIdentifier("workspace.tool.histogram")
            }

            GVConsoleSection(label: "CAPTURE") {
                GVConsoleKey(symbol: "4k.tv", label: "Format", value: format.rawValue) {
                    cycleResolution()
                    GVInteractionHaptics.select()
                }
                .accessibilityIdentifier("workspace.tool.format")

                GVConsoleKey(symbol: aspectIcon, label: "Aspect", value: aspect.shortLabel) {
                    cycleAspect()
                    GVInteractionHaptics.select()
                }
                .accessibilityIdentifier("workspace.tool.aspect")

                GVConsoleKey(symbol: preferences.ndShutterEnabled ? "camera.aperture" : "camera.metering.matrix",
                             label: "Shutter", value: preferences.ndShutterEnabled ? "ND" : "AUTO",
                             active: preferences.ndShutterEnabled) {
                    preferences.ndShutterEnabled.toggle()
                }
                .accessibilityIdentifier("workspace.tool.shutter")

                GVConsoleKey(symbol: cameraRuntime.snapshot.torchEnabled ? "bolt.fill" : "bolt",
                             label: "Torch", active: cameraRuntime.snapshot.torchEnabled,
                             enabled: cameraRuntime.snapshot.torchAvailable) {
                    cameraRuntime.pulseTorch()
                }
                .accessibilityIdentifier("workspace.tool.flash")

                GVConsoleKey(symbol: "arrow.triangle.2.circlepath.camera", label: "Flip") {
                    appModel.switchCameraPosition()
                }
                .accessibilityIdentifier("workspace.tool.flip")

                GVConsoleKey(symbol: audioRuntime.isEnabled ? "waveform.badge.mic" : "waveform",
                             label: "Audio", value: audioRuntime.isEnabled ? "LIVE" : "OFF",
                             active: audioRuntime.isEnabled) {
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
            }
        }
        .onAppear {
            format = appModel.setup.resolution
            aspect = appModel.setup.aspectRatio
        }
        .accessibilityIdentifier("workspace.camera.controls")
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
}
