import simd

/// A slow, deterministic stand-in finger for effects that are drawn *by* touch.
///
/// The brushes and the fluid solver do nothing at all until something touches
/// them, which reads as a broken effect the moment it is selected. While no
/// real finger is down, these effects are driven along a Lissajous path
/// instead; a real touch replaces it on the same frame. Only the effects that
/// opt in via `WorkspaceAdjustableEffect.idlesOnGhostFinger` ever see it —
/// colour modes and lenses that merely *respond* to touch keep their honest
/// untouched look.
enum GVGhostFinger {
    struct Inputs {
        let touch: SIMD4<Float>
        let drag: SIMD4<Float>
    }

    /// Path position and velocity at `time` (seconds on the effect clock).
    static func inputs(at time: Float) -> Inputs {
        let position = SIMD2<Float>(
            0.5 + 0.30 * sin(time * 0.47),
            0.5 + 0.26 * sin(time * 0.31 + 1.2)
        )
        let velocity = SIMD2<Float>(
            0.30 * 0.47 * cos(time * 0.47),
            0.26 * 0.31 * cos(time * 0.31 + 1.2)
        )
        return Inputs(
            touch: SIMD4(position.x, position.y, min(length(velocity) * 0.75 * 6, 2), 1),
            drag: SIMD4(velocity.x, velocity.y, 0, 1)
        )
    }

    /// The touch an effect should see: the real one when a finger is down,
    /// the ghost otherwise — for effects that opt in.
    static func resolve(effect: WorkspaceAdjustableEffect, touch: SIMD4<Float>, drag: SIMD4<Float>,
                        time: Float) -> Inputs
    {
        guard effect.idlesOnGhostFinger, touch.w < 0.5 else { return Inputs(touch: touch, drag: drag) }
        return inputs(at: time)
    }
}

extension WorkspaceAdjustableEffect {
    /// Effects whose whole output is drawn by a finger, and so are blank
    /// without one. These run on `GVGhostFinger` while nobody is touching.
    var idlesOnGhostFinger: Bool {
        switch self {
        case .freezeBrush, .sortBrush, .moshBrush, .fluid, .timeGraffiti: true
        default: false
        }
    }
}
