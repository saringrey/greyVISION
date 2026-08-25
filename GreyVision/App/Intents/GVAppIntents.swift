import AppIntents
import SwiftUI

@available(iOS 16.0, *)
struct CaptureStillIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Still"
    static let description = IntentDescription("Captures a processed high-resolution still in grey//VISION.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}

@available(iOS 16.0, *)
struct ToggleRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Video Recording"
    static let description = IntentDescription("Starts or stops video recording in grey//VISION.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}

@available(iOS 16.0, *)
struct SetEffectIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Active Visual Effect"
    static let description = IntentDescription("Selects a visual filter effect in grey//VISION.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Effect Name")
    var effectName: String

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}
