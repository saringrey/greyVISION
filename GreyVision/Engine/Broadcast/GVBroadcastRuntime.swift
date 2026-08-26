import Combine
import Foundation
import SwiftUI

/// UI-facing state for the Mac link.
///
/// Owns the engine, holds the passcode the operator reads off the screen, and
/// polls stats on a timer. Same split as `CameraRuntime` and
/// `CameraMetalRenderer`: everything observable lives on the main actor,
/// everything per-frame lives off it.
@MainActor
final class GVBroadcastRuntime: ObservableObject {
    @Published private(set) var state: GVBroadcastLinkState = .idle
    @Published private(set) var stats = GVBroadcastStats.idle
    /// Regenerated per session. Shown on the phone, typed on the Mac.
    @Published private(set) var passcode = ""

    /// The service name the Mac sees while browsing.
    @AppStorage("gv.broadcast.name") var serviceName = "greyVISION"

    private let engine = GVBroadcastEngine()
    private var statsTimer: Timer?

    var isArmed: Bool {
        if case .idle = state { return false }
        return true
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// Handed to the renderer so the render thread can submit frames without
    /// touching this object.
    var frameSink: GVBroadcastEngine { engine }

    init() {
        engine.onStateChange = { [weak self] newState in
            Task { @MainActor in
                self?.state = newState
            }
        }
    }

    func start() {
        guard !isArmed else { return }
        passcode = Self.makePasscode()
        engine.start(serviceName: serviceName, passcode: passcode)
        startPolling()
    }

    func stop() {
        engine.stop()
        statsTimer?.invalidate()
        statsTimer = nil
        stats = .idle
        passcode = ""
    }

    private func startPolling() {
        statsTimer?.invalidate()
        // Twice a second. The numbers are a one-second rolling window, so
        // polling faster only redraws the same value.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.stats = self.engine.stats
            }
        }
        statsTimer = timer
    }

    /// Six digits, from the system CSPRNG.
    ///
    /// Short because a person types it, and single-use because it only has to
    /// survive one handshake. It is stretched through HKDF before it reaches
    /// TLS — see `GVBroadcastLink.makeParameters`.
    private static func makePasscode() -> String {
        String(format: "%06d", Int.random(in: 0 ..< 1_000_000))
    }

    var statusLine: String {
        switch state {
        case .idle:
            "LINK OFFLINE"
        case .advertising:
            "LINK // WAITING FOR MAC \u{2014} CODE \(passcode)"
        case let .connected(peer):
            "LINK // \(peer.uppercased()) \(Int(stats.framesPerSecond))FPS \(Int(stats.kilobitsPerSecond))KBPS"
        case let .failed(reason):
            "LINK FAILED // \(reason.uppercased())"
        }
    }
}
