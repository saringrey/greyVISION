import Foundation

/// Physical UI units and normalized session storage share a single definition.
struct DepthParameterDescriptor: Identifiable {
    let id: String
    let keyPath: WritableKeyPath<DepthEffectParameters, Double>
    let range: ClosedRange<Double>
    let defaultValue: Double
    var unit: String = "%"
    var normalizedStorage = false

    func value(in parameters: DepthEffectParameters) -> Double {
        let raw = parameters[keyPath: keyPath]
        let stored = raw.isFinite ? raw : (normalizedStorage ? 0.5 : defaultValue)
        return normalizedStorage ? range.lowerBound + stored * (range.upperBound - range.lowerBound) : stored
    }

    func set(_ value: Double, in parameters: inout DepthEffectParameters) {
        let finite = value.isFinite ? value : defaultValue
        let clamped = min(max(finite, range.lowerBound), range.upperBound)
        parameters[keyPath: keyPath] = normalizedStorage
            ? (clamped - range.lowerBound) / (range.upperBound - range.lowerBound) : clamped
    }

    func formatted(_ value: Double) -> String {
        let finite = value.isFinite ? value : defaultValue
        switch unit {
        case "%": return String(format: "%.0f%%", finite * 100)
        case "°": return String(format: "%.0f°", finite)
        case "CONF": return finite >= 1.5 ? "HIGH" : finite >= 0.5 ? "MED+" : "ALL"
        case "M", "M/S": return String(format: "%.2f %@", finite, unit)
        default: return String(format: "%.1f %@", finite, unit)
        }
    }
}

enum DepthEffectCatalog {
    static func canonicalMode(for mode: DepthEffectMode) -> DepthEffectMode {
        switch mode {
        case .depthBands: .contours
        case .depthGlow: .depthEdges
        default: mode
        }
    }

    static func variants(for mode: DepthEffectMode) -> [DepthEffectMode] {
        switch canonicalMode(for: mode) {
        case .contours: [.contours, .depthBands]
        case .depthEdges: [.depthEdges, .depthGlow]
        default: [mode]
        }
    }

    static func isAnimated(_ mode: DepthEffectMode) -> Bool {
        [.sonarPulse, .nightVision, .subjectDecay].contains(mode)
    }

    static func controls(for mode: DepthEffectMode) -> [DepthParameterDescriptor] {
        controlPages(for: mode).flatMap(\.self)
    }

    static func controlPages(for mode: DepthEffectMode) -> [[DepthParameterDescriptor]] {
        // Keep effect controls on the first page, acquisition gates on page two.
        let defining = effectControls(for: mode)
        let first = [DepthParameterDescriptor(id: "INTENSITY", keyPath: \.intensity, range: 0 ... 1.5, defaultValue: 0.72)] + Array(defining.prefix(3))
        let acquisition = [
            DepthParameterDescriptor(id: "NEAR", keyPath: \.nearMeters, range: 0.08 ... 1, defaultValue: 0.18, unit: "M"),
            DepthParameterDescriptor(id: "FAR", keyPath: \.farMeters, range: 1.2 ... 8, defaultValue: 5, unit: "M"),
            DepthParameterDescriptor(id: "CONFIDENCE", keyPath: \.confidenceThreshold, range: 0 ... 2, defaultValue: 0, unit: "CONF")
        ]
        let remaining = Array(defining.dropFirst(3))
        var pages = [first, acquisition + Array(remaining.prefix(1))]
        if remaining.count > 1 { pages.append(Array(remaining.dropFirst())) }
        return pages
    }

    static func effectControls(for mode: DepthEffectMode) -> [DepthParameterDescriptor] {
        func normalized(_ name: String, _ key: WritableKeyPath<DepthEffectParameters, Double>, _ value: Double) -> DepthParameterDescriptor {
            DepthParameterDescriptor(id: name, keyPath: key, range: 0 ... 1, defaultValue: value)
        }
        func physical(_ name: String, _ key: WritableKeyPath<DepthEffectParameters, Double>, _ range: ClosedRange<Double>, _ value: Double, _ unit: String) -> DepthParameterDescriptor {
            DepthParameterDescriptor(id: name, keyPath: key, range: range, defaultValue: value, unit: unit, normalizedStorage: true)
        }
        switch mode {
        case .surfaceRelight:
            return [physical("LIGHT ANGLE", \.falloff, -180 ... 180, -35, "°"), physical("ELEVATION", \.detail, 5 ... 85, 45, "°"), physical("ROUGHNESS", \.bandCenter, 0.08 ... 1, 0.35, "%")]
        case .worldGrid:
            return [physical("CELL SIZE", \.falloff, 0.05 ... 1, 0.25, "M"), physical("LINE WIDTH", \.detail, 0.5 ... 3, 1, "PX"), physical("AXIS MIX", \.bandCenter, 0 ... 1, 1, "%")]
        case .sonarPulse:
            return [physical("SPEED", \.falloff, 0.15 ... 3, 0.75, "M/S"), physical("WIDTH", \.detail, 0.02 ... 0.5, 0.08, "M"), physical("TRAIL", \.bandCenter, 0 ... 1, 0.45, "%")]
        case .pointCloud:
            return [DepthParameterDescriptor(id: "POINT SIZE", keyPath: \.pointSize, range: 1 ... 7, defaultValue: 3.2, unit: "PX"), normalized("DEPTH SIZE", \.falloff, 0.55), normalized("COLOR MIX", \.detail, 0.5), DepthParameterDescriptor(id: "SAMPLE STEP", keyPath: \.sampleStride, range: 1 ... 6, defaultValue: 1, unit: "PX"), DepthParameterDescriptor(id: "YAW", keyPath: \.yawDegrees, range: -35 ... 35, defaultValue: 0, unit: "°"), DepthParameterDescriptor(id: "PITCH", keyPath: \.pitchDegrees, range: -28 ... 28, defaultValue: 0, unit: "°")]
        case .depthMap: return [normalized("PALETTE", \.falloff, 0.55), normalized("CONTRAST", \.detail, 0.5)]
        case .depthEdges: return [normalized("EDGE WIDTH", \.falloff, 0.55), normalized("THRESHOLD", \.detail, 0.5)]
        case .depthWarp: return [normalized("WARP SCALE", \.falloff, 0.55), normalized("CURVE", \.detail, 0.5)]
        case .confidence: return [normalized("LOW COLOR", \.falloff, 0.55), normalized("HIGH COLOR", \.detail, 0.5)]
        case .fog: return [normalized("DENSITY CURVE", \.falloff, 0.55), normalized("FOG COLOR", \.detail, 0.5)]
        case .depthSlice: return [normalized("CENTER", \.bandCenter, 0.42), normalized("WIDTH", \.bandWidth, 0.18), normalized("FEATHER", \.detail, 0.5)]
        case .contours, .depthBands: return [normalized("FREQUENCY", \.detail, 0.5), normalized("LINE WIDTH", \.bandWidth, 0.18), normalized("PHASE", \.bandCenter, 0.42)]
        case .depthPosterize: return [normalized("LEVELS", \.detail, 0.5), normalized("PALETTE", \.falloff, 0.55)]
        case .surfaceNormals: return [normalized("STRENGTH", \.detail, 0.5), normalized("SMOOTH", \.falloff, 0.55)]
        case .foregroundCutout: return [normalized("CUT RANGE", \.bandCenter, 0.42), normalized("FEATHER", \.bandWidth, 0.18), normalized("EDGE", \.detail, 0.5)]
        case .depthChromatic: return [normalized("OFFSET", \.detail, 0.5), normalized("DEPTH CURVE", \.falloff, 0.55)]
        case .depthMosaic: return [normalized("BLOCK SIZE", \.detail, 0.5), normalized("DEPTH SCALE", \.falloff, 0.55)]
        case .depthGlow: return [normalized("GLOW", \.detail, 0.5), normalized("WIDTH", \.bandWidth, 0.18), normalized("THRESHOLD", \.falloff, 0.55)]
        case .nightVision: return [normalized("TUBE GAIN", \.falloff, 0.55), normalized("SCINTILLATION", \.detail, 0.5), normalized("IR FALLOFF", \.bandWidth, 0.18), normalized("RANGE GATE", \.bandCenter, 0.42)]
        case .subjectDecay: return [normalized("DECAY", \.falloff, 0.55), normalized("FLOW", \.detail, 0.5), normalized("EDGE", \.bandWidth, 0.18), normalized("TRAIL", \.bandCenter, 0.42)]
        }
    }
}
