@preconcurrency import Foundation
import Metal
import UIKit

struct RenderTelemetrySnapshot: Equatable, Sendable {
    var frameIndex: UInt64 = 0
    var framesPerSecond: Double = 0
    var cpuFrameMilliseconds: Double = 0
    var gpuFrameMilliseconds: Double = 0
    var droppedOrSkippedFrames: UInt64 = 0
    var renderDimensions = RenderDimensions(width: 0, height: 0)
    var textureMemoryBytes: Int = 0
    var passMeasurements: [RenderPassMeasurement] = []
    var thermalState: ProcessInfo.ThermalState = .nominal
    var memoryWarningCount: UInt64 = 0
}

final class RenderTelemetry: @unchecked Sendable {
    private let lock = NSLock()
    private var value = RenderTelemetrySnapshot()
    private var lastFrameTime: TimeInterval?
    private var expectedFrameIndex: UInt64?

    var latest: RenderTelemetrySnapshot { lock.withLock { value } }

    func beginFrame(index: UInt64, dimensions: RenderDimensions) -> TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            if let expectedFrameIndex, index > expectedFrameIndex {
                value.droppedOrSkippedFrames &+= index - expectedFrameIndex
            }
            expectedFrameIndex = index &+ 1
            value.frameIndex = index
            value.renderDimensions = dimensions
            if let lastFrameTime {
                let interval = max(now - lastFrameTime, 0.000_001)
                let instantaneous = 1 / interval
                value.framesPerSecond = value.framesPerSecond == 0
                    ? instantaneous
                    : value.framesPerSecond * 0.9 + instantaneous * 0.1
            }
            lastFrameTime = now
        }
        return now
    }

    func finishEncoding(
        startedAt: TimeInterval,
        passes: [RenderPassMeasurement],
        textureMemoryBytes: Int
    ) {
        let elapsed = max(ProcessInfo.processInfo.systemUptime - startedAt, 0) * 1000
        lock.withLock {
            value.cpuFrameMilliseconds = elapsed
            value.passMeasurements = passes
            value.textureMemoryBytes = textureMemoryBytes
        }
    }

    func attachGPUCompletion(to commandBuffer: MTLCommandBuffer) {
        commandBuffer.addCompletedHandler { [weak self] buffer in
            guard let self else { return }
            let milliseconds = max(buffer.gpuEndTime - buffer.gpuStartTime, 0) * 1000
            self.lock.withLock { self.value.gpuFrameMilliseconds = milliseconds }
        }
    }

    func updateSystemSignals(thermalState: ProcessInfo.ThermalState, memoryWarningCount: UInt64) {
        lock.withLock {
            value.thermalState = thermalState
            value.memoryWarningCount = memoryWarningCount
        }
    }
}

struct EngineResourceSignalSnapshot: Equatable, Sendable {
    var thermalState: ProcessInfo.ThermalState
    var memoryWarningCount: UInt64
}

@MainActor
final class EngineResourceMonitor {
    private(set) var snapshot = EngineResourceSignalSnapshot(
        thermalState: ProcessInfo.processInfo.thermalState,
        memoryWarningCount: 0
    )
    var onChange: (@MainActor @Sendable (EngineResourceSignalSnapshot) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init(center: NotificationCenter = .default) {
        observers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshThermalState() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.receivedMemoryWarning() }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func refreshThermalState() {
        snapshot.thermalState = ProcessInfo.processInfo.thermalState
        onChange?(snapshot)
    }

    private func receivedMemoryWarning() {
        snapshot.memoryWarningCount &+= 1
        onChange?(snapshot)
    }
}

struct AdaptiveQualitySettings: Equatable, Sendable {
    var effectScale: Float = 1
    var analysisFrameInterval = 1
    var optionalPassesEnabled = true
}

protocol AdaptiveQualityProviding: AnyObject {
    var settings: AdaptiveQualitySettings { get set }
    func evaluate(_ telemetry: RenderTelemetrySnapshot)
}
