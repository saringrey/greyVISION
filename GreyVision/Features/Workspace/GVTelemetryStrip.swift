import SwiftUI
import UIKit

/// The capture metadata row, as the instrument's primary motif.
///
/// Reads: `60 FPS   4K   180°   ISO 590   2725K   SDR   PR422`
///
/// Every value is polled from the live capture pipeline — `CameraRuntime`'s
/// snapshot and the exposure mailbox — inside one `TimelineView` at 4 Hz.
/// Nothing here is a placeholder, and where a value cannot be read the field
/// prints dashes rather than inventing a plausible number.
///
/// Fields are tappable, and a tap opens the control for that field and
/// nothing else, directly beneath the reading it belongs to. See
/// `GVFieldAdjuster`.
struct GVTelemetryStrip: View {
    @EnvironmentObject private var cameraRuntime: CameraRuntime
    @EnvironmentObject private var audioRuntime: AudioReactiveRuntime
    @EnvironmentObject private var hud: GVHUDState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Read only for the shed count. The governor drops effects silently
    /// otherwise, and an operator watching their stack stop working has no way
    /// to tell a shed from a broken effect.
    let statsMailbox: CameraRenderStatsMailbox
    /// Reports what just happened with exposure, so the workspace can say it
    /// where notices are said.
    let onExposureNotice: (String) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 1.0 : 0.25)) { _ in
            let snapshot = cameraRuntime.snapshot
            let exposure = cameraRuntime.deviceTelemetryMailbox.latest
            let shed = statsMailbox.latest.shedEffects
            let audio = audioRuntime.snapshot

            HStack(spacing: GVMetrics.stepRelated) {
                ForEach(Self.order, id: \.self) { field in
                    item(field, value: value(field, snapshot: snapshot, exposure: exposure))
                }
                if audio.rms > 0.005 || audio.peak > 0.005 {
                    audioSpectrogram(audio)
                }
                if shed > 0 {
                    shedNotice(shed)
                }
            }
            // No identifier on the row itself: SwiftUI propagates a container
            // identifier down over its children, so one here overwrote every
            // field's own — which is why `workspace.status.shed` and each
            // field button all resolved as `workspace.status.line`.
            .frame(maxWidth: .infinity)
        }
    }

    private func audioSpectrogram(_ audio: AudioReactiveSnapshot) -> some View {
        let values: [Float] = [
            audio.bass,
            (audio.bass + audio.mid) * 0.5,
            audio.mid,
            (audio.mid + audio.treble) * 0.5,
            audio.treble,
            audio.peak
        ]
        return HStack(spacing: 1.5) {
            ForEach(0 ..< values.count, id: \.self) { idx in
                let val = values[idx]
                let barHeight = max(2.0, min(10.0, CGFloat(val) * 12.0))
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(val > 0.7 ? GVTheme.record : (val > 0.35 ? GVTheme.violet : GVTheme.ash))
                    .frame(width: 1.5, height: barHeight)
            }
        }
        .frame(height: 10, alignment: .bottom)
        .padding(.horizontal, 2)
        .accessibilityIdentifier("workspace.telemetry.audio")
        .accessibilityLabel("Audio Spectrum")
    }

    /// Only present while the governor is actually shedding. `warn`, not
    /// `record`: the instrument is degrading, not failing.
    private func shedNotice(_ count: Int) -> some View {
        Text("SHED \(count)")
            .gvFont(.telemetry)
            .monospacedDigit()
            .tracking(GVTheme.TypeLevel.telemetry.tracking)
            .foregroundStyle(GVTheme.warn)
            .shadow(color: .black.opacity(0.9), radius: 2, y: 0.5)
            .lineLimit(1)
            .fixedSize()
            .padding(.vertical, GVMetrics.stepRelated)
            .transition(.opacity)
            .accessibilityIdentifier("workspace.status.shed")
            .accessibilityLabel("Effects shed for frame rate")
            .accessibilityValue("\(count)")
    }

    private func restoreAutoExposure() {
        cameraRuntime.resumeAutoExposure()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onExposureNotice("EXPOSURE // AUTO RESTORED")
    }

    private static let order: [GVTelemetryField] = [
        .frameRate, .resolution, .shutter, .iso, .whiteBalance, .dynamicRange, .codec
    ]

    private func item(_ field: GVTelemetryField, value: String) -> some View {
        let isActive = hud.activeField == field
        // Manual exposure is a state the camera is *in*, not a thing the
        // operator did once. Driving ISO or shutter stops the device metering,
        // and until this was surfaced there was no sign of it on screen and no
        // way back short of restarting the engine.
        let isManual = field.holdsExposure && cameraRuntime.snapshot.exposureLocked

        return Button {
            hud.select(field)
        } label: {
            // `M` for manual, the way a cine camera marks it. Not colour
            // alone: warn on its own would be invisible to anyone who cannot
            // separate it from ash.
            Text(isManual ? "\(value) M" : value)
                .gvFont(.telemetry)
                .monospacedDigit()
                .tracking(GVTheme.TypeLevel.telemetry.tracking)
                .foregroundStyle(isActive ? GVTheme.violet : (isManual ? GVTheme.warn : GVTheme.ash))
                .shadow(color: .black.opacity(0.9), radius: 2, y: 0.5)
                .lineLimit(1)
                .fixedSize()
                .overlay(alignment: .bottom) {
                    // Selection is a rule under the value, not a box around
                    // it. A pill here would make seven pills.
                    Rectangle()
                        .fill(GVTheme.violet)
                        .frame(height: 1)
                        .offset(y: 3)
                        .opacity(isActive ? 1 : 0)
                }
                // Drawn small, tapped at full height.
                .padding(.vertical, GVMetrics.stepRelated)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Hold either exposure field to hand metering back. The first time the
        // camera goes manual the workspace says so in the notice line, so this
        // is a stated gesture rather than a discovered one.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                guard isManual else { return }
                restoreAutoExposure()
            }
        )
        .animation(GVMotion.resolved(GVMotion.snap, reduceMotion: reduceMotion), value: isActive)
        .accessibilityIdentifier("workspace.status.\(field.rawValue)")
        .accessibilityLabel(field.railLabel)
        .accessibilityValue(isManual ? "\(value), manual" : value)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .accessibilityAction(named: "Restore auto exposure") {
            guard isManual else { return }
            restoreAutoExposure()
        }
    }

    // MARK: - Values

    private func value(
        _ field: GVTelemetryField,
        snapshot: CameraRuntimeSnapshot,
        exposure: CameraDeviceTelemetry
    ) -> String {
        switch field {
        case .frameRate:
            snapshot.framesPerSecond > 0 ? "\(snapshot.framesPerSecond) FPS" : "-- FPS"
        case .resolution:
            resolution(snapshot)
        case .shutter:
            shutterAngle(exposure: exposure, fps: snapshot.framesPerSecond)
        case .iso:
            exposure.isValid ? "ISO \(Int(exposure.iso.rounded()))" : "ISO ---"
        case .whiteBalance:
            exposure.isValid && exposure.whiteBalanceKelvin > 0
                ? "\(exposure.whiteBalanceKelvin)K"
                : "----K"
        case .dynamicRange:
            snapshot.hdrEnabled ? "HDR" : "SDR"
        case .codec:
            snapshot.requestedVideoCodec.compactLabel
        case .zoom:
            String(format: "%.2f×", snapshot.zoom)
        case .exposure:
            String(format: "%+.1f", snapshot.exposureBias)
        }
    }

    private func resolution(_ snapshot: CameraRuntimeSnapshot) -> String {
        let label = snapshot.formatLabel.uppercased()
        if label.contains("4K") || label.contains("3840") || label.contains("2160") { return "4K" }
        if label.contains("1080") { return "1080P" }
        if label.contains("720") { return "720P" }
        return label.isEmpty ? "----" : String(label.prefix(6))
    }

    /// Shutter as an angle, the way it is read on a cine camera: 180° is the
    /// familiar half-the-frame-interval exposure.
    private func shutterAngle(exposure: CameraDeviceTelemetry, fps: Int) -> String {
        guard exposure.isValid, exposure.shutterDenominator > 0, fps > 0 else { return "---°" }
        let angle = 360.0 * Double(fps) / Double(exposure.shutterDenominator)
        return "\(Int(angle.rounded()))°"
    }
}
