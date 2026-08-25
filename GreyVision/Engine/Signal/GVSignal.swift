import Combine
import CoreMotion
import Foundation
import QuartzCore
import SwiftUI

/// A single reading of everything the instrument currently knows about itself.
///
/// Every field is real runtime data, not an animation curve. Decorative UI
/// subscribes to this instead of inventing its own motion, so what moves on
/// screen always means something.
struct GVSignalSnapshot: Sendable, Equatable {
    /// Broadband audio level, 0...1.
    var audio: Double = 0
    var bass: Double = 0
    var mid: Double = 0
    var treble: Double = 0
    /// Fast peak-above-RMS component, used as a transient trigger.
    var transient: Double = 0
    /// Mean scene luminance from the live camera frame, 0...1.
    var luminance: Double = 0
    /// Frame-to-frame change magnitude — an optical-flow proxy, 0...1.
    var motion: Double = 0
    /// Smoothed device tilt, each axis -1...1.
    var tilt = CGSize.zero
    /// Roll relative to the nearest portrait/landscape cardinal, in radians.
    var horizonDeviationRadians: Double = 0
    /// Uses a one-degree enter and 1.5-degree exit threshold to avoid flicker.
    var isLevel = false
    /// Rotation rate magnitude, 0...1.
    var shake: Double = 0
    /// Most recent GPU frame time in milliseconds.
    var frameMilliseconds: Double = 0
    /// GPU time against the frame budget, 0...1. Above 1 means dropped frames.
    var frameStress: Double = 0
    /// Touch speed in normalised units per second, clamped to 0...1.
    var touchVelocity: Double = 0
    /// Where the last touch happened, normalised.
    var touchPoint = CGPoint(x: 0.5, y: 0.5)
    /// Whether a touch is currently down.
    var isTouching = false
    /// Combined intensity of the active effect stack, 0...1.
    var effectIntensity: Double = 0
    /// Whether depth is currently driving the image.
    var depthPresence: Double = 0
    /// Mean normalized LiDAR depth, near 0 and far 1.
    var depth: Double = 0
    /// One-finger circular modulation gesture, 0...1.
    var modulationOrbit: Double = 0

    static let idle = GVSignalSnapshot()

    /// Convenience: a general "the instrument is busy" level for glow and
    /// disturbance decisions.
    var energy: Double {
        min(max(audio * 0.4 + motion * 0.35 + effectIntensity * 0.25, 0), 1)
    }
}

/// Global runtime signal bus.
///
/// Publishes at 20 Hz maximum. Producers push raw values from whatever thread
/// they own; the bus smooths and republishes on the main actor.
@MainActor
final class GVSignal: ObservableObject {
    @Published private(set) var snapshot = GVSignalSnapshot.idle

    /// Scene statistics arrive from the renderer on the GPU completion thread.
    let sceneMailbox = GVSceneStatsMailbox()
    /// Normalized LiDAR mean arrives from a tiny GPU reduction buffer.
    let depthMailbox = GVDepthSignalMailbox()

    private let motionManager = CMMotionManager()
    private var publishTimer: Timer?
    private var lastTouchTime: CFTimeInterval = 0
    private var lastTouchPoint = CGPoint(x: 0.5, y: 0.5)
    private var filteredHorizonRadians: Double = 0
    private var hasHorizonSample = false

    /// Smoothed working values.
    private var working = GVSignalSnapshot.idle

    /// Teardown is explicit via `stop()`, called from `AppModel` on scene phase
    /// changes and route exit. There is no nonisolated deinit path.
    func start() {
        startMotion()
        guard publishTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        publishTimer = timer
    }

    func stop() {
        publishTimer?.invalidate()
        publishTimer = nil
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
        filteredHorizonRadians = 0
        hasHorizonSample = false
        depthMailbox.clear()
        working = .idle
        snapshot = .idle
    }

    // MARK: - Producers

    func submitAudio(_ audio: AudioReactiveSnapshot, isEnabled: Bool) {
        guard isEnabled else {
            working.audio = 0
            working.bass = 0
            working.mid = 0
            working.treble = 0
            working.transient = 0
            return
        }
        working.audio = Double(audio.rms)
        working.bass = Double(audio.bass)
        working.mid = Double(audio.mid)
        working.treble = Double(audio.treble)
        working.transient = min(max(Double(audio.peak - audio.rms) * 3.5, 0), 1)
    }

    func submitRender(_ stats: CameraRenderStats, framesPerSecond: Int) {
        working.frameMilliseconds = stats.gpuMilliseconds
        let budget = 1000.0 / Double(max(framesPerSecond, 1))
        working.frameStress = min(stats.gpuMilliseconds / max(budget, 0.001), 2)
    }

    func submitEffectIntensity(_ intensity: Double) {
        working.effectIntensity = min(max(intensity, 0), 1)
    }

    func submitDepthPresence(_ presence: Double) {
        working.depthPresence = min(max(presence, 0), 1)
        if presence <= 0 {
            working.depth = 0
        }
    }

    func submitDepth(_ normalizedDepth: Double) {
        working.depth = working.depth * 0.72 + min(max(normalizedDepth, 0), 1) * 0.28
    }

    func submitModulationOrbit(_ value: Double, isActive: Bool) {
        working.modulationOrbit = isActive ? min(max(value, 0), 1) : 0
    }

    /// Touch velocity is derived here rather than by each gesture site so every
    /// consumer sees the same normalisation.
    func submitTouch(at point: CGPoint, isDown: Bool) {
        let now = CACurrentMediaTime()
        let elapsed = max(now - lastTouchTime, 1 / 240)
        let travel = hypot(point.x - lastTouchPoint.x, point.y - lastTouchPoint.y)
        if isDown, lastTouchTime > 0, elapsed < 0.4 {
            working.touchVelocity = min(travel / elapsed / 3.0, 1)
        }
        working.touchPoint = point
        working.isTouching = isDown
        lastTouchPoint = point
        lastTouchTime = now
        if !isDown {
            working.touchVelocity = 0
        }
    }

    func endTouch() {
        working.isTouching = false
        working.touchVelocity = 0
    }

    // MARK: - Internals

    private func startMotion() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 1 / 20
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let roll = min(max(motion.attitude.roll, -0.7), 0.7) / 0.7
            let pitch = min(max(motion.attitude.pitch + 0.6, -0.7), 0.7) / 0.7
            working.tilt = CGSize(
                width: working.tilt.width * 0.84 + roll * 0.16,
                height: working.tilt.height * 0.84 + pitch * 0.16
            )

            // Gravity stays stable near vertical where Euler roll can jump. Keep
            // one process-wide motion source, then derive both parallax and level.
            let rawHorizon = atan2(-motion.gravity.x, -motion.gravity.y)
            if hasHorizonSample {
                let delta = atan2(
                    sin(rawHorizon - filteredHorizonRadians),
                    cos(rawHorizon - filteredHorizonRadians)
                )
                filteredHorizonRadians += delta * 0.15
            } else {
                filteredHorizonRadians = rawHorizon
                hasHorizonSample = true
            }
            let deviation = GVHorizonModel.deviation(from: filteredHorizonRadians)
            let leveled = GVHorizonModel.isLevel(
                deviation: deviation,
                wasLevel: working.isLevel
            )
            working.horizonDeviationRadians = leveled ? 0 : deviation
            working.isLevel = leveled

            let rate = motion.rotationRate
            let magnitude = sqrt(rate.x * rate.x + rate.y * rate.y + rate.z * rate.z)
            working.shake = min(magnitude / 6.0, 1)
        }
    }

    private func tick() {
        let scene = sceneMailbox.latest
        if scene.isValid {
            working.luminance = working.luminance * 0.72 + Double(scene.luminance) * 0.28
            working.motion = working.motion * 0.66 + Double(scene.motion) * 0.34
        }
        let depthSample = depthMailbox.latest
        if working.depthPresence > 0, depthSample.isValid {
            submitDepth(Double(depthSample.normalizedMean))
        }
        // Touch velocity decays if the finger stops moving without lifting.
        if working.isTouching, CACurrentMediaTime() - lastTouchTime > 0.12 {
            working.touchVelocity *= 0.7
        }
        guard working != snapshot else { return }
        snapshot = working
    }
}

/// Pure cardinal-orientation math for the viewfinder level and its tests.
enum GVHorizonModel {
    static let enterThresholdRadians = Double.pi / 180
    static let exitThresholdRadians = 1.5 * Double.pi / 180

    /// Wraps portrait, both landscapes, and upside-down to the same ±45° band.
    static func deviation(from roll: Double) -> Double {
        var value = roll.truncatingRemainder(dividingBy: .pi / 2)
        if value > .pi / 4 {
            value -= .pi / 2
        }
        if value < -.pi / 4 {
            value += .pi / 2
        }
        return value
    }

    static func isLevel(deviation: Double, wasLevel: Bool) -> Bool {
        abs(deviation) <= (wasLevel ? exitThresholdRadians : enterThresholdRadians)
    }
}

/// Scene statistics computed on the GPU and read back through a small shared
/// buffer. No image data crosses to the CPU.
struct GVSceneStats: Sendable, Equatable {
    var luminance: Float = 0
    var motion: Float = 0
    var isValid = false
}

final class GVSceneStatsMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = GVSceneStats()

    var latest: GVSceneStats {
        lock.withLock { value }
    }

    func publish(_ stats: GVSceneStats) {
        lock.withLock { value = stats }
    }

    func clear() {
        lock.withLock { value = GVSceneStats() }
    }
}

struct GVDepthSignalSample: Sendable, Equatable {
    var normalizedMean: Float = 0
    var isValid = false
}

final class GVDepthSignalMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = GVDepthSignalSample()

    var latest: GVDepthSignalSample {
        lock.withLock { value }
    }

    func publish(_ sample: GVDepthSignalSample) {
        lock.withLock { value = sample }
    }

    func clear() {
        lock.withLock { value = GVDepthSignalSample() }
    }
}

// `GestureType` and `GestureStateRegistry` live in App/GestureStateRegistry.swift.
// This file carried an older, cut-down copy of both; keeping it would have
// given the project two arbiters and two priority tables.

/// Detects a coherent one-finger circular path and publishes its wrapped phase
/// only after enough arc has accumulated to distinguish it from a normal drag.
@MainActor
final class GVModulationOrbitTracker: ObservableObject {
    private var samples: [CGPoint] = []
    private var lastAngle: Double?
    private var travel = 0.0

    func update(
        at point: CGPoint,
        isEnabled: Bool,
        registry: GestureStateRegistry,
        signal: GVSignal
    ) {
        guard isEnabled else { return }
        samples.append(point)
        if samples.count > 24 {
            samples.removeFirst(samples.count - 24)
        }
        guard samples.count >= 5 else { return }

        let sum = samples.reduce(CGPoint.zero) { partial, sample in
            CGPoint(x: partial.x + sample.x, y: partial.y + sample.y)
        }
        let divisor = CGFloat(samples.count)
        let center = CGPoint(x: sum.x / divisor, y: sum.y / divisor)
        let radii = samples.map { hypot($0.x - center.x, $0.y - center.y) }
        let meanRadius = radii.reduce(0, +) / CGFloat(radii.count)
        guard meanRadius > 0.025 else { return }
        let radialError = radii.reduce(0.0) { $0 + abs($1 - meanRadius) } /
            CGFloat(radii.count) / meanRadius
        guard radialError < 0.68 else { return }

        let angle = atan2(Double(point.y - center.y), Double(point.x - center.x))
        if let lastAngle {
            travel += atan2(sin(angle - lastAngle), cos(angle - lastAngle))
        }
        self.lastAngle = angle
        guard abs(travel) > .pi * 0.45 else { return }

        if registry.activeGesture != .modulationOrbit {
            registry.activateGesture(.modulationOrbit)
        } else {
            registry.updateActivity(for: .modulationOrbit)
        }
        let phase = travel.truncatingRemainder(dividingBy: .pi * 2) / (.pi * 2)
        signal.submitModulationOrbit(phase < 0 ? phase + 1 : phase, isActive: true)
    }

    func end(registry: GestureStateRegistry, signal: GVSignal) {
        if registry.activeGesture == .modulationOrbit {
            registry.completeGesture(.modulationOrbit)
        }
        signal.submitModulationOrbit(0, isActive: false)
        samples.removeAll(keepingCapacity: true)
        lastAngle = nil
        travel = 0
    }
}

extension EnvironmentValues {
    @Entry var gvSignal: GVSignalSnapshot = .idle
}
