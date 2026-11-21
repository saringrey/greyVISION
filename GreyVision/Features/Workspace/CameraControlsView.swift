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
                         label: "Torch", active: snapshot.torchEnabled,
                         enabled: snapshot.torchAvailable) {
                cameraRuntime.pulseTorch()
            }
            .accessibilityIdentifier("workspace.tool.flash")
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

            GVConsoleKey(symbol: aspectIcon, label: "Aspect", value: aspect.shortLabel) {
                cycleAspect()
                GVInteractionHaptics.select()
            }
            .accessibilityIdentifier("workspace.tool.aspect")
        }
        .onAppear {
            format = appModel.setup.resolution
            aspect = appModel.setup.aspectRatio
        }
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
