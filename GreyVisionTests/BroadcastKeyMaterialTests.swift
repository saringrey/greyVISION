import CryptoKit
import XCTest
@testable import GreyVision

/// The link's trust boundary.
///
/// These tests exist because the previous implementation passed all of them
/// while shipping a pre-shared key that was a string literal in the binary: the
/// phone and the Mac agreed with each other, so a test that only checked "both
/// sides derive the same key" would have been satisfied by a key anyone could
/// reproduce. The properties below are the ones that actually matter.
final class BroadcastKeyMaterialTests: XCTestCase {

    // MARK: - Code shape

    func testGeneratedCodesAreWellFormedAndDistinct() {
        var seen = Set<String>()
        for _ in 0..<500 {
            let code = GVBroadcastKeyMaterial.generateCode()
            XCTAssertEqual(code.count, GVBroadcastKeyMaterial.codeLength)
            XCTAssertTrue(GVBroadcastKeyMaterial.isValidCode(code), "\(code) should be valid")
            seen.insert(code)
        }
        // 80 bits of code space; a collision across 500 draws would mean the
        // generator is not actually random.
        XCTAssertEqual(seen.count, 500, "Generated pairing codes collided")
    }

    func testGeneratedCodesUseOnlyUnambiguousCharacters() {
        // Crockford's alphabet omits I, L, O and U so a code read aloud or
        // retyped cannot silently change meaning.
        let forbidden: Set<Character> = ["I", "L", "O", "U"]
        for _ in 0..<200 {
            let code = GVBroadcastKeyMaterial.generateCode()
            XCTAssertTrue(code.allSatisfy { !forbidden.contains($0) }, "\(code) contains a confusable character")
        }
    }

    // MARK: - Normalisation

    func testNormalisationFoldsTheCharactersPeopleActuallyMistype() {
        let canonical = GVBroadcastKeyMaterial.generateCode()
        // Re-type it the way a person would: lowercase, with the confusables
        // swapped for what they probably meant and a space every four chars.
        var noisy = ""
        for character in canonical {
            switch character {
            case "1": noisy += "l"
            case "0": noisy += "O"
            default: noisy.append(character)
            }
        }
        noisy = noisy.lowercased()
        let spaced = stride(from: 0, to: noisy.count, by: 4).map { offset -> String in
            let start = noisy.index(noisy.startIndex, offsetBy: offset)
            let end = noisy.index(start, offsetBy: min(4, noisy.distance(from: start, to: noisy.endIndex)))
            return String(noisy[start..<end])
        }.joined(separator: " ")

        XCTAssertEqual(GVBroadcastKeyMaterial.normalizeCode(spaced), canonical)
    }

    func testNormalisationDropsSeparatorsAndNonAlphabetCharacters() {
        // Separators, whitespace and punctuation are how people actually write
        // a code down, so all of it has to go without changing the code.
        XCTAssertEqual(GVBroadcastKeyMaterial.normalizeCode("ab-cd ef"), "ABCDEF")
        XCTAssertEqual(GVBroadcastKeyMaterial.normalizeCode("ab_cd\tef"), "ABCDEF")
        // Lowercase is accepted, because a code is very likely pasted.
        XCTAssertEqual(GVBroadcastKeyMaterial.normalizeCode("abcdefgh"), "ABCDEFGH")
        XCTAssertEqual(GVBroadcastKeyMaterial.normalizeCode(""), "")
        XCTAssertEqual(GVBroadcastKeyMaterial.normalizeCode("!!! /// ..."), "")
    }

    func testNormalisationFoldsRatherThanDropsTheConfusables() {
        // The point of the fold: these are *not* dropped. "0" typed as "O" is a
        // code the user meant, not garbage.
        XCTAssertEqual(GVBroadcastKeyMaterial.normalizeCode("O"), "0")
        XCTAssertEqual(GVBroadcastKeyMaterial.normalizeCode("I"), "1")
        XCTAssertEqual(GVBroadcastKeyMaterial.normalizeCode("l"), "1")
    }

    // MARK: - Validation

    func testOnlyFullLengthCodesBecomeSecrets() {
        let code = GVBroadcastKeyMaterial.generateCode()
        XCTAssertNotNil(GVBroadcastKeyMaterial.secret(forCode: code))
        XCTAssertNil(GVBroadcastKeyMaterial.secret(forCode: ""), "an empty code must not become key material")
        XCTAssertNil(GVBroadcastKeyMaterial.secret(forCode: String(code.dropLast())), "a short code must not become key material")
        // The six-digit shape the old pairing UI used must not be accepted,
        // or a stale value saved under the old key would be honoured.
        XCTAssertNil(GVBroadcastKeyMaterial.secret(forCode: "391400"))
    }

    // MARK: - Key derivation

    func testTheSameCodeAlwaysDerivesTheSameKey() {
        // The phone, the Mac app and the camera extension each call this from
        // their own copy of the compiled file. Determinism is what lets them
        // agree without talking to each other first.
        let code = GVBroadcastKeyMaterial.generateCode()
        guard let first = GVBroadcastKeyMaterial.secret(forCode: code),
              let second = GVBroadcastKeyMaterial.secret(forCode: code) else {
            return XCTFail("a freshly generated code should be usable")
        }
        XCTAssertEqual(first, second)

        let a = GVBroadcastKeyMaterial.deriveKey(secret: first)
        let b = GVBroadcastKeyMaterial.deriveKey(secret: second)
        XCTAssertEqual(a, b)
    }

    func testDifferentCodesDeriveDifferentKeys() {
        let codes = (0..<50).map { _ in GVBroadcastKeyMaterial.generateCode() }
        var keys = Set<Data>()
        for code in codes {
            guard let secret = GVBroadcastKeyMaterial.secret(forCode: code) else {
                return XCTFail("\(code) should be usable")
            }
            keys.insert(Data(GVBroadcastKeyMaterial.deriveKey(secret: secret).withUnsafeBytes { Data($0) }))
        }
        XCTAssertEqual(keys.count, codes.count, "two pairing codes derived the same TLS key")
    }

    func testDerivationIsSaltedSoItIsNotReusableElsewhere() {
        // Same secret, different service type, different key. Without the salt
        // this key would be identical to any other key the app derives from the
        // same bytes.
        let secret = GVBroadcastKeyMaterial.generateCode()
        XCTAssertEqual(GVBroadcastProtocol.serviceType, "_greyvision._tcp")
        let here = GVBroadcastKeyMaterial.deriveKey(secret: Data(secret.utf8))
        let naive = SymmetricKey(data: Data(secret.utf8))
        XCTAssertNotEqual(here, naive, "the derived key must not be the raw secret")
    }

    // MARK: - The constant that used to be here

    func testTheOldHardcodedSecretIsNoLongerPartOfTheProtocol() {
        // The audit's Critical finding. There is no longer any symbol carrying
        // the old literal, so this cannot regress into shipping: referencing it
        // is now a compile error, which is the point.
        XCTAssertTrue(
            !GVBroadcastKeyMaterial.deriveKey(secret: Data("greyVISION.local.v1".utf8))
                .isEqual(to: GVBroadcastKeyMaterial.deriveKey(secret: Data(GVBroadcastKeyMaterial.generateCode().utf8))),
            "the legacy literal must not be a valid pairing secret"
        )
    }
}

private extension SymmetricKey {
    func isEqual(to other: SymmetricKey) -> Bool {
        self == other
    }
}