import SwiftUI

/// Camera capture controls, in the deck language — plates, not sliders.
///
/// Zoom is a segmented stop selector. Exposure is a stepper with a detent.
/// Everything else is an explicit toggle or action plate. No tracks, no
/// scrubbing, nothing that needs a steady thumb to look intentional.
struct CameraControlsView: View {
    @EnvironmentObject private var cameraRuntime: CameraRuntime

    // Rack focus state (session-local).
    @State private var lensA: Float?
    @State private var lensB: Float?
    @State private var pullDuration: Double = 1.2
    @State private var pullTask: Task<Void, Never>?
    @State private var isPulling = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                header
                zoomStops
                exposureStepper
                ToggleRow(label: "LIGHT",
                          isOn: Binding(get: { cameraRuntime.snapshot.torchEnabled },
                                        set: { cameraRuntime.setTorchEnabled($0) }),
                          enabled: cameraRuntime.snapshot.torchAvailable,
                          identifier: "workspace.camera.torch")
                ToggleRow(label: "WB LOCK",
                          isOn: Binding(get: { cameraRuntime.snapshot.whiteBalanceLocked },
                                        set: { cameraRuntime.setWhiteBalanceLocked($0) }),
                          enabled: true,
                          identifier: "workspace.camera.wb-lock")
                ToggleRow(label: "FOCUS LOCK",
                          isOn: Binding(get: { cameraRuntime.snapshot.focusLocked },
                                        set: { cameraRuntime.setFocusLocked($0) }),
                          enabled: true,
                          identifier: "workspace.camera.focus-lock")
                lensRow
                rackFocusRow
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("workspace.camera.controls")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            GVTerminalText(
                text: "CAM.PARAM // \(GVCameraLabels.lens(cameraRuntime.snapshot))",
                size: GVMetrics.textSmall,
                weight: .black,
                tracking: 1.2,
                alignment: .leading,
                intensity: 1.05
            )
            Spacer(minLength: 0)
        }
        .padding(.bottom, 1)
    }

    // MARK: - Zoom stops

    private var zoomStops: some View {
        let snapshot = cameraRuntime.snapshot
        let maxZoom = max(snapshot.maximumZoom, 1.0)
        let stops: [(String, Double)] = [
            ("0.5", min(0.5, maxZoom)),
            ("1", 1.0),
            ("2", min(2.0, maxZoom)),
            ("MAX", maxZoom)
        ]
        return VStack(alignment: .leading, spacing: 5) {
            sectionLabel("ZOOM")
            HStack(spacing: 6) {
                ForEach(stops, id: \.0) { label, factor in
                    let active = abs(snapshot.zoom - factor) < 0.05
                    Button {
                        cameraRuntime.setZoom(factor)
                        GVParameterHaptics.detentCrossed()
                    } label: {
                        Text(label)
                            .gvMono(GVMetrics.textBody, .bold)
                            .tracking(0.8)
                            .foregroundStyle(active ? Color.white : GVTheme.bone.opacity(0.7))
                            .shadow(color: active ? .white.opacity(0.5) : .clear, radius: 3)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(active ? Color.white.opacity(0.13) : Color(white: 0.105))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(
                                                active ? Color.white.opacity(0.6) : Color.white.opacity(0.08),
                                                lineWidth: 1
                                            )
                                    )
                            )
                    }
                    .buttonStyle(GVPressStyle())
                    .accessibilityLabel("Zoom \(label)")
                }
            }
        }
        .plate()
    }

    // MARK: - Exposure stepper

    private var exposureStepper: some View {
        let bias = cameraRuntime.snapshot.exposureBias
        return VStack(alignment: .leading, spacing: 5) {
            sectionLabel("EXPOSURE")
            HStack(spacing: 8) {
                stepButton(symbol: "minus") {
                    cameraRuntime.setExposureBias(max(bias - 0.1, evRange.lowerBound))
                }
                Button {
                    cameraRuntime.setExposureBias(0)
                    GVParameterHaptics.select()
                } label: {
                    Text(String(format: "%+.1f EV", bias))
                        .gvMono(GVMetrics.textBody, .bold)
                        .monospacedDigit()
                        .foregroundStyle(abs(bias) < 0.001 ? GVTheme.bone.opacity(0.7) : Color.white)
                        .shadow(color: abs(bias) < 0.001 ? .clear : .white.opacity(0.35), radius: 3)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Exposure zero")

                stepButton(symbol: "plus") {
                    cameraRuntime.setExposureBias(min(bias + 0.1, evRange.upperBound))
                }
            }
        }
        .plate()
        .onTapGesture(count: 2) {
            cameraRuntime.setExposureBias(0)
        }
    }

    private func stepButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: GVMetrics.textValue, weight: .bold))
                .foregroundStyle(GVTheme.bone.opacity(0.85))
                .frame(width: 40, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(white: 0.13))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(GVPressStyle())
    }

    private var evRange: ClosedRange<Double> {
        let snapshot = cameraRuntime.snapshot
        return snapshot.minimumExposureBias < snapshot.maximumExposureBias
            ? snapshot.minimumExposureBias ... snapshot.maximumExposureBias
            : -2.0 ... 2.0
    }

    // MARK: - Lens

    private var lensRow: some View {
        let available = cameraRuntime.snapshot.availableLensCount > 1
        return Button {
            Task { @MainActor in
                let changed = await cameraRuntime.cycleLens()
                if changed { GVParameterHaptics.detentCrossed() }
            }
        } label: {
            HStack(spacing: 8) {
                Text("LENS")
                    .gvMono(GVMetrics.textSmall, .bold)
                    .tracking(1.0)
                    .foregroundStyle(GVTheme.bone.opacity(0.75))
                Spacer(minLength: 4)
                Text(GVCameraLabels.lens(cameraRuntime.snapshot))
                    .gvMono(GVMetrics.textBody, .bold)
                    .tracking(0.6)
                    .foregroundStyle(Color.white.opacity(0.92))
                    .shadow(color: Color.white.opacity(0.28), radius: 3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Image(systemName: "repeat")
                    .font(.system(size: GVMetrics.textMicro + 2, weight: .bold))
                    .foregroundStyle(GVTheme.ash)
            }
            .padding(.horizontal, 11)
            .frame(height: 44)
            .background(rowPlate(active: false))
            .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        .opacity(available ? 1 : 0.34)
        .disabled(!available)
        .accessibilityIdentifier("workspace.camera.lens")
    }

    // MARK: - Rack focus

    private var liveLens: Float? { cameraRuntime.liveLensPosition }

    private var rackFocusRow: some View {
        let canPull = lensA != nil && lensB != nil && !isPulling && liveLens != nil
        return VStack(alignment: .leading, spacing: 5) {
            sectionLabel("RACK FOCUS")
            HStack(spacing: 6) {
                storeChip(letter: "A", stored: lensA) { lensA = liveLens }
                storeChip(letter: "B", stored: lensB) { lensB = liveLens }

                Button {
                    pull(from: lensA, to: lensB)
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: GVMetrics.textValue - 1, weight: .bold))
                        .foregroundStyle(canPull ? Color.white : GVTheme.bone.opacity(0.3))
                        .shadow(color: canPull ? .white.opacity(0.4) : .clear, radius: 3)
                        .frame(width: 38, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(canPull ? Color.white.opacity(0.12) : Color(white: 0.12))
                        )
                }
                .buttonStyle(GVPressStyle())
                .disabled(!canPull)
                .accessibilityLabel("Pull focus A to B")

                Button {
                    pull(from: lensB, to: lensA)
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: GVMetrics.textValue - 1, weight: .bold))
                        .foregroundStyle(canPull ? Color.white : GVTheme.bone.opacity(0.3))
                        .shadow(color: canPull ? .white.opacity(0.4) : .clear, radius: 3)
                        .frame(width: 38, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(canPull ? Color.white.opacity(0.12) : Color(white: 0.12))
                        )
                }
                .buttonStyle(GVPressStyle())
                .disabled(!canPull)
                .accessibilityLabel("Pull focus B to A")

                Button {
                    let durations: [Double] = [0.6, 1.2, 2.4]
                    if let idx = durations.firstIndex(of: pullDuration) {
                        pullDuration = durations[(idx + 1) % durations.count]
                    }
                } label: {
                    Text(String(format: "%.1fs", pullDuration))
                        .gvMono(GVMetrics.textMicro, .black)
                        .tracking(0.6)
                        .foregroundStyle(GVTheme.bone.opacity(0.75))
                        .frame(width: 42, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color(white: 0.13))
                        )
                }
                .buttonStyle(GVPressStyle())
                .accessibilityLabel("Pull duration")
            }
        }
        .plate()
        .opacity(liveLens == nil ? 0.45 : 1)
    }

    private func storeChip(letter: String, stored: Float?, set: @escaping () -> Void) -> some View {
        Button(action: set) {
            VStack(spacing: 1) {
                Text(stored == nil ? "SET" : letter)
                    .gvMono(GVMetrics.textSmall, .black)
                    .tracking(0.8)
                if let stored {
                    Text(String(format: "%.2f", stored))
                        .gvMono(7.5, .bold)
                        .foregroundStyle(GVTheme.ash)
                }
            }
            .foregroundStyle(stored == nil ? GVTheme.bone.opacity(0.7) : Color.white)
            .shadow(color: stored == nil ? .clear : .white.opacity(0.35), radius: 3)
            .frame(width: 46, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(stored == nil ? Color(white: 0.12) : Color.white.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                stored == nil ? Color.white.opacity(0.08) : Color.white.opacity(0.45),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(GVPressStyle())
        .accessibilityLabel("Store focus point \(letter)")
    }

    /// Ease-in-out lens pull, stepped at 60 Hz through the runtime API.
    private func pull(from start: Float?, to end: Float?) {
        guard let start, let end, !isPulling else { return }
        isPulling = true
        cameraRuntime.setFocusLocked(true)
        let duration = pullDuration
        let steps = max(Int(duration * 60), 12)
        pullTask?.cancel()
        pullTask = Task { @MainActor in
            for step in 1 ... steps {
                guard !Task.isCancelled else { return }
                let t = Double(step) / Double(steps)
                let eased = t * t * (3 - 2 * t)
                let position = start + (end - start) * Float(eased)
                cameraRuntime.setLensPosition(position)
                try? await Task.sleep(for: .milliseconds(16))
            }
            cameraRuntime.setLensPosition(end)
            isPulling = false
        }
    }

    // MARK: - Shared bits

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .gvMono(GVMetrics.textMicro, .black)
            .tracking(1.3)
            .foregroundStyle(GVTheme.ash)
    }

    private func rowPlate(active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(active ? Color.white.opacity(0.09) : Color(white: 0.105))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        active ? Color.white.opacity(0.55) : Color.white.opacity(0.08),
                        lineWidth: active ? 1.1 : 1
                    )
            )
            .shadow(color: active ? Color.white.opacity(0.20) : .black.opacity(0.4), radius: active ? 7 : 4, y: 2)
    }
}

private extension View {
    /// Standard control plate wrapper used across this deck.
    func plate() -> some View {
        self
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(white: 0.105))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            )
    }
}

// MARK: - Toggle row

private struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool
    let enabled: Bool
    let identifier: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(label)
                    .gvMono(GVMetrics.textSmall, .bold)
                    .tracking(1.0)
                    .foregroundStyle(isOn ? Color.white : GVTheme.bone.opacity(0.75))
                Spacer(minLength: 4)
                Text(isOn ? "ON" : "OFF")
                    .gvMono(GVMetrics.textMicro, .black)
                    .tracking(1.4)
                    .foregroundStyle(isOn ? Color.white : GVTheme.ash)
                    .shadow(color: isOn ? .white.opacity(0.55) : .clear, radius: 4)
                Circle()
                    .fill(isOn ? Color.white : Color(white: 0.24))
                    .frame(width: 8, height: 8)
                    .shadow(color: isOn ? .white.opacity(0.85) : .clear, radius: 4)
            }
            .padding(.horizontal, 11)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isOn ? Color.white.opacity(0.09) : Color(white: 0.105))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                isOn ? Color.white.opacity(0.55) : Color.white.opacity(0.08),
                                lineWidth: isOn ? 1.1 : 1
                            )
                    )
                    .shadow(color: isOn ? Color.white.opacity(0.22) : .black.opacity(0.4), radius: isOn ? 7 : 4, y: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.34)
        .animation(GVMotion.micro, value: isOn)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(isOn ? "on" : "off")
    }
}

/// Shared formatting for capture labels.
enum GVCameraLabels {
    /// Turns `AVCaptureDeviceTypeBuiltInWideAngleCamera` into `WIDE`.
    static func lens(_ snapshot: CameraRuntimeSnapshot) -> String {
        let raw = snapshot.deviceType.uppercased()
        if raw.contains("ULTRAWIDE") { return "ULTRA WIDE" }
        if raw.contains("DUALWIDE") { return "DUAL WIDE" }
        if raw.contains("TELEPHOTO") { return "TELE" }
        if raw.contains("WIDE") { return "WIDE" }
        if raw.contains("TRUEDEPTH") { return "TRUEDEPTH" }
        if raw.contains("DUAL") { return "DUAL" }
        if raw.contains("TRIPLE") { return "TRIPLE" }
        let cleaned = raw
            .replacingOccurrences(of: "AVCAPTUREDEVICETYPE", with: "")
            .replacingOccurrences(of: "BUILTIN", with: "")
            .replacingOccurrences(of: "CAMERA", with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? snapshot.sourceLabel : cleaned
    }
}
