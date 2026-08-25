import SwiftUI

/// LiDAR effect parameters on the shared compact rail — one header row and
/// one horizontal slider row, matching FX.PARAM so switching between camera
/// effects and depth effects never feels like a different instrument.
struct DepthEffectParameterDeck: View {
    let effect: DepthEffectMode
    @Binding var parameters: DepthEffectParameters
    @EnvironmentObject private var toasts: GVToastBox
    let onClose: () -> Void
    let onExitDepth: () -> Void

    private struct Spec: Identifiable {
        let id: String
        let label: String
        let value: Binding<Double>
        let defaultValue: Double
        let range: ClosedRange<Double>
        let format: (Double) -> String
    }

    var body: some View {
        VStack(spacing: 6) {
            headerRow
            sliderRow
                .gvScrollProgressLine()
        }
        .gvCompactDeckPlate()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.parameters.depth.\(effect.rawValue)")
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 5) {
            GVTerminalText(
                text: "LIDAR.PARAM // \(effect.label)",
                size: GVMetrics.textSmall,
                weight: .black,
                tracking: 1.1,
                alignment: .leading,
                intensity: 1.1
            )

            Spacer(minLength: 6)

            GVDeckChip(label: "RST", id: "depth.reset") {
                parameters = .defaults
                toasts.show("LIDAR // \(effect.label) RESET")
            }
            GVDeckChip(label: "EXIT", symbol: "camera.aperture", id: "depth.exit") {
                onExitDepth()
                onClose()
            }
            GVDeckChip(label: "", symbol: "xmark", id: "depth.close") {
                onClose()
            }
        }
    }

    // MARK: - Sliders

    private var sliderRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(specs) { spec in
                    GVRailSlider(
                        label: spec.label,
                        value: spec.value,
                        defaultValue: spec.defaultValue,
                        range: spec.range,
                        format: spec.format
                    )
                    .accessibilityIdentifier("workspace.param.depth.\(spec.id.lowercased())")
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 1)
            .padding(.bottom, 3)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .gvHorizontalEdgeFade()
    }

    // MARK: - Parameter map

    private var specs: [Spec] {
        var list: [Spec] = [
            Spec(
                id: "NEAR", label: "NEAR",
                value: $parameters.nearMeters,
                defaultValue: DepthEffectParameters.defaults.nearMeters,
                range: 0.08...1.0,
                format: { String(format: "%.2f M", $0) }
            ),
            Spec(
                id: "FAR", label: "FAR",
                value: $parameters.farMeters,
                defaultValue: DepthEffectParameters.defaults.farMeters,
                range: 1.2...8.0,
                format: { String(format: "%.1f M", $0) }
            ),
            Spec(
                id: "INTENSITY", label: "INTENSITY",
                value: $parameters.intensity,
                defaultValue: DepthEffectParameters.defaults.intensity,
                range: 0...1.5,
                format: { "\(Int($0 * 100))%" }
            ),
            Spec(
                id: "CONFIDENCE", label: "CONFIDENCE",
                value: $parameters.confidenceThreshold,
                defaultValue: DepthEffectParameters.defaults.confidenceThreshold,
                range: 0...2,
                format: { _ in confidenceLabel }
            )
        ]
        list.append(contentsOf: effectSpecs)
        return list
    }

    private var effectSpecs: [Spec] {
        let defaults = DepthEffectParameters.defaults
        return switch effect {
        case .pointCloud:
            [
                Spec(id: "POINT SIZE", label: "POINT SIZE", value: $parameters.pointSize, defaultValue: defaults.pointSize, range: 1...7, format: { String(format: "%.1f PX", $0) }),
                Spec(id: "SAMPLE STEP", label: "SAMPLE STEP", value: $parameters.sampleStride, defaultValue: defaults.sampleStride, range: 1...6, format: { "\(Int($0.rounded())) PX" }),
                Spec(id: "YAW", label: "YAW", value: $parameters.yawDegrees, defaultValue: defaults.yawDegrees, range: -35...35, format: degrees),
                Spec(id: "PITCH", label: "PITCH", value: $parameters.pitchDegrees, defaultValue: defaults.pitchDegrees, range: -28...28, format: degrees),
                normalized("DEPTH SIZE", $parameters.falloff, defaults.falloff),
                normalized("COLOR MIX", $parameters.detail, defaults.detail)
            ]
        case .depthMap:
            [normalized("PALETTE", $parameters.falloff, defaults.falloff), normalized("CONTRAST", $parameters.detail, defaults.detail)]
        case .depthEdges:
            [normalized("EDGE WIDTH", $parameters.falloff, defaults.falloff), normalized("THRESHOLD", $parameters.detail, defaults.detail)]
        case .depthWarp:
            [normalized("WARP SCALE", $parameters.falloff, defaults.falloff), normalized("CURVE", $parameters.detail, defaults.detail)]
        case .confidence:
            [normalized("LOW COLOR", $parameters.falloff, defaults.falloff), normalized("HIGH COLOR", $parameters.detail, defaults.detail)]
        case .fog:
            [normalized("DENSITY CURVE", $parameters.falloff, defaults.falloff), normalized("FOG COLOR", $parameters.detail, defaults.detail)]
        case .depthSlice:
            [
                normalized("CENTER", $parameters.bandCenter, defaults.bandCenter),
                normalized("WIDTH", $parameters.bandWidth, defaults.bandWidth),
                normalized("FEATHER", $parameters.detail, defaults.detail)
            ]
        case .contours:
            [
                normalized("FREQUENCY", $parameters.detail, defaults.detail),
                normalized("LINE WIDTH", $parameters.bandWidth, defaults.bandWidth),
                normalized("PHASE", $parameters.bandCenter, defaults.bandCenter)
            ]
        case .depthPosterize:
            [normalized("LEVELS", $parameters.detail, defaults.detail), normalized("PALETTE", $parameters.falloff, defaults.falloff)]
        case .surfaceNormals:
            [normalized("STRENGTH", $parameters.detail, defaults.detail), normalized("SMOOTH", $parameters.falloff, defaults.falloff)]
        case .foregroundCutout:
            [
                normalized("CUT RANGE", $parameters.bandCenter, defaults.bandCenter),
                normalized("FEATHER", $parameters.bandWidth, defaults.bandWidth),
                normalized("EDGE", $parameters.detail, defaults.detail)
            ]
        case .depthChromatic:
            [normalized("OFFSET", $parameters.detail, defaults.detail), normalized("DEPTH CURVE", $parameters.falloff, defaults.falloff)]
        case .depthMosaic:
            [normalized("BLOCK SIZE", $parameters.detail, defaults.detail), normalized("DEPTH SCALE", $parameters.falloff, defaults.falloff)]
        case .depthGlow:
            [
                normalized("GLOW", $parameters.detail, defaults.detail),
                normalized("WIDTH", $parameters.bandWidth, defaults.bandWidth),
                normalized("THRESHOLD", $parameters.falloff, defaults.falloff)
            ]
        case .depthBands:
            [
                normalized("FREQUENCY", $parameters.detail, defaults.detail),
                normalized("WIDTH", $parameters.bandWidth, defaults.bandWidth),
                normalized("PHASE", $parameters.bandCenter, defaults.bandCenter)
            ]
        case .nightVision:
            [
                normalized("SCINTILLATION", $parameters.detail, defaults.detail),
                normalized("TUBE GAIN", $parameters.falloff, defaults.falloff),
                normalized("IR FALLOFF", $parameters.bandWidth, defaults.bandWidth),
                normalized("RANGE GATE", $parameters.bandCenter, defaults.bandCenter)
            ]
        case .subjectDecay:
            [
                normalized("DECAY", $parameters.falloff, defaults.falloff),
                normalized("FLOW", $parameters.detail, defaults.detail),
                normalized("EDGE", $parameters.bandWidth, defaults.bandWidth),
                normalized("TRAIL", $parameters.bandCenter, defaults.bandCenter)
            ]
        }
    }

    private func normalized(_ label: String, _ value: Binding<Double>, _ defaultValue: Double) -> Spec {
        Spec(
            id: label, label: label,
            value: value,
            defaultValue: defaultValue,
            range: 0...1,
            format: percentage
        )
    }

    private var degrees: (Double) -> String {
        { "\(Int($0.rounded()))\u{00B0}" }
    }

    private func percentage(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private var confidenceLabel: String {
        switch Int(parameters.confidenceThreshold.rounded()) {
        case 2: "HIGH"
        case 1: "MED+"
        default: "ALL"
        }
    }
}
