import Foundation
import Observation

@MainActor @Observable
final class GVCaptureCountdown {
    enum Intent: Equatable {
        case photo, video
    }

    enum Delay: Int, CaseIterable, Identifiable {
        case off = 0, three = 3, ten = 10, thirty = 30

        var id: Int { rawValue }
        var label: String { self == .off ? "Off" : "\(rawValue)s" }
    }

    private(set) var remaining = 0
    private(set) var deadline: ContinuousClock.Instant?
    private var intent: Intent?
    private var tickTask: Task<Void, Never>?

    /// Starts the countdown and owns the clock that drives it.
    ///
    /// The task lives here rather than in the view because `WorkspaceView` is a
    /// struct: a timer started from a render pass is re-created by the next one,
    /// and the only thing that can hold a shutter across renders is the model.
    func run(_ intent: Intent, delay: Delay, onFire: @escaping @MainActor (Intent) -> Void) {
        cancel()
        start(intent, delay: delay)
        tickTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
                if let fired = self.advance() {
                    onFire(fired)
                    return
                }
            }
        }
    }

    func start(_ intent: Intent, delay: Delay, now: ContinuousClock.Instant = .now) {
        self.intent = intent
        remaining = delay.rawValue
        deadline = now.advanced(by: .seconds(delay.rawValue))
    }

    func advance(at now: ContinuousClock.Instant = .now) -> Intent? {
        guard let deadline else { return nil }
        if now >= deadline {
            let completed = intent
            cancel()
            return completed
        }
        let duration = now.duration(to: deadline).components
        // Only publish a change. The tick runs ten times a second and the
        // displayed number moves once a second; writing the same value every
        // tick invalidates the whole workspace chrome ten times a second.
        let next = Int(duration.seconds) + (duration.attoseconds > 0 ? 1 : 0)
        if next != remaining { remaining = next }
        return nil
    }

    func cancel() {
        tickTask?.cancel()
        tickTask = nil
        intent = nil
        deadline = nil
        remaining = 0
    }
}
