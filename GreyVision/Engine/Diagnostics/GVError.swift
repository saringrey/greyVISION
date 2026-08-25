import Foundation

enum GVError: LocalizedError, Sendable, Equatable {
    case permissionDenied(resource: String)
    case capabilityUnavailable(feature: String, reason: String)
    case invalidState(operation: String, state: String)
    case captureFailure(message: String)
    case renderingFailure(message: String)
    case recordingFailure(message: String)
    case storageFailure(message: String)

    var errorDescription: String? {
        switch self {
        case let .permissionDenied(resource):
            "Permission denied: \(resource)."
        case let .capabilityUnavailable(feature, reason):
            "\(feature) is unavailable: \(reason)"
        case let .invalidState(operation, state):
            "Cannot \(operation) while the engine is \(state)."
        case let .captureFailure(message):
            "Capture failed: \(message)"
        case let .renderingFailure(message):
            "Rendering failed: \(message)"
        case let .recordingFailure(message):
            "Recording failed: \(message)"
        case let .storageFailure(message):
            "Storage failed: \(message)"
        }
    }
}
