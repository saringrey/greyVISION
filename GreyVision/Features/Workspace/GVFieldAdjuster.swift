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
        // Measured, not guessed. A fixed plate is invisible over a night
        // scene and not nearly enough over a white wall — and this panel is
        // the one place a wrong number gets set if the label cannot be read.
        .gvAdaptivePlate(
            statsMailbox,
            band: \.topChromeLoad,
            cornerRadius: GVMetrics.radius,
            quiet: 0.30,
            loud: 0.88
        )
        .overlay(
            RoundedRectangle(cornerRadius: GVMetrics.radius, style: .continuous)
                .strokeBorder(GVTheme.separatorActive.opacity(0.5), lineWidth: GVMetrics.hairline)
        )
        .task(id: field) { seed() }
        // No identifier on the panel: SwiftUI propagates a container's
        // identifier down over its children's own, so one here would rename
        // every chip inside it. Each shape names its own head element instead.
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
                tint: GVTheme.violet,
                fontSize: GVMetrics.textSmall,
                identifier: "workspace.field.\(field.rawValue)"
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
            onNotice("EXPOSURE // AUTO RESTORED")
            hud.keepAlive()
        } label: {
            Text("AUTO")
                .gvMono(GVMetrics.textSmall, .black)
                .tracking(0.7)
                .foregroundStyle(GVTheme.warn)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, GVMetrics.stepInternal)
                .frame(height: GVMetrics.touchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                .gvMono(GVMetrics.textSmall, .bold)
                .tracking(0.68)
                .foregroundStyle(GVTheme.ash)
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("workspace.field.\(field.rawValue)")

            // Codec can be a dozen entries on a ProRes-capable device; frame
            // rate is three. Scrolling handles both without a second layout.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: GVMetrics.stepMicro) {
                    ForEach(discrete.options) { option in
                        chip(option, isSelected: option.id == discrete.selectedID)
                    }
                }
                .padding(.trailing, GVMetrics.stepMicro)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }

    func chip(_ option: GVFieldControl.Option, isSelected: Bool) -> some View {
        let visualScale: CGFloat = field == .codec ? 0.9 : 1

        return Button {
            select(option)
        } label: {
            Text(option.label)
                .gvMono(GVMetrics.textSmall * visualScale, isSelected ? .black : .bold)
                .tracking(0.6 * visualScale)
                .foregroundStyle(isSelected ? GVTheme.bone : GVTheme.ash)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, GVMetrics.stepInternal * visualScale)
                .frame(height: 26 * visualScale)
                .background(
                    RoundedRectangle(cornerRadius: GVMetrics.radiusTight, style: .continuous)
                        .fill(isSelected ? GVTheme.violet.opacity(0.34) : Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: GVMetrics.radiusTight, style: .continuous)
                        .strokeBorder(
                            isSelected ? GVTheme.violet : GVTheme.separator,
                            lineWidth: GVMetrics.hairline
                        )
                )
                // Drawn at 26pt, tapped at the full minimum.
                .frame(height: GVMetrics.touchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workspace.field.\(field.rawValue).\(option.id.gvSlug)")
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
        onNotice("\(field.controlLabel) // \(option.label) — RECONFIGURING")
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
                .gvMono(GVMetrics.textSmall, .bold)
                .foregroundStyle(GVTheme.ash)
            Text(note)
                .gvMono(GVMetrics.textMicro, .bold)
                .foregroundStyle(GVTheme.faint)
            Spacer(minLength: 0)
        }
        .tracking(0.68)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
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
