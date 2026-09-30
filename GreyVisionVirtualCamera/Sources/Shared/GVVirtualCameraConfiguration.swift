import Foundation

enum GVVirtualCameraConfiguration {
    static let appGroup = "5NCWM6DS4H.com.saringrey.greyvision.virtualcamera"

    private enum Key {
        static let serviceName = "serviceName"
        static let passcode = "passcode"
        static let isEnabled = "isEnabled"
    }

    struct Pairing: Equatable {
        var serviceName: String
        var passcode: String
        var isEnabled: Bool
    }

    static func load() -> Pairing {
        let defaults = UserDefaults(suiteName: appGroup)
        return Pairing(
            serviceName: defaults?.string(forKey: Key.serviceName) ?? "greyVISION",
            passcode: defaults?.string(forKey: Key.passcode) ?? "",
            isEnabled: defaults?.bool(forKey: Key.isEnabled) ?? false
        )
    }

    static func save(serviceName: String, passcode: String, isEnabled: Bool) {
        let defaults = UserDefaults(suiteName: appGroup)
        defaults?.set(serviceName, forKey: Key.serviceName)
        defaults?.set(passcode, forKey: Key.passcode)
        defaults?.set(isEnabled, forKey: Key.isEnabled)
    }
}
