import Combine
import Foundation
import SwiftUI

/// UI-facing state for the Mac link.
///
/// Owns the engine and advertises the local GreyVision link.
/// polls stats on a timer. Same split as `CameraRuntime` and
/// `CameraMetalRenderer`: everything observable lives on the main actor,
/// everything per-frame lives off it.
@MainActor
final class GVBroadcastRuntime: ObservableObject {
    @Published private(set) var state: GVBroadcastLinkState = .idle
    @Published private(set) var stats = GVBroadcastStats.idle
    /// The service name the Mac sees while browsing.
    @AppStorage("gv.broadcast.name") var serviceName = "greyVISION"

    private let engine = GVBroadcastEngine()
    private var statsTimer: Timer?
    /// The pairing code this phone shows the user. The Mac apps derive the
    /// link's pre-shared key from whatever is typed into them, so this is the
    /// only thing standing between a live camera feed and anyone else on the
    /// network. See `GVBroadcastKeyMaterial`.
    private let pairing = GVBroadcastPairingStore()

    /// Translates desktop commands into composition changes and publishes the
    /// result back. Owned here because it has to outlive any one presentation
    /// of the workspace, which attaches its editor to it on appear.
    let control = GVBroadcastControlBridge()

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
                guard let self else { return }
                self.state = newState
                // A peer that just attached has never seen the catalogue or
                // the composition. Sent from here rather than from the engine
                // so it lands on the main actor, where the editor lives.
                switch newState {
                case .connected: self.control.peerAttached()
                default: self.control.peerDetached()
                }
            }
        }
        engine.onControlCommand = { [weak self] command in
            Task { @MainActor in
                _ = self?.control.handle(command)
            }
        }
        // The bridge encodes; the engine transports. Keeping the closure here
        // is what lets the bridge stay free of any link or queue knowledge.
        control.send = { [weak engine] kind, payload in
            engine?.sendControl(kind: kind, payload: payload)
        }
    }

    func configureProfile(frameRate: Int, requestedCodec: String) {
        engine.configureProfile(frameRate: frameRate, requestedCodec: requestedCodec)
    }

    func start() {
        guard !isArmed else { return }
        engine.start(serviceName: serviceName, pairingCode: pairing.code)
        startPolling()
    }

    /// The code to read off this phone and type into the Mac app.
    var pairingCode: String { pairing.code }

    /// Whether this phone has a code a Mac could already be holding.
    var hasPairingCode: Bool { pairing.hasStoredCode }

    /// Rolls the code. Anything paired with the old one stops connecting,
    /// which is what the user wants after a code has been seen by someone it
    /// should not have been.
    func regeneratePairingCode() {
        _ = pairing.regenerate()
        // A Mac already attached was authenticated under the old code, so it
        // has to re-handshake to stay attached.
        if isArmed {
            stop()
            start()
        }
    }

    func stop() {
        engine.stop()
        statsTimer?.invalidate()
        statsTimer = nil
        stats = .idle
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

    var statusLine: String {
        switch state {
        case .idle:
            "LINK OFFLINE"
        case .advertising:
            "LINK // WAITING FOR MAC \u{2014} AUTO-PAIR"
        case let .connected(peer):
            "LINK // \(peer.uppercased()) \(Int(stats.framesPerSecond))FPS \(Int(stats.kilobitsPerSecond))KBPS"
        case let .failed(reason):
            "LINK FAILED // \(reason.uppercased())"
        }
    }
}
