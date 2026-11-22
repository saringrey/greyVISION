import SwiftUI

/// The camera half of the one settings deck: the lens in use and how the
/// frame is shaped.
///
/// Trimmed to what changes the picture. Peaking, zebra, the histogram meter,
/// the ND shutter flag and the reticle switch are gone — the crosshair is
/// always drawn, and the rest either did nothing or duplicated what the
/// effects already show. Audio lives once, in the capture section beside it.
struct CameraControlsView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var cameraRuntime: CameraRuntime
    @EnvironmentObject private var preferences: GVPreferences

    /// Says what a key just did, where the workspace says things.
    var onNotice: (String) -> Void = { _ in }

    @State private var format: CaptureSetupDraft.Resolution = .ultraHD
    @State private var aspect: CaptureSetupDraft.AspectRatio = .native
    @State private var frameRate: CaptureSetupDraft.FrameRate = .cinematic
    @State private var codec: CaptureSetupDraft.VideoCodec = .hevc
    /// Index into the stops below. 0 is always "auto".
    @State private var biasIndex = 0
    @State private var isoIndex = 0
    @State private var whiteBalanceIndex = 0

    private static let biasStops: [Double] = [0, 0.7, 1.3, -1.3, -0.7]
    private static let isoStops: [Double] = [0, 100, 400, 1600]
    private static let kelvinStops: [Int] = [0, 3200, 4300, 5600, 6500]

    var body: some View {
        let snapshot = cameraRuntime.snapshot
        let stops = snapshot.lensZoomFactors

        GVConsoleSection(label: "LENS") {
            GVConsoleKey(symbol: "camera.aperture",
                         label: "Lens",
                         value: stops.isEmpty ? "1×" : snapshot.lensLabel(for: stops[snapshot.currentLensIndex]),
                         active: snapshot.currentLensIndex > 0,
                         enabled: stops.count > 1) {
                if let label = cameraRuntime.cycleLens() {
                    GVInteractionHaptics.select()
                    onNotice("Lens \(label)")
                }
            }
            .accessibilityIdentifier("workspace.tool.lens")

            GVConsoleKey(symbol: "arrow.triangle.2.circlepath.camera",
                         label: "Flip",
                         value: snapshot.position == .front ? "FRONT" : "REAR") {
                appModel.switchCameraPosition()
            }
            .accessibilityIdentifier("workspace.tool.flip")

            GVConsoleKey(symbol: snapshot.torchEnabled ? "bolt.fill" : "bolt",
                         label: "Flash", active: snapshot.torchEnabled,
                         enabled: snapshot.torchAvailable) {
                cameraRuntime.pulseTorch()
            }
            .accessibilityIdentifier("workspace.tool.flash")
        }

        GVConsoleSection(label: "EXPOSURE") {
            GVConsoleKey(symbol: "plusminus.circle",
                         label: "Exposure",
                         value: Self.biasLabel(Self.biasStops[biasIndex]),
                         active: biasIndex != 0) {
                biasIndex = (biasIndex + 1) % Self.biasStops.count
                cameraRuntime.setExposureBias(Self.biasStops[biasIndex])
                GVInteractionHaptics.select()
            }
            .accessibilityIdentifier("workspace.tool.exposure")

            GVConsoleKey(symbol: "camera.metering.center.weighted",
                         label: "ISO",
                         value: isoIndex == 0 ? "AUTO" : "\(Int(Self.isoStops[isoIndex]))",
                         active: isoIndex != 0) {
                isoIndex = (isoIndex + 1) % Self.isoStops.count
                if isoIndex == 0 {
                    restoreAuto(keepWhiteBalance: true)
                } else {
                    cameraRuntime.setISO(Self.isoStops[isoIndex])
                }
                GVInteractionHaptics.select()
            }
            .accessibilityIdentifier("workspace.tool.iso")

            GVConsoleKey(symbol: "thermometer.sun",
                         label: "White Bal",
                         value: whiteBalanceIndex == 0 ? "AUTO" : "\(Self.kelvinStops[whiteBalanceIndex])K",
                         active: whiteBalanceIndex != 0) {
                whiteBalanceIndex = (whiteBalanceIndex + 1) % Self.kelvinStops.count
                if whiteBalanceIndex == 0 {
                    restoreAuto(keepWhiteBalance: false)
                } else {
                    cameraRuntime.setWhiteBalanceKelvin(Self.kelvinStops[whiteBalanceIndex])
                }
                GVInteractionHaptics.select()
            }
            .accessibilityIdentifier("workspace.tool.whitebalance")

            GVConsoleKey(symbol: "a.circle", label: "Auto", value: "RESET",
                         enabled: biasIndex != 0 || isoIndex != 0 || whiteBalanceIndex != 0) {
                biasIndex = 0
                isoIndex = 0
                whiteBalanceIndex = 0
                cameraRuntime.setExposureBias(0)
                cameraRuntime.resumeAutoExposure()
                onNotice("Exposure back to auto")
            }
            .accessibilityIdentifier("workspace.tool.autoexposure")
        }

        GVConsoleSection(label: "FRAME") {
            GVConsoleKey(symbol: "squareshape.split.3x3", label: "Grid", active: preferences.gridEnabled) {
                preferences.gridEnabled.toggle()
            }
            .accessibilityIdentifier("workspace.tool.grid")

            GVConsoleKey(symbol: "4k.tv", label: "Format", value: format.rawValue) {
                cycleResolution()
                GVInteractionHaptics.select()
            }
            .accessibilityIdentifier("workspace.tool.format")

            GVConsoleKey(symbol: "speedometer", label: "Frame Rate", value: "\(frameRate.rawValue)") {
                cycleFrameRate()
                GVInteractionHaptics.select()
            }
            .accessibilityIdentifier("workspace.tool.framerate")

            GVConsoleKey(symbol: "film", label: "Codec", value: codec.compactLabel) {
                cycleCodec()
                GVInteractionHaptics.select()
            }
            .accessibilityIdentifier("workspace.tool.codec")

            GVConsoleKey(symbol: aspectIcon, label: "Aspect", value: aspect.shortLabel) {
                cycleAspect()
                GVInteractionHaptics.select()
            }
            .accessibilityIdentifier("workspace.tool.aspect")
        }
        .onAppear {
            format = appModel.setup.resolution
            aspect = appModel.setup.aspectRatio
            frameRate = appModel.setup.frameRate
            codec = appModel.setup.videoCodec
        }
    }

    // MARK: - Format and aspect tools

    private func cycleResolution() {
        guard formatChangeAllowed() else { return }
        let order: [CaptureSetupDraft.Resolution] = [.ultraHD, .fullHD, .hd720]
        let current = order.firstIndex(of: format) ?? 0
        let next = order[(current + 1) % order.count]
        format = next
        appModel.setup.resolution = next
        appModel.restartEngine()
    }

    private func cycleFrameRate() {
        guard formatChangeAllowed() else { return }
        let order = CaptureSetupDraft.FrameRate.allCases
        let current = order.firstIndex(of: frameRate) ?? 0
        let next = order[(current + 1) % order.count]
        frameRate = next
        appModel.setup.frameRate = next
        appModel.restartEngine()
        onNotice(next.label)
    }

    private func cycleCodec() {
        guard formatChangeAllowed() else { return }
        let curated = CaptureSetupDraft.VideoCodec.curated.filter(\.isOperatingSystemAvailable)
        let reported = cameraRuntime.snapshot.availableVideoCodecs.filter { curated.contains($0) }
        let order = reported.isEmpty ? curated : reported
        guard !order.isEmpty else { return }
        let current = order.firstIndex(of: codec) ?? -1
        let next = order[(current + 1) % order.count]
        codec = next
        appModel.setup.videoCodec = next
        appModel.restartEngine()
        onNotice("Codec \(next.compactLabel)")
    }

    /// Format changes restart the capture session, which would end a take.
    private func formatChangeAllowed() -> Bool {
        guard !cameraRuntime.isRecording else {
            onNotice("Locked during a take")
            return false
        }
        return true
    }

    /// Hands metering back to the device, then re-applies whichever manual
    /// value the operator is keeping.
    private func restoreAuto(keepWhiteBalance: Bool) {
        cameraRuntime.resumeAutoExposure()
        if keepWhiteBalance, whiteBalanceIndex != 0 {
            cameraRuntime.setWhiteBalanceKelvin(Self.kelvinStops[whiteBalanceIndex])
        }
        if !keepWhiteBalance, isoIndex != 0 {
            cameraRuntime.setISO(Self.isoStops[isoIndex])
        }
        cameraRuntime.setExposureBias(Self.biasStops[biasIndex])
    }

    private static func biasLabel(_ bias: Double) -> String {
        bias == 0 ? "0 EV" : String(format: "%+.1f", bias)
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
