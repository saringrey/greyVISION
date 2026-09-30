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
                "422"
            case .proRes422HQ:
                "422 HQ"
            case .proRes4444:
                "4444"
            case .proRes4444XQ:
                "4444XQ"
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

        var isProRes: Bool {
            switch self {
            case .proRes422Proxy, .proRes422LT, .proRes422, .proRes422HQ,
                 .proRes4444, .proRes4444XQ, .proResRAW, .proResRAWHQ:
                true
            default:
                false
            }
        }

        /// Chroma the format carries, in the notation a colourist would use.
        ///
        /// The boot chooser prints this, because a codec is picked for what it
        /// preserves: 4:2:0 to 4:2:2 to 4:4:4 is the first thing that
        /// separates the options, and it is not visible in any of the names.
        /// Raw formats have a Bayer mosaic and no subsampled chroma to name.
        var chromaLabel: String {
            switch self {
            case .h264, .hevc, .hevcWithAlpha, .jpegXL:
                "4:2:0"
            case .proRes422Proxy, .proRes422LT, .proRes422, .proRes422HQ:
                "4:2:2"
            case .proRes4444, .proRes4444XQ:
                "4:4:4"
            case .proResRAW, .proResRAWHQ:
                "RAW BAYER"
            }
        }

        /// Bits per component. The 422 family is 10-bit, the 4444 family and
        /// ProRes RAW are 12-bit, and everything the device hands straight to
        /// a delivery container is 8-bit.
        var bitDepthLabel: String {
            switch self {
            case .h264, .hevc, .hevcWithAlpha, .jpegXL:
                "8-BIT"
            case .proRes422Proxy, .proRes422LT, .proRes422, .proRes422HQ:
                "10-BIT"
            case .proRes4444, .proRes4444XQ, .proResRAW, .proResRAWHQ:
                "12-BIT"
            }
        }

        /// Which stage of the chain the format is for. Editorial, but it is
        /// the distinction the fidelity ladder beside it is actually
        /// measuring: a delivery codec and a sensor format are not the same
        /// tool with different numbers.
        var tierLabel: String {
            switch self {
            case .proRes422Proxy, .proRes422LT:
                "OFFLINE"
            case .proRes422, .proRes422HQ, .proRes4444, .proRes4444XQ:
                "MASTERING"
            case .proResRAW, .proResRAWHQ:
                "SENSOR"
            default:
                "DELIVERY"
            }
        }

        /// Relative fidelity, 1...5 — how much of the sensor's signal survives
        /// the format, ranked by depth and chroma rather than by hope.
        ///
        /// Only ever drawn as a ladder and a word. Before a session starts
        /// there is no measured bit rate to print, and a fabricated Mb/s
        /// figure in the one place the operator compares formats would be a
        /// lie dressed as telemetry.
        var fidelityClass: Int {
            switch self {
            case .h264, .proRes422Proxy, .jpegXL:
                1
            case .hevc, .hevcWithAlpha, .proRes422LT:
                2
            case .proRes422, .proRes422HQ:
                3
            case .proRes4444, .proRes4444XQ, .proResRAW:
                4
            case .proResRAWHQ:
                5
            }
        }

        /// Word for `fidelityClass`. The ladder says where the format sits;
        /// this says it in a language the operator can repeat out loud.
        var fidelityLabel: String {
            switch fidelityClass {
            case 1: "LEAN"
            case 2: "STANDARD"
            case 3: "HIGH"
            case 4: "MASTER"
            default: "MAXIMUM"
            }
        }

        var isProResRAW: Bool {
            self == .proResRAW || self == .proResRAWHQ
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

        /// Pixel dimensions this raster records. The boot chooser prints the
        /// sensor's own numbers rather than a tier name, so nothing here is a
        /// claim the format cannot be held to.
        var pixelLabel: String {
            switch self {
            case .hd720: "1280 × 720"
            case .fullHD: "1920 × 1080"
            case .ultraHD: "3840 × 2160"
            case .openGate: "4032 × 3024"
            }
        }

        /// What the raster buys the operator, in one word pair. Kept beside
        /// the dimensions so the note and the chooser's readout are the same
        /// fact spelled twice rather than two facts that can drift apart.
        var detailLabel: String {
            switch self {
            case .hd720: "LOW LATENCY"
            case .fullHD: "BALANCED"
            case .ultraHD: "MAX DETAIL"
            case .openGate: "FULL SENSOR"
            }
        }

        /// Relative pixel detail, 1...4, for the chooser's ladder.
        var detailClass: Int {
            switch self {
            case .hd720: 1
            case .fullHD: 2
            case .ultraHD: 3
            case .openGate: 4
            }
        }

        var availabilityNote: String {
            "\(pixelLabel) // \(detailLabel)"
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

        /// One word for the cadence, for the chooser's card micro line.
        var cadenceLabel: String {
            switch self {
            case .cinematic: "CINEMATIC"
            case .realtime: "REALTIME"
            case .highSpeed: "HIGH SPEED"
            }
        }

        /// Relative motion, 1...3, for the chooser's ladder.
        var motionClass: Int {
            switch self {
            case .cinematic: 1
            case .realtime: 2
            case .highSpeed: 3
            }
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

    /// Aspect ratio the operator wants from the sensor. Native asks the device
    /// for its full sensor readout; the others pick the format whose pixel
    /// dimensions most closely match the requested ratio at the chosen
    /// resolution. Stored on the draft and applied at capture start.
    enum AspectRatio: String, CaseIterable, Identifiable, Sendable {
        case native
        case ratio_4_3 = "4:3"
        case ratio_16_9 = "16:9"
        case ratio_1_1 = "1:1"

        var id: String {
            rawValue
        }

        var shortLabel: String {
            switch self {
            case .native: "NATIVE"
            case .ratio_4_3: "4:3"
            case .ratio_16_9: "16:9"
            case .ratio_1_1: "1:1"
            }
        }

        var ratio: CGFloat? {
            switch self {
            case .native: nil
            case .ratio_4_3: 4.0 / 3.0
            case .ratio_16_9: 16.0 / 9.0
            case .ratio_1_1: 1.0
            }
        }
    }

    var cameraPosition: CameraPosition = .rear
    var videoCodec: VideoCodec = .hevc
    var resolution: Resolution = .ultraHD
    var frameRate: FrameRate = .realtime
    var qualityTier: QualityTier = .balanced
    var aspectRatio: AspectRatio = .native
}
