//
//  PerformanceRecorder.swift
//  GreyVision
//
//  Records performance metadata as a sidecar to video recordings.
//  Enables future offline rerendering from source + performance data.
//

import CoreMedia
import Foundation
import os.log

/// Thread-safe performance event sink. Called from render thread, UI thread, camera thread.
@MainActor
public final class PerformanceRecorder: ObservableObject {
    public static let shared = PerformanceRecorder()

    // Configuration
    private var isEnabled = false
    private var currentSession: PerformanceSession?
    private let fileQueue = DispatchQueue(label: "com.saringrey.greyvision.performance.writer", qos: .utility)

    // Metrics
    @Published public private(set) var eventCount = 0
    @Published public private(set) var droppedEventCount = 0
    @Published public private(set) var currentSessionURL: URL?

    private init() {}

    /// Start a new performance recording session.
    /// Call when video recording starts.
    public func startSession(
        captureConfig: PerformanceMetadataCaptureConfig,
        effectGraph: PerformanceMetadataEffectGraph,
        randomSeeds: PerformanceMetadataRandomSeeds,
        appInfo: PerformanceMetadataAppInfo
    ) {
        guard isEnabled else { return }

        let sessionStartTime = Date().timeIntervalSinceReferenceDate
        let sessionStartUptime = ProcessInfo.processInfo.systemUptime

        let session = PerformanceSession(
            appInfo: appInfo,
            captureConfig: captureConfig,
            effectGraph: effectGraph,
            randomSeeds: randomSeeds,
            sessionStartTime: sessionStartTime,
            sessionStartUptime: sessionStartUptime
        )

        currentSession = session
        eventCount = 0
        droppedEventCount = 0
        currentSessionURL = nil

        // Record the recording start event
        recordEvent(.recordingStart(RecordingStartPayload(
            path: "processedFrames", // Will be updated by caller
            codec: captureConfig.videoCodec,
            dimensions: captureConfig.renderDimensions,
            fps: captureConfig.framesPerSecond,
            burnHUD: false
        )))

        GVLog.performance.notice("Performance recording started")
    }

    /// Stop the current performance recording session and write sidecar file.
    /// Call when video recording stops.
    public func stopSession(recordingResult: PerformanceRecordingResult) async -> URL? {
        guard let session = currentSession else { return nil }

        // Record the recording stop event
        recordEvent(.recordingStop(RecordingStopPayload(
            duration: session.currentDuration,
            frameCount: session.frameCount,
            droppedFrames: session.droppedFrames,
            result: recordingResult.rawValue
        )))

        currentSession = nil

        // Write to file
        let url = await writeSession(session)
        currentSessionURL = url

        GVLog.performance.notice("Performance recording stopped: \(url?.lastPathComponent ?? "failed")")
        return url
    }

    /// Abort current session without saving (e.g., on interruption).
    public func abortSession() {
        currentSession = nil
        eventCount = 0
        droppedEventCount = 0
        currentSessionURL = nil
        GVLog.performance.notice("Performance recording aborted")
    }

    /// Enable/disable performance recording globally.
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            abortSession()
        }
    }

    // MARK: - Event Recording

    /// Record a semantic event. Thread-safe, call from any thread.
    public func recordEvent(_ payload: EventPayload, presentationTime: CMTime = .zero, frameIndex: UInt64? = nil) {
        guard isEnabled, var session = currentSession else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let sessionTime = now - session.sessionStartUptime
        let frame = frameIndex ?? session.frameCount
        let pts = presentationTime.isValid ? presentationTime : CMTime(seconds: sessionTime, preferredTimescale: 600)
        let wallClock = Date().timeIntervalSinceReferenceDate

        // Determine event kind from payload
        let kind = eventKind(from: payload)

        let event = PerformanceEvent(
            sessionTime: sessionTime,
            frameIndex: frame,
            presentationTime: pts,
            wallClock: wallClock,
            kind: kind,
            payload: payload
        )

        // Append to session (bounded to prevent memory growth)
        session.events.append(event)
        session.frameCount = max(session.frameCount, frame + 1)
        eventCount += 1

        // Bound check: warn if event count gets very high
        if eventCount > 100_000 {
            GVLog.performance.warning("Performance event count high: \(eventCount)")
        }

        currentSession = session
    }

    /// Record a dropped frame event (called from recorder when backpressure occurs).
    public func recordDroppedFrame(reason: DroppedFrameReason) {
        guard var session = currentSession else { return }
        session.droppedFrames += 1
        droppedEventCount += 1
        currentSession = session

        recordEvent(.systemEvent(SystemEventPayload(
            eventType: "droppedFrames",
            severity: "fair",
            detail: "Dropped frame: \(reason.rawValue)"
        )))
    }

    /// Record a parameter change during a gesture (uncommitted).
    public func recordParameterChanging(effectIdentifier: String, slotIndex: Int, parameterKey: String, oldValue: Float, newValue: Float) {
        recordEvent(.parameterChange(ParameterChangePayload(
            effectIdentifier: effectIdentifier,
            slotIndex: slotIndex,
            parameterKey: parameterKey,
            oldValue: oldValue,
            newValue: newValue,
            isCommitted: false
        )))
    }

    /// Record a committed parameter change (gesture ended).
    public func recordParameterCommitted(effectIdentifier: String, slotIndex: Int, parameterKey: String, oldValue: Float, newValue: Float) {
        recordEvent(.parameterChange(ParameterChangePayload(
            effectIdentifier: effectIdentifier,
            slotIndex: slotIndex,
            parameterKey: parameterKey,
            oldValue: oldValue,
            newValue: newValue,
            isCommitted: true
        )))
    }

    /// Record a datamosh gesture event.
    public func recordDatamoshGesture(phase: GesturePhase, position: SIMD2<Float>?, velocity: SIMD2<Float>?, intensity: Float?, freezeActive: Bool) {
        let gestureType = freezeActive ? "datamoshFreeze" : "datamoshDrag"
        recordEvent(.gesture(GesturePayload(
            gestureType: gestureType,
            phase: phase.rawValue,
            normalizedPosition: position,
            velocity: velocity,
            intensity: intensity,
            extra: ["freezeActive": freezeActive ? 1.0 : 0.0]
        )))
    }

    /// Record a repeat/loop gesture.
    public func recordRepeatGesture(phase: GesturePhase, loopLength: Float?, loopCount: Int?) {
        recordEvent(.gesture(GesturePayload(
            gestureType: "repeat",
            phase: phase.rawValue,
            normalizedPosition: nil,
            velocity: nil,
            intensity: nil,
            extra: [
                "loopLength": loopLength ?? 0,
                "loopCount": Float(loopCount ?? 0)
            ]
        )))
    }

    /// Record a warp gesture.
    public func recordWarpGesture(phase: GesturePhase, position: SIMD2<Float>, velocity: SIMD2<Float>, intensity: Float) {
        recordEvent(.gesture(GesturePayload(
            gestureType: "warp",
            phase: phase.rawValue,
            normalizedPosition: position,
            velocity: velocity,
            intensity: intensity,
            extra: nil
        )))
    }

    /// Record a freeze frame gesture.
    public func recordFreezeFrameGesture(phase: GesturePhase, active: Bool) {
        recordEvent(.gesture(GesturePayload(
            gestureType: "freezeFrame",
            phase: phase.rawValue,
            normalizedPosition: nil,
            velocity: nil,
            intensity: active ? 1.0 : 0.0,
            extra: nil
        )))
    }

    /// Record an effect stack change.
    public func recordEffectChange(changeType: EffectChangeType, slotIndex: Int, effectIdentifier: String?, effectDisplayName: String?, stackDepth: Int) {
        recordEvent(.effectChange(EffectChangePayload(
            changeType: changeType.rawValue,
            slotIndex: slotIndex,
            effectIdentifier: effectIdentifier,
            effectDisplayName: effectDisplayName,
            stackDepth: stackDepth
        )))
    }

    /// Record a modulation assignment/change.
    public func recordModulationChange(source: String, targetEffect: String, targetParameter: String, depth: Float, isEnabled: Bool) {
        recordEvent(.modulation(ModulationPayload(
            source: source,
            targetEffect: targetEffect,
            targetParameter: targetParameter,
            depth: depth,
            isEnabled: isEnabled
        )))
    }

    /// Record a scene/preset/recipe change.
    public func recordSceneChange(identifier: String, name: String, transitionType: String) {
        recordEvent(.sceneChange(SceneChangePayload(
            sceneIdentifier: identifier,
            sceneName: name,
            transitionType: transitionType
        )))
    }

    /// Record a camera control change.
    public func recordCameraChange(changeType: String, oldValue: Float?, newValue: Float, isLocked: Bool) {
        recordEvent(.cameraChange(CameraChangePayload(
            changeType: changeType,
            oldValue: oldValue,
            newValue: newValue,
            isLocked: isLocked
        )))
    }

    /// Record orientation change.
    public func recordOrientationChange(from: String, to: String, isMirrored: Bool) {
        recordEvent(.orientationChange(OrientationChangePayload(
            fromOrientation: from,
            toOrientation: to,
            isMirrored: isMirrored
        )))
    }

    /// Record thermal state change.
    public func recordThermalState(severity: ThermalSeverity, detail: String?) {
        recordEvent(.systemEvent(SystemEventPayload(
            eventType: "thermal",
            severity: severity.rawValue,
            detail: detail
        )))
    }

    /// Record memory pressure.
    public func recordMemoryPressure(level: MemoryPressureLevel) {
        recordEvent(.systemEvent(SystemEventPayload(
            eventType: "memoryPressure",
            severity: level.rawValue,
            detail: nil
        )))
    }

    /// Record an error.
    public func recordError(domain: String, code: Int, message: String, recoverable: Bool) {
        recordEvent(.error(ErrorPayload(
            domain: domain,
            code: code,
            message: message,
            recoverable: recoverable
        )))
    }

    // MARK: - Private

    private func eventKind(from payload: EventPayload) -> EventKind {
        switch payload {
        case .recordingStart: return .recordingStart
        case .recordingStop: return .recordingStop
        case .effectChange: return .effectAdded // generic, specific type in payload
        case .parameterChange: return .effectParameterChanged
        case let .gesture(g):
            switch g.gestureType {
            case "datamoshDrag": return .gestureDatamoshDrag
            case "datamoshFreeze": return .gestureDatamoshFreeze
            case "repeat": return .gestureRepeatTrigger
            case "warp": return .gestureWarp
            case "freezeFrame": return .gestureFreezeFrame
            default: return .custom(g.gestureType)
            }
        case .modulation: return .modulationAssigned
        case .sceneChange: return .sceneChanged
        case let .cameraChange(c):
            switch c.changeType {
            case "lens": return .cameraLensChanged
            case "focus": return .cameraFocusChanged
            case "exposure": return .cameraExposureChanged
            case "whiteBalance": return .cameraWhiteBalanceChanged
            case "iso": return .cameraISOChanged
            case "shutter": return .cameraShutterChanged
            case "zoom": return .cameraZoomChanged
            default: return .custom("camera_\(c.changeType)")
            }
        case .orientationChange: return .orientationChanged
        case let .systemEvent(s):
            switch s.eventType {
            case "thermal": return .thermalStateChanged
            case "memoryPressure": return .memoryPressure
            case "droppedFrames": return .droppedFrames
            default: return .custom("system_\(s.eventType)")
            }
        case .error: return .error
        case .custom: return .custom("custom")
        }
    }

    private func writeSession(_ session: PerformanceSession) async -> URL? {
        await withCheckedContinuation { continuation in
            fileQueue.async {
                let metadata = PerformanceMetadata(
                    appInfo: session.appInfo,
                    captureConfig: session.captureConfig,
                    effectGraph: session.effectGraph,
                    randomSeeds: session.randomSeeds,
                    sessionStartTime: session.sessionStartTime,
                    sessionStartUptime: session.sessionStartUptime,
                    events: session.events
                )

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                encoder.dateEncodingStrategy = .iso8601

                do {
                    let data = try encoder.encode(metadata)
                    let timestamp = Int(session.sessionStartTime)
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("greyvision-perf-\(timestamp).json")
                    try data.write(to: url, options: .atomic)
                    continuation.resume(returning: url)
                } catch {
                    GVLog.performance.error("Failed to write performance metadata: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

/// Internal session state during recording.
private struct PerformanceSession {
    let appInfo: PerformanceMetadataAppInfo
    let captureConfig: PerformanceMetadataCaptureConfig
    let effectGraph: PerformanceMetadataEffectGraph
    let randomSeeds: PerformanceMetadataRandomSeeds
    let sessionStartTime: TimeInterval
    let sessionStartUptime: Double
    var events: [PerformanceEvent] = []
    var frameCount: UInt64 = 0
    var droppedFrames: UInt64 = 0

    var currentDuration: Double {
        ProcessInfo.processInfo.systemUptime - sessionStartUptime
    }
}

/// Result of the associated video recording.
public enum PerformanceRecordingResult: String, Sendable {
    case success
    case failed
    case cancelled
}

/// Reason for dropped frame.
public enum DroppedFrameReason: String, Sendable {
    case encoderBackpressure
    case rendererStall
    case bufferPoolExhaustion
    case thermalThrottle
    case unknown
}

/// Gesture phase.
public enum GesturePhase: String, Sendable {
    case began
    case changed
    case ended
    case cancelled
}

/// Effect change type.
public enum EffectChangeType: String, Sendable {
    case added
    case removed
    case reordered
    case focusChanged
    case enabled
    case disabled
}

/// Thermal severity levels.
public enum ThermalSeverity: String, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

/// Memory pressure levels.
public enum MemoryPressureLevel: String, Sendable {
    case normal
    case warning
    case critical
}
