import Combine
import SwiftUI

/// Operator preferences that persist across launches.
///
/// Deliberately small: these are the switches that change what the instrument
/// exposes, not per-effect state. Everything here defaults to the quietest,
/// least surprising option so a first launch is calm.
@MainActor
final class GVPreferences: ObservableObject {
    private enum Key {
        static let sigils = "gv.preferences.sigils"
        static let experimental = "gv.preferences.experimental"
        static let sound = "gv.preferences.sound"
        static let favorites = "gv.preferences.favorites"
        static let recents = "gv.preferences.recents"
        static let developer = "gv.preferences.developer"
        static let density = "gv.preferences.hudDensity"
        static let coachSeen = "gv.preferences.coach.seen"
    }

    /// How much telemetry the instrument prints at once. 0 minimal, 1
    /// standard, 2 diagnostic.
    @Published var hudDensity: Int {
        didSet { defaults.set(hudDensity, forKey: Key.density) }
    }

    /// The wrench and the diagnostics deck are maintenance surface, not
    /// framing surface. Hidden until opted in.
    @Published var developerEnabled: Bool {
        didSet { defaults.set(developerEnabled, forKey: Key.developer) }
    }

    /// First-run gesture coach. Shown once; the Help entry re-opens it.
    @Published var coachSeen: Bool {
        didSet { defaults.set(coachSeen, forKey: Key.coachSeen) }
    }

    /// Effects the operator has starred, stored as raw values so the set
    /// survives effects being added or reordered. Unknown identifiers are
    /// simply ignored on read rather than pruned, so a favourite parked by a
    /// build that hid an effect comes back when the effect does.
    @Published private(set) var favoriteEffects: Set<String> = [] {
        didSet { defaults.set(Array(favoriteEffects), forKey: Key.favorites) }
    }

    /// Effects the operator reached for most recently, newest first.
    ///
    /// Capped, because the point is "the handful I am working with", not a
    /// history. Stored as raw values for the same reason favourites are: an
    /// effect that disappears from a build should come back where it was
    /// rather than being pruned on read.
    @Published private(set) var recentEffects: [String] = [] {
        didSet { defaults.set(recentEffects, forKey: Key.recents) }
    }

    static let recentEffectLimit = 10

    /// Records a selection. Re-selecting something already recent moves it to
    /// the front rather than adding a duplicate.
    func noteEffectUsed(_ identifier: String) {
        var updated = recentEffects.filter { $0 != identifier }
        updated.insert(identifier, at: 0)
        recentEffects = Array(updated.prefix(Self.recentEffectLimit))
    }

    func isFavorite(_ identifier: String) -> Bool {
        favoriteEffects.contains(identifier)
    }

    func toggleFavorite(_ identifier: String) {
        if favoriteEffects.contains(identifier) {
            favoriteEffects.remove(identifier)
        } else {
            favoriteEffects.insert(identifier)
        }
    }

    /// Hidden stroke sequences. Off by default — the mechanic should be opted
    /// into, not discovered by accident while framing a shot.
    @Published var sigilsEnabled: Bool {
        didSet { defaults.set(sigilsEnabled, forKey: Key.sigils) }
    }

    /// Reveals the experimental effect categories in the dock rail. Hidden by
    /// default so the default surface stays the stable set.
    @Published var experimentalEnabled: Bool {
        didSet { defaults.set(experimentalEnabled, forKey: Key.experimental) }
    }

    /// Interface sound. On by default because the boot sequence is written
    /// around it, but muted the moment the operator says so.
    @Published var soundEnabled: Bool {
        didSet {
            defaults.set(soundEnabled, forKey: Key.sound)
            GVSoundEngine.shared.isEnabled = soundEnabled
        }
    }
    
    /// Whether to composite the HUD watermark into saved recordings.
    @Published var watermarkEnabled: Bool {
        didSet { defaults.set(watermarkEnabled, forKey: "gv.preferences.watermark") }
    }

    /// Menu track playback. Session-only by design — persisting it would mean
    /// the song starts on a later launch without the operator choosing it,
    /// which is the behaviour that was just removed.
    @Published var musicEnabled = false {
        didSet {
            guard musicEnabled != oldValue else { return }
            if musicEnabled {
                GVSoundEngine.shared.startMenuMusic()
            } else {
                GVSoundEngine.shared.stopMenuMusic()
            }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.density: 1])
        hudDensity = defaults.integer(forKey: Key.density)
        developerEnabled = defaults.bool(forKey: Key.developer)
        coachSeen = defaults.bool(forKey: Key.coachSeen)
        sigilsEnabled = defaults.bool(forKey: Key.sigils)
        experimentalEnabled = defaults.bool(forKey: Key.experimental)
        
        defaults.register(defaults: ["gv.preferences.watermark": true])
        watermarkEnabled = defaults.bool(forKey: "gv.preferences.watermark")
        // `bool(forKey:)` returns false for an unset key, so sound has to be
        // registered explicitly to default on.
        // Sound state is persisted, so once it is switched off it stays off
        // across reinstalls. Bumping the key resets everyone to on one time
        // rather than leaving the app silent with no obvious cause.
        defaults.register(defaults: [Key.sound: true])
        if defaults.object(forKey: "gv.preferences.sound.reset.v2") == nil {
            defaults.set(true, forKey: Key.sound)
            defaults.set(true, forKey: "gv.preferences.sound.reset.v2")
        }
        soundEnabled = defaults.bool(forKey: Key.sound)
        GVSoundEngine.shared.isEnabled = soundEnabled
        favoriteEffects = Set(defaults.stringArray(forKey: Key.favorites) ?? [])
        recentEffects = Array(
            (defaults.stringArray(forKey: Key.recents) ?? []).prefix(Self.recentEffectLimit)
        )

    }
}
