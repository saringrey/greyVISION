import Foundation

/// Wire format for the greyVISION link.
///
/// This file is the contract between the phone and the Mac helper that
/// publishes the virtual camera. It is deliberately free of AVFoundation,
/// VideoToolbox, Network and UIKit imports so it can be copied verbatim into
/// the macOS target rather than reimplemented there — two hand-written parsers
/// for one format is how a protocol drifts.
///
/// ## Why a custom protocol at all
///
/// Continuity Camera only flows iOS → Mac as a *system* service; there is no
/// API for a third-party app to publish frames into it. So the transport is
/// ours: framed messages over TLS-PSK TCP, discovered by Bonjour.
///
/// ## Framing
///
/// Every message is a fixed 20-byte header followed by `payloadLength` bytes.
/// All integers are big-endian. A reader that has 20 bytes always knows
/// exactly how many more to wait for, which is the only property a stream
/// parser actually needs.
///
///     0       4     5     6        8                12                    20
///     +-------+-----+-----+--------+-----------------+---------------------+
///     | magic |kind |flags|reserved|  payloadLength  |  timestamp (ns)     |
///     +-------+-----+-----+--------+-----------------+---------------------+
enum GVBroadcastProtocol {
    /// Bonjour service type. Registered under the `_tcp` domain; the Mac
    /// browses for exactly this.
    static let serviceType = "_greyvision._tcp"
    /// Automatic pairing for the single-user local-network workflow.
    /// Bonjour remains the trust boundary when no code is entered.
    static let automaticPairingSecret = "greyVISION.local.v1"

    /// "GVX1". Bumped only on an incompatible framing change — payload
    /// additions are handled by `version` in the hello message instead.
    static let magic: UInt32 = 0x4756_5831

    static let headerLength = 20

    /// Refuses absurd payloads before allocating for them. A 4K HEVC keyframe
    /// at a sane bitrate is well under a megabyte; 8 MB is generous headroom
    /// and still small enough that a corrupt length cannot exhaust memory.
    static let maximumPayloadLength = 8 * 1024 * 1024

    /// Incremented when payload shapes change in a way an older peer cannot
    /// read. Exchanged in `Hello` so a mismatch is a clean refusal rather than
    /// a stream of unparseable frames.
    static let version = 1

    enum MessageKind: UInt8 {
        /// Sent once by each side immediately after connecting.
        case hello = 1
        /// Codec parameter sets. Always precedes the first frame, and is
        /// resent whenever the encoder's format description changes.
        case videoFormat = 2
        /// One encoded access unit, in length-prefixed NAL form exactly as
        /// VideoToolbox emits it.
        case videoFrame = 3
        /// Mac → phone. See `GVBroadcastCommand`.
        case command = 4
        /// Either direction. Keeps NAT/idle timers alive and measures RTT.
        case keepalive = 5
        /// Phone -> Mac. The catalogue of everything the desktop is allowed
        /// to drive: effect identities, their human labels, their parameter
        /// names and defaults, and the families they group into. Sent once
        /// per connection because it is large and does not change while the
        /// app is running.
        case controlSurface = 6
        /// Phone -> Mac. The live composition: which slots exist, in render
        /// order, with their parameters. Sent on every committed change, so
        /// the desktop mirrors the phone rather than guessing what its own
        /// commands did.
        case controlState = 7
    }

    struct Header: Equatable, Sendable {
        /// Nil when the peer sent a kind this build has no case for.
        ///
        /// An unrecognised kind is not a broken stream. The header still
        /// carries a payload length, so the only correct response is to skip
        /// that many bytes and keep reading — which is what lets a peer add a
        /// message type without breaking every older build.
        ///
        /// This was learned the hard way: adding `controlSurface`/`controlState`
        /// for desktop effect control made an already-deployed Mac build drop
        /// the connection on the first control message, because its enum had
        /// no case 6 and `decode` reported that as an unfollowable stream.
        var kind: MessageKind?
        /// Set on sync samples. The receiver cannot start decoding until one
        /// arrives, so it is worth a bit rather than a parse of the payload.
        var isKeyframe: Bool
        var payloadLength: Int
        /// Presentation time in nanoseconds since the broadcast began.
        var timestampNanoseconds: Int64

        /// True when this build cannot interpret the message. The payload
        /// must still be consumed so the stream stays framed.
        var isUnknownKind: Bool { kind == nil }

        init(kind: MessageKind?, isKeyframe: Bool = false, payloadLength: Int, timestampNanoseconds: Int64 = 0) {
            self.kind = kind
            self.isKeyframe = isKeyframe
            self.payloadLength = payloadLength
            self.timestampNanoseconds = timestampNanoseconds
        }

        var encoded: Data {
            var data = Data(capacity: GVBroadcastProtocol.headerLength)
            data.appendBigEndian(GVBroadcastProtocol.magic)
            // Only ever encoded for messages this build actually sends, so a
            // nil kind here would be a programming error rather than a peer's
            // doing. Zero is not a valid case, which makes it visible.
            data.append(kind?.rawValue ?? 0)
            data.append(isKeyframe ? 1 : 0)
            data.appendBigEndian(UInt16(0))
            data.appendBigEndian(UInt32(payloadLength))
            data.appendBigEndian(UInt64(bitPattern: timestampNanoseconds))
            return data
        }

        /// Parses a header from the first `headerLength` bytes.
        ///
        /// Returns nil only for a bad magic or an over-long payload. Those two
        /// mean the reader has lost its place in the byte stream, and the
        /// caller's only correct response is to drop the connection —
        /// resynchronising on a stream with no delimiters is guesswork.
        ///
        /// An *unknown kind* is deliberately not in that category. It means the
        /// peer speaks a newer vocabulary, which the framing was designed to
        /// survive: the length field says exactly how much to skip.
        static func decode(_ data: Data) -> Header? {
            guard data.count >= GVBroadcastProtocol.headerLength else { return nil }
            return data.withUnsafeBytes { raw -> Header? in
                guard raw.loadBigEndian(at: 0, as: UInt32.self) == GVBroadcastProtocol.magic else {
                    return nil
                }
                let length = Int(raw.loadBigEndian(at: 8, as: UInt32.self))
                guard length <= GVBroadcastProtocol.maximumPayloadLength else { return nil }
                return Header(
                    kind: MessageKind(rawValue: raw.load(fromByteOffset: 4, as: UInt8.self)),
                    isKeyframe: raw.load(fromByteOffset: 5, as: UInt8.self) != 0,
                    payloadLength: length,
                    timestampNanoseconds: Int64(bitPattern: raw.loadBigEndian(at: 12, as: UInt64.self))
                )
            }
        }
    }
}

// MARK: - Payloads

/// Identifies a peer and its stream. JSON rather than a packed struct: it is
/// sent once per connection, and being able to add a field without a version
/// bump is worth more than the bytes.
struct GVBroadcastHello: Codable, Equatable, Sendable {
    var version = GVBroadcastProtocol.version
    var deviceName: String
    var width: Int
    var height: Int
    /// FourCC of the codec in use, `hvc1` or `avc1`.
    var codec: String
    /// The camera profile selected on the iPhone before the live encoder's
    /// hardware negotiation. The receiver uses this for truthful UI reporting.
    var requestedCodec: String = "hevc"
    var frameRate: Int = 30
}

/// Codec configuration. The Mac rebuilds a `CMVideoFormatDescription` from
/// these before it can decode anything, which is why it is a separate message
/// rather than a field on each frame.
struct GVBroadcastVideoFormat: Codable, Equatable, Sendable {
    var codec: String
    /// VPS/SPS/PPS for HEVC, SPS/PPS for H.264, in the order the encoder
    /// reported them.
    var parameterSets: [Data]
    /// Length in bytes of the size prefix on each NAL unit in the frame
    /// payloads. Almost always 4, but the encoder is entitled to say
    /// otherwise and the decoder has to be told.
    var nalUnitHeaderLength: Int32
    var width: Int
    var height: Int
    /// The rate the encoder is actually producing. Absent from a build that
    /// predates it, which is why decoding is lenient about this one field:
    /// an older phone that omits it still has to be presented, and 30 is the
    /// rate it was sending anyway.
    var framesPerSecond: Int?

    enum CodingKeys: String, CodingKey {
        case codec
        case parameterSets
        case nalUnitHeaderLength
        case width
        case height
        case framesPerSecond
    }

    init(
        codec: String,
        parameterSets: [Data],
        nalUnitHeaderLength: Int32,
        width: Int,
        height: Int,
        framesPerSecond: Int? = nil
    ) {
        self.codec = codec
        self.parameterSets = parameterSets
        self.nalUnitHeaderLength = nalUnitHeaderLength
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codec = try container.decode(String.self, forKey: .codec)
        parameterSets = try container.decode([Data].self, forKey: .parameterSets)
        nalUnitHeaderLength = try container.decode(Int32.self, forKey: .nalUnitHeaderLength)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        framesPerSecond = try container.decodeIfPresent(Int.self, forKey: .framesPerSecond)
    }
}

/// Mac → phone control.
///
/// Addressing is deliberately loose on the Mac's side: effects travel as
/// their `rawValue` string and slots as their `UUID`. The desktop never
/// holds a copy of the effect enum — it learns the vocabulary from
/// `GVBroadcastControlSurface` at connect time, so adding an effect to the
/// phone needs no matching change here or on the Mac.
///
/// Every mutating case is a *delta*. The phone answers by publishing a fresh
/// `GVBroadcastControlState`; the Mac never assumes a command landed.
enum GVBroadcastCommand: Codable, Equatable, Sendable {
    /// The receiver has no decodable state — it joined late, or dropped a
    /// frame. Forces the next encode to be a sync sample.
    case requestKeyframe
    /// Retarget the encoder, in bits per second. The Mac knows what the link
    /// is sustaining; the phone does not.
    case setBitrate(Int)

    // MARK: Control surface

    /// Ask the phone to resend the catalogue and the current composition.
    /// Sent by the Mac after connecting, and after any decode failure.
    case requestControlSurface

    // MARK: Stack composition

    /// Append an effect, placed where the phone's own pipeline order would
    /// put it. `effect` is a `WorkspaceAdjustableEffect` rawValue.
    case addEffect(effect: String)
    case removeSlot(slot: UUID)
    case duplicateSlot(slot: UUID)
    /// Move a slot to an absolute index in render order.
    case moveSlot(slot: UUID, toIndex: Int)
    /// Restore a slot's parameters to the effect's defaults, preserving its
    /// enabled state.
    case resetSlot(slot: UUID)
    case setSlotEnabled(slot: UUID, enabled: Bool)
    case setSlotParameter(slot: UUID, channel: GVBroadcastParameterChannel, value: Double)
    /// ADD mode. When false, selecting an effect on the phone clears the rest.
    case setStackArmed(Bool)
    case clearEffects

    // MARK: RGB split

    /// RGB SPLIT predates the slot stack and keeps its own parameters with
    /// their own ranges, so it cannot be addressed as a slot. Nil fields are
    /// left untouched, which makes this a partial update rather than a
    /// clobber of everything the operator did not just move.
    case setRGBSplit(enabled: Bool?, amount: Double?, angleDegrees: Double?, mix: Double?)

    // MARK: Capture

    case setRecording(Bool)
    case capturePhoto
}

/// The addressable channels of `CameraEffectParameters`.
///
/// A string key path in all but name. Named cases rather than raw strings so
/// a typo on the desktop fails to decode instead of silently addressing
/// nothing.
enum GVBroadcastParameterChannel: String, Codable, Equatable, Sendable, CaseIterable {
    case primary
    case secondary
    case tertiary
    case blend
    case overlayX
    case overlayY
}

// MARK: - Byte helpers

extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

extension UnsafeRawBufferPointer {
    /// Unaligned big-endian load. `loadUnaligned` rather than `load` because
    /// header fields sit at whatever offset the layout puts them at, and a
    /// misaligned `load` traps.
    func loadBigEndian<T: FixedWidthInteger>(at offset: Int, as _: T.Type) -> T {
        T(bigEndian: loadUnaligned(fromByteOffset: offset, as: T.self))
    }
}
