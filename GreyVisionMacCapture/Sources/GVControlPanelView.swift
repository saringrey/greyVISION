import SwiftUI

/// The bidirectional control surface, rendered as a Mac-side panel.
///
/// Consolidated remote control surface for the processed iPhone feed. The Mac
/// exposes only the high-value capture actions and effect catalogue; detailed
/// composition editing stays on the phone so this panel remains readable.
///
/// The view is intentionally not a model — it reads from the `GVRemoteControl`
/// and writes through it, but holds no state of its own beyond local UI
/// affordances (selected family, expanded slot).
struct GVControlPanelView: View {
    @ObservedObject var remote: GVRemoteControl
    @ObservedObject var receiver: CaptureReceiver

    @State private var selectedFamilyID: String?
    @State private var expandedSlotID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().background(.white.opacity(0.14))

            if remote.surface == nil {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        captureStrip
                        Divider().background(.white.opacity(0.10))
                        effectsSection
                    }
                    .padding(20)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black.opacity(0.94))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.20), lineWidth: 1)
                }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(remote.hasSurface ? .white : .white.opacity(0.25))
                .frame(width: 6, height: 6)
            Text("REMOTE")
                .gvCaptureMono(11, weight: .bold)
                .tracking(1.4)
            Text(remote.hasSurface ? "MIRRORED" : "WAITING")
                .gvCaptureMono(10, weight: .medium)
                .tracking(1.0)
                .foregroundStyle(.white.opacity(0.43))
            Spacer(minLength: 0)
            Button(action: remote.clearEffects) {
                Text("CLEAR")
                    .gvCaptureMono(9, weight: .bold)
                    .tracking(1.2)
            }
            .buttonStyle(GVRemoteButtonStyle())
            .disabled(remote.state.slots.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 22, weight: .ultraLight))
            Text("CATALOGUE PENDING")
                .gvCaptureMono(10, weight: .bold)
                .tracking(1.2)
            Text("Waiting for iPhone to publish its effect surface…")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.7))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    // MARK: - Capture strip

    private var captureStrip: some View {
        HStack(spacing: 10) {
            Button {
                remote.setRecording(!remote.state.isRecording)
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(remote.state.isRecording ? .red : .white.opacity(0.85))
                        .frame(width: 8, height: 8)
                    Text(remote.state.isRecording ? "RECORDING" : "RECORD")
                        .gvCaptureMono(10, weight: .bold)
                        .tracking(1.3)
                }
            }
            .buttonStyle(GVRemoteButtonStyle(isPrimary: remote.state.isRecording))
            .disabled(!receiver.isRunning)

            Button {
                remote.capturePhoto()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 10, weight: .semibold))
                    Text("CAPTURE")
                        .gvCaptureMono(10, weight: .bold)
                        .tracking(1.3)
                }
            }
            .buttonStyle(GVRemoteButtonStyle())
            .disabled(!receiver.isRunning)

            Spacer(minLength: 0)
        }
    }

    // Detailed stack editing intentionally stays on the iPhone. The Mac panel
    // is a launch and capture surface, not a second dense composition editor.

    // MARK: - Effects catalogue

    private var effectsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("CATALOGUE", detail: effectsSummary)
            familyPicker
            effectGrid
        }
    }

    private var effectsSummary: String {
        guard let surface = remote.surface else { return "" }
        return "\(surface.effects.count) EFFECTS"
    }

    private var familyPicker: some View {
        let families = remote.surface?.families ?? []
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(families) { family in
                    Button {
                        selectedFamilyID = family.id
                    } label: {
                        Text(family.label)
                            .gvCaptureMono(9, weight: .bold)
                            .tracking(1.0)
                    }
                    .buttonStyle(GVRemoteButtonStyle(isActive: selectedFamilyID == family.id))
                }
            }
        }
    }

    private var effectGrid: some View {
        let families = remote.surface?.families ?? []
        let activeFamily = families.first(where: { $0.id == selectedFamilyID }) ?? families.first
        let effectIDs = activeFamily?.effectIDs ?? []
        let columns = [GridItem(.adaptive(minimum: 124, maximum: 180), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(effectIDs, id: \.self) { id in
                effectChip(id)
            }
        }
    }

    private func effectChip(_ id: String) -> some View {
        let descriptor = remote.descriptor(for: id)
        let label = descriptor?.label ?? id.uppercased()
        let reason = remote.unavailabilityReason(id)
        return Button {
            remote.addEffect(id)
        } label: {
            VStack(spacing: 3) {
                Text(label)
                    .gvCaptureMono(9, weight: .semibold)
                    .tracking(0.9)
                    .lineLimit(1)
                if let reason {
                    Text(reason)
                        .gvCaptureMono(7, weight: .medium)
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.white.opacity(reason == nil ? 0.08 : 0.025))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(reason == nil ? 0.20 : 0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(.white.opacity(reason == nil ? 0.9 : 0.4))
        }
        .buttonStyle(.plain)
        .disabled(reason != nil || !receiver.isRunning)
        .help(reason ?? "Activate effect")
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .gvCaptureMono(10, weight: .bold)
                .tracking(1.3)
            Text(detail)
                .gvCaptureMono(9, weight: .medium)
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.43))
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Buttons

private struct GVRemoteButtonStyle: ButtonStyle {
    var isPrimary: Bool = false
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(minHeight: 52)
            .background(background(pressed: configuration.isPressed))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(strokeColor(pressed: configuration.isPressed), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(textColor())
    }

    private func background(pressed: Bool) -> Color {
        if isPrimary { return .white.opacity(pressed ? 0.18 : 0.12) }
        if isActive { return .white.opacity(pressed ? 0.22 : 0.16) }
        return .white.opacity(pressed ? 0.1 : 0.04)
    }

    private func strokeColor(pressed: Bool) -> Color {
        if isPrimary { return .white.opacity(pressed ? 0.6 : 0.45) }
        if isActive { return .white.opacity(pressed ? 0.7 : 0.55) }
        return .white.opacity(pressed ? 0.3 : 0.18)
    }

    private func textColor() -> Color {
        if isPrimary { return .white }
        if isActive { return .white }
        return .white.opacity(0.85)
    }
}
