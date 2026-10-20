import SwiftUI
import UIKit

/// The control for one telemetry reading, opened directly under it.
///
/// Tapping `ISO 590` in the status line used to open the camera popout — six
/// unrelated controls, one of which was ISO — and tapping `60 FPS` opened the
/// settings popout, which has no frame-rate control in it at all. The reading
/// and the control for it were in different places, and for half the row the
/// control did not exist anywhere.
///
/// One row, for the field that was tapped, in the slot immediately beneath the
/// value it belongs to. A second tap on the same reading closes it; the HUD's
/// own idle timer closes it if the operator walks away.
struct GVFieldAdjuster: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var cameraRuntime: CameraRuntime
    @EnvironmentObject private var hud: GVHUDState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let field: GVTelemetryField
    /// Drives the plate: this panel sits in the top band, so how dark it needs
    /// to be is whatever the renderer measured up there.
    let statsMailbox: CameraRenderStatsMailbox
    /// Said in the workspace's notice line, where every other transient
    /// message is said.
    let onNotice: (String) -> Void

    /// Held here rather than read live on every frame.
    ///
    /// The status line above already prints the live reading at 4 Hz. If the
    /// track re-read the device mid-drag it would fight the drag every time
    /// the camera lagged a frame behind the finger — so the track owns its
    /// value from the moment it opens, seeded from the real one.
    @State private var drive: Double = 0

    var body: some View {
        Group {
            switch shape {
            case let .continuous(continuous):
                scrub(continuous)
            case let .discrete(discrete):
                chooser(discrete)
            case let .readOnly(note):
                readOnly(note)
            }
        }
        .padding(.horizontal, GVMetrics.stepInternal)
        .padding(.vertical, GVMetrics.stepMicro)
        .background { fieldBackground }
        .overlay(
            RoundedRectangle(cornerRadius: GVMetrics.radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.055), lineWidth: GVMetrics.hairline)
        )
        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
        .task(id: field) { seed() }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: GVMetrics.radius, style: .continuous)
            .fill(Color.black)
    }

    private var shape: GVFieldControl.Shape {
        GVFieldControl.shape(
            for: field,
            snapshot: cameraRuntime.snapshot,
            exposure: cameraRuntime.deviceTelemetryMailbox.latest,
            setup: appModel.setup,
            isRecording: cameraRuntime.isRecording
        )
    }

    /// Seeds the track from the live reading. Runs on open, and again if the
    /// operator moves to another field without closing first.
    private func seed() {
        guard case let .continuous(continuous) = shape else { return }
        drive = continuous.drive
    }
}

// MARK: - Continuous

private extension GVFieldAdjuster {
    /// The scrub track the effect deck already uses, so a camera parameter is
    /// driven with exactly the same gesture — and the same precision ramp — as
    /// an effect parameter.
    func scrub(_ continuous: GVFieldControl.Continuous) -> some View {
        HStack(spacing: GVMetrics.stepInternal) {
            GVTerminalParameterRow(
                label: field.controlLabel,
                value: Binding(
                    get: { drive },
                    set: { newValue in
                        drive = newValue
                        GVFieldControl.commit(field, drive: newValue, to: cameraRuntime)
                        hud.keepAlive()
                    }
                ),
                range: continuous.range,
                step: continuous.step,
                display: GVFieldControl.display(field, drive: drive),
                tint: Color.white,
                // Doubled from textSmall so the spawned slider matches the
                // enlarged telemetry row text.
                fontSize: GVMetrics.textSmall * 2,
                identifier: "workspace.field.\(field.rawValue)",
                // Camera fields are not part of the composition, so there is
                // no undo to bracket — but the HUD idle timer must not close
                // the control out from under a finger that is still moving.
                onEditingChanged: { editing in
                    hud.setAdjusting(editing)
                }
            )

            // Only for the two fields whose setters stop the device metering,
            // and only once it actually has. Driving ISO or shutter puts the
            // camera in custom exposure mode, and the way back has to be next
            // to the control that took it away.
            if field.holdsExposure, cameraRuntime.snapshot.exposureLocked {
                autoButton
            }
        }
    }

    var autoButton: some View {
        Button {
            cameraRuntime.resumeAutoExposure()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onNotice("Auto exposure restored")
            hud.keepAlive()
        } label: {
            Text("Auto")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GVTheme.warn)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, GVMetrics.stepInternal)
                .frame(height: GVMetrics.touchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        .accessibilityIdentifier("workspace.field.\(field.rawValue).auto")
        .accessibilityLabel("Restore auto exposure")
    }
}

// MARK: - Discrete

private extension GVFieldAdjuster {
    /// Format fields are a short list of exact choices, so they get chips
    /// rather than a track. A scrub between 30 and 120 with nothing in between
    /// would be a slider pretending three values are a continuum.
    func chooser(_ discrete: GVFieldControl.Discrete) -> some View {
        HStack(spacing: GVMetrics.stepInternal) {
            Text(field.controlLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(GVTheme.ash)
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("workspace.field.\(field.rawValue)")

            // FPS + RES have 3 options — shrink to fit with no scroll.
            // Codec may have many (HEVC/H264/ProRes) so it keeps horizontal
            // scroll, but now at the same shrunken scale and shared styling.
            if field == .codec {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: GVMetrics.stepMicro) {
                        ForEach(discrete.options) { option in
                            chip(option, isSelected: option.id == discrete.selectedID)
                        }
                    }
                    .padding(.trailing, GVMetrics.stepMicro)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            } else {
                HStack(spacing: 5) {
                    ForEach(discrete.options) { option in
                        chip(option, isSelected: option.id == discrete.selectedID)
                    }
                }
            }
        }
    }

    func chip(_ option: GVFieldControl.Option, isSelected: Bool) -> some View {
        // Unified at 0.82 — small enough for FPS/RES (3 chips) to fit
        // without scrolling, and codec now shares the same language.
        let visualScale: CGFloat = 0.82
        let isCodec = false

        return Button {
            select(option)
        } label: {
            Text(option.label)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? GVTheme.bone : GVTheme.ash)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, GVMetrics.stepInternal * visualScale)
                .frame(height: 26 * visualScale)
        }
        .buttonStyle(GVStardustFieldChipStyle(selected: isSelected, scale: visualScale, isCodec: isCodec))
        .frame(height: GVMetrics.touchTarget)
        .contentShape(Rectangle())
        .accessibilityIdentifier("workspace.field.\(field.rawValue).\(option.id.gvSlug)")
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Stardust chip style — darker, starfield-backed, monochrome.
    /// Used for codec selection and format fields to match CameraControlsView.
    private struct GVStardustFieldChipStyle: ButtonStyle {
        let selected: Bool
        let scale: CGFloat
        let isCodec: Bool

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

        private var pulseTint: SIMD3<Float> {
            SIMD3<Float>(0.7, 0.2, 1.0)
        }

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background { stardustBackground(isPressed: configuration.isPressed) }
                .overlay { stardustBorder(isPressed: configuration.isPressed) }
                .clipShape(RoundedRectangle(cornerRadius: GVMetrics.radiusTight * scale, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: GVMetrics.radiusTight * scale, style: .continuous))
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.96 : 1))
                .animation(GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion), value: configuration.isPressed)
        }

        @ViewBuilder
        private func stardustBackground(isPressed: Bool) -> some View {
            let baseTint = Color.black.opacity(isPressed ? 0.52 : (selected ? 0.62 : 0.58))
            ZStack {
                // Darker veil
                RoundedRectangle(cornerRadius: GVMetrics.radiusTight * scale, style: .continuous)
                    .fill(baseTint)
                if !reduceTransparency {
                    // Stardust field — very dim, slow
                    DeterministicStarfield()
                        .opacity(0.22)
                        .blur(radius: 0.6)
                        .clipShape(RoundedRectangle(cornerRadius: GVMetrics.radiusTight * scale, style: .continuous))
                    // Frost on top to keep blur + readability
                    RoundedRectangle(cornerRadius: GVMetrics.radiusTight * scale, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(0.55))
                    RoundedRectangle(cornerRadius: GVMetrics.radiusTight * scale, style: .continuous)
                        .fill(Color.black.opacity(0.22))
                }
            }
            .overlay {
                // subtle inner glow when pressed or selected
                if isPressed || selected {
                    RoundedRectangle(cornerRadius: GVMetrics.radiusTight * scale, style: .continuous)
                        .fill(Color.white.opacity(isPressed ? 0.06 : (selected ? 0.04 : 0)))
                }
            }
        }

        private func stardustBorder(isPressed: Bool) -> some View {
            RoundedRectangle(cornerRadius: GVMetrics.radiusTight * scale, style: .continuous)
                .strokeBorder(
                    isPressed ? Color.white.opacity(0.28) : (selected ? Color.white.opacity(0.4) : Color.white.opacity(0.10)),
                    lineWidth: isPressed ? 1.0 : (selected ? 1.0 : 0.5)
                )
                .modifier(GVLightReactiveBorderOverlay(radius: GVMetrics.radiusTight * scale, baseOpacity: isPressed ? 0.22 : (selected ? 0.18 : 0.10), lightLevel: GVAmbientLight.shared.level, lineWidth: 0.5))
        }
    }

    /// Format changes are not live. Frame rate, resolution and codec are all
    /// decided when the session is configured, so picking one tears the
    /// session down and starts it again — which is a second of black preview.
    /// It says so rather than looking like a crash.
    func select(_ option: GVFieldControl.Option) {
        guard GVFieldControl.apply(field, optionID: option.id, to: &appModel.setup) else {
            hud.keepAlive()
            return
        }
        GVParameterHaptics.select()
        onNotice("\(field.controlLabel): \(option.label) · Reconfiguring")
        appModel.restartEngine()
        hud.clearField()
    }
}

// MARK: - Read only

private extension GVFieldAdjuster {
    /// Nothing in the capture layer can set this. Saying so is the control.
    func readOnly(_ note: String) -> some View {
        HStack(spacing: GVMetrics.stepInternal) {
            Text(field.controlLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(GVTheme.ash)
            Text(note)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(GVTheme.faint)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(height: GVMetrics.touchTarget)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workspace.field.\(field.rawValue)")
    }
}

extension String {
    /// Identifier-safe form, so an accessibility identifier built from a codec
    /// name like `PRORES 422 HQ` is stable and greppable.
    var gvSlug: String {
        lowercased()
            .replacingOccurrences(of: ".", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: "-")
    }
}
