import Combine
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import simd
import UIKit

// MARK: - Esoteric designations

/// Procedural designation generator for tracked blobs. Deterministic for a
/// given (seed, index) pair so a blob keeps the same designation across frames
/// while the field itself is never reused.
enum EsotericLabelGenerator {
    private static let prefixes = [
        "VESPER", "THROAT", "ATRIUM", "SPECTER", "ORACLE", "HALCYON", "MONAD",
        "CHORUS", "AURIC", "NULL", "TELEM", "VEXIL", "OPHIDIAN", "CLOTHO",
        "CIPHER", "SABLE", "ARCANE", "LUCID", "EMPYREAN", "NOCTURNE"
    ]
    private static let stems = [
        "RING", "CORE", "VEIL", "TOOTH", "MIRROR", "GATE", "FONT", "SPINE",
        "LOOM", "WELL", "FOLD", "SIGNAL", "CIRCUIT", "HUM", "SHELL"
    ]
    private static let qualifiers = [
        "OF THE NEST", "BENEATH THE GRID", "AFTER CONTACT", "IN DELTA",
        "AT TERMINAL", "BEYOND RECALL", "UNDER GLASS", "WITHOUT NAME"
    ]
    private static let deltas = ["Δ", "Ω", "Σ", "Ψ", "Λ", "Θ"]

    static func label(for seed: UInt64, index: Int) -> String {
        let mixer = (seed &+ UInt64(index)) &* 0x9E37_79B9_7F4A_7C15
        let prefix = prefixes[Int((mixer >> 0) % UInt64(prefixes.count))]
        let stem = stems[Int((mixer >> 8) % UInt64(stems.count))]
        let qualifier = qualifiers[Int((mixer >> 16) % UInt64(qualifiers.count))]
        let delta = deltas[Int((mixer >> 24) % UInt64(deltas.count))]
        let numeral = UInt64((mixer >> 32) % 97) + 1
        return switch Int((mixer >> 40) % 3) {
        case 0: "\(prefix)-\(numeral)"
        case 1: "\(stem) \(delta) \(prefix)-\(numeral)"
        default: "\(prefix) \(qualifier) // \(numeral)"
        }
    }
}

// MARK: - Tracker

/// The analysis pipeline: analysis frame in, tracked subjects out.
///
/// Frames arrive from `GVTrackingFeed`, already throttled to the analysis
/// rate, and are processed one at a time on a private serial queue — a frame
/// that arrives while a pass is running replaces the waiting one rather than
/// queueing behind it. The detector is chosen by mode, and switching mode
/// resets identity, because a face and a red field are not the same subject.
final class BlobTracker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.saringrey.greyvision.tracking", qos: .userInitiated)
    private let lock = NSLock()
    private var parameters = BlobTrackingParameters.defaults
    private var pending: GVTrackingFrame?
    private var draining = false
    private var resultHandler: (@Sendable (BlobAnalysisResult) -> Void)?

    // Queue-confined.
    private let field = GVFieldDetector()
    private let vision = GVVisionDetector()
    private let associator = GVTrackAssociator()
    private var lastMode: GVTrackingMode?
    private var passTimes: [Double] = []

    func setParameters(_ parameters: BlobTrackingParameters) {
        lock.withLock { self.parameters = parameters.sanitized }
    }

    func start(resultHandler: @escaping @Sendable (BlobAnalysisResult) -> Void) {
        lock.withLock {
            self.resultHandler = resultHandler
            pending = nil
        }
        queue.async { [self] in
            associator.reset()
            field.reset()
            lastMode = nil
            passTimes = []
        }
    }

    func stop() {
        lock.withLock {
            resultHandler = nil
            pending = nil
        }
    }

    func submit(_ frame: GVTrackingFrame) {
        let shouldDrain = lock.withLock { () -> Bool in
            guard resultHandler != nil else { return false }
            pending = frame
            guard !draining else { return false }
            draining = true
            return true
        }
        guard shouldDrain else { return }
        queue.async { [self] in drain() }
    }

    private func drain() {
        while true {
            let next = lock.withLock { () -> (GVTrackingFrame, BlobTrackingParameters, (@Sendable (BlobAnalysisResult) -> Void))? in
                guard let frame = pending, let handler = resultHandler else {
                    draining = false
                    return nil
                }
                pending = nil
                return (frame, parameters, handler)
            }
            guard let (frame, parameters, handler) = next else { return }
            handler(analyze(frame, parameters: parameters))
        }
    }

    private func analyze(_ frame: GVTrackingFrame, parameters: BlobTrackingParameters) -> BlobAnalysisResult {
        if lastMode != parameters.mode {
            associator.reset()
            field.reset()
            lastMode = parameters.mode
        }
        let detections: [GVTrackingDetection]
        var mask: GVTrackingMask?
        var problem: String?
        if parameters.mode.usesVision {
            let output = vision.detect(frame, parameters: parameters)
            detections = output.detections
            problem = output.error
        } else {
            let output = field.detect(frame, parameters: parameters)
            detections = output.detections
            mask = output.mask
        }
        let blobs = associator.update(detections, at: frame.timestamp, parameters: parameters)

        passTimes.append(frame.timestamp)
        passTimes.removeAll { frame.timestamp - $0 > 1 }
        let rate = Double(passTimes.count)

        let noun = parameters.mode.noun
        let status = if let problem {
            "\(parameters.mode.label.uppercased()) // \(problem)"
        } else if blobs.isEmpty {
            "\(parameters.mode.label.uppercased()) // SEARCHING // \(Int(rate)) HZ"
        } else {
            "\(parameters.mode.label.uppercased()) // \(blobs.count) \(noun)\(blobs.count == 1 ? "" : "S") // \(Int(rate)) HZ"
        }
        return BlobAnalysisResult(
            blobs: blobs,
            status: status,
            sourceSize: CGSize(width: frame.width, height: frame.height),
            timestamp: frame.timestamp,
            mask: mask,
            passRate: rate,
            region: frame.region
        )
    }
}

// MARK: - Runtime

/// The tracking suite's state for the interface: parameters, the latest
/// tracked subjects, and the feed the renderer fills.
@MainActor
final class BlobTrackingRuntime: ObservableObject {
    @Published private(set) var parameters: BlobTrackingParameters
    @Published private(set) var isEnabled = false
    @Published private(set) var blobs: [TrackedBlob] = []
    @Published private(set) var status = "TRACKING // OFFLINE"
    @Published private(set) var sourceSize = CGSize.zero
    @Published private(set) var resultTimestamp: Double = 0
    @Published private(set) var mask: GVTrackingMask?
    @Published private(set) var passRate: Double = 0
    /// The analysed region within the full working frame. Subjects are in
    /// this region's coordinates; effects sampling the full frame map back.
    @Published private(set) var region = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Handed to the renderer, which fills it while tracking is enabled.
    nonisolated let feed = GVTrackingFeed()

    private let tracker = BlobTracker()
    private let defaults: UserDefaults
    private static let storageKey = "gv.tracking.parameters.v2"
    private var lastBlobCount = 0
    private var lastBlobHapticTime: TimeInterval = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        parameters = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(BlobTrackingParameters.self, from: $0) }?
            .sanitized ?? .defaults
    }

    func setParameters(_ parameters: BlobTrackingParameters) {
        let sanitized = parameters.sanitized
        guard sanitized != self.parameters else { return }
        self.parameters = sanitized
        tracker.setParameters(sanitized)
        feed.setRate(sanitized.rate)
        if let data = try? JSONEncoder().encode(sanitized) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// Applies a preset and starts tracking if it is not already running.
    func apply(_ preset: GVTrackingPreset) {
        setParameters(preset.parameters)
        start()
    }

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        status = "\(parameters.mode.label.uppercased()) // ANALYZING"
        tracker.setParameters(parameters)
        tracker.start { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, isEnabled else { return }
                blobs = result.blobs
                status = result.status
                sourceSize = result.sourceSize
                resultTimestamp = result.timestamp
                mask = result.mask
                passRate = result.passRate
                region = result.region
                feed.publish(GVTrackingSnapshot(
                    parameters: parameters, blobs: result.blobs, mask: result.mask,
                    region: result.region, passRate: result.passRate, timestamp: result.timestamp
                ))
                pulseFieldHaptic(count: result.blobs.count)
            }
        }
        feed.attach(rate: parameters.rate) { [tracker] frame in
            tracker.submit(frame)
        }
        GVLog.analysis.notice("Tracking started: \(self.parameters.mode.rawValue, privacy: .public)")
    }

    func stop() {
        guard isEnabled else { return }
        isEnabled = false
        feed.detach()
        tracker.stop()
        blobs = []
        mask = nil
        status = "TRACKING // OFFLINE"
        lastBlobCount = 0
        GVLog.analysis.notice("Tracking stopped")
    }

    /// A single selection tick when the tracked count changes, gated to one
    /// per second so a jittery field does not stutter the haptic.
    private func pulseFieldHaptic(count: Int) {
        let now = CACurrentMediaTime()
        guard count != lastBlobCount, now - lastBlobHapticTime > 1 else {
            lastBlobCount = count
            return
        }
        lastBlobCount = count
        lastBlobHapticTime = now
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
