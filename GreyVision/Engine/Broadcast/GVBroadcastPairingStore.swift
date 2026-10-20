import Foundation

/// The phone's half of pairing: the code it shows, and the fact it remembers.
///
/// ## Why the phone stores a code at all
///
/// The link is authenticated by a pre-shared key, and a key delivered over the
/// channel it protects is not a secret. So the code has to reach the Mac out of
/// band — the user reads it off this phone and types it into whichever Mac app
/// they are pairing with — and the only thing the phone has to do about that is
/// keep showing the same code.
///
/// That is deliberately a smaller promise than "stores a credential". The code
/// is displayed in plaintext on the phone's own screen; a thief who can
/// unlock the phone can read it, and then use it. Protecting it beyond that
/// would mean hiding it from the person who needs it.
///
/// ## Storage
///
/// `UserDefaults`, not the keychain: the value is not a secret the app needs to
/// keep to itself, it is one the user has to be able to see and copy, and
/// putting a displayed value behind a background-only access class tends to
/// produce exactly the bug it is meant to prevent — the code silently failing
/// to appear the first time it is asked for after a reboot.
final class GVBroadcastPairingStore: @unchecked Sendable {

    private enum Key {
        static let code = "greyvision.broadcast.pairingCode"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()
    /// The code generated this launch, when nothing was stored. Held so two
    /// reads in the same session always agree even before the write lands.
    private var pending: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The code the phone is currently paired with, created on first use.
    var code: String {
        lock.withLock {
            if let stored = defaults.string(forKey: Key.code) {
                let normalized = GVBroadcastKeyMaterial.normalizeCode(stored)
                if GVBroadcastKeyMaterial.isValidCode(normalized) {
                    return normalized
                }
            }
            if let pending { return pending }
            let fresh = GVBroadcastKeyMaterial.generateCode()
            defaults.set(fresh, forKey: Key.code)
            pending = fresh
            return fresh
        }
    }

    /// Whether a Mac already holds this code. Purely informational: the phone
    /// cannot know, because a peer that fails the handshake is told nothing.
    /// Shown so the operator is not left wondering whether they have ever
    /// paired.
    var hasStoredCode: Bool {
        lock.withLock {
            guard let stored = defaults.string(forKey: Key.code) else { return false }
            return GVBroadcastKeyMaterial.isValidCode(GVBroadcastKeyMaterial.normalizeCode(stored))
        }
    }

    /// A new code. Every Mac that was paired with the old one stops working,
    /// which is the point: this is the escape hatch for a code that has been
    /// seen by someone it should not have been.
    func regenerate() -> String {
        lock.withLock {
            let fresh = GVBroadcastKeyMaterial.generateCode()
            defaults.set(fresh, forKey: Key.code)
            pending = fresh
            return fresh
        }
    }
}