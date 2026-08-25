@preconcurrency import AVFoundation
import CoreMedia
import Foundation

enum CameraDiscovery {
    static func capabilities() -> CameraCapabilities {
        let capabilities = devices().map { device in
            let formats = Set(device.formats.map { format in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let maximumFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                return CaptureFormatCapability(
                    dimensions: CaptureDimensions(width: dimensions.width, height: dimensions.height),
                    maximumFramesPerSecond: Int(maximumFPS.rounded(.down)),
                    supportsHDR: format.isVideoHDRSupported,
                    mediaSubType: CMFormatDescriptionGetMediaSubType(format.formatDescription)
                )
            })
            .sorted { lhs, rhs in
                if lhs.dimensions.width == rhs.dimensions.width {
                    return lhs.maximumFramesPerSecond > rhs.maximumFramesPerSecond
                }
                return lhs.dimensions.width > rhs.dimensions.width
            }

            return CameraDeviceCapability(
                id: device.uniqueID,
                name: device.localizedName,
                position: device.position == .front ? .front : .rear,
                deviceType: device.deviceType.rawValue,
                minimumZoom: Double(device.minAvailableVideoZoomFactor),
                maximumZoom: Double(device.maxAvailableVideoZoomFactor),
                hasTorch: device.hasTorch,
                supportsFocusPoint: device.isFocusPointOfInterestSupported,
                supportsExposurePoint: device.isExposurePointOfInterestSupported,
                formats: formats
            )
        }

        return CameraCapabilities(
            devices: capabilities,
            discoveryReason: capabilities.isEmpty ? "No compatible video capture device was discovered." : nil
        )
    }

    static func device(
        configuration: CaptureConfiguration,
        capabilities: CameraCapabilities
    ) throws -> AVCaptureDevice {
        let available = devices().filter { $0.position == configuration.position.avPosition }
        if let preferredID = configuration.preferredDeviceID {
            if let preferred = available.first(where: { $0.uniqueID == preferredID }) {
                return preferred
            }
        }

        // Dual-wide first on the rear: the 0.5–1x virtual device is the
        // native field of view at rest, and zoom continues smoothly into
        // the triple's longer reach.
        let priority: [AVCaptureDevice.DeviceType] = configuration.position == .rear
            ? [.builtInDualWideCamera, .builtInTripleCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        for type in priority {
            if let match = available.first(where: { $0.deviceType == type }) {
                return match
            }
        }
        if let fallback = available.first {
            return fallback
        }

        let reason = capabilities.discoveryReason ?? "No camera exists for the selected position."
        throw GVError.capabilityUnavailable(feature: "Camera", reason: reason)
    }

    static func format(
        device: AVCaptureDevice,
        configuration: CaptureConfiguration
    ) throws -> AVCaptureDevice.Format {
        guard !device.formats.isEmpty else {
            throw GVError.capabilityUnavailable(
                feature: "Camera format",
                reason: "The selected device reports no formats."
            )
        }

        if configuration.resolution == .openGate {
            return openGateFormat(device: device, configuration: configuration)
        }

        let eligibleFormats = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width >= configuration.dimensions.width &&
                dimensions.height >= configuration.dimensions.height
        }
        let candidates = eligibleFormats.isEmpty ? device.formats : eligibleFormats

        let targetPixels = Int64(configuration.dimensions.width) * Int64(configuration.dimensions.height)
        return candidates.min { lhs, rhs in
            formatScore(lhs, targetPixels: targetPixels, configuration: configuration) <
                formatScore(rhs, targetPixels: targetPixels, configuration: configuration)
        } ?? device.activeFormat
    }

    private static func openGateFormat(
        device: AVCaptureDevice,
        configuration: CaptureConfiguration
    ) -> AVCaptureDevice.Format {
        let requestedFPS = Double(configuration.framesPerSecond)
        let fourByThree = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let aspect = Double(dimensions.width) / Double(max(dimensions.height, 1))
            return abs(aspect - (4.0 / 3.0)) < 0.08
        }
        let sensorFormats = fourByThree.isEmpty ? device.formats : fourByThree
        let frameRateCompatible = sensorFormats.filter { format in
            format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= requestedFPS && range.maxFrameRate >= requestedFPS
            }
        }
        let candidates = frameRateCompatible.isEmpty ? sensorFormats : frameRateCompatible
        return candidates.max { lhs, rhs in
            let lhsDimensions = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rhsDimensions = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let lhsPixels = Int64(lhsDimensions.width) * Int64(lhsDimensions.height)
            let rhsPixels = Int64(rhsDimensions.width) * Int64(rhsDimensions.height)
            if lhsPixels == rhsPixels, configuration.prefersHDR {
                return !lhs.isVideoHDRSupported && rhs.isVideoHDRSupported
            }
            return lhsPixels < rhsPixels
        } ?? device.activeFormat
    }

    private static func formatScore(
        _ format: AVCaptureDevice.Format,
        targetPixels: Int64,
        configuration: CaptureConfiguration
    ) -> Int64 {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let pixels = Int64(dimensions.width) * Int64(dimensions.height)
        let resolutionDistance = abs(pixels - targetPixels)
        let requestedFPS = Double(configuration.framesPerSecond)
        let supportsRequestedFPS = format.videoSupportedFrameRateRanges.contains { range in
            range.minFrameRate <= requestedFPS && range.maxFrameRate >= requestedFPS
        }
        let closestFPSDistance = format.videoSupportedFrameRateRanges.map { range in
            abs(min(max(requestedFPS, range.minFrameRate), range.maxFrameRate) - requestedFPS)
        }.min() ?? requestedFPS
        let fpsPenalty: Int64 = supportsRequestedFPS
            ? 0
            : 10_000_000_000 + Int64((closestFPSDistance * 1_000_000).rounded())
        let hdrPenalty: Int64 = configuration.prefersHDR && !format.isVideoHDRSupported ? 2_000_000_000 : 0
        return resolutionDistance + fpsPenalty + hdrPenalty
    }

    private static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInTripleCamera,
                .builtInDualWideCamera,
                .builtInDualCamera,
                .builtInWideAngleCamera,
                .builtInUltraWideCamera,
                .builtInTelephotoCamera,
                .builtInTrueDepthCamera
            ],
            mediaType: .video,
            position: .unspecified
        ).devices
    }
}
