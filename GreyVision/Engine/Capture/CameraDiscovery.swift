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

    /// An opaque stand-in for a discovered device: just enough identity for
    /// selection, none of the hardware. Exists so the priority rules below
    /// are a pure function and unit-testable without an AVCaptureDevice.
    struct DeviceCandidate: Equatable {
        let uniqueID: String
        let deviceTypeRawValue: String
    }

    /// Pure selection over candidates. The default is the dual camera, not
    /// the bare wide: a Pro-class iPhone ships with a fused wide+tele as its
    /// default stills/recording device, and the wide-only fallback is used
    /// only when no dual device is present. Selection never crosses position
    /// — candidates are expected to be pre-filtered to one position.
    static func selectCandidate(
        from candidates: [DeviceCandidate],
        position: CapturePosition,
        preferredDeviceID: String?
    ) -> DeviceCandidate? {
        // GreyVision deliberately captures through the primary rear camera;
        // alternate virtual-camera paths never enter this instrument.
        //
        // Order is significant. The first match wins:
        //   1. The plain wide — a physical sensor with a stable format set.
        //      Virtual devices fuse constituents and can switch lenses
        //      mid-take, which is the opposite of what OPEN GATE and
        //      ProRes RAW capture require (see device(_:capabilities:)).
        //   2. The dual camera (wide+tele fused) where no plain wide exists.
        //   3. The dual wide (wide+ultrawide fused) as a last resort.
        //   4. The front TrueDepth, then the front wide, on the front side.
        let priority: [String] = position == .rear
            ? [
                AVCaptureDevice.DeviceType.builtInWideAngleCamera.rawValue,
                AVCaptureDevice.DeviceType.builtInDualCamera.rawValue,
                AVCaptureDevice.DeviceType.builtInDualWideCamera.rawValue
            ]
            : [
                AVCaptureDevice.DeviceType.builtInTrueDepthCamera.rawValue,
                AVCaptureDevice.DeviceType.builtInWideAngleCamera.rawValue
            ]
        let supportedCandidates = candidates.filter { candidate in
            priority.contains(candidate.deviceTypeRawValue)
        }
        if let preferredID = preferredDeviceID,
           let preferred = supportedCandidates.first(where: { $0.uniqueID == preferredID })
        {
            return preferred
        }
        for type in priority {
            if let match = supportedCandidates.first(where: { $0.deviceTypeRawValue == type }) {
                return match
            }
        }
        return nil
    }

    static func device(
        configuration: CaptureConfiguration,
        capabilities: CameraCapabilities
    ) throws -> AVCaptureDevice {
        let available = devices().filter { $0.position == configuration.position.avPosition }
        // Full-sensor and RAW capture must bind to a physical sensor. A virtual
        // dual camera may switch constituents and advertises a fused/cropped
        // format set, which is the opposite of OPEN GATE and invalid for Bayer
        // ProRes RAW metadata.
        if configuration.position == .rear,
           configuration.resolution == .openGate || configuration.videoCodec.isProResRAW,
           let physicalWide = available.first(where: { $0.deviceType == .builtInWideAngleCamera })
        {
            return physicalWide
        }
        let chosen = selectCandidate(
            from: available.map {
                DeviceCandidate(uniqueID: $0.uniqueID, deviceTypeRawValue: $0.deviceType.rawValue)
            },
            position: configuration.position,
            preferredDeviceID: configuration.preferredDeviceID
        )
        if let chosen,
           let match = available.first(where: { $0.uniqueID == chosen.uniqueID })
        {
            return match
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

        let compatibleFormats: [AVCaptureDevice.Format]
        if configuration.videoCodec.isProResRAW {
            let requiredSubtype: FourCharCode = configuration.videoCodec == .proResRAWHQ
                ? kCMVideoCodecType_AppleProResRAWHQ
                : kCMVideoCodecType_AppleProResRAW
            compatibleFormats = device.formats.filter {
                CMFormatDescriptionGetMediaSubType($0.formatDescription) == requiredSubtype
            }
            guard !compatibleFormats.isEmpty else {
                throw GVError.capabilityUnavailable(
                    feature: configuration.videoCodec.rawValue,
                    reason: "The physical camera exposes no matching ProRes RAW sensor format."
                )
            }
        } else {
            compatibleFormats = device.formats.filter {
                let subtype = CMFormatDescriptionGetMediaSubType($0.formatDescription)
                return subtype != kCMVideoCodecType_AppleProResRAW &&
                    subtype != kCMVideoCodecType_AppleProResRAWHQ
            }
            guard !compatibleFormats.isEmpty else {
                throw GVError.capabilityUnavailable(
                    feature: "Camera format",
                    reason: "The selected camera exposes no processed video formats."
                )
            }
        }

        if configuration.resolution == .openGate {
            return try openGateFormat(formats: compatibleFormats, configuration: configuration)
        }

        let eligibleFormats = compatibleFormats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width >= configuration.dimensions.width &&
                dimensions.height >= configuration.dimensions.height
        }
        let candidates = eligibleFormats.isEmpty ? compatibleFormats : eligibleFormats

        let targetPixels = Int64(configuration.dimensions.width) * Int64(configuration.dimensions.height)
        return candidates.min { lhs, rhs in
            formatScore(lhs, targetPixels: targetPixels, configuration: configuration) <
                formatScore(rhs, targetPixels: targetPixels, configuration: configuration)
        } ?? device.activeFormat
    }

    /// An opaque stand-in for one of a device's formats: dimensions, cadence
    /// and HDR, none of the hardware. Exists for the same reason
    /// `DeviceCandidate` does — so the OPEN GATE rules below are a pure
    /// function that can be tested without an AVCaptureDevice.
    struct FormatCandidate: Equatable {
        let width: Int32
        let height: Int32
        let frameRateRanges: [ClosedRange<Double>]
        let supportsHDR: Bool

        var pixels: Int64 {
            Int64(width) * Int64(height)
        }

        var aspect: Double {
            Double(width) / Double(max(height, 1))
        }

        var maximumFrameRate: Double {
            frameRateRanges.map(\.upperBound).max() ?? 0
        }

        func supports(frameRate: Double) -> Bool {
            frameRateRanges.contains { $0.contains(frameRate) }
        }
    }

    /// Pure OPEN GATE selection over candidates, returning an index.
    ///
    /// OPEN GATE means the full 4:3 sensor readout *at video rates* — on
    /// iPhone that is the 4032x3024 video format, and `targetPixels` is what
    /// says so.
    ///
    /// The pixel ceiling is the point of this function. A Pro-class rear
    /// camera also reports 4:3 *stills* formats, up to 8064x6048, and those
    /// are not video formats in any sense this app can use: the data output
    /// hands back ~73MB buffers, and the effect chain's full-resolution hold
    /// during a take asks for four rgba16Float textures of ~390MB each. That
    /// is roughly 1.5GB of GPU allocation for one frame, and the app is
    /// jetsammed before it reaches the screen. Selecting on "largest 4:3
    /// wins" is what made OPEN GATE unshippable.
    ///
    /// Every fallback here narrows or holds; none of them widen past the
    /// ceiling. That is the other half of the old bug — the frame-rate filter
    /// discarded itself whenever nothing matched, which at the default 60fps
    /// is always, and handed the stills format straight back.
    static func selectOpenGateFormat(
        from candidates: [FormatCandidate],
        targetPixels: Int64,
        requestedFrameRate: Double,
        prefersHDR: Bool
    ) -> Int? {
        guard targetPixels > 0, targetPixels <= Int64.max / 9,
              requestedFrameRate.isFinite, requestedFrameRate > 0 else { return nil }
        // No fallback may escape the sensor-area or video-cadence limits.
        let withinCeiling = candidates.indices.filter {
            let candidate = candidates[$0]
            return candidate.width > 0 && candidate.height > 0 &&
                abs(candidate.aspect - (4.0 / 3.0)) < 0.08 &&
                candidate.pixels >= targetPixels * 9 / 10 &&
                candidate.pixels <= targetPixels * 3 / 2 &&
                candidate.frameRateRanges.contains {
                    $0.lowerBound.isFinite && $0.upperBound.isFinite &&
                        $0.lowerBound > 0 && $0.upperBound >= 24
                }
        }

        let atRequestedRate = withinCeiling.filter {
            candidates[$0].supports(frameRate: requestedFrameRate)
        }
        let pool = atRequestedRate.isEmpty ? withinCeiling : atRequestedRate

        return pool.max { lhs, rhs in
            isOpenGateFormat(candidates[lhs], worseThan: candidates[rhs], prefersHDR: prefersHDR)
        }
    }

    /// Ranking within the eligible pool: sensor area first, then HDR when it
    /// was asked for, then cadence headroom.
    private static func isOpenGateFormat(
        _ lhs: FormatCandidate,
        worseThan rhs: FormatCandidate,
        prefersHDR: Bool
    ) -> Bool {
        if lhs.pixels != rhs.pixels {
            return lhs.pixels < rhs.pixels
        }
        if prefersHDR, lhs.supportsHDR != rhs.supportsHDR {
            return !lhs.supportsHDR
        }
        return lhs.maximumFrameRate < rhs.maximumFrameRate
    }

    private static func openGateFormat(
        formats: [AVCaptureDevice.Format],
        configuration: CaptureConfiguration
    ) throws -> AVCaptureDevice.Format {
        let candidates = formats.map(FormatCandidate.init(format:))
        let targetPixels = Int64(configuration.dimensions.width) * Int64(configuration.dimensions.height)
        guard let index = selectOpenGateFormat(
            from: candidates,
            targetPixels: targetPixels,
            requestedFrameRate: Double(configuration.framesPerSecond),
            prefersHDR: configuration.prefersHDR
        ) else {
            throw GVError.capabilityUnavailable(
                feature: "OPEN GATE",
                reason: "The selected physical sensor exposes no video-rate formats."
            )
        }
        let selected = candidates[index]
        guard abs(selected.aspect - (4.0 / 3.0)) < 0.08,
              selected.pixels >= targetPixels * 9 / 10
        else {
            throw GVError.capabilityUnavailable(
                feature: "OPEN GATE",
                reason: "A full 4:3 sensor readout is unavailable for this codec and camera."
            )
        }
        return formats[index]
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
                .builtInDualCamera,
                .builtInDualWideCamera,
                .builtInWideAngleCamera,
                .builtInTrueDepthCamera
            ],
            mediaType: .video,
            position: .unspecified
        ).devices
    }
}

extension CameraDiscovery.FormatCandidate {
    init(format: AVCaptureDevice.Format) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        self.init(
            width: dimensions.width,
            height: dimensions.height,
            frameRateRanges: format.videoSupportedFrameRateRanges.map { range in
                range.minFrameRate ... max(range.minFrameRate, range.maxFrameRate)
            },
            supportsHDR: format.isVideoHDRSupported
        )
    }
}
