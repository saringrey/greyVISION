import Foundation
#if canImport(UIKit)
    import UIKit
#endif

/// Moves the renderer along the `GVRenderQuality` ladder when frames run over
/// budget, and moves it back when they stop.
///
/// Hysteresis is the whole point. Without it, one slow frame reallocates the
/// simulation fields, the reallocation makes the next frame slower, and the
/// renderer oscillates for as long as the camera is running. Thirty
/// consecutive over-budget frames to step down, three hundred comfortable
/// ones to step back up — a ratio of ten to one, so the loop settles rather
/// than hunting.
///
/// The governor only moves while the operator has left quality on
/// `automatic`. A pinned choice is a promise, and `fullResolution` is the
/// recording escape hatch on top of that: a take in progress must be recorded
/// at the resolution the operator was looking at, whatever the preview was
/// doing to stay warm.
struct CameraEffectQuality {
    /// Frames over budget before stepping down one rung.
    private static let overBudgetFramesToDownshift = 30
    /// Comfortable frames before stepping back up.
    private static let underBudgetFramesToUpshift = 300
    /// Fraction of the frame budget above which a frame counts as over.
    private static let overBudgetRatio = 0.85
    /// Fraction below which a frame counts as comfortable. The gap between the
    /// two is the dead band that keeps the renderer from oscillating.
    private static let underBudgetRatio = 0.55

    /// The operator's setting, which is what the picker writes.
    private(set) var tier: GVRenderQuality
    /// The rung the chain is actually running at.
    ///
    /// `tier` and this are the same value except while the setting is
    /// `automatic`, in which case the governor owns the rung and walks it
    /// itself. Resolving the automatic setting to a concrete rung is what
    /// lets the ladder be walked at all: a governor that starts on
    /// `.automatic` and looks for the next rung down *from* `.automatic` finds
    /// nothing and silently never reduces anything.
    private(set) var resolvedTier: GVRenderQuality
    private var overBudget = 0
    private var underBudget = 0
    private var lastFrame: UInt64 = 0
    /// True while a recording, a still, or a screenshot is holding the chain
    /// at native resolution.
    private var isPinnedToFullResolution = false
    private var isLowPowerModeEnabled: Bool

    init(tier: GVRenderQuality = .automatic, isLowPowerModeEnabled: Bool = false) {
        self.tier = tier
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.resolvedTier = GVRenderQuality.resolve(tier, isLowPowerModeEnabled: isLowPowerModeEnabled)
    }

    /// Adopts the operator's pinned tier, or a change in Low Power Mode.
    ///
    /// Called every frame, so it has to be a no-op unless something actually
    /// changed: re-resolving unconditionally would push the chain back to the
    /// top of the ladder on every frame and undo the governor's own walking.
    mutating func applyRequestedTier(
        _ requested: GVRenderQuality,
        isLowPowerModeEnabled lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    ) {
        guard requested != tier || lowPower != isLowPowerModeEnabled else { return }
        tier = requested
        isLowPowerModeEnabled = lowPower
        resolvedTier = GVRenderQuality.resolve(requested, isLowPowerModeEnabled: lowPower)
        // A new request is a new starting position, not a continuation of the
        // evidence gathered under the old one.
        overBudget = 0
        underBudget = 0
    }

    /// Longest-edge multiplier for the render chain. The adaptive step: the
    /// chain is rendered smaller and the final blit scales it back up, which
    /// costs sharpness but never changes *which* effects run.
    var renderScale: Double { resolvedTier.renderScale }

    /// Simulation field sizes, derived from the tier so a step down actually
    /// buys something rather than only flagging a boolean that the flow field
    /// happens to read.
    var flowEdge: Int { resolvedTier.flowEdge }
    var simulationEdge: Int { resolvedTier.simulationEdge }
    var pressureIterations: Int { resolvedTier.pressureIterations }

    /// The ceiling the datamosh round trip encodes under. The governor's other
    /// levers are GPU-side and the codec is not, so it needs its own — see
    /// `GVRenderQuality.codecEdge`.
    var codecEdge: Int { resolvedTier.codecEdge }

    /// Historical alias. The HUD and the telemetry strip both report this.
    var reducedDetail: Bool { resolvedTier != .high }

    /// Pins the chain at native resolution for the duration of a take. Call
    /// every frame the chain should stay pinned; the pin lapses on its own
    /// once the caller stops asking.
    mutating func setFullResolutionHold(_ isHeld: Bool) {
        isPinnedToFullResolution = isHeld
    }

    mutating func update(stats: CameraRenderStats, fps: Int, thermalPressure: Bool) {
        guard stats.frameNumber != lastFrame else { return }
        lastFrame = stats.frameNumber

        guard tier.allowsAutomaticScaling, !isPinnedToFullResolution else {
            overBudget = 0
            underBudget = 0
            return
        }

        let budget = 1000.0 / Double(max(fps, 30))
        if thermalPressure || stats.gpuMilliseconds > budget * Self.overBudgetRatio {
            overBudget += 1
            underBudget = 0
            if overBudget >= Self.overBudgetFramesToDownshift, let next = Self.stepDown(from: resolvedTier) {
                resolvedTier = next
                overBudget = 0
            }
        } else if stats.gpuMilliseconds > 0, stats.gpuMilliseconds < budget * Self.underBudgetRatio {
            underBudget += 1
            overBudget = 0
            if underBudget >= Self.underBudgetFramesToUpshift {
                resolvedTier = .high
                underBudget = 0
            }
        } else {
            overBudget = 0
            underBudget = 0
        }
    }

    /// The automatic ladder, in the order the governor walks it. Each rung is
    /// a self-consistent set of scale, field sizes and solve depth, so
    /// dropping one never leaves a field at a size the solver was not tuned
    /// for.
    private static let automaticLadder: [GVRenderQuality] = [.high, .balanced, .efficient]

    private static func stepDown(from tier: GVRenderQuality) -> GVRenderQuality? {
        guard let index = automaticLadder.firstIndex(of: tier) else { return nil }
        let next = index + 1
        guard next < automaticLadder.count else { return nil }
        return automaticLadder[next]
    }
}
