import Foundation

enum GVVirtualCameraConfiguration {
    static let appGroup = "5NCWM6DS4H.com.saringrey.greyvision.virtualcamera"

    private enum Key {
        static let serviceName = "serviceName"
        // Renamed from "passcode". The value's shape changed from six digits
        // to a sixteen-character code, so a value stored under the old key
        // would be read back as a pairing code that can never work. Reading it
        // under the new key means such a pairing simply starts unset, which is
        // what it effectively was.
        static let pairingCode = "pairingCode"
        static let isEnabled = "isEnabled"
    }

    struct Pairing: Equatable {
        var serviceName: String
        var pairingCode: String
        var isEnabled: Bool
    }

    static func load() -> Pairing {
        let defaults = UserDefaults(suiteName: appGroup)
        let stored = defaults?.string(forKey: Key.pairingCode) ?? ""
        return Pairing(
            serviceName: defaults?.string(forKey: Key.serviceName) ?? "greyVISION",
            pairingCode: GVBroadcastKeyMaterial.isValidCode(stored) ? stored : "",
            isEnabled: defaults?.bool(forKey: Key.isEnabled) ?? false
        )
    }

    static func save(serviceName: String, pairingCode: String, isEnabled: Bool) {
        let defaults = UserDefaults(suiteName: appGroup)
        defaults?.set(serviceName, forKey: Key.serviceName)
        defaults?.set(pairingCode, forKey: Key.pairingCode)
        defaults?.set(isEnabled, forKey: Key.isEnabled)
    }
}
