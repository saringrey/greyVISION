import SwiftUI

// MARK: - AR objects parameter deck

/// AR object placement controls on the shared compact rail — same charcoal
/// material, header chips and one-row sliders as FX.PARAM.
struct ARObjectsParameterDeck: View {
    @Binding var parameters: ARObjectParameters
    let objectCount: Int
    /// ARKit's tracking quality, e.g. "TRACKING · INITIALIZING".
    var status = ""
    let isRecording: Bool
    @EnvironmentObject private var toasts: GVToastBox
    let onRecordToggle: () -> Void
    let onClear: () -> Void
    let onExit: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            headerRow
            sliderRow
                .gvScrollProgressLine()
        }
        .gvCompactDeckPlate()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.parameters.ar")
    }

    private var headerRow: some View {
        HStack(spacing: 5) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(objectCount) OBJECTS")
                    .font(GVTheme.mono(13, .semibold))
                    .tracking(0.8)
                    .foregroundStyle(GVTheme.bone)
                if !status.isEmpty {
                    Text(status)
                        .font(GVTheme.mono(9.5, .medium))
                        .foregroundStyle(status == "TRACKING NORMAL" ? Color.mint : GVTheme.ash)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .accessibilityIdentifier("workspace.ar.tracking")
                }
            }

            Spacer(minLength: 6)

            GVDeckChip(
                label: isRecording ? "Stop" : "Record",
                symbol: nil,
                active: isRecording,
                tint: GVTheme.record,
                id: "ar.record"
            ) {
                onRecordToggle()
            }
            GVDeckChip(label: "Clear", id: "ar.clear") {
                onClear()
                toasts.show("AR geometry cleared")
            }
            GVDeckChip(label: "Camera", symbol: "camera.aperture", id: "ar.exit") {
                onExit()
                onClose()
            }
            GVDeckChip(label: "", symbol: "xmark", id: "ar.close") {
                onClose()
            }
        }
    }

    private var sliderRow: some View {
        HStack(spacing: 8) {
            GVRailSlider(
                label: "Size",
                value: $parameters.size,
                defaultValue: ARObjectParameters.defaults.size,
                range: 0.35 ... 1.8,
                format: { String(format: "%.2f\u{00D7}", $0) }
            )
            .accessibilityIdentifier("workspace.param.ar.size")

            GVRailSlider(
                label: "Spin",
                value: $parameters.spin,
                defaultValue: ARObjectParameters.defaults.spin,
                range: 0 ... 2,
                format: { String(format: "%.2f", $0) }
            )
            .accessibilityIdentifier("workspace.param.ar.spin")

            GVRailSlider(
                label: "Glow",
                value: $parameters.glow,
                defaultValue: ARObjectParameters.defaults.glow,
                range: 0.1 ... 1.6,
                format: { String(format: "%.2f", $0) }
            )
            .accessibilityIdentifier("workspace.param.ar.glow")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }
}
