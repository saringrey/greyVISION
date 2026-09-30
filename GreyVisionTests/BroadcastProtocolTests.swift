@testable import GreyVision
import XCTest

/// The wire format, which is the one piece of this feature that two separate
/// codebases have to agree on byte for byte.
///
/// A framing bug here does not look like a framing bug from either end — it
/// looks like a decoder that produces green mush, or a link that drops for no
/// reason. These are cheap and they are the only thing standing between a
/// protocol change and a very slow debugging session.
final class BroadcastProtocolTests: XCTestCase {
    func testHeaderRoundTripsEveryField() {
        for kind in [GVBroadcastProtocol.MessageKind.hello, .videoFormat, .videoFrame, .command, .keepalive] {
            for isKeyframe in [true, false] {
                let original = GVBroadcastProtocol.Header(
                    kind: kind,
                    isKeyframe: isKeyframe,
                    payloadLength: 123_456,
                    // Negative on purpose: the field is signed and a timestamp
                    // before the epoch must survive rather than wrap.
                    timestampNanoseconds: -9_007_199_254
                )
                let encoded = original.encoded
                XCTAssertEqual(encoded.count, GVBroadcastProtocol.headerLength)
                XCTAssertEqual(GVBroadcastProtocol.Header.decode(encoded), original, "\(kind) keyframe=\(isKeyframe)")
            }
        }
    }

    /// `Data` slices do not start at index zero, and the receive path hands
    /// over subranges of a larger buffer. Indexing a slice as though it were
    /// zero-based is the single most common way to write a parser that passes
    /// its own tests and fails on the wire.
    func testHeaderDecodesFromANonZeroBasedSlice() {
        let padded = Data([0xAA, 0xBB]) +
            GVBroadcastProtocol.Header(kind: .videoFrame, payloadLength: 9).encoded
        XCTAssertEqual(GVBroadcastProtocol.Header.decode(padded.dropFirst(2))?.payloadLength, 9)
    }

    func testMalformedHeadersAreRejected() {
        var badMagic = GVBroadcastProtocol.Header(kind: .videoFrame, payloadLength: 4).encoded
        badMagic[0] = 0
        XCTAssertNil(GVBroadcastProtocol.Header.decode(badMagic), "a bad magic must not parse")

        // An unknown kind is NOT a broken stream: the header still carries a
        // payload length, so the reader decodes it with a nil kind and skips
        // that many bytes. This is what lets a peer add a message type
        // without dropping every older build (see controlSurface/controlState).
        var unknownKind = GVBroadcastProtocol.Header(kind: .videoFrame, payloadLength: 4).encoded
        unknownKind[4] = 99
        let decoded = GVBroadcastProtocol.Header.decode(unknownKind)
        XCTAssertNotNil(decoded, "an unknown kind must stay framed so its payload can be skipped")
        XCTAssertNil(decoded?.kind)
        XCTAssertTrue(decoded?.isUnknownKind == true)
        XCTAssertEqual(decoded?.payloadLength, 4)

        XCTAssertNil(GVBroadcastProtocol.Header.decode(Data([1, 2, 3])), "a short buffer must not parse")
    }

    /// A corrupt length field must be refused before it is used to size an
    /// allocation, otherwise a single flipped bit is an out-of-memory kill.
    func testOversizePayloadLengthIsRejected() {
        let huge = GVBroadcastProtocol.Header(
            kind: .videoFrame,
            payloadLength: GVBroadcastProtocol.maximumPayloadLength + 1
        ).encoded
        XCTAssertNil(GVBroadcastProtocol.Header.decode(huge))

        let atLimit = GVBroadcastProtocol.Header(
            kind: .videoFrame,
            payloadLength: GVBroadcastProtocol.maximumPayloadLength
        ).encoded
        XCTAssertNotNil(GVBroadcastProtocol.Header.decode(atLimit), "the limit itself is valid")
    }

    func testPayloadsRoundTrip() throws {
        let format = GVBroadcastVideoFormat(
            codec: "hvc1",
            parameterSets: [Data([1, 2, 3]), Data([4, 5]), Data([6])],
            nalUnitHeaderLength: 4,
            width: 1920,
            height: 1080
        )
        let encodedFormat = try JSONEncoder().encode(format)
        XCTAssertEqual(try JSONDecoder().decode(GVBroadcastVideoFormat.self, from: encodedFormat), format)

        let hello = GVBroadcastHello(deviceName: "phone", width: 1920, height: 1080, codec: "hvc1")
        let encodedHello = try JSONEncoder().encode(hello)
        XCTAssertEqual(try JSONDecoder().decode(GVBroadcastHello.self, from: encodedHello), hello)

        for command in [GVBroadcastCommand.requestKeyframe, .setBitrate(8_000_000)] {
            let encoded = try JSONEncoder().encode(command)
            XCTAssertEqual(try JSONDecoder().decode(GVBroadcastCommand.self, from: encoded), command)
        }
    }
}
