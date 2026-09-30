import AppIntents
import SwiftUI

/// Capture and record.
///
/// These are the two intents that must reach the hardware rather than the
/// composition, so they post through the same bridge and let the workspace
/// decide what "take a still" means in the current state — a still while a
/// take is running is a frame grab, not a new file.
@available(iOS 16.0, *)
struct CaptureStillIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Still"
    static let description = IntentDescription("Captures a processed high-resolution still in grey//VISION.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        GVIntentBridge.shared.post(.captureStill)
        return .result()
    }
}

@available(iOS 16.0, *)
struct ToggleRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Video Recording"
    static let description = IntentDescription("Starts or stops video recording in grey//VISION.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        GVIntentBridge.shared.post(.toggleRecording)
        return .result()
    }
}
