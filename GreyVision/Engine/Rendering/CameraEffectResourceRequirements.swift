import Foundation

/// Actual camera graph dependencies, independent of the browsing category.
struct CameraEffectResourceRequirements: OptionSet, Sendable {
    let rawValue: UInt8
    static let opticalFlow = Self(rawValue: 1 << 0)
    static let timestampedHistory = Self(rawValue: 1 << 1)
    static let legacyHistoryTaps = Self(rawValue: 1 << 2)
    static let slotHistory = Self(rawValue: 1 << 3)
    static let moshState = Self(rawValue: 1 << 4)
    static let simulation = Self(rawValue: 1 << 5)
}

/// How much renderer time an effect asks for, as a three-step read the rail
/// can show without a legend.
///
/// Derived from the requirements the graph already declares rather than from
/// measurements, because a per-effect benchmark table would go stale the first
/// time a shader changed and the number on the card would quietly become a
/// lie. The mapping is coarse on purpose: the point is to separate a colour
/// grade from an optical-flow solve, not to predict milliseconds.
enum GVEffectGPUCost: Int, Comparable, Sendable {
    case light = 1
    case moderate = 2
    case heavy = 3

    static func < (lhs: GVEffectGPUCost, rhs: GVEffectGPUCost) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension WorkspaceAdjustableEffect {
    /// The cost band the rail shows, and what the ACTIVE rail sums.
    var gpuCost: GVEffectGPUCost {
        let requirements = cameraResourceRequirements
        // A full multi-pass simulation is categorically its own thing: it owns
        // a grid, a pressure solve and a composite, and nothing else in the
        // graph does that much per frame.
        if requirements.contains(.simulation) { return .heavy }
        // Optical flow and stateful mosh both carry history across frames and
        // run their own passes; stacking two of them is where a device starts
        // dropping frames.
        let statefulPasses = [requirements.contains(.opticalFlow), requirements.contains(.moshState)]
            .filter(\.self)
            .count
        if statefulPasses >= 2 { return .heavy }
        if statefulPasses == 1 { return .moderate }
        if requirements.contains(.legacyHistoryTaps) || requirements.contains(.timestampedHistory) {
            return .moderate
        }
        return .light
    }
}

extension WorkspaceAdjustableEffect {
    var cameraResourceRequirements: CameraEffectResourceRequirements {
        var requirements: CameraEffectResourceRequirements = []
        switch self {
        case .datamosh, .liquidMosh, .heavyMosh, .predictionDrift, .vectorCodebook,
             .motionTransplant, .bitplaneLatch, .opticalFlowLiquid, .causalSmear,
             .realityCavitation, .timeFracture, .antiCamera, .memoryBurnIn,
             .spectralDepth, .vectorNecromancy:
            requirements.insert(.opticalFlow)
        default: break
        }
        switch self {
        case .timeGraffiti, .timeMap: requirements.insert(.timestampedHistory)
        case .frameTear, .bufferUnderrun, .packetLoss, .chromaFailure,
             .realityCavitation, .timeFracture, .antiCamera, .spectralDepth, .vectorNecromancy:
            requirements.insert(.legacyHistoryTaps)
        default: break
        }
        switch self {
        case .datamosh, .liquidMosh, .heavyMosh, .predictionDrift, .moshBrush,
             .vectorCodebook, .motionTransplant, .bitplaneLatch:
            requirements.formUnion([.slotHistory, .moshState])
        case .fluid, .reactionGarden: requirements.insert(.simulation)
        default: break
        }
        return requirements
    }
}
