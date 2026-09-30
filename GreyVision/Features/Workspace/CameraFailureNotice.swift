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
            Text("Capture Unavailable")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(GVTheme.record)

            Text(message)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(GVTheme.bone)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let reason {
                Text(reason)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(GVTheme.ash)
                    .multilineTextAlignment(.center)
            }

            Button(action: onRetry) {
                Text("Retry Capture")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(GVTheme.bone)
                    .padding(.horizontal, GVMetrics.gapWide)
                    .frame(height: GVMetrics.controlHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: GVMetrics.hairline)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
