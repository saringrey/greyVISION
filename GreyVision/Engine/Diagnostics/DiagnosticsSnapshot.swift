import Foundation

struct DiagnosticsSnapshot: Sendable, Equatable {
    enum EngineState: String, Sendable, Codable {
        case idle
        case starting
        case running
        case interrupted
        case failed
    }

    var engineState: EngineState
    var activeSource: String
    var renderedFrames: UInt64
    var droppedFrames: UInt64
    var lastError: String?

    static let initial = DiagnosticsSnapshot(
        engineState: .idle,
        activeSource: "NONE",
        renderedFrames: 0,
        droppedFrames: 0,
        lastError: nil
    )
}
