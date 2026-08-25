import AVFoundation
import Foundation
import Metal
import UIKit

struct BootTelemetry: Sendable, Equatable {
    let operatingSystem: String
    let deviceModel: String
    let metalDevice: String
    let discoveredCameras: Int
    let processorCount: Int
    let thermalState: String
    let lowPowerMode: Bool
    let depthSensor: String
    let audioDSP: String
    let frameHeapMegabytes: Int

    var terminalLines: [String] {
        [
            "OS.VERSION ...... \(operatingSystem)",
            "DEVICE.CLASS .... \(deviceModel)",
            "METAL.DEVICE .... \(metalDevice)",
            "CAMERA.NODES .... \(String(format: "%02d", discoveredCameras))",
            "DEPTH.SENSOR .... \(depthSensor)",
            "AUDIO.DSP ....... \(audioDSP)",
            "FRAME.HEAP ...... \(frameHeapMegabytes) MB",
            "CPU.LOGICAL ..... \(processorCount)",
            "THERMAL.STATE ... \(thermalState)",
            "LOW.POWER ....... \(lowPowerMode ? "ON" : "OFF")"
        ]
    }

    @MainActor
    static func collect() -> BootTelemetry {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInUltraWideCamera,
                .builtInTelephotoCamera,
                .builtInTrueDepthCamera
            ],
            mediaType: .video,
            position: .unspecified
        )
        let processInfo = ProcessInfo.processInfo
        let device = MTLCreateSystemDefaultDevice()
        let workingSet = device.map { Int($0.recommendedMaxWorkingSetSize / (1024 * 1024)) } ?? 0

        return BootTelemetry(
            operatingSystem: UIDevice.current.systemVersion,
            deviceModel: UIDevice.current.localizedModel.uppercased(),
            metalDevice: device?.name.uppercased() ?? "UNAVAILABLE",
            discoveredCameras: discovery.devices.count,
            processorCount: processInfo.activeProcessorCount,
            thermalState: processInfo.thermalState.gvLabel,
            lowPowerMode: processInfo.isLowPowerModeEnabled,
            depthSensor: DepthCapability.discover().isSupported ? "ONLINE" : "ABSENT",
            audioDSP: AVAudioApplication.shared.recordPermission.gvLabel,
            frameHeapMegabytes: workingSet
        )
    }
}

private extension AVAudioApplication.recordPermission {
    var gvLabel: String {
        switch self {
        case .granted:
            "ARMED"
        case .denied:
            "DENIED"
        case .undetermined:
            "STANDBY"
        @unknown default:
            "UNKNOWN"
        }
    }
}

private extension ProcessInfo.ThermalState {
    var gvLabel: String {
        switch self {
        case .nominal:
            "NOMINAL"
        case .fair:
            "FAIR"
        case .serious:
            "SERIOUS"
        case .critical:
            "CRITICAL"
        @unknown default:
            "UNKNOWN"
        }
    }
}
