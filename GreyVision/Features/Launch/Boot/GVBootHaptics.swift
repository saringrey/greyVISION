import UIKit

/// Restrained tactile punctuation for boot and signal events.
///
/// Deliberately sparse: one impact when the instrument becomes operational and
/// one when a torn signal reconnects. Nothing fires per frame.
@MainActor
enum GVBootHaptics {
    static func armed() {
        guard UIAccessibility.isReduceMotionEnabled == false else { return }
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        generator.impactOccurred(intensity: 0.55)
    }

    static func signalSnap() {
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.prepare()
        generator.impactOccurred(intensity: 0.72)
    }

    static func signalBreak() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
    }
}
