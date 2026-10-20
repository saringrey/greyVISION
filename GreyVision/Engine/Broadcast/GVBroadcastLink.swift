import CryptoKit
import Foundation
import Network

enum GVBroadcastLinkState: Equatable, Sendable {
    case idle
    /// Advertising over Bonjour, nobody attached yet.
    case advertising
    case connected(peer: String)
    case failed(reason: String)
}

/// The phone's side of the link: a Bonjour-advertised, TLS-protected listener
/// that accepts one Mac at a time and streams framed messages to it.
///
/// ## Why TLS with a pairing code
///
/// This publishes a live camera feed onto whatever network the phone is on —
/// a studio, an office, a café. Unencrypted that is a camera anyone on the
/// subnet can watch, and Bonjour tells them it is there.
///
/// The pairing code shown on the phone is mixed into a pre-shared key, so a
/// peer that cannot produce the same code fails the TLS handshake and never
/// sees a frame. The code reaches the Mac out of band — the user reads it off
/// this phone and types it in — so it is never carried by the link it
/// protects. There is no automatic fallback: with no code, the listener does
/// not start at all.
///
/// The derivation itself is in `GVBroadcastKeyMaterial.swift`, which the Mac
/// app and the camera extension compile too. It used to be duplicated here and
/// in both of those, and the copies disagreed.
///
/// ## One peer
///
/// A second connection replaces the first rather than joining it. Fanning out
/// would mean encoding once and writing N times with N different congestion
/// states, and the frame-dropping policy below only makes sense against a
/// single backlog.
final class GVBroadcastLink: @unchecked Sendable {
    /// Bytes allowed in flight before video frames start being dropped.
    ///
    /// Live video must never queue: a backlog is latency that never comes
    /// back, and the newest frame is always worth more than the oldest one
    /// still waiting. Roughly a quarter second of headroom at 8 Mbps.
    private static let sendBacklogLimit = 256 * 1024

    /// Seconds of silence before the first TCP keepalive probe goes out.
    /// Re-exported from the shared key material so callers that only import
    /// this file keep working.
    static var keepaliveIdleSeconds: Int { GVBroadcastKeyMaterial.keepaliveIdleSeconds }
    /// Spacing between probes once a probe has been sent.
    static var keepaliveIntervalSeconds: Int { GVBroadcastKeyMaterial.keepaliveIntervalSeconds }

    private let queue = DispatchQueue(label: "greyVISION.broadcast.link")
    private let lock = NSLock()

    private var listener: NWListener?
    private var connection: NWConnection?
    private var pendingBytes = 0
    private var droppedFrames = 0
    private var state: GVBroadcastLinkState = .idle

    var onStateChange: (@Sendable (GVBroadcastLinkState) -> Void)?
    var onCommand: (@Sendable (GVBroadcastCommand) -> Void)?

    var isConnected: Bool {
        lock.withLock { if case .connected = state { return true } else { return false } }
    }

    var droppedFrameCount: Int {
        lock.withLock { droppedFrames }
    }

    // MARK: - Lifecycle

    /// Starts advertising to Macs that already hold the pairing code.
    ///
    /// A malformed code is refused here rather than being papered over with a
    /// fallback key: a listener that came up under any other key would accept a
    /// connection it should have rejected.
    func start(serviceName: String, pairingCode: String) {
        stop()
        guard let secret = GVBroadcastKeyMaterial.secret(forCode: pairingCode) else {
            publish(.failed(reason: "PAIRING CODE REJECTED"))
            return
        }
        do {
            let parameters = GVBroadcastKeyMaterial.listenerParameters(secret: secret)
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: serviceName, type: GVBroadcastProtocol.serviceType)

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.publish(.advertising)
                case let .failed(error):
                    self.publish(.failed(reason: error.localizedDescription))
                    self.stop()
                case .cancelled:
                    self.publish(.idle)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.adopt(connection)
            }

            lock.withLock { self.listener = listener }
            listener.start(queue: queue)
        } catch {
            publish(.failed(reason: error.localizedDescription))
        }
    }

    func stop() {
        let (listener, connection) = lock.withLock { () -> (NWListener?, NWConnection?) in
            let pair = (self.listener, self.connection)
            self.listener = nil
            self.connection = nil
            self.pendingBytes = 0
            return pair
        }
        connection?.cancel()
        listener?.cancel()
        publish(.idle)
    }

    // MARK: - Sending

    /// Queues one message.
    ///
    /// Video frames are dropped when the socket is already behind; everything
    /// else — format, hello, commands — is always sent, because those are
    /// small, rare, and the stream is undecodable without them.
    func send(
        kind: GVBroadcastProtocol.MessageKind,
        payload: Data,
        isKeyframe: Bool = false,
        timestampNanoseconds: Int64 = 0
    ) {
        let connection: NWConnection? = lock.withLock {
            guard let connection = self.connection else { return nil }
            if kind == .videoFrame, pendingBytes > Self.sendBacklogLimit {
                droppedFrames += 1
                return nil
            }
            pendingBytes += payload.count
            return connection
        }
        guard let connection else { return }

        let header = GVBroadcastProtocol.Header(
            kind: kind,
            isKeyframe: isKeyframe,
            payloadLength: payload.count,
            timestampNanoseconds: timestampNanoseconds
        )
        // One send, not two: a header and its payload written separately can
        // interleave with another send on the same connection and corrupt the
        // stream.
        var message = header.encoded
        message.append(payload)

        connection.send(
            content: message,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.lock.withLock { self.pendingBytes = max(0, self.pendingBytes - payload.count) }
                if let error {
                    GVLog.recording.error("Broadcast send failed: \(error.localizedDescription)")
                    self.dropConnection()
                }
            }
        )
    }

    // MARK: - Connection handling

    private func adopt(_ incoming: NWConnection) {
        let previous = lock.withLock { () -> NWConnection? in
            let old = connection
            connection = incoming
            pendingBytes = 0
            return old
        }
        previous?.cancel()

        incoming.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.publish(.connected(peer: Self.describe(incoming.endpoint)))
                self.receiveHeader(on: incoming)
            case let .failed(error):
                GVLog.recording.error("Broadcast connection failed: \(error.localizedDescription)")
                self.dropConnection()
            case .cancelled:
                self.dropConnection()
            default:
                break
            }
        }
        incoming.start(queue: queue)
    }

    private func dropConnection() {
        let connection = lock.withLock { () -> NWConnection? in
            let existing = self.connection
            self.connection = nil
            self.pendingBytes = 0
            return existing
        }
        connection?.cancel()
        // Only fall back to advertising if the listener is still up; a stop()
        // that cancelled everything must stay idle.
        let advertising = lock.withLock { listener != nil }
        publish(advertising ? .advertising : .idle)
    }

    /// Reads exactly one header, then its payload. Exact-length reads mean the
    /// parser never has to buffer a partial message or scan for a delimiter.
    private func receiveHeader(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: GVBroadcastProtocol.headerLength,
            maximumLength: GVBroadcastProtocol.headerLength
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil || isComplete {
                self.dropConnection()
                return
            }
            guard let data, let header = GVBroadcastProtocol.Header.decode(data) else {
                // Unparseable: the stream is not one we can follow and there
                // is no delimiter to resynchronise on.
                GVLog.recording.error("Broadcast received a malformed header; dropping peer")
                self.dropConnection()
                return
            }
            guard header.payloadLength > 0 else {
                self.receiveHeader(on: connection)
                return
            }
            self.receivePayload(on: connection, header: header)
        }
    }

    private func receivePayload(on connection: NWConnection, header: GVBroadcastProtocol.Header) {
        connection.receive(
            minimumIncompleteLength: header.payloadLength,
            maximumLength: header.payloadLength
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil || isComplete {
                self.dropConnection()
                return
            }
            if let data {
                self.handle(header: header, payload: data)
            }
            self.receiveHeader(on: connection)
        }
    }

    private func handle(header: GVBroadcastProtocol.Header, payload: Data) {
        switch header.kind {
        case .none:
            // A newer peer's message type. The payload has already been read,
            // so the stream stays framed; dropping the connection here would
            // make every future addition a breaking change.
            break
        case .command:
            guard let command = try? JSONDecoder().decode(GVBroadcastCommand.self, from: payload) else {
                GVLog.recording.error("Broadcast received an undecodable command")
                return
            }
            // Copy under lock, invoke after release: a command handler that
            // re-enters link state (stop/send) must never run while the lock
            // is held, or the network path can deadlock.
            let handler = lock.withLock { onCommand }
            handler?(command)
        case .keepalive:
            break
        case .hello, .videoFormat, .videoFrame, .controlSurface, .controlState:
            // Phone-to-Mac messages. Receiving one back means the peer is not
            // speaking this protocol; ignoring is enough, the handshake
            // version check is what actually gates compatibility.
            break
        }
    }

    // MARK: - Parameters
    //
    // `makeParameters` used to live here. It is now `GVBroadcastKeyMaterial`,
    // shared with the Mac app and the camera extension — see that file for why
    // duplicating it was a security bug rather than only a maintenance cost.

    private static func describe(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case let .hostPort(host, _): String(describing: host)
        case let .service(name, _, _, _): name
        default: String(describing: endpoint)
        }
    }

    private func publish(_ newState: GVBroadcastLinkState) {
        let handler = lock.withLock { () -> (@Sendable (GVBroadcastLinkState) -> Void)? in
            guard state != newState else { return nil }
            state = newState
            return onStateChange
        }
        handler?(newState)
    }
}
