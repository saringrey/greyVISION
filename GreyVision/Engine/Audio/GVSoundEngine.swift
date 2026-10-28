@preconcurrency import AVFAudio
import Foundation

/// Interface sound, synthesised at runtime.
///
/// There are no audio assets in the bundle. Each cue is generated once into a
/// small PCM buffer and then replayed, so the palette is tuned by editing
/// numbers rather than re-exporting files.
///
/// The palette is deliberately narrow: square waves, abrupt gates and
/// bit-crushed noise, rolled off at the top so they read as a small speaker
/// in a room rather than as a synth chip. Nothing resolves musically — a
/// terminal acknowledging a keystroke, not a UI chime. Sound is reserved for
/// the two selections that change what the whole interface is showing;
/// everything else stays silent so these still register.
@MainActor
final class GVSoundEngine {
    static let shared = GVSoundEngine()

    enum Cue: CaseIterable {
        /// Effect category committed on the bottom rail.
        case category
        /// Top toolbar menu opened or closed.
        case menu
        /// Rejected action. Available for wiring; intentionally dissonant.
        case error
        /// Access keypad. Bit-crushed and gated so it reads as a machine
        /// acknowledging a key, not as the system keyboard.
        case keypad
        /// Correct code. The one unambiguously good sound in the instrument.
        case accept
        /// Cold-start POST beep: one bare PC-speaker tone.
        case postBeep
        /// The cold start's boot log being typed: a mechanical switch — a
        /// sharp click over a short plastic thock. Two voicings alternate so
        /// a run of keys never sounds like one sample on repeat.
        case keyClick
        case keyClickAlt
        /// The heavier keypress that lands each line's [ OK ].
        case keyReturn
        /// The setup failure: a two-chord system error, bright then falling,
        /// in the manner of a 90s desktop OS refusing to continue.
        case systemError
        /// The cold start's crash: a quarter second of chopped, crushed
        /// digital noise that stops dead.
        case crash
    }

    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                if wantsMenuMusic { startMenuMusic() }
            } else {
                music?.pause()
                stopStings()
            }
        }
    }

    /// Menu bed level. Deliberately well under the cues so a category beep
    /// still cuts through the track.
    private let musicVolume: Float = 0.30

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var buffers: [Cue: AVAudioPCMBuffer] = [:]
    private var started = false
    private var music: AVAudioPlayer?
    private var stings: [String: AVAudioPlayer] = [:]
    private var wantsMenuMusic = false

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
            ?? AVAudioEngine().outputNode.outputFormat(forBus: 0)
    }

    // MARK: - Playback

    func play(_ cue: Cue) {
        guard isEnabled, prepareEngine() else { return }
        let buffer: AVAudioPCMBuffer
        if let cached = buffers[cue] {
            buffer = cached
        } else if let built = render(cue) {
            buffers[cue] = built
            buffer = built
        } else {
            return
        }
        player.scheduleBuffer(buffer, at: nil, options: [.interrupts], completionHandler: nil)
        if !player.isPlaying {
            player.play()
        }
    }

    // MARK: - One-shot stings

    /// Bundled one-shot audio played over the menu bed.
    enum Sting {
        /// System working through its boot checks.
        case retroBeeps
        /// The mark resolving out of reconstruction.
        case errorGlitch
        /// The same file played backwards, for the inverse moment.
        case errorGlitchReversed
        /// One tick of the phosphor pixel powering on.
        case blip
        /// The glitch sting dragged well under speed, for the moment the
        /// pixel stops blinking and starts transforming.
        case errorGlitchSlow
        /// Looping corruption bed under the whole boot sequence. Stopped by
        /// `stopStings()` when the splash hands over, which the launch path
        /// already calls, so it can never survive into the workspace.
        case bootGlitch
        /// The raster tearing open under a two-finger pull.
        case signalTear
        /// Held under the boot sequence while elements resolve into the scene.
        /// Shares the tear's file: the same rising laser reads as assembly
        /// here and as rupture there, and one asset is cheaper than two.
        case sceneLoad
        /// Fires once the system arms. The discharge is the payoff for the
        /// load bed that preceded it.
        case systemReady
        /// Passcode accepted — bright chime over the unlock thud.
        case successChime

        var resource: String {
            switch self {
            case .retroBeeps: "gv_retro_beeps"
            case .bootGlitch: "gv_boot_glitch"
            case .signalTear: "gv_signal_tear"
            case .sceneLoad: "gv_signal_tear"
            case .systemReady: "gv_electricity"
            case .blip: "gv_short_beep"
            case .errorGlitch, .errorGlitchReversed, .errorGlitchSlow: "gv_error_glitch"
            case .successChime: "success-chime"
            }
        }

        /// Sits above the 0.30 music bed so the sting reads as an event, while
        /// staying under the level where it would swamp the track.
        /// Playback rate. The beeps run well under speed so the boot reads as
        /// tired hardware rather than a modem handshake.
        var rate: Float {
            switch self {
            // Dragged down so the laser reads as something powering up
            // rather than as a UI zap.
            case .sceneLoad: 0.62
            // Twice speed, so the cue is half as long and lands inside the
            // glitch burst instead of outrunning it.
            case .bootGlitch: 2.0
            case .retroBeeps: 0.55
            // Dragged right down so the transformation reads as the tube
            // straining rather than as a quick stutter.
            case .errorGlitchSlow: 0.42
            default: 1.0
            }
        }

        /// Reversed playback. AVAudioPlayer supports a negative rate, which is
        /// cheaper and simpler than decoding and reversing the samples.
        var isReversed: Bool { self == .errorGlitchReversed }

        /// Loop count. Only the boot bed repeats; every other cue is a
        /// one-shot and must stay one.
        /// Nothing loops. Both beds were repeating for the whole sequence,
        /// which turned a cue into a drone and made it impossible to hear when
        /// the thing it was announcing actually happened.
        var loops: Int { 0 }

        var volume: Float {
            switch self {
            case .retroBeeps: 0.14
            // Fires up to twenty times during the blink, so it has to sit well
            // under the stings or it becomes the loudest thing on the screen.
            case .blip: 0.16
            case .errorGlitch, .errorGlitchReversed, .errorGlitchSlow: 0.35
            // Sits under the beeps: this runs for the whole sequence, so it
            // is texture, not an event.
            case .bootGlitch: 0.13
            case .signalTear: 0.38
            // Under the glitch bed: this runs for the whole reveal, so it
            // is texture rather than an event.
            case .sceneLoad: 0.11
            case .systemReady: 0.26
            case .successChime: 0.24
            }
        }
    }

    /// Plays a bundled sting once.
    ///
    /// Each sting keeps its own player so it layers over the music instead of
    /// interrupting it, and so retriggering one cannot cut the other short.
    func play(_ sting: Sting) {
        guard isEnabled else { return }
        // Reversed and forward variants share a file but need separate players
        // and start positions, so they key on the cue, not the resource.
        let key = "\(sting)"
        if let existing = stings[key] {
            existing.currentTime = sting.isReversed ? existing.duration - 0.01 : 0
            existing.play()
            return
        }
        guard let url = Bundle.main.url(forResource: sting.resource, withExtension: "mp3") else {
            GVLog.audio.error("sting missing from bundle: \(sting.resource).mp3")
            return
        }
        configureSessionIfSafe()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = sting.volume
            player.numberOfLoops = sting.loops
            player.enableRate = true
            player.rate = sting.isReversed ? -sting.rate : sting.rate
            player.prepareToPlay()
            if sting.isReversed {
                player.currentTime = player.duration - 0.01
            }
            player.play()
            stings[key] = player
        } catch {
            GVLog.audio.error("sting failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Gesture-modulated playback

    /// Plays a cue whose pitch and stereo position are driven by the gesture
    /// that triggered it.
    ///
    /// A fixed sample would make every tear sound identical no matter how the
    /// operator opened it, which breaks the illusion that the sound is the
    /// screen rather than a UI noise attached to it. Rate follows how far the
    /// tear was pulled, pan follows where on the frame it happened, and volume
    /// follows how violently it was moved.
    ///
    /// - Parameters:
    ///   - sting: Cue to play.
    ///   - openness: Tear separation, 0...1. Drives pitch.
    ///   - position: Horizontal midpoint of the tear, 0...1. Drives pan.
    ///   - rotation: Tear angle in radians. Detunes further as it twists.
    ///   - velocity: Gesture speed, 0...1. Drives level.
    func playModulated(
        _ sting: Sting,
        openness: Float,
        position: Float,
        rotation: Float,
        velocity: Float
    ) {
        guard isEnabled else { return }
        guard let url = Bundle.main.url(forResource: sting.resource, withExtension: "mp3") else {
            GVLog.audio.error("sting missing from bundle: \(sting.resource).mp3")
            return
        }
        configureSessionIfSafe()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            // A wider tear drops the pitch, so opening it further sounds like
            // more material giving way rather than the same click repeated.
            let twist = min(abs(rotation) / .pi, 1)
            player.enableRate = true
            player.rate = max(0.55, 1.35 - openness * 0.62 - twist * 0.18)
            // Pan follows the tear across the frame.
            player.pan = min(max(position * 2 - 1, -1), 1)
            player.volume = sting.volume * (0.7 + min(velocity, 1) * 0.3)
            player.prepareToPlay()
            player.play()
            // Keyed per playback so overlapping tears layer instead of
            // cutting each other off.
            stings["\(sting)-\(UUID().uuidString)"] = player
        } catch {
            GVLog.audio.error("modulated sting failed: \(error.localizedDescription)")
        }
    }

    /// Stops one cue without disturbing the others.
    ///
    /// Needed for the looping beds: `stopStings()` would take the boot glitch
    /// down with the load bed, and the two have different lifetimes.
    func stop(_ sting: Sting) {
        let key = "\(sting)"
        stings[key]?.stop()
        stings[key] = nil
    }

    /// Stops any in-flight stings. Used when leaving the menu so a long beep
    /// sequence cannot survive into the camera workspace.
    func stopStings() {
        for player in stings.values {
            player.stop()
        }
        stings.removeAll()
    }

    // MARK: - Menu music

    /// Starts the looping menu bed.
    ///
    /// Uses `AVAudioPlayer` rather than the cue engine: it decodes MP3, loops
    /// natively and carries its own volume, none of which is worth rebuilding
    /// on top of the PCM path used for the beeps.
    func startMenuMusic() {
        wantsMenuMusic = true
        guard isEnabled else { return }

        if let music {
            if !music.isPlaying { music.play() }
            return
        }
        guard let url = Bundle.main.url(forResource: "greyvision", withExtension: "mp3") else {
            GVLog.audio.error("menu music missing from bundle")
            return
        }
        configureSessionIfSafe()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = musicVolume
            player.prepareToPlay()
            player.play()
            music = player
        } catch {
            GVLog.audio.error("menu music failed: \(error.localizedDescription)")
        }
    }

    /// Fades out and releases the bed. Called when leaving the menu, so the
    /// track never bleeds into the camera workspace.
    func stopMenuMusic(fadeDuration: TimeInterval = 0.6) {
        wantsMenuMusic = false
        guard let player = music else { return }
        music = nil
        player.setVolume(0, fadeDuration: fadeDuration)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(fadeDuration))
            player.stop()
        }
    }

    func shutdown() {
        stopStings()
        music?.stop()
        music = nil
        guard started else { return }
        player.stop()
        engine.stop()
        started = false
    }

    private func prepareEngine() -> Bool {
        if started { return true }
        configureSessionIfSafe()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.28
        do {
            try engine.start()
            started = true
            return true
        } catch {
            GVLog.audio.error("sound engine unavailable: \(error.localizedDescription)")
            return false
        }
    }

    /// Uses `.playback`, not `.ambient` — `.ambient` is silenced by the
    /// hardware ring/silent switch, which made the whole palette inaudible on
    /// a phone left on silent. Leaves an active recording category alone so
    /// enabling the audio-reactive analyser is never broken by a button press.
    private func configureSessionIfSafe() {
        let session = AVAudioSession.sharedInstance()
        let recording: Set<AVAudioSession.Category> = [.record, .playAndRecord]
        guard !recording.contains(session.category) else { return }
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            GVLog.audio.error("sound session refused: \(error.localizedDescription)")
        }
    }

    // MARK: - Synthesis

    /// One gated segment of a cue. A cue is a short sequence of these, which is
    /// what produces the stepped "bi-dip" character of terminal feedback rather
    /// than a single sustained note.
    private struct Segment {
        var duration: Double
        /// Zero renders silence — used for the gaps between blips.
        var frequency: Float
        /// Square-wave duty cycle. Away from 0.5 the tone thins toward a pulse.
        var duty: Float = 0.5
        /// Blend toward sample-and-hold noise: 0 pure tone, 1 pure crush.
        var crush: Float = 0
        /// Amplitude gate rate in Hz. Non-zero chops the segment into a buzz.
        var gate: Float = 0
        var gain: Float = 0.5
        /// A second square voiced with the first, for chords.
        var harmony: Float = 0
        /// Exponential decay rate per second; 0 holds the level flat.
        var decay: Float = 0
        /// Low-pass cutoff in Hz. 0 leaves the waveform alone. Rolling the
        /// top off is what stops a hard square from sounding like a toy: no
        /// real speaker has edges that sharp.
        var cutoff: Float = 0
    }

    private func segments(for cue: Cue) -> [Segment] {
        switch cue {
        case .category:
            // A pop, not a beep. Short enough that it reads as contact rather
            // than as a tone, and quiet enough to disappear under the camera.
            [
                Segment(duration: 0.010, frequency: 740, duty: 0.30, gain: 0.13, decay: 90, cutoff: 2600),
                Segment(duration: 0.014, frequency: 1180, duty: 0.26, crush: 0.22, gain: 0.11, cutoff: 2600)
            ]
        case .menu:
            [
                Segment(duration: 0.012, frequency: 960, duty: 0.32, crush: 0.14, gain: 0.10, cutoff: 2600)
            ]
        case .keypad:
            // A keyboard click: tiny transient over a short body. Crisper and
            // quieter than the old crushed pair — a keypress, not a modem.
            [
                Segment(duration: 0.0025, frequency: 4200, duty: 0.5, gain: 0.05, cutoff: 3000),
                Segment(duration: 0.010, frequency: 1150, duty: 0.45, crush: 0.08, gain: 0.075, cutoff: 3000)
            ]
        case .accept:
            // An unlock: bolt thud, mechanism settle, latch note.
            [
                Segment(duration: 0.018, frequency: 150, duty: 0.5, gain: 0.20, cutoff: 1400),
                Segment(duration: 0.004, frequency: 0),
                Segment(duration: 0.028, frequency: 96, duty: 0.55, gain: 0.17, cutoff: 1400),
                Segment(duration: 0.006, frequency: 0),
                Segment(duration: 0.055, frequency: 660, duty: 0.35, crush: 0.06, gain: 0.13, decay: 22, cutoff: 1800)
            ]
        case .postBeep:
            // A bare PC speaker, not a synth beep: the tone falls away and the
            // top end is rolled off, so the cone thuds instead of chirping.
            [
                Segment(duration: 0.11, frequency: 988, duty: 0.5, gain: 0.2, decay: 7, cutoff: 2200)
            ]
        case .crash:
            // Digital failure keeps its brightness and its ugliness: this one
            // is supposed to sound like a picture coming apart.
            [
                Segment(duration: 0.06, frequency: 1_760, duty: 0.3, crush: 0.7, gate: 90, gain: 0.2),
                Segment(duration: 0.08, frequency: 0, crush: 1, gate: 60, gain: 0.22),
                Segment(duration: 0.1, frequency: 311, duty: 0.5, crush: 0.85, gate: 120, gain: 0.2)
            ]
        case .keyClick:
            // Plastic over a hollow case: a filtered transient, not a hiss,
            // over a low body that dies inside a few milliseconds.
            [
                Segment(duration: 0.0016, frequency: 0, crush: 0.75, gain: 0.17, cutoff: 2600),
                Segment(duration: 0.011, frequency: 196, duty: 0.5, crush: 0.25, gain: 0.1, decay: 230, cutoff: 2600),
                Segment(duration: 0.008, frequency: 132, duty: 0.5, gain: 0.05, decay: 300, cutoff: 2600)
            ]
        case .keyClickAlt:
            [
                Segment(duration: 0.0013, frequency: 0, crush: 0.75, gain: 0.15, cutoff: 2600),
                Segment(duration: 0.012, frequency: 208, duty: 0.46, crush: 0.3, gain: 0.09, decay: 240, cutoff: 2600),
                Segment(duration: 0.007, frequency: 146, duty: 0.5, gain: 0.045, decay: 320, cutoff: 2600)
            ]
        case .keyReturn:
            [
                Segment(duration: 0.0022, frequency: 0, crush: 0.8, gain: 0.2, cutoff: 1900),
                Segment(duration: 0.022, frequency: 118, duty: 0.5, crush: 0.3, gain: 0.16, decay: 120, cutoff: 1900),
                Segment(duration: 0.018, frequency: 88, duty: 0.5, gain: 0.08, decay: 160, cutoff: 1900)
            ]
        case .systemError:
            // Not the bright two-note jingle every 90s desktop played on
            // failure. A dull sour fall, low and unresolving: the machine
            // cannot continue, and that is all it says.
            [
                Segment(duration: 0.16, frequency: 233, duty: 0.5, gain: 0.12, decay: 5, cutoff: 950),
                Segment(duration: 0.55, frequency: 196, duty: 0.5, crush: 0.12, gain: 0.12, decay: 4.2, cutoff: 950)
            ]
        case .error:
            // Low dissonant buzz, hard-gated. Unmistakably a refusal, and
            // held under the old level so it corrects rather than punishes.
            [
                Segment(duration: 0.09, frequency: 196, duty: 0.5, gate: 60, gain: 0.24, cutoff: 1_200),
                Segment(duration: 0.02, frequency: 0),
                Segment(duration: 0.11, frequency: 174, duty: 0.5, crush: 0.3, gate: 48, gain: 0.24, cutoff: 1_200)
            ]
        }
    }

    private func render(_ cue: Cue) -> AVAudioPCMBuffer? {
        let parts = segments(for: cue)
        let sampleRate = Float(format.sampleRate)
        guard sampleRate > 0 else { return nil }

        let total = parts.reduce(0) { $0 + $1.duration }
        let frameCount = AVAudioFrameCount(total * Double(sampleRate))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = frameCount

        var noiseState: UInt32 = 0x9E37_79B9
        var cursor = 0
        /// One-pole filter state, kept across segments so a segment boundary
        /// does not click.
        var filtered: Float = 0

        for part in parts {
            let frames = Int(part.duration * Double(sampleRate))
            var phase: Float = 0
            var harmonyPhase: Float = 0
            var held: Float = 0

            for frame in 0 ..< frames where cursor + frame < Int(frameCount) {
                var value: Float = 0

                if part.frequency > 0 {
                    phase += part.frequency / sampleRate
                    if phase >= 1 { phase -= 1 }
                    // Hard square: no interpolation, no smoothing. The abrupt
                    // edge is the whole character.
                    value = phase < part.duty ? 1 : -1
                }
                if part.harmony > 0 {
                    harmonyPhase += part.harmony / sampleRate
                    if harmonyPhase >= 1 { harmonyPhase -= 1 }
                    value = (value + (harmonyPhase < 0.5 ? 1 : -1)) * 0.5
                }

                if part.crush > 0 {
                    // Sample-and-hold at a low rate reads as digital failure
                    // rather than as analogue hiss.
                    if frame % 12 == 0 {
                        noiseState ^= noiseState << 13
                        noiseState ^= noiseState >> 17
                        noiseState ^= noiseState << 5
                        held = Float(noiseState % 2_001) / 1_000 - 1
                    }
                    value = value * (1 - part.crush) + held * part.crush
                }

                if part.gate > 0 {
                    let t = Float(frame) / sampleRate
                    value *= fmod(t * part.gate, 1) < 0.5 ? 1 : 0
                }

                if part.decay > 0 {
                    value *= exp(-part.decay * Float(frame) / sampleRate)
                }

                // One-pole low-pass. A hard square has edges no real speaker
                // has; rolling the top off is what keeps these cues from
                // sounding like a synth chip.
                if part.cutoff > 0 {
                    let coefficient = 1 - exp(-2 * Float.pi * part.cutoff / sampleRate)
                    filtered += coefficient * (value - filtered)
                    value = filtered
                } else {
                    filtered = value
                }

                // Only the last two milliseconds are ramped, purely to stop the
                // speaker clicking. Everything before that stays square.
                let remaining = Float(frames - frame) / sampleRate
                if remaining < 0.002 {
                    value *= remaining / 0.002
                }

                channel[cursor + frame] = max(min(value * part.gain, 1), -1)
            }
            cursor += frames
        }
        return buffer
    }
}
