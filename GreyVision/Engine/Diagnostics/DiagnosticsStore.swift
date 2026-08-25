import Foundation

actor DiagnosticsStore {
    private var current = DiagnosticsSnapshot.initial

    func snapshot() -> DiagnosticsSnapshot {
        current
    }

    func update(_ mutation: @Sendable (inout DiagnosticsSnapshot) -> Void) {
        mutation(&current)
    }

    func reset() {
        current = .initial
    }
}
