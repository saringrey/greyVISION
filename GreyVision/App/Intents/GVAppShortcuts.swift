import AppIntents

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
    }
}
