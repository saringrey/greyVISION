import CryptoKit
import Foundation
import Network

/// The one place the greyVISION link's TLS key is derived.
///
/// ## Why this file exists
///
/// The link runs TLS-PSK over a Bonjour-advertised TCP listener, so the
/// pre-shared key *is* the trust boundary: anything that can reproduce it can
/// watch the live camera feed.
///
/// That key used to be assembled three times — once per product — and the three
/// copies disagreed. Two of them threw their `passcode` argument away and
/// derived the key from a string literal compiled into the binary, while the
/// third used the real passcode. The result was that the phone and the Mac
/// agreed with each other on a publicly-known key, and the camera extension
/// could never complete a handshake with either.
///
/// So the derivation lives here, once, and all three targets compile this same
/// file. The phone builds it from its own tree; the Mac app already reached
/// across into the iOS tree for `GVBroadcastProtocol.swift` and now does the
/// same for this; the virtual camera does the same after dropping its
/// hand-kept copy.
///
/// ## What makes it safe
///
/// The secret is a pairing code the user reads off the phone and types into
/// whichever Mac app they are pairing with. It is never transmitted, never
/// advertised over Bonjour, and never stored in plaintext on the phone — the
/// phone keeps only the code itself, which is what it has to display anyway.
/// There is no automatic fallback: no code, no link.
///
/// ## Portability
///
/// Only Foundation, CryptoKit and Network. All three are present on iOS and
/// macOS, including inside a sandboxed system extension, so this file compiles
/// unchanged into every target that speaks the link.
enum GVBroadcastKeyMaterial {

    // MARK: - Pairing code

    /// Number of characters in a pairing code.
    ///
    /// 16 Crockford Base32 characters is 80 bits. That is far more than the
    /// six digits the pairing UI used to accept — a six-digit code is a
    /// million candidates and a local-network attacker gets unlimited, silent
    /// guesses — while still being short enough to read off a phone screen
    /// and type on a keyboard without a mistake-rate problem.
    static let codeLength = 16

    /// Crockford Base32: no I, L, O or U, so `1`/`I` and `0`/`O` cannot be
    /// confused when a code is read aloud or retyped.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Uppercases, strips spaces and dashes, and maps the characters Crockford
    /// folds together back onto their canonical form.
    ///
    /// Normalising on both sides is what lets a user paste a code with spaces,
    /// or type `O` where the phone showed `0`, and still pair.
    static func normalizeCode(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for character in raw.uppercased() {
            switch character {
            case "I", "L": out.append("1")
            case "O": out.append("0")
            case "-", " ", "\u{2007}", "\t", "\n": continue
            default:
                if alphabet.contains(character) { out.append(character) }
            }
        }
        return out
    }

    /// Whether a code is the right shape to be used as a secret.
    static func isValidCode(_ code: String) -> Bool {
        code.count == codeLength
    }

    /// A fresh, random pairing code.
    ///
    /// Drawn from `SystemRandomNumberGenerator`, which is a CSPRNG on Apple
    /// platforms — the code is key material, so `Int.random` and friends are
    /// not good enough here.
    static func generateCode() -> String {
        // Five bits per character over `codeLength` characters is exactly
        // `codeLength * 5 / 8` bytes, so the encoder below consumes the buffer
        // with nothing left over and no character spent on padding.
        let needed = codeLength * 5 / 8
        // An explicit generator rather than `using: .system` inline: the
        // full-width `UInt8.random(in:)` form over an explicitly-typed range is
        // one of the expressions the Swift type checker gives up on and reports
        // as a failed-to-produce-diagnostic.
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(needed)
        while bytes.count < needed {
            var word = generator.next()
            withUnsafeBytes(of: &word) { raw in
                for byte in raw where bytes.count < needed {
                    bytes.append(byte)
                }
            }
        }
        return code(fromBytes: bytes)
    }

    /// Encodes bytes as a fixed-length Base32 string.
    ///
    /// Big-endian bit packing through a 16-bit window: five bits per character,
    /// so every character spans at most two bytes and the window always holds
    /// it. Arithmetic rather than slicing a binary string, because the obvious
    /// string implementation needs a range subscript Swift will not give it.
    static func code(fromBytes bytes: [UInt8]) -> String {
        var out = ""
        out.reserveCapacity(codeLength)
        for index in 0..<codeLength {
            let bit = index * 5
            let byteIndex = bit / 8
            guard byteIndex < bytes.count else { break }
            // Each character spans at most two bytes, so a 16-bit window
            // starting at byteIndex always contains it. Pad past the end rather
            // than trapping: the last character of a short input is the only
            // one that can need it.
            let hi = UInt32(bytes[byteIndex])
            let lo = byteIndex + 1 < bytes.count ? UInt32(bytes[byteIndex + 1]) : 0
            let window = (hi << 8) | lo
            // 16 bits in, five bits wanted, `offset` bits already consumed by
            // earlier characters inside the high byte.
            let shift = UInt(16 - 5 - (bit % 8))
            out.append(alphabet[Int((window >> shift) & 0x1F)])
        }
        return out
    }

    /// The key material for a code: its ASCII bytes.
    ///
    /// Returning nil for a malformed code rather than silently deriving from
    /// whatever was typed is deliberate. A peer that presents a bad code must
    /// fail the handshake, not connect under some fallback key.
    static func secret(forCode raw: String) -> Data? {
        let code = normalizeCode(raw)
        guard isValidCode(code) else { return nil }
        return Data(code.utf8)
    }

    // MARK: - Key derivation

    /// HKDF-SHA256 from the secret, salted by the service type.
    ///
    /// The salt is a constant, which is correct: its job is domain separation,
    /// so that this key can never be reused as key material for anything else
    /// derived from the same secret. All of the entropy is in `secret`.
    /// Internal rather than private so the tests can assert that the same code
    /// always yields the same key and two different codes never do. That pair of
    /// properties is the whole security claim; a refactor that broke either
    /// would be invisible otherwise, because every failure would look like "the
    /// Mac cannot see my phone".
    static func deriveKey(secret: Data) -> SymmetricKey {
        let salt = SymmetricKey(data: SHA256.hash(data: Data(GVBroadcastProtocol.serviceType.utf8)))
        let input = SymmetricKey(data: secret)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: input,
            salt: salt.withUnsafeBytes { Data($0) },
            info: Data("greyVISION.link.v2".utf8),
            outputByteCount: 32
        )
    }

    // MARK: - Transport

    /// TCP keepalive timing, shared so the three cannot drift.
    ///
    /// Probing every two seconds holds the Wi-Fi and AWDL radios awake for the
    /// whole session and costs noticeably more battery than the link itself
    /// when the Mac is idle between bursts.
    static let keepaliveIdleSeconds: Int = 30
    static let keepaliveIntervalSeconds: Int = 10
    static let keepaliveCount: Int = 3

    /// TLS options carrying the pre-shared key.
    static func tlsOptions(secret: Data) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let key = deriveKey(secret: secret)
        let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("greyVISION".utf8).withUnsafeBytes { DispatchData(bytes: $0) }

        sec_protocol_options_add_pre_shared_key(
            options.securityProtocolOptions,
            psk as __DispatchData,
            identity as __DispatchData
        )
        sec_protocol_options_append_tls_ciphersuite(
            options.securityProtocolOptions,
            tls_ciphersuite_t.AES_128_GCM_SHA256
        )
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        return options
    }

    /// The complete connection or listener parameters.
    ///
    /// TLS, TCP and peer-to-peer all in one place because all three targets
    /// need all three, and a link only works when they agree. `includePeerToPeer`
    /// is the one genuine difference between the phone's listener and the Macs'
    /// browsers: the phone advertises over AWDL so it can be found with no
    /// shared network, while the Mac browses LAN-first and only escalates to
    /// peer-to-peer when that finds nothing.
    static func parameters(secret: Data, includePeerToPeer: Bool) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        // Nagle batches small writes, which is exactly wrong for a stream of
        // frames that are each already the right size to send.
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = keepaliveIdleSeconds
        tcp.keepaliveInterval = keepaliveIntervalSeconds
        tcp.keepaliveCount = keepaliveCount

        let parameters = NWParameters(tls: tlsOptions(secret: secret), tcp: tcp)
        parameters.includePeerToPeer = includePeerToPeer
        return parameters
    }

    /// Listener parameters. The phone always advertises peer-to-peer: it is
    /// advertisement, not connection, that needs the interface, and a phone
    /// that does not advertise over AWDL is invisible to a Mac that has
    /// fallen back to looking for it.
    static func listenerParameters(secret: Data) -> NWParameters {
        parameters(secret: secret, includePeerToPeer: true)
    }
}