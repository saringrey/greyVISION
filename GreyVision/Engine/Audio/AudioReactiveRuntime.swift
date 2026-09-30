import Accelerate
@preconcurrency import AVFAudio
import Combine
import Foundation
import UIKit

enum AudioReactiveState: String, Sendable {
    case idle
    case requestingPermission
    case running
    case denied
    case failed

    /// Spoken and toasted form. The intent bus reports this back to Shortcuts,
    /// where `denied` has to read as a state an operator can act on rather
    /// than as a raw case name.
    var label: String {
        switch self {
        case .idle: "IDLE"
        case .requestingPermission: "ASKING FOR THE MICROPHONE"
        case .running: "RUNNING"
        case .denied: "MICROPHONE DENIED"
        case .failed: "AUDIO ENGINE UNAVAILABLE"
        }
    }
}

struct AudioReactiveSnapshot: Equatable, Sendable {
    var rms: Float
    var bass: Float
    var mid: Float
    var treble: Float
    var peak: Float
    /// Hz of the strongest spectral bin in the voice/whistle range; zero when
    /// the analyser has no signal. Feeds the hidden "hum" incantation.
    var dominantFrequency: Float = 0

    /// Positive spectral flux since the previous analysis frame, normalised.
    /// This is the onset signal: it spikes on a hit and decays immediately,
    /// which is what "sound as destructive energy" needs — damage should land
    /// on the transient, not track the overall level.
    var transient: Float = 0

    /// How long the signal has stayed loud, 0...1 over roughly two seconds.
    /// Sustained tones stretch and drag the image rather than fracture it.
    var sustain: Float = 0

    /// How long the signal has been quiet, 0...1 over roughly three seconds.
    /// Drives repair: in silence the frame slowly heals back toward clean.
    var silence: Float = 0

    /// Sixteen log-spaced band energies, 40 Hz to 14 kHz, each 0...1.
    ///
    /// The three coarse bands above answer "is there bass", which is enough to
    /// modulate a filter and not nearly enough to *draw* a spectrum. A scope
    /// needs the shape of the signal, so the analyser now publishes the shape
    /// it already computed instead of throwing it away after summing it into
    /// three numbers.
    var spectrum = SIMD16<Float>()

    static let zero = AudioReactiveSnapshot(rms: 0, bass: 0, mid: 0, treble: 0, peak: 0)

    var metalBands: SIMD4<Float> {
        SIMD4(rms, bass, mid, treble)
    }

    /// The spectrum repacked as the four `float4`s the effect uniform carries.
    var metalSpectrum: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        (
            SIMD4(spectrum[0], spectrum[1], spectrum[2], spectrum[3]),
            SIMD4(spectrum[4], spectrum[5], spectrum[6], spectrum[7]),
            SIMD4(spectrum[8], spectrum[9], spectrum[10], spectrum[11]),
            SIMD4(spectrum[12], spectrum[13], spectrum[14], spectrum[15])
        )
    }

    /// Second audio uniform: the dynamics the band energies cannot express.
    var metalDynamics: SIMD4<Float> {
        SIMD4(peak, transient, sustain, silence)
    }
}

final class AudioReactiveSnapshotMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = AudioReactiveSnapshot.zero

    var latest: AudioReactiveSnapshot {
        lock.withLock { value }
    }

    func publish(_ snapshot: AudioReactiveSnapshot) {
        lock.withLock { value = snapshot }
    }

    func clear() {
        lock.withLock { value = .zero }
    }
}

@MainActor
final class AudioReactiveRuntime: ObservableObject {
    @Published private(set) var state = AudioReactiveState.idle
    @Published var intensity = 0.72
    /// Hidden "hum" incantation: true while the golden sigil overlay is up.
    @Published private(set) var incantationActive = false

    let snapshotMailbox = AudioReactiveSnapshotMailbox()

    var snapshot: AudioReactiveSnapshot {
        snapshotMailbox.latest
    }

    private let analyzer: AudioReactiveAnalyzer
    private var humStreak = 0
    private var lastHumFrequency: Float = 0
    private var incantationCooldownUntil: TimeInterval = 0

    init() {
        analyzer = AudioReactiveAnalyzer()
        analyzer.setSnapshotHandler { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.consume(snapshot)
            }
        }
    }

    /// Monitors the dominant frequency: a steady tone held in the voice range
    /// for about two seconds unlocks the golden sigil. Never fires while the
    /// sigil is already up, and re-arms only after a half-minute cooldown so it
    /// can't spam.
    private func consume(_ snapshot: AudioReactiveSnapshot) {
        snapshotMailbox.publish(snapshot)
        let now = ProcessInfo.processInfo.systemUptime
        if incantationActive || now < incantationCooldownUntil {
            humStreak = 0
            lastHumFrequency = 0
            return
        }
        let frequency = snapshot.dominantFrequency
        let hasSignal = snapshot.rms > 0.05 && snapshot.bass > 0.10
        if hasSignal, frequency > 120, frequency < 1800 {
            if lastHumFrequency == 0 {
                humStreak = 1
            } else if abs(frequency - lastHumFrequency) / max(lastHumFrequency, 1) < 0.03 {
                humStreak += 1
            } else {
                humStreak = 1
            }
            lastHumFrequency = frequency
        } else {
            humStreak = 0
            lastHumFrequency = 0
        }
        guard humStreak >= 60 else { return } // ~2 s at the 30 Hz analysis rate
        humStreak = 0
        lastHumFrequency = 0
        incantationActive = true
        incantationCooldownUntil = now + 30
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        GVLog.analysis.notice("AUDIO INCANTATION ACCEPTED at \(Int(frequency)) Hz")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.6))
            self?.incantationActive = false
        }
    }

    var isEnabled: Bool {
        state == .running
    }

    func toggle() async {
        if isEnabled {
            stop()
        } else {
            await start()
        }
    }

    func start() async {
        guard state != .running, state != .requestingPermission else { return }
        state = .requestingPermission
        let granted = await requestPermission()
        guard granted else {
            state = .denied
            snapshotMailbox.clear()
            return
        }

        do {
            try analyzer.start()
            state = .running
            GVLog.capture.notice("Audio-reactive analyzer started")
        } catch {
            analyzer.stop()
            snapshotMailbox.clear()
            state = .failed
            GVLog.capture.error("Audio-reactive analyzer failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        analyzer.stop()
        snapshotMailbox.clear()
        state = .idle
    }

    private func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
}

private final class AudioSampleMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float]
    private var sampleRate: Float = 48000
    private var isPending = false

    init(sampleCount: Int) {
        samples = [Float](repeating: 0, count: sampleCount)
    }

    func publish(_ source: UnsafePointer<Float>, count: Int, sampleRate: Float) -> Bool {
        lock.withLock {
            guard !isPending else { return false }
            let copiedCount = min(count, samples.count)
            samples.withUnsafeMutableBufferPointer { destination in
                guard let baseAddress = destination.baseAddress else { return }
                baseAddress.update(from: source, count: copiedCount)
                if copiedCount < destination.count {
                    baseAddress.advanced(by: copiedCount).initialize(
                        repeating: 0,
                        count: destination.count - copiedCount
                    )
                }
            }
            self.sampleRate = sampleRate
            isPending = true
            return true
        }
    }

    func consume(into destination: inout [Float]) -> Float? {
        lock.withLock {
            guard isPending else { return nil }
            destination.withUnsafeMutableBufferPointer { destinationBuffer in
                samples.withUnsafeBufferPointer { sourceBuffer in
                    guard let source = sourceBuffer.baseAddress,
                          let target = destinationBuffer.baseAddress
                    else { return }
                    target.update(from: source, count: min(sourceBuffer.count, destinationBuffer.count))
                }
            }
            isPending = false
            return sampleRate
        }
    }
}

private final class AudioReactiveAnalyzer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let analysisQueue = DispatchQueue(
        label: "com.saringrey.greyvision.audio.analysis",
        qos: .userInteractive
    )
    private let handlerLock = NSLock()
    private let mailbox: AudioSampleMailbox
    private let sampleCount = 1024
    private let log2SampleCount = vDSP_Length(10)
    private let fftSetup: FFTSetup
    private var handler: (@Sendable (AudioReactiveSnapshot) -> Void)?
    private var window: [Float]
    private var samples: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var magnitudes: [Float]
    private var lastPublishTime: TimeInterval = 0
    /// Running state for the dynamics envelopes. Analysis runs at a fixed 30Hz
    /// publish rate, so these can use per-frame constants rather than dt.
    private var previousBandEnergy: Float = 0
    private var transientEnvelope: Float = 0
    private var sustainEnvelope: Float = 0
    private var silenceEnvelope: Float = 0
    private var running = false

    init() {
        mailbox = AudioSampleMailbox(sampleCount: sampleCount)
        window = [Float](repeating: 0, count: sampleCount)
        samples = [Float](repeating: 0, count: sampleCount)
        windowed = [Float](repeating: 0, count: sampleCount)
        real = [Float](repeating: 0, count: sampleCount / 2)
        imaginary = [Float](repeating: 0, count: sampleCount / 2)
        magnitudes = [Float](repeating: 0, count: sampleCount / 2)
        guard let setup = vDSP_create_fftsetup(log2SampleCount, FFTRadix(kFFTRadix2)) else {
            fatalError("Unable to create the reusable audio FFT setup")
        }
        fftSetup = setup
        vDSP_hann_window(&window, vDSP_Length(sampleCount), Int32(vDSP_HANN_NORM))
    }

    deinit {
        stop()
        vDSP_destroy_fftsetup(fftSetup)
    }

    func setSnapshotHandler(_ handler: (@Sendable (AudioReactiveSnapshot) -> Void)?) {
        handlerLock.withLock {
            self.handler = handler
        }
    }

    func start() throws {
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw GVError.capabilityUnavailable(
                feature: "Microphone",
                reason: "The active audio route exposes no input channel."
            )
        }

        let bufferSize = AVAudioFrameCount(sampleCount)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            guard let self,
                  let channel = buffer.floatChannelData?.pointee,
                  mailbox.publish(
                      channel,
                      count: Int(buffer.frameLength),
                      sampleRate: Float(buffer.format.sampleRate)
                  )
            else { return }
            analysisQueue.async { [weak self] in
                self?.analyzePendingSamples()
            }
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running || engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func analyzePendingSamples() {
        guard let sampleRate = mailbox.consume(into: &samples) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPublishTime >= 1.0 / 30.0 else { return }
        lastPublishTime = now

        var rms: Float = 0
        var peak: Float = 0
        var peakIndex = vDSP_Length.zero
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        vDSP_maxmgvi(samples, 1, &peak, &peakIndex, vDSP_Length(samples.count))
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(sampleCount))

        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                guard let realBase = realBuffer.baseAddress,
                      let imaginaryBase = imaginaryBuffer.baseAddress
                else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imaginaryBase)
                windowed.withUnsafeBufferPointer { sourceBuffer in
                    guard let source = sourceBuffer.baseAddress else { return }
                    source.withMemoryRebound(to: DSPComplex.self, capacity: sampleCount / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(sampleCount / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2SampleCount, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(magnitudes.count))
            }
        }

        let binWidth = sampleRate / Float(sampleCount)
        let bass = normalizedEnergy(from: 32, through: 180, binWidth: binWidth)
        let mid = normalizedEnergy(from: 180, through: 2000, binWidth: binWidth)
        let treble = normalizedEnergy(from: 2000, through: 12000, binWidth: binWidth)
        let level = saturate(rms * 7.5)

        // Onset detection by half-wave-rectified spectral flux. Only energy
        // that *increased* since the last frame counts, so a steady loud tone
        // produces no transient while a hit produces a sharp one.
        let energy = bass + mid + treble
        let flux = max(energy - previousBandEnergy, 0)
        previousBandEnergy = energy
        // Fast attack, fast release: the spike must not smear across frames or
        // it stops reading as an impact.
        transientEnvelope = max(flux * 2.6, transientEnvelope * 0.55)

        // Sustain rises while loud and falls quickly once the signal drops.
        let loud = level > 0.18
        sustainEnvelope = loud
            ? min(sustainEnvelope + 1.0 / 60.0, 1)
            : max(sustainEnvelope - 1.0 / 15.0, 0)

        // Silence is the inverse, deliberately slower so repair feels gradual.
        silenceEnvelope = loud
            ? 0
            : min(silenceEnvelope + 1.0 / 90.0, 1)

        let snapshot = AudioReactiveSnapshot(
            rms: level,
            bass: bass,
            mid: mid,
            treble: treble,
            peak: saturate(peak),
            dominantFrequency: dominantFrequency(binWidth: binWidth),
            transient: saturate(transientEnvelope),
            sustain: sustainEnvelope,
            silence: silenceEnvelope,
            spectrum: logSpectrum(binWidth: binWidth)
        )
        handlerLock.withLock { handler }?(snapshot)
    }

    /// Strongest spectral bin between 150 Hz and 2 kHz — the range where a
    /// held humming note lands.
    private func dominantFrequency(binWidth: Float) -> Float {
        let lower = min(max(Int(150.0 / max(binWidth, 1)), 1), magnitudes.count - 1)
        let upper = min(max(Int(2000.0 / max(binWidth, 1)), lower + 1), magnitudes.count)
        guard lower < upper else { return 0 }
        var peakMagnitude: Float = 0
        var peakIndex = vDSP_Length.zero
        magnitudes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vDSP_maxmgvi(
                base + lower,
                1,
                &peakMagnitude,
                &peakIndex,
                vDSP_Length(upper - lower)
            )
        }
        guard peakMagnitude > 0 else { return 0 }
        return (Float(lower) + Float(peakIndex)) * binWidth
    }

    /// Sixteen bands spaced logarithmically across 40 Hz - 14 kHz.
    ///
    /// Log spacing rather than linear because a linear split puts thirteen of
    /// sixteen bands above 4 kHz, where almost nothing lives, and draws a
    /// spectrum that is flat everywhere the music actually is.
    private func logSpectrum(binWidth: Float) -> SIMD16<Float> {
        var bands = SIMD16<Float>()
        let lowest: Float = 40
        let highest: Float = 14_000
        let ratio = highest / lowest
        for index in 0 ..< 16 {
            let low = lowest * pow(ratio, Float(index) / 16)
            let high = lowest * pow(ratio, Float(index + 1) / 16)
            bands[index] = normalizedEnergy(from: low, through: high, binWidth: binWidth)
        }
        return bands
    }

    private func normalizedEnergy(from low: Float, through high: Float, binWidth: Float) -> Float {
        let lower = min(max(Int(low / max(binWidth, 1)), 1), magnitudes.count - 1)
        let upper = min(max(Int(high / max(binWidth, 1)), lower + 1), magnitudes.count)
        guard lower < upper else { return 0 }
        var energy: Float = 0
        for index in lower ..< upper {
            energy += magnitudes[index]
        }
        let mean = energy / Float(upper - lower)
        return saturate(log10(1 + mean) * 0.82)
    }

    private func saturate(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}
