import Combine
import Foundation
import UIKit

@MainActor
final class DepthRuntime: ObservableObject {
    @Published private(set) var snapshot = DepthRuntimeSnapshot.idle
    @Published private(set) var effect = DepthEffectMode.pointCloud
    @Published var parameters = DepthEffectParameters.defaults

    let capability: DepthCapability
    let mailbox: LatestDepthFrameMailbox

    private var modeParameters: [DepthEffectMode: DepthEffectParameters] = [:]

    private let source: ARDepthFrameSource

    init(capability: DepthCapability = .discover()) {
        self.capability = capability
        let mailbox = LatestDepthFrameMailbox()
        self.mailbox = mailbox
        source = ARDepthFrameSource(mailbox: mailbox)
        source.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.consume(event)
            }
        }
    }

    var isActive: Bool {
        switch snapshot.state {
        case .starting, .running, .interrupted:
            true
        case .idle, .unsupported, .failed:
            false
        }
    }

    func setEffect(_ effect: DepthEffectMode) {
        guard effect != self.effect else { return }
        modeParameters[self.effect] = parameters.sanitized
        self.effect = effect
        parameters = modeParameters[effect] ?? .defaults(for: effect)
    }

    func start(effect: DepthEffectMode) async -> Bool {
        setEffect(effect)
        guard capability.isSupported else {
            snapshot = DepthRuntimeSnapshot(
                state: .unsupported,
                sourceLabel: "LIDAR UNAVAILABLE",
                formatLabel: capability.reason,
                frameCount: 0,
                timestamp: nil,
                usesSmoothedDepth: false,
                hasConfidence: false,
                errorMessage: capability.reason
            )
            return false
        }

        refreshOrientation()
        snapshot = DepthRuntimeSnapshot(
            state: .starting,
            sourceLabel: "LIDAR STARTING",
            formatLabel: capability.reason,
            frameCount: 0,
            timestamp: nil,
            usesSmoothedDepth: capability.supportsSmoothedDepth,
            hasConfidence: false,
            errorMessage: nil
        )

        do {
            let usesSmoothed = try await source.start(capability: capability)
            snapshot.usesSmoothedDepth = usesSmoothed
        } catch {
            snapshot.state = .failed
            snapshot.sourceLabel = "LIDAR FAILURE"
            snapshot.errorMessage = error.localizedDescription
            return false
        }

        for _ in 0 ..< 40 {
            guard !Task.isCancelled else {
                await source.stop()
                snapshot = .idle
                return false
            }
            if snapshot.state == .running {
                return true
            }
            if snapshot.state == .failed {
                await source.stop()
                return false
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        await source.stop()
        snapshot.state = .failed
        snapshot.sourceLabel = "LIDAR TIMEOUT"
        snapshot.errorMessage = "ARKit did not deliver a scene-depth frame within four seconds."
        return false
    }

    func stop() async {
        await source.stop()
        snapshot = .idle
    }

    func stopSoon() {
        source.stopSoon()
        snapshot = .idle
    }

    func refreshOrientation(_ requestedOrientation: UIInterfaceOrientation? = nil) {
        let interfaceOrientation = requestedOrientation ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .interfaceOrientation ?? .portrait
        let orientation: CapturedFrameOrientation? = switch interfaceOrientation {
        case .portrait:
            .portrait
        case .portraitUpsideDown:
            .portraitUpsideDown
        case .landscapeLeft:
            .landscapeLeft
        case .landscapeRight:
            .landscapeRight
        default:
            nil
        }
        guard let orientation else { return }
        source.updateOrientation(orientation)
    }

    private func consume(_ event: ARDepthSourceEvent) {
        switch event {
        case let .frame(metadata):
            snapshot.state = .running
            snapshot.sourceLabel = metadata.usesSmoothedDepth ? "LIDAR SMOOTHED" : "LIDAR SCENE DEPTH"
            snapshot.formatLabel = "\(metadata.width)×\(metadata.height) DEPTH"
            snapshot.frameCount = metadata.sequence
            snapshot.timestamp = metadata.timestamp
            snapshot.usesSmoothedDepth = metadata.usesSmoothedDepth
            snapshot.hasConfidence = metadata.hasConfidence
            snapshot.errorMessage = nil
        case let .interrupted(reason):
            snapshot.state = .interrupted
            snapshot.errorMessage = reason
        case .resumed:
            snapshot.state = .starting
            snapshot.errorMessage = nil
        case let .failed(message):
            snapshot.state = .failed
            snapshot.sourceLabel = "LIDAR FAILURE"
            snapshot.errorMessage = message
        }
    }
}
