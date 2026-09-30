import SwiftUI

/// The schedule every decorative `TimelineView` in this project should read
/// from.
///
/// ## What was actually missing
///
/// Most ambient animations here already branch on `accessibilityReduceMotion`
/// and render a still frame instead — that part was right, and the audit that
/// prompted this file was wrong to call it a gap. What none of them did was
/// consult `scenePhase`. A `TimelineView` whose `paused:` argument is a
/// hard-coded `false` keeps being scheduled when the app is backgrounded or
/// interrupted: the display link may or may not be torn down, the phone may or
/// may not be locked, and either way the view is rebuilding a decoration
/// nobody is looking at.
///
/// ## The rule
///
/// An ambient loop runs only while the scene is active. Reduce Motion stays
/// where it already lives — in the branch that decides *what* to draw — because
/// a still frame and a parked clock are different decisions and both are
/// correct.
enum GVAmbientClock {
    /// Schedule for an ambient, looping decoration.
    ///
    /// - Parameters:
    ///   - hertz: the rate the effect wants when it is running.
    ///   - scenePhase: the current scene phase, so the clock parks itself when
    ///     the app is not in front.
    /// - Returns: a schedule that is paused whenever the scene is not active.
    static func ambient(hertz: Double, scenePhase: ScenePhase) -> AnimationTimelineSchedule {
        .animation(minimumInterval: 1 / max(hertz, 1), paused: scenePhase != .active)
    }

    /// Variant for effects that additionally gate on their own `isActive`
    /// flag — a boot phase that has finished, a starfield that has dimmed out.
    static func ambient(
        hertz: Double,
        scenePhase: ScenePhase,
        isActive: Bool
    ) -> AnimationTimelineSchedule {
        .animation(minimumInterval: 1 / max(hertz, 1), paused: scenePhase != .active || !isActive)
    }
}
