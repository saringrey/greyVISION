import Combine
import Foundation
import SwiftUI

/// Ordered phases of the grey//VISION cold-start sequence.
///
/// The sequence is decorative only. It never gates permission prompts or the
/// capture session: `AppModel.startEngine()` is still the single entry point
/// into the workspace and is only invoked from the LAUNCH control.
///
/// **EPIC DRAMATIC SEQUENCE (~12-15s actual):**
/// Void and spark holds are randomised so repeat launches are not metronomic,
/// which is why wall-clock time runs longer than the nominal phase budgets in
/// `GVBootTiming`. First launch plays the full ceremony once; later launches
/// take the fast path (see `seenKey`).
enum GVBootPhase: Int, Comparable, Sendable {
    /// Phase 0: Pure void - absolute darkness, building anticipation
    case void
    /// Phase 1: A single purple pixel awakens in the center
    case spark
    /// Phase 2: Phosphor bloom - dramatic radial CRT glow explosion
    case bloom
    /// Phase 3: Star field wakes progressively from the bloom
    case wake
    /// Phase 4: Terminal telemetry cascades line by line
    case discovery
    /// Phase 5: The mark reconstructs through visual language
    case materialize
    /// Phase 6: CRT synchronisation sweep locks the frame
    case sync
    /// Phase 7: LAUNCH energises; the instrument is operational
    case armed
    /// Phase 8: Raster tear opening signal path into camera
    case departing

    static func < (lhs: GVBootPhase, rhs: GVBootPhase) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Drives the boot choreography.
///
/// Continuous animation is derived from `phaseStart` inside `TimelineView`
/// bodies rather than published per-frame, so the sequence costs one timer and
/// no main-actor churn. Every timer stops as soon as the sequence completes.
/// Individually-revealed chrome on the splash screen.
///
/// Each one wakes on its own schedule rather than sharing a single
/// `isInterfaceVisible` flag, so no two launches assemble the same way.
enum GVBootElement: CaseIterable, Sendable {
    case header
    case hint
    case identity
    case dock
}

@MainActor
final class GVBootSequence: ObservableObject {
    @Published private(set) var phase = GVBootPhase.void
    @Published private(set) var phaseStart = Date()
    /// Indices of telemetry lines that have resolved.
    ///
    /// A set rather than a count: the lines come up in shuffled order, so
    /// "how many" can no longer imply "which".
    @Published private(set) var revealedLines: Set<Int> = []
    /// Momentarily re-corrupts one already-resolved line. Purely decorative —
    /// it makes the console feel like it is holding a noisy signal rather than
    /// having finished printing.
    @Published private(set) var glitchIndex: Int?
    /// Chrome elements that have woken. Filled in shuffled order.
    @Published private(set) var revealedElements: Set<GVBootElement> = []
    /// The chrome element currently decaying, if any.
    @Published private(set) var glitchedElement: GVBootElement?
    /// Identity sub-rows that have started resolving. Each row is hidden
    /// outright until its index lands here, so nothing flashes in fully-formed.
    @Published private(set) var revealedIdentityRows: Set<Int> = []
    /// Blink count consumed by the phosphor pixel before the sequence proceeds.
    @Published private(set) var sparkBlink = false
    @Published private(set) var isMarkVisible = false
    @Published private(set) var isInterfaceVisible = false
    @Published private(set) var isSparkVisible = false
    @Published private(set) var isBloomActive = false

    /// Wall-clock origin of the whole sequence, used for absolute timing
    private(set) var sequenceStart = Date()

    private var driver: Task<Void, Never>?
    private var lineCount = 0
    private var chromeTask: Task<Void, Never>?
    private var decayTask: Task<Void, Never>?
    private var identityTask: Task<Void, Never>?
    private var consoleTask: Task<Void, Never>?

    var isReady: Bool {
        phase >= .armed
    }

    var isDeparting: Bool {
        phase == .departing
    }

    /// Continuous animation still needed by any layer.
    var wantsTimeline: Bool {
        phase < .armed || phase == .departing
    }

    deinit {
        driver?.cancel()
    }

    /// The full ceremony plays once per install. Every later cold launch lands
    /// directly on the armed splash — the operator has seen the tube warm up;
    /// replaying it on every app switch is friction, not theatre.
    private static let seenKey = "gv.boot.sequence.seen"

    func start(lineCount: Int, reduceMotion: Bool) {
        guard driver == nil else { return }
        self.lineCount = lineCount
        sequenceStart = Date()

        guard !reduceMotion, !UserDefaults.standard.bool(forKey: Self.seenKey) else {
            applyReducedSequence()
            return
        }

        driver = Task { @MainActor [weak self] in
            await self?.run()
        }
    }

    func cancel() {
        driver?.cancel()
        driver = nil
        // The chrome and decay loops outlive the main driver, so they have to
        // be torn down explicitly or the decay task keeps ticking after the
        // splash is gone.
        chromeTask?.cancel()
        chromeTask = nil
        decayTask?.cancel()
        decayTask = nil
        identityTask?.cancel()
        identityTask = nil
        consoleTask?.cancel()
        consoleTask = nil
        glitchedElement = nil
    }

    /// Called by the LAUNCH control. Returns `false` when the instrument is not
    /// yet armed so callers can ignore premature taps.
    @discardableResult
    func beginDeparture() -> Bool {
        guard phase == .armed else { return false }
        advance(to: .departing)
        return true
    }

    /// Normalised progress through `duration`, clamped to `0 ... 1`.
    func progress(_ duration: Double, now: Date) -> Double {
        guard duration > 0 else { return 1 }
        return min(max(now.timeIntervalSince(phaseStart) / duration, 0), 1)
    }

    func elapsed(_ now: Date) -> Double {
        max(now.timeIntervalSince(phaseStart), 0)
    }

    private func applyReducedSequence() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        phase = .armed
        phaseStart = Date()
        revealedLines = Set(0 ..< lineCount)
        revealedElements = Set(GVBootElement.allCases)
        revealedIdentityRows = Set(0 ..< (2 + Self.identityCapabilityCount))
        isMarkVisible = true
        isInterfaceVisible = true
    }

    private func run() async {
        // PHASE 0 — VOID: near-total darkness. Deliberately long: the dead
        // screen is doing the work of making the first pixel feel like an
        // event. Randomised so repeat launches are not metronomic.
        advance(to: .void)
        guard await sleep(milliseconds: Int.random(in: 1900 ... 2500)) else { return }

        // PHASE 1 — SPARK: one phosphor pixel powers on and holds.
        advance(to: .spark)
        // The pixel gutters a few times before it holds, like a tube deciding
        // whether it still works.
        // Blink for 3-5 seconds before anything else wakes. Irregular on/off
        // intervals so it reads as a failing tube rather than a metronome.
        let blinkDeadline = Date().addingTimeInterval(Double.random(in: 3.0 ... 5.0))
        while Date() < blinkDeadline {
            withAnimation(.linear(duration: 0.06)) { isSparkVisible = true }
            // Fired on the rising edge so the beep lands exactly with the
            // pixel lighting, not after it.
            GVSoundEngine.shared.play(.blip)
            guard await sleep(milliseconds: Int.random(in: 90 ... 260)) else { return }
            withAnimation(.linear(duration: 0.06)) { isSparkVisible = false }
            guard await sleep(milliseconds: Int.random(in: 70 ... 300)) else { return }
        }
        withAnimation(.easeIn(duration: 0.5)) {
            isSparkVisible = true
        }
        // Void + spark together sit in the 3-5s window before anything else
        // appears on screen.
        guard await sleep(milliseconds: Int.random(in: 500 ... 900)) else { return }

        // PHASE 2 — BLOOM. The slowed sting takes over from the blinking, so
        // the pixel stops ticking and starts straining.
        GVSoundEngine.shared.play(.errorGlitchSlow)
        advance(to: .bloom)
        withAnimation(.easeOut(duration: 1.2)) {
            isBloomActive = true
        }
        guard await sleep(milliseconds: 1500) else { return }

        // PHASE 3 — WAKE
        advance(to: .wake)
        // The console beeps belong to THIS moment — they are the sound
        // of the chrome waking. They used to fire a full phase later,
        // arriving after the rows they narrate had already resolved.
        GVSoundEngine.shared.play(.retroBeeps)
        withAnimation(.easeOut(duration: 0.9)) {
            isInterfaceVisible = true
        }
        // Chrome wakes on its own clock from here, concurrently with the
        // console. Nothing waits on anything else, so the screen assembles
        // out of order every launch.
        chromeTask = Task { @MainActor [weak self] in await self?.wakeChrome() }
        decayTask = Task { @MainActor [weak self] in await self?.runDecay() }
        // Bottom identity block resolves alongside the console, not after the
        // mark. Previously it waited on materialize, so top and bottom filled
        // in sequence and the screen assembled in two obvious halves.
        identityTask = Task { @MainActor [weak self] in await self?.revealIdentityRows() }
        // Console starts on the same beat as the identity block. It used to be
        // inline in `run()` one phase later, which is why the top half always
        // trailed the bottom half by a full second.
        consoleTask = Task { @MainActor [weak self] in await self?.revealConsoleLines() }
        guard await sleep(milliseconds: 1100) else { return }

        // PHASE 4 — DISCOVERY. Both halves are already resolving; this just
        // holds long enough for them to finish before the mark arrives.
        advance(to: .discovery)
        guard await sleep(milliseconds: Int.random(in: 2600 ... 3200)) else { return }

        // PHASE 5 — MATERIALIZE
        advance(to: .materialize)
        // Fires as the mark begins resolving, so the sting lands with the
        // reconstruction rather than after it.
        // Same sting played backwards, so the mark arriving reads as the
        // inverse of the pixel dissolving.
        GVSoundEngine.shared.play(.errorGlitchReversed)
        withAnimation(.easeOut(duration: 1.2)) {
            isMarkVisible = true
        }
        guard await sleep(milliseconds: 1400) else { return }

        // PHASE 6 — SYNC
        advance(to: .sync)
        guard await sleep(milliseconds: 500) else { return }

        // PHASE 7 — ARMED
        advance(to: .armed)
        // Full ceremony completed once; later launches take the fast path.
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        GVBootHaptics.armed()
    }

    /// Wakes each chrome element independently on a shuffled, jittered
    /// schedule. Runs alongside the console reveal rather than after it.
    private func wakeChrome() async {
        var order = GVBootElement.allCases
        order.shuffle()
        for element in order {
            guard await sleep(milliseconds: Int.random(in: 260 ... 900)) else { return }
            withAnimation(.easeOut(duration: Double.random(in: 0.28 ... 0.62))) {
                _ = revealedElements.insert(element)
            }
        }
    }

    /// Randomly decays one already-woken element at a time until the system
    /// arms. This is what keeps the screen feeling like it is holding a noisy
    /// signal rather than having finished drawing.
    private func runDecay() async {
        // Tighter gaps and longer hits than before. At 420-1400ms between
        // events the screen spent most of the sequence sitting still, which
        // read as a finished layout waiting rather than a signal being held
        // together. The hit itself is also held longer so it registers.
        while !Task.isCancelled, phase < .armed {
            guard await sleep(milliseconds: Int.random(in: 620 ... 1900)) else { return }
            guard let victim = revealedElements.randomElement() else { continue }
            glitchedElement = victim
            guard await sleep(milliseconds: Int.random(in: 110 ... 230)) else { return }
            glitchedElement = nil

            // Bursts: roughly one event in three drags a second element down
            // immediately after the first, so the decay arrives in clusters
            // instead of an even tick.
            if Int.random(in: 0 ... 5) == 0, let second = revealedElements.randomElement() {
                glitchedElement = second
                guard await sleep(milliseconds: Int.random(in: 70 ... 160)) else { return }
                glitchedElement = nil
            }
        }
        glitchedElement = nil
    }

    /// Resolves console telemetry in shuffled order, occasionally knocking an
    /// already-resolved line back into noise.
    private func revealConsoleLines() async {
        var order = Array(0 ..< lineCount)
        order.shuffle()
        for index in order {
            guard await sleep(milliseconds: Int.random(in: 140 ... 300)) else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                _ = revealedLines.insert(index)
            }

            // Every other resolved line now knocks an earlier one back into
            // noise, up from one in four, and the knock lasts longer.
            if revealedLines.count > 2, Int.random(in: 0 ... 3) == 0 {
                let victim = revealedLines.randomElement()
                glitchIndex = victim
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 150 ... 300)))
                    if self?.glitchIndex == victim { self?.glitchIndex = nil }
                }
            }
        }
        glitchIndex = nil
    }

    /// Number of capability rows in the identity manifest, after the
    /// attribution and wordmark. Must track `BootView.capabilities`; the two
    /// are asserted equal in `BootViewTests`.
    static let identityCapabilityCount = 12

    /// Brings the identity block up one row at a time. Rows stay entirely
    /// hidden until their turn, so the block never appears pre-drawn.
    private func revealIdentityRows() async {
        // Attribution then wordmark, in order: those two are the statement and
        // have to land before the manifest starts filling in around them.
        for index in 0 ... 1 {
            guard await sleep(milliseconds: Int.random(in: 150 ... 320)) else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                _ = revealedIdentityRows.insert(index)
            }
        }

        // Capability rows resolve in shuffled order, so the block fills in the
        // way a machine enumerating hardware would report it — whatever
        // answers first — rather than top to bottom like a credits roll.
        for index in (2 ..< (2 + Self.identityCapabilityCount)).shuffled() {
            guard await sleep(milliseconds: Int.random(in: 60 ... 150)) else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                _ = revealedIdentityRows.insert(index)
            }
        }
    }

    private func advance(to next: GVBootPhase) {
        phase = next
        phaseStart = Date()
    }

    /// Collapses the sequence under UI test.
    ///
    /// The cinematic boot is 12s by design. A UI test asserting on the mark
    /// would either need every timeout inflated past that or would fail, and
    /// inflating the timeouts hides real hangs. One flag here keeps the
    /// designed sequence intact and lets the state machine run at speed.
    var isAccelerated = false

    private func sleep(milliseconds: Int) async -> Bool {
        let scaled = isAccelerated ? max(milliseconds / 40, 1) : milliseconds
        try? await Task.sleep(for: .milliseconds(scaled))
        return !Task.isCancelled
    }
}

enum GVBootTiming {
    /// Nominal budgets, not wall-clock promises. `GVBootSequence.run()` holds
    /// void, spark and discovery for randomised intervals, so the ceremony
    /// lands around 12-15s. Only the shader-driven durations below (bloom,
    /// reconstruction, sweep) are read as exact seconds.
    /// PHASE 0: Pure void darkness (nominal; run() uses 1900-2500ms random)
    static let voidMilliseconds = 1500
    static let voidSeconds = 1.5

    /// PHASE 1: Single spark awakens (nominal; run() blinks 3-5s random)
    static let sparkMilliseconds = 800
    static let sparkSeconds = 0.8

    /// PHASE 2: Phosphor bloom explosion
    static let bloomMilliseconds = 1800
    static let bloomSeconds = 1.8

    /// PHASE 3: Star field wake (nominal; run() holds 1100ms)
    static let wakeMilliseconds = 1200
    static let wakeSeconds = 1.2

    /// PHASE 4: Terminal cascade (nominal; run() holds 2600-3200ms random)
    static let discoveryMilliseconds = 2500
    static let discoverySeconds = 2.5

    /// PHASE 5: Logo reconstruction
    static let reconstructionMilliseconds = 1500
    static let reconstructionSeconds = 1.5

    /// PHASE 6: CRT synchronisation sweep
    static let sweepMilliseconds = 500
    static let sweepSeconds = 0.5

    /// PHASE 7: Armed state capacitor
    static let armSeconds = 0.3

    /// PHASE 8: Departure raster tear
    static let departSeconds = 0.34

    /// Total dramatic sequence: ~9.8 seconds nominal (actual ~12-15s randomised)
    static let totalSeconds = voidSeconds + sparkSeconds + bloomSeconds +
        wakeSeconds + discoverySeconds + reconstructionSeconds +
        sweepSeconds
}
