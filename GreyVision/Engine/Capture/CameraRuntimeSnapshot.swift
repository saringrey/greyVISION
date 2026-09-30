import Foundation

struct CameraRuntimeSnapshot: Sendable, Equatable {
    enum State: String, Codable, Sendable {
        case idle
        case requestingPermission
        case configuring
        case running
        case interrupted
        case denied
        case failed

        var label: String {
            switch self {
            case .requestingPermission:
                "PERMISSION"
            default:
                rawValue.uppercased()
            }
        }
    }

    var state: State
    var sourceLabel: String
    var formatLabel: String
    var deviceID: String?
    var deviceType: String
    var position: CapturePosition
    var framesPerSecond: Int
    var requestedVideoCodec: CaptureSetupDraft.VideoCodec
    var availableVideoCodecs: [CaptureSetupDraft.VideoCodec]
    var isRequestedVideoCodecAvailable: Bool
    var codecAvailabilityReason: String?
    var isSynthetic: Bool
    var hdrEnabled: Bool
    var zoom: Double
    var minimumZoom: Double
    var maximumZoom: Double
    var exposureBias: Double
    var minimumExposureBias: Double
    var maximumExposureBias: Double
    var torchAvailable: Bool
    var torchEnabled: Bool
    var whiteBalanceLocked: Bool
    var focusLocked = false
    /// True once ISO or shutter has been driven by hand. Setting either
    /// requires custom exposure mode, so the device stops metering — and a
    /// camera that has silently stopped metering has to say so.
    var exposureLocked = false
    var interruptionReason: String?
    var errorMessage: String?

    static let idle = CameraRuntimeSnapshot(
        state: .idle,
        sourceLabel: "NONE",
        formatLabel: "UNRESOLVED",
        deviceID: nil,
        deviceType: "NONE",
        position: .rear,
        framesPerSecond: 0,
        requestedVideoCodec: .hevc,
        availableVideoCodecs: [],
        isRequestedVideoCodecAvailable: false,
        codecAvailabilityReason: "SESSION NOT CONFIGURED",
        isSynthetic: false,
        hdrEnabled: false,
        zoom: 1,
        minimumZoom: 1,
        maximumZoom: 1,
        exposureBias: 0,
        minimumExposureBias: 0,
        maximumExposureBias: 0,
        torchAvailable: false,
        torchEnabled: false,
        whiteBalanceLocked: false,
        interruptionReason: nil,
        errorMessage: nil
    )
}
