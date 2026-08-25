import SwiftUI

/// Shown when capture has failed.
///
/// `CameraRuntime` writes a reason into `snapshot.errorMessage` for permission
/// denial, format attachment failure and session configuration failure. Until
/// now nothing read it: the viewport went dead and the interface said nothing,
/// which made a broken camera impossible to diagnose from the device itself.
///
/// Deliberately plain. This is the one moment where the instrument has to stop
/// performing and tell the operator what went wrong.
struct CameraFailureNotice: View {
    let message: String
    let reason: String?
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: GVMetrics.gap) {
            GVTerminalText(
                text: "CAPTURE FAULT",
                size: GVMetrics.textBody,
                weight: .black,
                tracking: 1.6,
                baseColor: GVTheme.record,
                intensity: 1.0
            )

            Text(message)
                .gvMono(GVMetrics.textSmall, .bold)
                .tracking(0.6)
                .foregroundStyle(GVTheme.bone)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let reason {
                Text(reason.uppercased())
                    .gvMono(GVMetrics.textMicro, .bold)
                    .tracking(0.8)
                    .foregroundStyle(GVTheme.ash)
                    .multilineTextAlignment(.center)
            }

            Button(action: onRetry) {
                GVTerminalText(
                    text: "RETRY CAPTURE",
                    size: GVMetrics.textSmall,
                    weight: .black,
                    tracking: 1.3,
                    baseColor: GVTheme.bone,
                    intensity: 0.9
                )
                .padding(.horizontal, GVMetrics.gapWide)
                .frame(height: GVMetrics.controlHeight)
                .background(
                    GVChamferedPlate(cut: 9)
                        .fill(GVTheme.violet.opacity(0.18))
                )
                .overlay(
                    GVChamferedPlate(cut: 9)
                        .stroke(GVTheme.violet, lineWidth: GVMetrics.hairline)
                )
                .contentShape(GVChamferedPlate(cut: 9))
            }
            .buttonStyle(GVPressStyle())
            .accessibilityIdentifier("workspace.capture.retry")
        }
        .padding(GVMetrics.gapWide + 4)
        .frame(maxWidth: 300)
        .background(
            RoundedRectangle(cornerRadius: GVMetrics.radiusPanel, style: .continuous)
                .fill(Color.black.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: GVMetrics.radiusPanel, style: .continuous)
                        .strokeBorder(GVTheme.record.opacity(0.55), lineWidth: GVMetrics.hairline)
                )
        )
        .shadow(color: GVTheme.elevationShadow, radius: 18, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Capture fault. \(message)")
    }
}
