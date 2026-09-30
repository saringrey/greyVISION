import Combine
import Foundation

/// Real-time beat tracker derived from the existing `AudioReactiveSnapshot`.
///
/// The audio analyser already publishes per-frame `bass`, `mid`, `treble`,
/// `peak` and `transient`. This layer runs an onset detector + tempo estimator
/// on top of those values and publishes a stream of `GVBeatEvent`s to
/// subscribers. The detector is adaptive — it listens to the live signal, not
/// a fixed threshold — so a quiet room and a club mix both produce clean cues.
@MainActor
final class GVBeatDetector: ObservableObject {
    @Published private(set) var bpm: Double = 0
    @Published private(set) var confidence: Double = 0
    @Published private(set) var phase: Double = 0
    @Published private(set) var isLocked: Bool = false

    /// 0...1 strength of the most recent onset, for visual flash.
    @Published private(set) var lastOnsetStrength: Double = 0

    private let subject = PassthroughSubject<GVBeatEvent, Never>()
    var publisher: AnyPublisher<GVBeatEvent, Never> { subject.eraseToAnyPublisher() }

    private weak var audio: AudioReactiveRuntime?
    private var subscription: AnyCancellable?
    private var onsetHistory: [TimeInterval] = []
    private var bpmEstimate: Double = 0
    private var phaseAccumulator: Double = 0
    private var lastOnsetAt: TimeInterval = 0
    private let historyWindow: TimeInterval = 4
    private let bpmMin: Double = 60
    private let bpmMax: Double = 200
    private var prevEnergy: Double = 0
    private var smoothedFlux: Double = 0
    private let fluxAlpha: Double = 0.15
    private let onsetThreshold: Double = 1.4
    private let refractorySeconds: TimeInterval = 0.18

    func attach(audio: AudioReactiveRuntime) {
        self.audio = audio
        subscription = audio.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                if state != .running {
                    self.reset()
                }
            }
    }

    private func reset() {
        onsetHistory.removeAll()
        bpmEstimate = 0
        confidence = 0
        bpm = 0
        phase = 0
        lastOnsetStrength = 0
        prevEnergy = 0
        smoothedFlux = 0
        isLocked = false
    }

    /// Pumps the detector with the current audio snapshot. Call once per
    /// animation tick (the existing 30/60 Hz loop is fine — it gives finer
    /// onset resolution than the audio frame rate).
    func tick(snapshot: AudioReactiveSnapshot, now: TimeInterval) {
        // Energy is a weighted sum of bass and mid — kick + snare territory.
        let energy = Double(snapshot.bass) * 0.65 + Double(snapshot.mid) * 0.35
        let flux = max(0, energy - prevEnergy)
        prevEnergy = energy
        smoothedFlux = smoothedFlux + (flux - smoothedFlux) * fluxAlpha
        let localMean = max(smoothedFlux, 0.0001)
        let onset = flux / localMean

        let sinceLast = now - lastOnsetAt
        if onset > onsetThreshold, sinceLast > refractorySeconds {
            lastOnsetAt = now
            lastOnsetStrength = min(max(onset / 4, 0), 1)
            registerOnset(at: now)
        } else {
            lastOnsetStrength *= 0.86
        }
    }

    private func registerOnset(at now: TimeInterval) {
        onsetHistory.append(now)
        onsetHistory = onsetHistory.filter { now - $0 < historyWindow }

        if let bpm = estimateBPM(now: now) {
            bpmEstimate = bpm
            self.bpm = bpm
            confidence = min(Double(onsetHistory.count) / 12, 1)
            isLocked = confidence > 0.5
            subject.send(.onset(strength: lastOnsetStrength, at: now))
            if isLocked {
                phaseAccumulator += 1
                let beatPeriod = 60.0 / bpm
                phase = (now / beatPeriod).truncatingRemainder(dividingBy: 1)
                if isOnDownbeat(history: onsetHistory, now: now, bpm: bpm) {
                    subject.send(.downbeat(bpm: bpm, at: now))
                }
            }
        } else {
            subject.send(.onset(strength: lastOnsetStrength, at: now))
        }
    }

    private func estimateBPM(now _: TimeInterval) -> Double? {
        guard onsetHistory.count >= 4 else { return nil }
        let intervals = zip(onsetHistory.dropFirst(), onsetHistory).map { $0 - $1 }
        // Cluster intervals into BPM bins and pick the densest cluster.
        var bins: [Int: Int] = [:]
        for interval in intervals {
            let bpm = 60.0 / interval
            guard bpm >= bpmMin, bpm <= bpmMax else { continue }
            let bin = Int((bpm - bpmMin) / 2)
            bins[bin, default: 0] += 1
        }
        guard let (bin, count) = bins.max(by: { $0.value < $1.value }) else { return nil }
        guard count >= 2 else { return nil }
        return Double(bin) * 2 + bpmMin + 1
    }

    private func isOnDownbeat(history: [TimeInterval], now: TimeInterval, bpm: Double) -> Bool {
        let beatPeriod = 60.0 / bpm
        guard let first = history.first else { return false }
        let beatsFromStart = (now - first) / beatPeriod
        return abs(beatsFromStart - beatsFromStart.rounded()) < 0.12
    }
}

/// A single beat event. `onset` is a transient trigger; `downbeat` fires when
/// the detector is confident enough to mark the start of a measure.
enum GVBeatEvent: Sendable {
    case onset(strength: Double, at: TimeInterval)
    case downbeat(bpm: Double, at: TimeInterval)
}
