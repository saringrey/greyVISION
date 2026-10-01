@preconcurrency import ARKit
import CoreVideo
import Foundation
import simd

/// LiDAR looks, consolidated. Raw values are stable wire numbers: they travel
/// inside `DepthMetalUniforms` and inside saved session state, so the numbers
/// retired by consolidation (2, 4, 5, 8-14, 19) are never reused — otherwise an
/// old recording would silently resolve to a different look.
///
/// Twenty modes collapsed to nine. The removed ones were not separate looks,
/// they were single parameters of the ones that remain: posterize and mosaic are
/// `LEVELS`/`BLOCKS` on the heatmap, bands and edge glow are `FILL`/`GLOW` on
/// contours, foreground cutout and fog are `ISOLATE`/`HAZE` on the depth field,
/// chromatic split is `CHROMA` on the parallax field, raw normals are
/// `MATERIAL` on relight, and the sonar pulse is one of the echoes of space
/// scan. `CONFIDENCE` was a diagnostic, not an effect: confidence already gates
/// every mode through the acquisition knob.
enum DepthEffectMode: UInt32, CaseIterable, Identifiable, Sendable {
    case pointCloud = 0
    case depthMap = 1
    case contours = 7
    case depthSlice = 6
    case depthWarp = 3
    case surfaceRelight = 17
    case worldGrid = 18
    case subjectDecay = 15
    case nightVision = 16

    var id: UInt32 {
        rawValue
    }

    var label: String {
        switch self {
        case .pointCloud: "POINT CLOUD"
        case .depthMap: "HEATMAP"
        case .contours: "CONTOURS"
        case .depthSlice: "DEPTH FIELD"
        case .depthWarp: "PARALLAX"
        case .surfaceRelight: "RELIGHT"
        case .worldGrid: "SPACE SCAN"
        case .subjectDecay: "SUBJECT DECAY"
        case .nightVision: "NIGHT VISION"
        }
    }

    var detail: String {
        switch self {
        case .pointCloud: "SHADED GEOMETRY // DEPTH TESTED"
        case .depthMap: "METRIC RANGE // LEVELS + LOD"
        case .contours: "ISO-RANGE MAP // EDGE LIGHT"
        case .depthSlice: "METRIC DEPTH OF FIELD"
        case .depthWarp: "OCCCLUSION-AWARE REPROJECTION"
        case .surfaceRelight: "WORLD-SPACE SURFACE LIGHT"
        case .worldGrid: "METRIC GRID + ECHO SWEEP"
        case .subjectDecay: "MASK + FLOW + OCCLUSION TEAR"
        case .nightVision: "IR INTENSIFIER // AUTO GAIN"
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

    /// The four effect knobs, resolved through their descriptors so the shader
    /// always receives real physical units. Every consolidated mode declares
    /// exactly four effect controls, which is why the special-casing the old
    /// mixed-unit modes needed is gone.
    func packedControls(for mode: DepthEffectMode) -> SIMD4<Float> {
        let value = sanitized
        let controls = DepthEffectCatalog.effectControls(for: mode)
        func at(_ index: Int) -> Float {
            index < controls.count ? Float(controls[index].value(in: value)) : 0
        }
        return SIMD4(at(0), at(1), at(2), at(3))
    }

    /// Clamps every field before it reaches a descriptor, a uniform or a saved
    /// session. The first eight are absolute: metres, pixels, degrees, LiDAR
    /// confidence. The last four are *normalized* storage for whichever mode
    /// owns them — the catalog maps them onto that mode's physical range — so
    /// they are clamped to 0...1 here. Clamping them to a physical bound would
    /// silently rewrite a stored 0 into a non-zero value, which is exactly how
    /// BLOCK SIZE at its minimum came back as 0.02 px instead of 0.01 px.
    var sanitized: DepthEffectParameters {
        func finite(_ value: Double, _ fallback: Double) -> Double {
            value.isFinite ? value : fallback
        }
        func unit(_ value: Double, _ fallback: Double) -> Double {
            min(max(finite(value, fallback), 0), 1)
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
            falloff: unit(falloff, Self.defaults.falloff),
            detail: unit(detail, Self.defaults.detail),
            bandCenter: unit(bandCenter, Self.defaults.bandCenter),
            bandWidth: unit(bandWidth, Self.defaults.bandWidth)
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
