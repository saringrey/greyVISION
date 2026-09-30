import Foundation

/// How hard the renderer is allowed to work, and how far it may back off.
///
/// ## Why a scale and not an effect cull
///
/// The composition is authoritative. Skipping a visible slot to save a
/// millisecond is the one thing this renderer will not do — the operator
/// asked for that effect and has to get it. Resolution is the honest lever:
/// rendering the chain at 80% and letting the final blit scale to the
/// drawable is a visible-but-acceptable change, where dropping a DATAMOSH is
/// a wrong answer.
///
/// ## The ladder
///
/// `full` is native. Each step down trades sharpness for headroom, and the
/// governor in `CameraEffectQuality` moves along it only after a sustained
/// run of frames over budget, so a single slow frame never changes the image.
///
/// Recording pins `full`, because the recorded file must match what the
/// operator was looking at rather than whatever the governor had settled on.
enum GVRenderQuality: String, CaseIterable, Codable, Sendable {
    /// Follow the frame budget automatically. The default.
    case automatic
    /// Never scale down. For a device that is thermally calm and an operator
    /// who would rather have a dropped frame than a soft one.
    case high
    /// Cap at a fixed middle rung.
    case balanced
    /// Pin to the bottom rung. Also what Low Power Mode selects.
    case efficient

    /// Longest-edge multiplier applied to the render chain.
    var renderScale: Double {
        switch self {
        case .automatic: 1
        case .high: 1
        case .balanced: 0.85
        case .efficient: 0.7
        }
    }

    /// Whether the governor is allowed to move along the ladder at all.
    var allowsAutomaticScaling: Bool { self == .automatic }

    /// Longest edge of the optical-flow field.
    var flowEdge: Int {
        switch self {
        case .automatic: 192
        case .high: 192
        case .balanced: 160
        case .efficient: 128
        }
    }

    /// Longest edge of the fluid and reaction-diffusion grids.
    var simulationEdge: Int {
        switch self {
        case .automatic: 256
        case .high: 256
        case .balanced: 192
        case .efficient: 128
        }
    }

    /// Jacobi iterations in the pressure solve. Below ~20 the field stays
    /// visibly divergent and the fluid reads as smearing; above ~40 the cost
    /// stops buying anything you can see.
    var pressureIterations: Int {
        switch self {
        case .automatic: 24
        case .high: 24
        case .balanced: 18
        case .efficient: 12
        }
    }

    /// Ceiling on the display refresh rate the preview will drive.
    var maximumFramesPerSecond: Int {
        switch self {
        case .automatic: 120
        case .high: 120
        case .balanced: 60
        case .efficient: 30
        }
    }

    /// What the badge in the workspace says.
    var displayName: String {
        switch self {
        case .automatic: "AUTO"
        case .high: "HIGH"
        case .balanced: "BALANCED"
        case .efficient: "EFFICIENT"
        }
    }

    /// The tier actually in force this instant, once the automatic governor
    /// and any system-level restriction have had their say.
    ///
    /// This always answers with a concrete rung, never with `.automatic`.
    /// Everything downstream — the governor's ladder, the badge, the frame
    /// rate cap — needs a tier it can step from, and `.automatic` is a
    /// statement of intent rather than a rung to walk down from.
    static func resolve(_ requested: GVRenderQuality, isLowPowerModeEnabled: Bool) -> GVRenderQuality {
        guard requested.allowsAutomaticScaling else { return requested }
        // Low Power Mode is a request to spend less, not to stop working: one
        // rung down rather than straight to the bottom.
        return isLowPowerModeEnabled ? .balanced : .high
    }
}
