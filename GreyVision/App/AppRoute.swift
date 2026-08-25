import Foundation

enum AppRoute: Sendable, Equatable {
    /// Access ceremony. Cold launch only.
    case gate
    case boot
    case workspace
}

enum RuntimeStatus: String, Sendable, Equatable {
    case offline
    case queued
    case starting
    case running
    case interrupted
    case failed

    var label: String {
        rawValue.uppercased()
    }
}

struct CaptureSetupDraft: Sendable, Equatable {
    enum VideoCodec: String, CaseIterable, Identifiable, Codable, Sendable {
        /// The curated picker list. The enum keeps every case it ever spelled
        /// for decoding old drafts, but the interface only offers the basics:
        /// H.264, HEVC, ProRes 422 HQ, 4444 XQ and RAW HQ.
        static let curated: [VideoCodec] = [.h264, .hevc, .proRes422HQ, .proRes4444XQ, .proResRAWHQ]

        case h264 = "H.264"
        case hevc = "HEVC"
        case hevcWithAlpha = "HEVC ALPHA"
        case proRes422Proxy = "PRORES 422 PROXY"
        case proRes422LT = "PRORES 422 LT"
        case proRes422 = "PRORES 422"
        case proRes422HQ = "PRORES 422 HQ"
        case proRes4444 = "PRORES 4444"
        case proRes4444XQ = "PRORES 4444 XQ"
        case proResRAW = "PRORES RAW"
        case proResRAWHQ = "PRORES RAW HQ"
        case jpegXL = "JPEG XL"

        var id: String {
            rawValue
        }

        var compactLabel: String {
            switch self {
            case .hevcWithAlpha:
                "HEVC A"
            case .proRes422Proxy:
                "422 PXY"
            case .proRes422LT:
                "422 LT"
            case .proRes422:
                "PRORES"
            case .proRes422HQ:
                "422 HQ"
            case .proRes4444:
                "4444"
            case .proRes4444XQ:
                "4444 XQ"
            case .proResRAW:
                "RAW"
            case .proResRAWHQ:
                "RAW HQ"
            case .jpegXL:
                "JXL"
            default:
                rawValue
            }
        }

        var isOperatingSystemAvailable: Bool {
            switch self {
            case .proResRAW, .proResRAWHQ:
                if #available(iOS 26.0, *) {
                    true
                } else {
                    false
                }
            case .proRes4444XQ, .jpegXL:
                if #available(iOS 18.0, *) {
                    true
                } else {
                    false
                }
            default:
                true
            }
        }

        var availabilityNote: String {
            switch self {
            case .h264:
                "UNIVERSAL // .MP4 OR .MOV"
            case .hevc:
                "HIGH EFFICIENCY // .MOV"
            case .hevcWithAlpha:
                "ALPHA CHANNEL // LIVE CHECK"
            case .proRes422Proxy:
                "LOW DATA RATE PRORES // LIVE CHECK"
            case .proRes422LT:
                "LIGHT PRORES // LIVE CHECK"
            case .proRes422:
                "DEVICE + FORMAT CHECKED LIVE"
            case .proRes422HQ:
                "HIGH DATA RATE // LIVE CHECK"
            case .proRes4444:
                "4:4:4 + ALPHA // LIVE CHECK"
            case .proRes4444XQ:
                "MAX 4:4:4 PRORES // LIVE CHECK"
            case .proResRAW:
                isOperatingSystemAvailable
                    ? "IOS 26+ // SENSOR + FORMAT CHECK"
                    : "REQUIRES IOS 26+"
            case .proResRAWHQ:
                isOperatingSystemAvailable
                    ? "IOS 26+ RAW HQ // SENSOR CHECK"
                    : "REQUIRES IOS 26+"
            case .jpegXL:
                "IOS 18+ JXL // LIVE CHECK"
            }
        }
    }

    enum CameraPosition: String, CaseIterable, Identifiable, Sendable {
        case rear = "REAR"
        case front = "FRONT"

        var id: String {
            rawValue
        }
    }

    enum Resolution: String, CaseIterable, Identifiable, Codable, Sendable {
        case hd720 = "720P"
        case fullHD = "1080P"
        case ultraHD = "4K"
        case openGate = "OPEN GATE"

        var id: String {
            rawValue
        }

        var availabilityNote: String {
            switch self {
            case .hd720:
                "1280 × 720 // LOW LATENCY"
            case .fullHD:
                "1920 × 1080 // BALANCED"
            case .ultraHD:
                "3840 × 2160 // MAX DETAIL"
            case .openGate:
                "STABILITY HOLD // OFFLINE THIS BUILD"
            }
        }

        /// OPEN GATE takes the full 4:3 sensor readout, and that path is
        /// crashing on device. Held out of the pickers until it is root-caused;
        /// the raw value still decodes so an old draft does not fail.
        var isSelectable: Bool {
            self != .openGate
        }
    }

    enum FrameRate: Int, CaseIterable, Identifiable, Sendable {
        case cinematic = 30
        case realtime = 60
        case highSpeed = 120

        var id: Int {
            rawValue
        }

        var label: String {
            "\(rawValue) FPS"
        }

        var availabilityNote: String {
            switch self {
            case .cinematic:
                "CINEMATIC CADENCE"
            case .realtime:
                "REALTIME BASELINE"
            case .highSpeed:
                "HIGH SPEED // FORMAT CHECKED LIVE"
            }
        }
    }

    enum QualityTier: String, CaseIterable, Identifiable, Sendable {
        case full = "FULL"
        case balanced = "BALANCED"
        case low = "LOW"

        var id: String {
            rawValue
        }
    }

    var cameraPosition: CameraPosition = .rear
    var videoCodec: VideoCodec = .hevc
    var resolution: Resolution = .ultraHD
    var frameRate: FrameRate = .realtime
    var qualityTier: QualityTier = .balanced
}
