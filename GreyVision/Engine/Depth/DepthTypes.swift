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

    var id: UInt32 {
        rawValue
    }

    var label: String {
        switch self {
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

    var sanitized: DepthEffectParameters {
        DepthEffectParameters(
            nearMeters: min(max(nearMeters, 0.08), 1.0),
            farMeters: min(max(farMeters, 1.2), 8.0),
            intensity: min(max(intensity, 0), 1.5),
            pointSize: min(max(pointSize, 1), 7),
            sampleStride: min(max(sampleStride, 1), 6),
            confidenceThreshold: min(max(confidenceThreshold, 0), 2),
            yawDegrees: min(max(yawDegrees, -35), 35),
            pitchDegrees: min(max(pitchDegrees, -28), 28),
            falloff: min(max(falloff, 0), 1),
            detail: min(max(detail, 0), 1),
            bandCenter: min(max(bandCenter, 0), 1),
            bandWidth: min(max(bandWidth, 0.01), 1)
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
              intrinsics.x > 0, intrinsics.y > 0
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
