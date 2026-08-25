@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import simd
import UIKit

enum CapturePosition: String, Codable, Sendable, CaseIterable {
    case rear
    case front

    var avPosition: AVCaptureDevice.Position {
        switch self {
        case .rear:
            .back
        case .front:
            .front
        }
    }
}

struct CaptureDimensions: Codable, Hashable, Sendable {
    let width: Int32
    let height: Int32

    static let hd720 = CaptureDimensions(width: 1280, height: 720)
    static let fullHD = CaptureDimensions(width: 1920, height: 1080)
    static let ultraHD = CaptureDimensions(width: 3840, height: 2160)
    static let openGate = CaptureDimensions(width: 4032, height: 3024)

    var label: String {
        "\(width)×\(height)"
    }
}

struct CaptureConfiguration: Codable, Equatable, Sendable {
    var position: CapturePosition
    var videoCodec: CaptureSetupDraft.VideoCodec
    var resolution: CaptureSetupDraft.Resolution
    var dimensions: CaptureDimensions
    var framesPerSecond: Int
    var prefersHDR: Bool
    var preferredDeviceID: String?

    static let standard = CaptureConfiguration(
        position: .rear,
        videoCodec: .hevc,
        resolution: .ultraHD,
        dimensions: .ultraHD,
        framesPerSecond: 60,
        prefersHDR: false,
        preferredDeviceID: nil
    )
}

struct CaptureFormatCapability: Codable, Hashable, Sendable {
    let dimensions: CaptureDimensions
    let maximumFramesPerSecond: Int
    let supportsHDR: Bool
    let mediaSubType: UInt32
}

struct CameraDeviceCapability: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let position: CapturePosition
    let deviceType: String
    let minimumZoom: Double
    let maximumZoom: Double
    let hasTorch: Bool
    let supportsFocusPoint: Bool
    let supportsExposurePoint: Bool
    let formats: [CaptureFormatCapability]
}

struct CameraCapabilities: Codable, Equatable, Sendable {
    let devices: [CameraDeviceCapability]
    let discoveryReason: String?

    static let synthetic = CameraCapabilities(
        devices: [],
        discoveryReason: "Simulator uses the deterministic synthetic source."
    )

    func devices(at position: CapturePosition) -> [CameraDeviceCapability] {
        devices.filter { $0.position == position }
    }

    func device(id: String?) -> CameraDeviceCapability? {
        guard let id else { return nil }
        return devices.first { $0.id == id }
    }
}

struct ActiveCameraInfo: Sendable, Equatable {
    let capabilities: CameraCapabilities
    let deviceID: String
    let deviceName: String
    let deviceType: String
    let position: CapturePosition
    let dimensions: CaptureDimensions
    let framesPerSecond: Int
    let pixelFormat: UInt32
    let hdrEnabled: Bool
    let minimumZoom: Double
    let maximumZoom: Double
    let minimumExposureBias: Double
    let maximumExposureBias: Double
    let torchAvailable: Bool
    let requestedVideoCodec: CaptureSetupDraft.VideoCodec
    let availableVideoCodecs: [CaptureSetupDraft.VideoCodec]
    let whiteBalanceLocked: Bool
}

enum CapturedFrameOrientation: Int, Sendable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight
}

struct CapturedFrame: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let presentationTime: CMTime
    let dimensions: CaptureDimensions
    let orientation: CapturedFrameOrientation
    let isMirrored: Bool
}

final class LatestCapturedFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latestFrame: CapturedFrame?

    func publish(_ frame: CapturedFrame) {
        lock.withLock {
            latestFrame = frame
        }
    }

    func consumeLatest() -> CapturedFrame? {
        lock.withLock {
            defer { latestFrame = nil }
            return latestFrame
        }
    }

    func clear() {
        lock.withLock {
            latestFrame = nil
        }
    }
}

struct DepthFrame: @unchecked Sendable {
    let capturedImage: CVPixelBuffer
    let depthMap: CVPixelBuffer
    let confidenceMap: CVPixelBuffer?
    let intrinsics: simd_float3x3
    let cameraTransform: simd_float4x4
    let imageDimensions: CaptureDimensions
    let orientation: CapturedFrameOrientation
    let timestamp: TimeInterval
}

protocol FrameSource: AnyObject, Sendable {
    var sourceID: String { get }
    func setFrameHandler(_ handler: (@Sendable (CapturedFrame) -> Void)?)
    func start(configuration: CaptureConfiguration) async throws -> ActiveCameraInfo
    func stop() async
}

extension CaptureConfiguration {
    init(draft: CaptureSetupDraft, preferredDeviceID: String? = nil) {
        position = draft.cameraPosition == .rear ? .rear : .front
        videoCodec = draft.videoCodec
        resolution = draft.resolution
        dimensions = switch draft.resolution {
        case .hd720:
            .hd720
        case .fullHD:
            .fullHD
        case .ultraHD:
            .ultraHD
        case .openGate:
            .openGate
        }
        framesPerSecond = draft.frameRate.rawValue
        prefersHDR = false
        self.preferredDeviceID = preferredDeviceID
    }
}

extension CaptureSetupDraft.VideoCodec {
    var avVideoCodecType: AVVideoCodecType? {
        switch self {
        case .h264:
            .h264
        case .hevc:
            .hevc
        case .hevcWithAlpha:
            .hevcWithAlpha
        case .proRes422Proxy:
            .proRes422Proxy
        case .proRes422LT:
            .proRes422LT
        case .proRes422:
            .proRes422
        case .proRes422HQ:
            .proRes422HQ
        case .proRes4444:
            .proRes4444
        case .proRes4444XQ:
            if #available(iOS 18.0, *) {
                AVVideoCodecType(rawValue: "ap4x")
            } else {
                nil
            }
        case .proResRAW:
            if #available(iOS 26.0, *) {
                .proResRAW
            } else {
                nil
            }
        case .proResRAWHQ:
            if #available(iOS 26.0, *) {
                .proResRAWHQ
            } else {
                nil
            }
        case .jpegXL:
            if #available(iOS 18.0, *) {
                AVVideoCodecType(rawValue: "jxlc")
            } else {
                nil
            }
        }
    }

    static func supportedChoices(from codecTypes: [AVVideoCodecType]) -> [Self] {
        allCases.filter { codec in
            guard let type = codec.avVideoCodecType else { return false }
            return codecTypes.contains(type)
        }
    }
}

public struct GVLastCapture: Equatable, Sendable {
    public enum MediaType: Sendable {
        case still(image: CGImage)
        case video(url: URL)
    }

    public let id: UUID
    public let mediaType: MediaType
    public let capturedAt: Date
    public let thumbnail: UIImage?

    public init(mediaType: MediaType, thumbnail: UIImage?) {
        id = UUID()
        self.mediaType = mediaType
        capturedAt = Date()
        self.thumbnail = thumbnail
    }

    public static func == (lhs: GVLastCapture, rhs: GVLastCapture) -> Bool {
        lhs.id == rhs.id
    }
}
