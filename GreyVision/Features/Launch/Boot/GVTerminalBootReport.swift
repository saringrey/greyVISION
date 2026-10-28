import AVFoundation
import Metal

/// What the cold-start terminal prints: a POST of this device and this
/// install, read from the real system rather than written as flavour text.
/// A line that says AUTHORIZED means the permission is granted; a GPU name is
/// the one Metal reports.
struct GVTerminalBootReport {
    enum Status: Equatable {
        case none, ok, wait, fail

        var token: String {
            switch self {
            case .none: ""
            case .ok: "[ OK ]"
            case .wait: "[WAIT]"
            case .fail: "[FAIL]"
            }
        }
    }

    enum Style { case title, subtitle, entry, prompt }

    struct Line: Identifiable {
        let id: Int
        let style: Style
        /// Dim label column for entries; empty for titles.
        let key: String
        let value: String
        let status: Status

        /// The text the typewriter reveals, key and leader included.
        var typed: String {
            guard style == .entry else { return value }
            let leader = String(repeating: ".", count: max(13 - key.count, 2))
            return "\(key) \(leader) \(value)"
        }

        var keyLength: Int { style == .entry ? key.count : 0 }
    }

    let lines: [Line]

    var lengths: [Int] { lines.map(\.typed.count) }

    @MainActor
    static func current(setup: CaptureSetupDraft) -> GVTerminalBootReport {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let gpu = MTLCreateSystemDefaultDevice()?.name.uppercased()
        let effects = EffectCatalog.canonicalEffects(EffectCatalog.shelves.flatMap(\.effects)).count
        let memory = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let filled = min(max(Int((memory / 12 * 14).rounded()), 3), 14)
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: 14 - filled)

        var entries: [(Style, String, String, Status)] = [
            (.title, "", "grey//VISION", .none),
            (.subtitle, "", "ROM \(version) (\(build)) · CREATIVE ENGINE · (C) GREY", .none),
            (.entry, "GPU", gpu ?? "NO METAL DEVICE", gpu == nil ? .fail : .ok),
            (.entry, "EFFECTS", "\(effects) LOADED", .ok),
            (.entry, "CAPTURE", "\(setup.resolution.rawValue) · \(setup.frameRate.rawValue) FPS · \(setup.videoCodec.compactLabel)", .ok),
            (.entry, "TRACKING", "\(GVTrackingPreset.all.count) PRESETS · VISION", .ok),
        ]
        entries.append(permission("CAMERA", AVCaptureDevice.authorizationStatus(for: .video)))
        entries.append(permission("MICROPHONE", AVCaptureDevice.authorizationStatus(for: .audio)))
        entries.append((.entry, "MEMORY", "\(bar) \(String(format: "%.0f", memory.rounded())) GB", .ok))
        entries.append((.prompt, "", "> exec greyvision --live", .none))
        return GVTerminalBootReport(lines: entries.enumerated().map { index, entry in
            Line(id: index, style: entry.0, key: entry.1, value: entry.2, status: entry.3)
        })
    }

    private static func permission(_ key: String, _ status: AVAuthorizationStatus) -> (Style, String, String, Status) {
        switch status {
        case .authorized: (.entry, key, "AUTHORIZED", .ok)
        case .notDetermined: (.entry, key, "AWAITING OPERATOR", .wait)
        default: (.entry, key, "DENIED", .fail)
        }
    }
}
