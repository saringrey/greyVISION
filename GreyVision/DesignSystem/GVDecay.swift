import SwiftUI

/// What the machine is reacting to.
///
/// Corruption is an event, not a texture. The interface is precise enough the
/// rest of the time that a 120ms fracture reads as the instrument being
/// disturbed rather than as decoration that happens to be animating.
enum GVDecayEvent: Equatable, Sendable {
    case boot
    case effectActivated
    case effectExtreme
    case recordingStarted
    case recordingStopped
    case lensChanged
    case thermalWarning
    case stackChanged
    case developerMode

    /// Deliberately short. The longest non-boot event is a third of a second;
    /// anything longer stops reading as a glitch and starts reading as a
    /// transition the operator has to wait through.
    var duration: TimeInterval {
        switch self {
        case .boot: 1.2
        case .effectActivated, .stackChanged: 0.20
        case .effectExtreme: 0.10
        case .recordingStarted, .recordingStopped: 0.16
        case .lensChanged: 0.28
        case .thermalWarning: 0.32
        case .developerMode: 0.24
        }
    }

    /// How hard it hits, 0...1.
    var severity: Double {
        switch self {
        case .boot: 1.0
        case .lensChanged, .thermalWarning: 0.8
        case .effectActivated, .stackChanged: 0.6
        case .recordingStarted, .recordingStopped: 0.45
        case .developerMode: 0.5
        case .effectExtreme: 0.3
        }
    }

    /// Only real faults are allowed to look like faults.
    var tint: Color {
        switch self {
        case .thermalWarning: GVTheme.warn
        case .recordingStarted, .recordingStopped: GVTheme.record
        default: GVTheme.violet
        }
    }
}

/// One decay state for the whole interface.
///
/// Views subscribe to this instead of each running its own corruption
/// animation. That is what keeps a fracture reading as one machine-wide event
/// rather than six unrelated things twitching at slightly different times.
@MainActor
final class GVDecayEngine: ObservableObject {
    @Published private(set) var event: GVDecayEvent?
    /// When the current event started, so views derive progress from the clock
    /// instead of each holding an animation.
    @Published private(set) var startedAt: Date = .distantPast

    private var clearTask: Task<Void, Never>?

    func fire(_ event: GVDecayEvent) {
        // A higher-severity event interrupts a lower one; the reverse is
        // ignored, so a stream of parameter changes cannot stamp on the
        // fracture from arming a take.
        if let current = self.event, current.severity > event.severity { return }

        self.event = event
        startedAt = .now
        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(event.duration))
            guard !Task.isCancelled, self?.event == event else { return }
            self?.event = nil
        }
    }

    /// Progress through the active event, 0...1.
    func progress(at date: Date) -> Double {
        guard let event else { return 0 }
        let elapsed = date.timeIntervalSince(startedAt)
        return min(max(elapsed / event.duration, 0), 1)
    }

    func stop() {
        clearTask?.cancel()
        clearTask = nil
        event = nil
    }
}

extension View {
    /// Subscribes a view to the shared decay state.
    ///
    /// Displacement and separation only — no blur, no shader, no offscreen
    /// pass. At 100% GPU with datamosh running there is no headroom for a
    /// full-preview effect, and an offset is nearly free.
    func gvDecay(_ engine: GVDecayEngine, scale: Double = 1) -> some View {
        modifier(GVDecayModifier(engine: engine, scale: scale))
    }
}

private struct GVDecayModifier: ViewModifier {
    @ObservedObject var engine: GVDecayEngine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let scale: Double

    func body(content: Content) -> some View {
        if engine.event == nil || reduceMotion {
            // No TimelineView while idle. A per-frame clock left running on
            // every decorated view was the cheapest thing to get wrong here.
            content
        } else {
            TimelineView(.animation(minimumInterval: 1 / 60, paused: false)) { timeline in
                let progress = engine.progress(at: timeline.date)
                let event = engine.event
                let severity = (event?.severity ?? 0) * scale
                // Hits hard, decays out. A symmetric envelope reads as a
                // pulse; this reads as an impact.
                let envelope = pow(1 - progress, 2.2)
                let amount = severity * envelope
                let tear = tearOffset(progress: progress, amount: amount)

                content
                    .offset(x: tear)
                    .overlay {
                        // Channel separation, drawn as two offset copies
                        // rather than a shader.
                        if amount > 0.02 {
                            content
                                .foregroundStyle(GVTheme.record.opacity(amount * 0.5))
                                .offset(x: -tear * 1.6)
                                .blendMode(.screen)
                                .allowsHitTesting(false)

                            content
                                .foregroundStyle((event?.tint ?? GVTheme.violet).opacity(amount * 0.5))
                                .offset(x: tear * 1.6)
                                .blendMode(.screen)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
    }

    /// Stepped rather than smooth: sampled from a hash so the displacement
    /// jumps between discrete values the way a broken signal does, instead of
    /// sliding sinusoidally like an animation.
    private func tearOffset(progress: Double, amount: Double) -> CGFloat {
        let slice = Int(progress * 14)
        let hash = sin(Double(slice) * 127.1) * 43_758.5453
        let noise = hash - hash.rounded(.down)
        return CGFloat((noise - 0.5) * 14 * amount)
    }
}
