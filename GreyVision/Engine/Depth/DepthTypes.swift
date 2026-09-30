@preconcurrency import ARKit
import CoreVideo
import Foundation
import simd

enum DepthEffectMode: UInt32, CaseIterable, Identifiable, Sendable {
    case pointCloud
    case depthMap
    case depthEdges
    case depthWarp
    case confidence
    case fog
    case depthSlice
    case contours
    case depthPosterize
    case surfaceNormals
    case foregroundCutout
    case depthChromatic
    case depthMosaic
    case depthGlow
    case depthBands
    case subjectDecay
    /// Image-intensifier emulation driven by LiDAR range.
    case nightVision

    case surfaceRelight = 17
    case worldGrid = 18
    case sonarPulse = 19

    var id: UInt32 {
        rawValue
    }

    var label: String {
        switch self {
        case .surfaceRelight: "SURFACE RELIGHT"
        case .worldGrid: "WORLD GRID"
        case .sonarPulse: "SONAR PULSE"
        case .pointCloud: "POINT CLOUD"
        case .depthMap: "DEPTH MAP"
        case .depthEdges: "DEPTH EDGES"
        case .depthWarp: "DEPTH WARP"
        case .confidence: "CONFIDENCE"
        case .fog: "DEPTH FOG"
        case .depthSlice: "DEPTH SLICE"
        case .contours: "CONTOURS"
        case .depthPosterize: "DEPTH POSTERIZE"
        case .surfaceNormals: "SURFACE NORMALS"
        case .foregroundCutout: "FOREGROUND CUTOUT"
        case .depthChromatic: "DEPTH CHROMATIC"
        case .depthMosaic: "DEPTH MOSAIC"
        case .depthGlow: "DEPTH GLOW"
        case .depthBands: "DEPTH BANDS"
        case .subjectDecay: "SUBJECT DECAY"
        case .nightVision: "NIGHT VISION"
        }
    }

    var detail: String {
        switch self {
        case .surfaceRelight: "CALIBRATED SURFACE LIGHT"
        case .worldGrid: "WORLD-ANCHORED METRIC GRID"
        case .sonarPulse: "WORLD-SPACE RANGE WAVE"
        case .pointCloud: "XYZ RECONSTRUCTION"
        case .depthMap: "METRIC HEATMAP"
        case .depthEdges: "DEPTH GRADIENT"
        case .depthWarp: "PARALLAX FIELD"
        case .confidence: "LIDAR CERTAINTY"
        case .fog: "METRIC ATMOSPHERE"
        case .depthSlice: "RANGE ISOLATION"
        case .contours: "ISO-DISTANCE LINES"
        case .depthPosterize: "QUANTIZED METERS"
        case .surfaceNormals: "DEPTH-DERIVED NORMALS"
        case .foregroundCutout: "METRIC OCCLUSION MASK"
        case .depthChromatic: "RANGE CHANNEL SPLIT"
        case .depthMosaic: "DEPTH-DRIVEN BLOCKS"
        case .depthGlow: "DISCONTINUITY BLOOM"
        case .depthBands: "SCANNED RANGE PLANES"
        case .subjectDecay: "VISION + DEPTH + FLOW"
        case .nightVision: "IR INTENSIFIER // RANGE GATED"
        }
    }
}

struct DepthEffectParameters: Equatable, Sendable {
    var nearMeters = 0.18
    var farMeters = 5.0
    var intensity = 0.72
    var pointSize = 3.2
    var sampleStride = 1.0
    var confidenceThreshold = 0.0
    var yawDegrees = 0.0
    var pitchDegrees = 0.0
    var falloff = 0.55
    var detail = 0.50
    var bandCenter = 0.42
    var bandWidth = 0.18

    static let defaults = DepthEffectParameters()

    static func defaults(for mode: DepthEffectMode) -> DepthEffectParameters {
        var result = defaults
        for descriptor in DepthEffectCatalog.effectControls(for: mode) {
            descriptor.set(descriptor.defaultValue, in: &result)
        }
        return result
    }

    func packedControls(for mode: DepthEffectMode) -> SIMD4<Float> {
        let value = sanitized
        if mode == .surfaceRelight || mode == .worldGrid || mode == .sonarPulse {
            let controls = DepthEffectCatalog.effectControls(for: mode)
            return SIMD4(Float(controls[0].value(in: value)), Float(controls[1].value(in: value)),
                         Float(controls[2].value(in: value)), Float(value.bandWidth))
        }
        return SIMD4(Float(value.falloff), Float(value.detail), Float(value.bandCenter), Float(value.bandWidth))
    }

    var sanitized: DepthEffectParameters {
        func finite(_ value: Double, _ fallback: Double) -> Double {
            value.isFinite ? value : fallback
        }
        return DepthEffectParameters(
            nearMeters: min(max(finite(nearMeters, Self.defaults.nearMeters), 0.08), 1.0),
            farMeters: min(max(finite(farMeters, Self.defaults.farMeters), 1.2), 8.0),
            intensity: min(max(finite(intensity, Self.defaults.intensity), 0), 1.5),
            pointSize: min(max(finite(pointSize, Self.defaults.pointSize), 1), 7),
            sampleStride: min(max(finite(sampleStride, Self.defaults.sampleStride), 1), 6),
            confidenceThreshold: min(max(finite(confidenceThreshold, Self.defaults.confidenceThreshold), 0), 2),
            yawDegrees: min(max(finite(yawDegrees, Self.defaults.yawDegrees), -35), 35),
            pitchDegrees: min(max(finite(pitchDegrees, Self.defaults.pitchDegrees), -28), 28),
            falloff: min(max(finite(falloff, Self.defaults.falloff), 0), 1),
            detail: min(max(finite(detail, Self.defaults.detail), 0), 1),
            bandCenter: min(max(finite(bandCenter, Self.defaults.bandCenter), 0), 1),
            bandWidth: min(max(finite(bandWidth, Self.defaults.bandWidth), 0.01), 1)
        )
    }
}

struct DepthCapability: Equatable, Sendable {
    let isSupported: Bool
    let supportsSmoothedDepth: Bool
    let reason: String

    static func discover() -> DepthCapability {
        #if targetEnvironment(simulator)
            return DepthCapability(
                isSupported: false,
                supportsSmoothedDepth: false,
                reason: "SIMULATOR HAS NO ARKIT SCENE DEPTH"
            )
        #else
            guard ARWorldTrackingConfiguration.isSupported else {
                return DepthCapability(
                    isSupported: false,
                    supportsSmoothedDepth: false,
                    reason: "WORLD TRACKING IS NOT SUPPORTED"
                )
            }
            let supportsSmoothed = ARWorldTrackingConfiguration
                .supportsFrameSemantics(.smoothedSceneDepth)
            let supportsRaw = ARWorldTrackingConfiguration
                .supportsFrameSemantics(.sceneDepth)
            guard supportsSmoothed || supportsRaw else {
                return DepthCapability(
                    isSupported: false,
                    supportsSmoothedDepth: false,
                    reason: "LIDAR SCENE DEPTH IS NOT AVAILABLE"
                )
            }
            return DepthCapability(
                isSupported: true,
                supportsSmoothedDepth: supportsSmoothed,
                reason: supportsSmoothed ? "SMOOTHED SCENE DEPTH READY" : "SCENE DEPTH READY"
            )
        #endif
    }
}

enum DepthRuntimeState: String, Equatable, Sendable {
    case idle
    case starting
    case running
    case interrupted
    case unsupported
    case failed

    var label: String {
        rawValue.uppercased()
    }
}

struct DepthRuntimeSnapshot: Equatable, Sendable {
    var state: DepthRuntimeState
    var sourceLabel: String
    var formatLabel: String
    var frameCount: UInt64
    var timestamp: TimeInterval?
    var usesSmoothedDepth: Bool
    var hasConfidence: Bool
    var errorMessage: String?

    static let idle = DepthRuntimeSnapshot(
        state: .idle,
        sourceLabel: "LIDAR OFFLINE",
        formatLabel: "NO DEPTH FRAME",
        frameCount: 0,
        timestamp: nil,
        usesSmoothedDepth: false,
        hasConfidence: false,
        errorMessage: nil
    )
}

struct DepthFrameMetadata: Equatable, Sendable {
    let width: Int
    let height: Int
    let timestamp: TimeInterval
    let sequence: UInt64
    let hasConfidence: Bool
    let usesSmoothedDepth: Bool
}

enum ARDepthSourceEvent: Sendable {
    case frame(DepthFrameMetadata)
    case interrupted(String)
    case resumed
    case failed(String)
}

final class LatestDepthFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latestFrame: DepthFrame?
    private var generation: UInt64 = 0

    var sessionGeneration: UInt64 { lock.withLock { generation } }

    func publish(_ frame: DepthFrame) {
        lock.withLock {
            latestFrame = frame
        }
    }

    func consumeLatest() -> DepthFrame? {
        lock.withLock {
            defer { latestFrame = nil }
            return latestFrame
        }
    }

    func clear() {
        lock.withLock {
            latestFrame = nil
            generation &+= 1
        }
    }
}

enum DepthGeometry {
    static func cameraPoint(
        pixel: SIMD2<Float>,
        depthMeters: Float,
        intrinsics: SIMD4<Float>
    ) -> SIMD3<Float>? {
        guard depthMeters.isFinite, depthMeters > 0,
              intrinsics.x.isFinite, intrinsics.y.isFinite,
              intrinsics.x > 0, intrinsics.y > 0,
              intrinsics.z.isFinite, intrinsics.w.isFinite, pixel.x.isFinite, pixel.y.isFinite
        else {
            return nil
        }
        return SIMD3<Float>(
            (pixel.x - intrinsics.z) * depthMeters / intrinsics.x,
            (pixel.y - intrinsics.w) * depthMeters / intrinsics.y,
            depthMeters
        )
    }
}
