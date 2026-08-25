import Foundation

enum CameraEvent: Sendable, Equatable {
    case interrupted(reason: String)
    case resumed
    case mediaServicesReset
    case failed(message: String)
}
