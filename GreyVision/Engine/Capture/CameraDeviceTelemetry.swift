import AVFoundation
import Foundation

/// Live exposure readout for the camera HUD.
///
/// Sampled on the capture output queue at a low rate; the HUD polls it from a
/// `TimelineView`, so no per-frame publishing crosses the main actor.
struct CameraDeviceTelemetry: Sendable, Equatable {
    var iso: Float = 0
    /// Shutter speed expressed as the denominator of `1/x`.
    var shutterDenominator: Int = 0
    var whiteBalanceKelvin: Int = 0
    var lensPosition: Float = 0
    var isValid = false

    static let unavailable = CameraDeviceTelemetry()

    var isoLabel: String {
        isValid ? "ISO \(Int(iso.rounded()))" : "ISO ----"
    }

    var shutterLabel: String {
        isValid && shutterDenominator > 0 ? "1/\(shutterDenominator)" : "1/---"
    }

    var whiteBalanceLabel: String {
        isValid && whiteBalanceKelvin > 0 ? "WB \(whiteBalanceKelvin)K" : "WB ----K"
    }
}

final class CameraDeviceTelemetryMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = CameraDeviceTelemetry.unavailable

    var latest: CameraDeviceTelemetry {
        lock.withLock { value }
    }

    func publish(_ telemetry: CameraDeviceTelemetry) {
        lock.withLock { value = telemetry }
    }

    func clear() {
        lock.withLock { value = .unavailable }
    }
}
