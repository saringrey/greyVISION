//
//  PerformanceMetadata.swift
//  GreyVision
//
//  Performance recording schema for offline rerender foundation.
//  Captures semantic events with precise timebase alignment.
//

import CoreMedia
import Foundation
import simd

/// Schema version for forward/backward compatibility.
public let PerformanceMetadataSchemaVersion = 1

/// Application version at capture time (injected at runtime).
public struct PerformanceMetadataAppInfo: Codable, Sendable {
    public let appVersion: String
    public let buildNumber: String
    public let schemaVersion: Int

    public init(appVersion: String, buildNumber: String, schemaVersion: Int = PerformanceMetadataSchemaVersion) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.schemaVersion = schemaVersion
    }
}

/// Device and capture configuration at session start.
public struct PerformanceMetadataCaptureConfig: Codable, Sendable {
    public let deviceModel: String
    public let deviceName: String
    public let iOSVersion: String
    public let metalDeviceName: String

    // Camera config
    public let cameraPosition: String // "rear" | "front"
    public let cameraDeviceType: String
    public let sensorDimensions: SIMD2<Int> // width, height
    public let sensorPixelFormat: String // e.g. "420YpCbCr8BiPlanarFullRange"
    public let framesPerSecond: Int
    public let videoCodec: String // CaptureSetupDraft.VideoCodec rawValue
    public let prefersHDR: Bool

    // Render config
    public let renderDimensions: SIMD2<Int> // effect render target size
    public let renderPixelFormat: String // e.g. "bgra8Unorm" | "rgba16Float"
    public let colorSpace: String // "linear" | "srgb" | "p3"

    public init(
        deviceModel: String,
        deviceName: String,
        iOSVersion: String,
        metalDeviceName: String,
        cameraPosition: String,
        cameraDeviceType: String,
        sensorDimensions: SIMD2<Int>,
        sensorPixelFormat: String,
        framesPerSecond: Int,
        videoCodec: String,
        prefersHDR: Bool,
        renderDimensions: SIMD2<Int>,
        renderPixelFormat: String,
        colorSpace: String
    ) {
        self.deviceModel = deviceModel
        self.deviceName = deviceName
        self.iOSVersion = iOSVersion
        self.metalDeviceName = metalDeviceName
        self.cameraPosition = cameraPosition
        self.cameraDeviceType = cameraDeviceType
        self.sensorDimensions = sensorDimensions
        self.sensorPixelFormat = sensorPixelFormat
        self.framesPerSecond = framesPerSecond
        self.videoCodec = videoCodec
        self.prefersHDR = prefersHDR
        self.renderDimensions = renderDimensions
        self.renderPixelFormat = renderPixelFormat
        self.colorSpace = colorSpace
    }
}

/// Effect graph at session start (composition snapshot).
public struct PerformanceMetadataEffectGraph: Codable, Sendable {
    public let rgbSplit: PerformanceMetadataRGBSplit?
    public let effectStack: [PerformanceMetadataEffectSlot]
    public let recipes: [String] // recipe identifiers active at start

    public init(rgbSplit: PerformanceMetadataRGBSplit?, effectStack: [PerformanceMetadataEffectSlot], recipes: [String]) {
        self.rgbSplit = rgbSplit
        self.effectStack = effectStack
        self.recipes = recipes
    }
}

public struct PerformanceMetadataRGBSplit: Codable, Sendable {
    public let enabled: Bool
    public let redOffset: SIMD2<Float>
    public let greenOffset: SIMD2<Float>
    public let blueOffset: SIMD2<Float>
    public let mode: Int // RGBSplitMode rawValue

    public init(enabled: Bool, redOffset: SIMD2<Float>, greenOffset: SIMD2<Float>, blueOffset: SIMD2<Float>, mode: Int) {
        self.enabled = enabled
        self.redOffset = redOffset
        self.greenOffset = greenOffset
        self.blueOffset = blueOffset
        self.mode = mode
    }
}

public struct PerformanceMetadataEffectSlot: Codable, Sendable {
    public let slotIndex: Int
    public let effectIdentifier: String // stable effect ID from Agent 2
    public let effectDisplayName: String
    public let parameters: [String: Float] // parameter key -> value
    public let isEnabled: Bool
    public let isFocused: Bool

    public init(slotIndex: Int, effectIdentifier: String, effectDisplayName: String, parameters: [String: Float], isEnabled: Bool, isFocused: Bool) {
        self.slotIndex = slotIndex
        self.effectIdentifier = effectIdentifier
        self.effectDisplayName = effectDisplayName
        self.parameters = parameters
        self.isEnabled = isEnabled
        self.isFocused = isFocused
    }
}

/// Random seed state for procedural effects (from Agent 2).
public struct PerformanceMetadataRandomSeeds: Codable, Sendable {
    // Per-effect seeds for reproducible procedural behavior
    public let effectSeeds: [String: UInt64] // effectIdentifier -> seed

    // Global seeds
    public let globalSeed: UInt64
    public let temporalSeed: UInt64
    public let noiseSeed: UInt64
    public let datamoshSeed: UInt64
    public let feedbackSeed: UInt64

    public init(
        effectSeeds: [String: UInt64],
        globalSeed: UInt64,
        temporalSeed: UInt64,
        noiseSeed: UInt64,
        datamoshSeed: UInt64,
        feedbackSeed: UInt64
    ) {
        self.effectSeeds = effectSeeds
        self.globalSeed = globalSeed
        self.temporalSeed = temporalSeed
        self.noiseSeed = noiseSeed
        self.datamoshSeed = datamoshSeed
        self.feedbackSeed = feedbackSeed
    }
}

/// Single semantic event in the performance timeline.
public struct PerformanceEvent: Codable, Sendable {
    /// Monotonic session time in seconds (from ProcessInfo.processInfo.systemUptime at session start)
    public let sessionTime: Double

    /// Frame index at event time (0-based, incremented per rendered frame)
    public let frameIndex: UInt64

    /// Presentation timestamp (CMTime, matches video frame PTS)
    public let presentationTime: CMTime

    /// Wall clock for correlation (Date.timeIntervalSinceReferenceDate)
    public let wallClock: TimeInterval

    /// Event type discriminator
    public let kind: EventKind

    /// Event-specific payload
    public let payload: EventPayload

    public init(sessionTime: Double, frameIndex: UInt64, presentationTime: CMTime, wallClock: TimeInterval, kind: EventKind, payload: EventPayload) {
        self.sessionTime = sessionTime
        self.frameIndex = frameIndex
        self.presentationTime = presentationTime
        self.wallClock = wallClock
        self.kind = kind
        self.payload = payload
    }
}

/// Discriminated union for event types.
public enum EventKind: String, Codable, Sendable {
    case recordingStart
    case recordingStop
    case effectAdded
    case effectRemoved
    case effectParameterChanged
    case effectFocusChanged
    case effectReordered
    case gestureDatamoshDrag
    case gestureDatamoshFreeze
    case gestureDatamoshRelease
    case gestureRepeatTrigger
    case gestureWarp
    case gestureFreezeFrame
    case modulationAssigned
    case modulationChanged
    case automationEvent
    case sceneChanged
    case presetApplied
    case recipeApplied
    case cameraLensChanged
    case cameraFocusChanged
    case cameraExposureChanged
    case cameraWhiteBalanceChanged
    case cameraISOChanged
    case cameraShutterChanged
    case cameraZoomChanged
    case orientationChanged
    case thermalStateChanged
    case memoryPressure
    case droppedFrames
    case error
    case custom(String) // For future extensibility

    // Custom coding for the custom case
    private enum CodingKeys: String, CodingKey {
        case kind
        case customValue
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .custom(value):
            try container.encode(["custom": value])
        default:
            try container.encode(self.rawValue)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: String].self),
           let customValue = dict["custom"]
        {
            self = .custom(customValue)
        } else {
            let raw = try container.decode(String.self)
            self = EventKind(rawValue: raw) ?? .custom(raw)
        }
    }
}

/// Event payload variants.
public enum EventPayload: Codable, Sendable {
    case recordingStart(RecordingStartPayload)
    case recordingStop(RecordingStopPayload)
    case effectChange(EffectChangePayload)
    case parameterChange(ParameterChangePayload)
    case gesture(GesturePayload)
    case modulation(ModulationPayload)
    case sceneChange(SceneChangePayload)
    case cameraChange(CameraChangePayload)
    case orientationChange(OrientationChangePayload)
    case systemEvent(SystemEventPayload)
    case error(ErrorPayload)
    case custom(Data) // Opaque data for future extensibility

    private enum CodingKeys: String, CodingKey {
        case type
        case data
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .recordingStart(p):
            try container.encode("recordingStart", forKey: .type)
            try container.encode(p, forKey: .data)
        case let .recordingStop(p):
            try container.encode("recordingStop", forKey: .type)
            try container.encode(p, forKey: .data)
        case let .effectChange(p):
            try container.encode("effectChange", forKey: .type)
            try container.encode(p, forKey: .data)
        case let .parameterChange(p):
            try container.encode("parameterChange", forKey: .type)
            try container.encode(p, forKey: .data)
        case let .gesture(p):
            try container.encode("gesture", forKey: .type)
            try container.encode(p, forKey: .data)
        case let .modulation(p):
            try container.encode("modulation", forKey: .type)
            try container.encode(p, forKey: .data)
        case let .sceneChange(p):
            try container.encode("sceneChange", forKey: .type)
            try container.encode(p, forKey: .data)
        case let .cameraChange(p):
            try container.encode("cameraChange", forKey: .type)
            try container.encode(p, forKey: .data)
        case let .orientationChange(p):
            try container.encode("orientationChange", forKey: .type)
            try container.encode(p, forKey: .data)
        case let .systemEvent(p):
            try container.encode("systemEvent", forKey: .type)
            try container.encode(p, forKey: .data)
        case let .error(p):
            try container.encode("error", forKey: .type)
            try container.encode(p, forKey: .data)
        case let .custom(data):
            try container.encode("custom", forKey: .type)
            try container.encode(data, forKey: .data)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "recordingStart":
            self = try .recordingStart(container.decode(RecordingStartPayload.self, forKey: .data))
        case "recordingStop":
            self = try .recordingStop(container.decode(RecordingStopPayload.self, forKey: .data))
        case "effectChange":
            self = try .effectChange(container.decode(EffectChangePayload.self, forKey: .data))
        case "parameterChange":
            self = try .parameterChange(container.decode(ParameterChangePayload.self, forKey: .data))
        case "gesture":
            self = try .gesture(container.decode(GesturePayload.self, forKey: .data))
        case "modulation":
            self = try .modulation(container.decode(ModulationPayload.self, forKey: .data))
        case "sceneChange":
            self = try .sceneChange(container.decode(SceneChangePayload.self, forKey: .data))
        case "cameraChange":
            self = try .cameraChange(container.decode(CameraChangePayload.self, forKey: .data))
        case "orientationChange":
            self = try .orientationChange(container.decode(OrientationChangePayload.self, forKey: .data))
        case "systemEvent":
            self = try .systemEvent(container.decode(SystemEventPayload.self, forKey: .data))
        case "error":
            self = try .error(container.decode(ErrorPayload.self, forKey: .data))
        case "custom":
            self = try .custom(container.decode(Data.self, forKey: .data))
        default:
            self = .custom(Data())
        }
    }
}

// MARK: - Payload Types

public struct RecordingStartPayload: Codable, Sendable {
    public let path: String // "processedFrames" | "objects" | "sensorRAW"
    public let codec: String
    public let dimensions: SIMD2<Int>
    public let fps: Int
    public let burnHUD: Bool

    public init(path: String, codec: String, dimensions: SIMD2<Int>, fps: Int, burnHUD: Bool) {
        self.path = path
        self.codec = codec
        self.dimensions = dimensions
        self.fps = fps
        self.burnHUD = burnHUD
    }
}

public struct RecordingStopPayload: Codable, Sendable {
    public let duration: Double
    public let frameCount: UInt64
    public let droppedFrames: UInt64
    public let result: String // "success" | "failed" | "cancelled"

    public init(duration: Double, frameCount: UInt64, droppedFrames: UInt64, result: String) {
        self.duration = duration
        self.frameCount = frameCount
        self.droppedFrames = droppedFrames
        self.result = result
    }
}

public struct EffectChangePayload: Codable, Sendable {
    public let changeType: String // "added" | "removed" | "reordered" | "focusChanged"
    public let slotIndex: Int
    public let effectIdentifier: String?
    public let effectDisplayName: String?
    public let stackDepth: Int

    public init(changeType: String, slotIndex: Int, effectIdentifier: String?, effectDisplayName: String?, stackDepth: Int) {
        self.changeType = changeType
        self.slotIndex = slotIndex
        self.effectIdentifier = effectIdentifier
        self.effectDisplayName = effectDisplayName
        self.stackDepth = stackDepth
    }
}

public struct ParameterChangePayload: Codable, Sendable {
    public let effectIdentifier: String
    public let slotIndex: Int
    public let parameterKey: String
    public let oldValue: Float
    public let newValue: Float
    public let isCommitted: Bool // true on gesture end, false during drag

    public init(effectIdentifier: String, slotIndex: Int, parameterKey: String, oldValue: Float, newValue: Float, isCommitted: Bool) {
        self.effectIdentifier = effectIdentifier
        self.slotIndex = slotIndex
        self.parameterKey = parameterKey
        self.oldValue = oldValue
        self.newValue = newValue
        self.isCommitted = isCommitted
    }
}

public struct GesturePayload: Codable, Sendable {
    public let gestureType: String // "datamoshDrag" | "datamoshFreeze" | "repeat" | "warp" | "freezeFrame"
    public let phase: String // "began" | "changed" | "ended" | "cancelled"
    public let normalizedPosition: SIMD2<Float>? // 0-1 in preview coordinates
    public let velocity: SIMD2<Float>?
    public let intensity: Float? // 0-1 for pressure-like values
    public let extra: [String: Float]? // Effect-specific extra data

    public init(gestureType: String, phase: String, normalizedPosition: SIMD2<Float>?, velocity: SIMD2<Float>?, intensity: Float?, extra: [String: Float]?) {
        self.gestureType = gestureType
        self.phase = phase
        self.normalizedPosition = normalizedPosition
        self.velocity = velocity
        self.intensity = intensity
        self.extra = extra
    }
}

public struct ModulationPayload: Codable, Sendable {
    public let source: String // "audio" | "motion" | "manual" | "sequencer"
    public let targetEffect: String
    public let targetParameter: String
    public let depth: Float
    public let isEnabled: Bool

    public init(source: String, targetEffect: String, targetParameter: String, depth: Float, isEnabled: Bool) {
        self.source = source
        self.targetEffect = targetEffect
        self.targetParameter = targetParameter
        self.depth = depth
        self.isEnabled = isEnabled
    }
}

public struct SceneChangePayload: Codable, Sendable {
    public let sceneIdentifier: String
    public let sceneName: String
    public let transitionType: String // "immediate" | "crossfade" | "cut"

    public init(sceneIdentifier: String, sceneName: String, transitionType: String) {
        self.sceneIdentifier = sceneIdentifier
        self.sceneName = sceneName
        self.transitionType = transitionType
    }
}

public struct CameraChangePayload: Codable, Sendable {
    public let changeType: String // "lens" | "focus" | "exposure" | "whiteBalance" | "iso" | "shutter" | "zoom"
    public let oldValue: Float?
    public let newValue: Float
    public let isLocked: Bool

    public init(changeType: String, oldValue: Float?, newValue: Float, isLocked: Bool) {
        self.changeType = changeType
        self.oldValue = oldValue
        self.newValue = newValue
        self.isLocked = isLocked
    }
}

public struct OrientationChangePayload: Codable, Sendable {
    public let fromOrientation: String
    public let toOrientation: String
    public let isMirrored: Bool

    public init(fromOrientation: String, toOrientation: String, isMirrored: Bool) {
        self.fromOrientation = fromOrientation
        self.toOrientation = toOrientation
        self.isMirrored = isMirrored
    }
}

public struct SystemEventPayload: Codable, Sendable {
    public let eventType: String // "thermal" | "memoryPressure" | "interruption" | "background"
    public let severity: String // "nominal" | "fair" | "serious" | "critical"
    public let detail: String?

    public init(eventType: String, severity: String, detail: String?) {
        self.eventType = eventType
        self.severity = severity
        self.detail = detail
    }
}

public struct ErrorPayload: Codable, Sendable {
    public let domain: String
    public let code: Int
    public let message: String
    public let recoverable: Bool

    public init(domain: String, code: Int, message: String, recoverable: Bool) {
        self.domain = domain
        self.code = code
        self.message = message
        self.recoverable = recoverable
    }
}

/// Complete performance metadata document.
public struct PerformanceMetadata: Codable, Sendable {
    public let schemaVersion: Int
    public let appInfo: PerformanceMetadataAppInfo
    public let captureConfig: PerformanceMetadataCaptureConfig
    public let effectGraph: PerformanceMetadataEffectGraph
    public let randomSeeds: PerformanceMetadataRandomSeeds
    public let sessionStartTime: TimeInterval // wall clock
    public let sessionStartUptime: Double // ProcessInfo.processInfo.systemUptime
    public let events: [PerformanceEvent]

    public init(
        appInfo: PerformanceMetadataAppInfo,
        captureConfig: PerformanceMetadataCaptureConfig,
        effectGraph: PerformanceMetadataEffectGraph,
        randomSeeds: PerformanceMetadataRandomSeeds,
        sessionStartTime: TimeInterval,
        sessionStartUptime: Double,
        events: [PerformanceEvent]
    ) {
        self.schemaVersion = PerformanceMetadataSchemaVersion
        self.appInfo = appInfo
        self.captureConfig = captureConfig
        self.effectGraph = effectGraph
        self.randomSeeds = randomSeeds
        self.sessionStartTime = sessionStartTime
        self.sessionStartUptime = sessionStartUptime
        self.events = events
    }
}

// MARK: - CMTime Codable Support

extension CMTime: @retroactive Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(timescale, forKey: .timescale)
        try container.encode(flags.rawValue, forKey: .flags)
        try container.encode(epoch, forKey: .epoch)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(CMTimeValue.self, forKey: .value)
        let timescale = try container.decode(CMTimeScale.self, forKey: .timescale)
        let flagsRaw = try container.decode(CMTimeFlags.RawValue.self, forKey: .flags)
        let epoch = try container.decode(CMTimeEpoch.self, forKey: .epoch)
        self.init(value: value, timescale: timescale, flags: CMTimeFlags(rawValue: flagsRaw), epoch: epoch)
    }

    private enum CodingKeys: String, CodingKey {
        case value, timescale, flags, epoch
    }
}

// MARK: - SIMD Codable Support

extension SIMD2: Codable where Scalar: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let x = try container.decode(Scalar.self)
        let y = try container.decode(Scalar.self)
        self.init(x, y)
    }
}

extension SIMD3: Codable where Scalar: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
        try container.encode(z)
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let x = try container.decode(Scalar.self)
        let y = try container.decode(Scalar.self)
        let z = try container.decode(Scalar.self)
        self.init(x, y, z)
    }
}

extension SIMD4: Codable where Scalar: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
        try container.encode(z)
        try container.encode(w)
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let x = try container.decode(Scalar.self)
        let y = try container.decode(Scalar.self)
        let z = try container.decode(Scalar.self)
        let w = try container.decode(Scalar.self)
        self.init(x, y, z, w)
    }
}
