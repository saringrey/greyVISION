import SwiftUI

/// Edge identity. Three tokens, not nine.
///
/// The rails used to take over and become a vertical gauge for whichever
/// telemetry field was selected. That made sense while the status line had
/// nowhere else to put a control — but the control now opens directly under
/// the reading it belongs to (`GVFieldAdjuster`), and a rail showing the same
/// value at the same time was two readouts of one number, on opposite sides of
/// the frame, both moving.
///
/// What is left is what cannot be read anywhere else on screen.
struct GVSideRail: View {
    enum Edge { case leading, trailing }

    @EnvironmentObject private var cameraRuntime: CameraRuntime

    let edge: Edge

    var body: some View {
        let snapshot = cameraRuntime.snapshot
        let tokens: [String] = edge == .leading
            ? ["CAM 01", railDeviceLabel]
            : [String(format: "GV.%06d", abs(snapshot.deviceID.hashValue % 1_000_000))]

        return VStack(alignment: edge == .leading ? .leading : .trailing, spacing: GVMetrics.stepMicro) {
            ForEach(tokens, id: \.self) { token in
                Text(token)
                    .gvFont(.diagnostic)
                    .tracking(GVTheme.TypeLevel.diagnostic.tracking)
                    .foregroundStyle(GVTheme.ash.opacity(0.55))
                    .shadow(color: .black.opacity(0.85), radius: 2)
                    .fixedSize()
            }
        }
        .accessibilityHidden(true)
    }

    /// Mirrors the controls header: DUAL, DUAL WIDE, WIDE, TRIPLE or FRONT,
    /// derived from the snapshot's raw device type.
    private var railDeviceLabel: String {
        if cameraRuntime.snapshot.position == .front {
            return "FRONT"
        }
        let raw = cameraRuntime.snapshot.deviceType.lowercased()
        if raw.contains("dual-wide") {
            return "DUAL WIDE"
        }
        if raw.contains("dual") {
            return "DUAL"
        }
        if raw.contains("triple") {
            return "TRIPLE"
        }
        return "WIDE"
    }
}
