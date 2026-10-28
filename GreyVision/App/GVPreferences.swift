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
        static let experimental = "gv.preferences.experimental"
        static let sound = "gv.preferences.sound"
        static let favorites = "gv.preferences.favorites"
        static let recents = "gv.preferences.recents"
        static let developer = "gv.preferences.developer"
        static let density = "gv.preferences.hudDensity"
        static let coachSeen = "gv.preferences.coach.seen"
        static let startupAnimation = "gv.preferences.startup.animation"
        static let renderQuality = "gv.preferences.renderQuality"
        static let countdown = "gv.preferences.capture.countdown"
    }

    /// Self-timer delay before the shutter fires, in seconds. `0` captures
    /// immediately. Applies to both photo and record so a countdown can be used
    /// to get in frame for a clip, not only for a still.
    @Published var captureCountdownSeconds: Int {
        didSet { defaults.set(captureCountdownSeconds, forKey: Key.countdown) }
    }

    /// How hard the renderer is allowed to work.
    ///
    /// Automatic lets the governor move the render scale, the simulation field
    /// sizes and the frame-rate ceiling when frames run over budget. The
    /// pinned options are promises: they will not move on their own, which is
    /// the right answer for an operator who would rather have a dropped frame
    /// than a soft image. See `GVRenderQuality`.
    @Published var renderQuality: GVRenderQuality {
        didSet { defaults.set(renderQuality.rawValue, forKey: Key.renderQuality) }
    }

    /// Whether unlocking runs the full boot ceremony or lands straight in the
    /// workspace. On by default because the sequence is the instrument's
    /// opening statement; operators who reopen the app many times a day can
    /// turn it off from the settings deck.
    @Published var startupAnimationEnabled: Bool {
        didSet { defaults.set(startupAnimationEnabled, forKey: Key.startupAnimation) }
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

    private static func currentEffectName(_ stored: String) -> String {
        WorkspaceAdjustableEffect.resolving(stored)?.rawValue ?? stored
    }

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

    /// Camera tools & guide preferences
    @Published var gridEnabled: Bool {
        didSet { defaults.set(gridEnabled, forKey: "gv.preferences.cam.grid") }
    }

    @Published var histogramEnabled: Bool {
        didSet { defaults.set(histogramEnabled, forKey: "gv.preferences.cam.histogram") }
    }

    @Published var peakingEnabled: Bool {
        didSet { defaults.set(peakingEnabled, forKey: "gv.preferences.cam.peaking") }
    }

    @Published var zebraEnabled: Bool {
        didSet { defaults.set(zebraEnabled, forKey: "gv.preferences.cam.zebra") }
    }

    @Published var reticleEnabled: Bool {
        didSet { defaults.set(reticleEnabled, forKey: "gv.preferences.cam.reticle.v2") }
    }

    @Published var ndShutterEnabled: Bool {
        didSet { defaults.set(ndShutterEnabled, forKey: "gv.preferences.cam.ndShutter") }
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
        experimentalEnabled = defaults.bool(forKey: Key.experimental)
        renderQuality = GVRenderQuality(
            rawValue: defaults.string(forKey: Key.renderQuality) ?? ""
        ) ?? .automatic
        // Unset is 0, and 0 is "fire the shutter now" — the pre-timer behaviour.
        captureCountdownSeconds = defaults.integer(forKey: Key.countdown)

        defaults.register(defaults: [Key.startupAnimation: true])
        startupAnimationEnabled = defaults.object(forKey: Key.startupAnimation) == nil
            ? true
            : defaults.bool(forKey: Key.startupAnimation)

        defaults.register(defaults: ["gv.preferences.watermark": true])
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
        let soundVal = defaults.bool(forKey: Key.sound)
        soundEnabled = soundVal

        defaults.register(defaults: [
            "gv.preferences.cam.grid": false,
            "gv.preferences.cam.histogram": false,
            "gv.preferences.cam.peaking": false,
            "gv.preferences.cam.zebra": false,
            // New default also applies to existing installs, then preserves
            // any subsequent choice to turn the reticle off.
            "gv.preferences.cam.reticle.v2": true,
            "gv.preferences.cam.ndShutter": false
        ])
        gridEnabled = defaults.bool(forKey: "gv.preferences.cam.grid")
        histogramEnabled = defaults.bool(forKey: "gv.preferences.cam.histogram")
        peakingEnabled = defaults.bool(forKey: "gv.preferences.cam.peaking")
        zebraEnabled = defaults.bool(forKey: "gv.preferences.cam.zebra")
        reticleEnabled = defaults.bool(forKey: "gv.preferences.cam.reticle.v2")
        ndShutterEnabled = defaults.bool(forKey: "gv.preferences.cam.ndShutter")

        // Stored names pass through the retirement table, so a favourite or
        // recent that named a removed effect points at its replacement.
        favoriteEffects = Set((defaults.stringArray(forKey: Key.favorites) ?? []).map(Self.currentEffectName))
        var seenRecents = Set<String>()
        recentEffects = Array(
            (defaults.stringArray(forKey: Key.recents) ?? []).map(Self.currentEffectName)
                .filter { seenRecents.insert($0).inserted }
                .prefix(Self.recentEffectLimit)
        )

        GVSoundEngine.shared.isEnabled = soundVal
    }
}
