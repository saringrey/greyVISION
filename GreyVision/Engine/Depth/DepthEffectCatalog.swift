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
    /// Modes that must keep rendering even when nothing the operator touched
    /// changed.
    static func isAnimated(_ mode: DepthEffectMode) -> Bool {
        [.worldGrid, .nightVision, .subjectDecay].contains(mode)
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

    /// Every consolidated mode declares exactly four effect knobs, because the
    /// four pack into one `SIMD4<Float>`: a fifth would be silently dropped
    /// before it reached the shader. Point cloud is the one exception — two of
    /// its six knobs are rasterisation settings the vertex stage reads through
    /// separate uniform lanes (`tuning.w`, `source.z`).
    static func effectControls(for mode: DepthEffectMode) -> [DepthParameterDescriptor] {
        func physical(_ name: String, _ key: WritableKeyPath<DepthEffectParameters, Double>, _ range: ClosedRange<Double>, _ value: Double, _ unit: String) -> DepthParameterDescriptor {
            DepthParameterDescriptor(id: name, keyPath: key, range: range, defaultValue: value, unit: unit, normalizedStorage: true)
        }
        func percent(_ name: String, _ key: WritableKeyPath<DepthEffectParameters, Double>, _ value: Double) -> DepthParameterDescriptor {
            physical(name, key, 0 ... 1, value, "%")
        }
        switch mode {
        case .pointCloud:
            return [
                DepthParameterDescriptor(id: "POINT SIZE", keyPath: \.pointSize, range: 1 ... 7, defaultValue: 3.2, unit: "PX"),
                DepthParameterDescriptor(id: "SAMPLE STEP", keyPath: \.sampleStride, range: 1 ... 6, defaultValue: 1, unit: "PX"),
                percent("DEPTH SIZE", \.falloff, 0.55),
                percent("COLOUR MIX", \.detail, 0.5),
                DepthParameterDescriptor(id: "YAW", keyPath: \.yawDegrees, range: -35 ... 35, defaultValue: 0, unit: "°"),
                DepthParameterDescriptor(id: "PITCH", keyPath: \.pitchDegrees, range: -28 ... 28, defaultValue: 0, unit: "°")
            ]
        case .depthMap:
            // LEVELS absorbs the old posterize mode, BLOCK SIZE the old mosaic:
            // both were only ever how far apart range buckets sit and how
            // coarsely the range is sampled.
            return [
                physical("LEVELS", \.detail, 1 ... 24, 1, "STEP"),
                physical("BLOCK SIZE", \.bandWidth, 0.01 ... 1, 0.01, "PX"),
                percent("RANGE CURVE", \.falloff, 0.5),
                percent("PALETTE", \.bandCenter, 0.4)
            ]
        case .contours:
            // FILL absorbs the old bands mode; EDGE GLOW absorbs the old depth
            // edges and depth glow modes, which were the same gradient test.
            return [
                physical("SPACING", \.falloff, 0.02 ... 0.6, 0.09, "M"),
                physical("LINE WEIGHT", \.bandWidth, 0.01 ... 1, 0.09, "PX"),
                percent("FILL", \.detail, 0.25),
                percent("EDGE GLOW", \.bandCenter, 0.35)
            ]
        case .depthSlice:
            // ISOLATE absorbs the old foreground cutout, and the atmosphere
            // term absorbs the old fog: both are what happens beyond focus.
            return [
                physical("FOCUS", \.falloff, 0.2 ... 6, 1.3, "M"),
                physical("DEPTH OF FIELD", \.detail, 0.05 ... 4, 0.6, "M"),
                percent("BLUR", \.bandCenter, 0.5),
                percent("ISOLATE", \.bandWidth, 0.12)
            ]

        case .depthWarp:
            // CHROMA absorbs the old depth-chromatic mode: a range-weighted
            // channel split is the same displacement, applied per channel.
            return [
                percent("DISPLACE", \.falloff, 0.55),
                percent("CURVE", \.detail, 0.5),
                percent("CHROMA", \.bandCenter, 0.25),
                percent("STIR", \.bandWidth, 0.5)
            ]
        case .surfaceRelight:
            // MATERIAL slides to 1 for the raw normals that used to be their
            // own mode. They are the same computation, one is just unlit.
            return [
                physical("LIGHT ANGLE", \.falloff, -180 ... 180, -35, "°"),
                physical("ELEVATION", \.detail, 5 ... 85, 45, "°"),
                physical("ROUGHNESS", \.bandCenter, 0.05 ... 1, 0.3, "%"),
                percent("MATERIAL", \.bandWidth, 0)
            ]
        case .worldGrid:
            // PULSE SPEED and ECHO WIDTH are the whole of the old sonar-pulse
            // mode, now layered on the metric grid it used to compete with.
            return [
                physical("CELL SIZE", \.falloff, 0.05 ... 1, 0.25, "M"),
                physical("LINE WIDTH", \.detail, 0.5 ... 3, 1, "PX"),
                physical("PULSE SPEED", \.bandCenter, 0.15 ... 3, 0.75, "M/S"),
                physical("ECHO WIDTH", \.bandWidth, 0.02 ... 0.5, 0.08, "M")
            ]
        case .subjectDecay:
            return [
                percent("DECAY", \.falloff, 0.55),
                percent("FLOW", \.detail, 0.5),
                percent("EDGE", \.bandWidth, 0.18),
                percent("TRAIL", \.bandCenter, 0.42)
            ]
        case .nightVision:
            return [
                percent("TUBE GAIN", \.falloff, 0.55),
                percent("SCINTILLATION", \.detail, 0.5),
                percent("IR FALLOFF", \.bandWidth, 0.18),
                percent("RANGE GATE", \.bandCenter, 0.42)
            ]
        }
    }
}

