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
    }

    struct Header: Equatable, Sendable {
        var kind: MessageKind
        /// Set on sync samples. The receiver cannot start decoding until one
        /// arrives, so it is worth a bit rather than a parse of the payload.
        var isKeyframe: Bool
        var payloadLength: Int
        /// Presentation time in nanoseconds since the broadcast began.
        var timestampNanoseconds: Int64

        init(kind: MessageKind, isKeyframe: Bool = false, payloadLength: Int, timestampNanoseconds: Int64 = 0) {
            self.kind = kind
            self.isKeyframe = isKeyframe
            self.payloadLength = payloadLength
            self.timestampNanoseconds = timestampNanoseconds
        }

        var encoded: Data {
            var data = Data(capacity: GVBroadcastProtocol.headerLength)
            data.appendBigEndian(GVBroadcastProtocol.magic)
            data.append(kind.rawValue)
            data.append(isKeyframe ? 1 : 0)
            data.appendBigEndian(UInt16(0))
            data.appendBigEndian(UInt32(payloadLength))
            data.appendBigEndian(UInt64(bitPattern: timestampNanoseconds))
            return data
        }

        /// Parses a header from exactly `headerLength` bytes.
        ///
        /// Returns nil for a bad magic, an unknown kind or an over-long
        /// payload. All three mean the stream is not one we can follow, and
        /// the caller's only correct response is to drop the connection —
        /// resynchronising on a byte stream with no delimiters is guesswork.
        static func decode(_ data: Data) -> Header? {
            guard data.count >= GVBroadcastProtocol.headerLength else { return nil }
            return data.withUnsafeBytes { raw -> Header? in
                guard raw.loadBigEndian(at: 0, as: UInt32.self) == GVBroadcastProtocol.magic,
                      let kind = MessageKind(rawValue: raw.load(fromByteOffset: 4, as: UInt8.self))
                else {
                    return nil
                }
                let length = Int(raw.loadBigEndian(at: 8, as: UInt32.self))
                guard length <= GVBroadcastProtocol.maximumPayloadLength else { return nil }
                return Header(
                    kind: kind,
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
}

/// Mac → phone control.
///
/// Only commands the broadcast engine can satisfy on its own are listed.
/// Driving the effect stack from the desktop needs a vocabulary designed
/// against the Mac's actual controls, and inventing one here before that
/// exists would ship a message set with nothing on the other end to honour it.
enum GVBroadcastCommand: Codable, Equatable, Sendable {
    /// The receiver has no decodable state — it joined late, or dropped a
    /// frame. Forces the next encode to be a sync sample.
    case requestKeyframe
    /// Retarget the encoder, in bits per second. The Mac knows what the link
    /// is sustaining; the phone does not.
    case setBitrate(Int)
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
