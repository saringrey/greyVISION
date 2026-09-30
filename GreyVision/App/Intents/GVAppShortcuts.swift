import AppIntents

/// The phrases Shortcuts and Siri will recognise.
///
/// Every intent here posts through `GVIntentBridge` rather than touching the
/// composition, so a shortcut fired from the Action button while the app is
/// backgrounded is picked up the moment the workspace is on screen — and one
/// fired from Spotlight launches the app and lands in the right state.
@available(iOS 16.0, *)
struct GVAppShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureStillIntent(),
            phrases: [
                "Capture still in \(.applicationName)",
                "Take a picture in \(.applicationName)",
                "Snapshot in \(.applicationName)"
            ],
            shortTitle: "Capture Still",
            systemImageName: "camera"
        )
        AppShortcut(
            intent: ToggleRecordingIntent(),
            phrases: [
                "Record video in \(.applicationName)",
                "Toggle recording in \(.applicationName)",
                "Start take in \(.applicationName)"
            ],
            shortTitle: "Toggle Recording",
            systemImageName: "record.circle"
        )
        // The composition verbs. Each is one word to say and one press to
        // undo, which is the point: an accidental shortcut is cheap to
        // reverse now that undo is reachable.
        AppShortcut(
            intent: UndoEditIntent(),
            phrases: [
                "Undo in \(.applicationName)",
                "Undo the last edit in \(.applicationName)"
            ],
            shortTitle: "Undo Edit",
            systemImageName: "arrow.uturn.backward"
        )
        AppShortcut(
            intent: RedoEditIntent(),
            phrases: [
                "Redo in \(.applicationName)",
                "Redo the last edit in \(.applicationName)"
            ],
            shortTitle: "Redo Edit",
            systemImageName: "arrow.uturn.forward"
        )
        AppShortcut(
            intent: SoloFocusedEffectIntent(),
            phrases: [
                "Solo effect in \(.applicationName)",
                "Solo the current effect in \(.applicationName)"
            ],
            shortTitle: "Solo Effect",
            systemImageName: "square.dashed"
        )
        AppShortcut(
            intent: RemoveFocusedEffectIntent(),
            phrases: [
                "Remove effect in \(.applicationName)",
                "Take the effect out in \(.applicationName)"
            ],
            shortTitle: "Remove Effect",
            systemImageName: "trash"
        )
        AppShortcut(
            intent: ToggleStackArmedIntent(),
            phrases: [
                "Toggle add mode in \(.applicationName)",
                "Stack effects in \(.applicationName)"
            ],
            shortTitle: "Toggle Add Mode",
            systemImageName: "square.3.layers.3d"
        )
        AppShortcut(
            intent: ToggleBypassIntent(),
            phrases: [
                "Bypass effects in \(.applicationName)",
                "Compare with clean in \(.applicationName)"
            ],
            shortTitle: "Bypass Effects",
            systemImageName: "eye.slash"
        )
        AppShortcut(
            intent: ToggleAudioReactiveIntent(),
            phrases: [
                "Toggle audio effects in \(.applicationName)",
                "Toggle the microphone in \(.applicationName)"
            ],
            shortTitle: "Toggle Audio",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: NextShelfIntent(),
            phrases: [
                "Next effect shelf in \(.applicationName)",
                "Next effect group in \(.applicationName)"
            ],
            shortTitle: "Next Shelf",
            systemImageName: "square.grid.2x2"
        )
    }
}
