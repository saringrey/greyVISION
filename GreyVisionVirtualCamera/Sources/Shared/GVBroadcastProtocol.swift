import Foundation

enum GVBroadcastProtocol {
    static let serviceType = "_greyvision._tcp"
    static let magic: UInt32 = 0x4756_5831
    static let headerLength = 20
    static let maximumPayloadLength = 8 * 1024 * 1024
    static let version = 1

    enum MessageKind: UInt8 {
        case hello = 1
        case videoFormat = 2
        case videoFrame = 3
        case command = 4
        case keepalive = 5
    }

    struct Header: Equatable, Sendable {
        var kind: MessageKind
        var isKeyframe: Bool
        var payloadLength: Int
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

        static func decode(_ data: Data) -> Header? {
            guard data.count == GVBroadcastProtocol.headerLength else { return nil }
            return data.withUnsafeBytes { raw in
                guard raw.loadBigEndian(at: 0, as: UInt32.self) == GVBroadcastProtocol.magic,
                      let kind = MessageKind(rawValue: raw.load(fromByteOffset: 4, as: UInt8.self))
                else { return nil }
                let payloadLength = Int(raw.loadBigEndian(at: 8, as: UInt32.self))
                guard payloadLength <= GVBroadcastProtocol.maximumPayloadLength else { return nil }
                return Header(
                    kind: kind,
                    isKeyframe: raw.load(fromByteOffset: 5, as: UInt8.self) != 0,
                    payloadLength: payloadLength,
                    timestampNanoseconds: Int64(bitPattern: raw.loadBigEndian(at: 12, as: UInt64.self))
                )
            }
        }
    }
}

struct GVBroadcastHello: Codable, Equatable, Sendable {
    var version = GVBroadcastProtocol.version
    var deviceName: String
    var width: Int
    var height: Int
    var codec: String
}

struct GVBroadcastVideoFormat: Codable, Equatable, Sendable {
    var codec: String
    var parameterSets: [Data]
    var nalUnitHeaderLength: Int32
    var width: Int
    var height: Int
    /// The rate the encoder is actually producing. Absent from a phone build
    /// that predates the field, so decoding is lenient about this one field
    /// and falls back to 30 rather than refusing the whole format.
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

enum GVBroadcastCommand: Codable, Equatable, Sendable {
    case requestKeyframe
    case setBitrate(Int)
}

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
    func loadBigEndian<T: FixedWidthInteger>(at offset: Int, as _: T.Type) -> T {
        T(bigEndian: loadUnaligned(fromByteOffset: offset, as: T.self))
    }
}
