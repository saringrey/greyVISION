import Combine
import Foundation
import SwiftUI

// MARK: - Gesture Types

/// Represents the different gesture types in the system
enum GestureType: String, CaseIterable, Comparable {
    case signalFracture
    case timeScrub
    case modulationOrbit

    static func < (lhs: GestureType, rhs: GestureType) -> Bool {
        lhs.priority < rhs.priority
    }
}

// MARK: - Gesture Priority

extension GestureType {
    /// Priority level for gesture conflict resolution (higher number = higher priority)
    var priority: Int {
        switch self {
        case .signalFracture:
            return 3 // Highest priority - two-finger pinch-out
        case .timeScrub:
            return 2 // Medium priority - touch-and-hold
        case .modulationOrbit:
            return 1 // Lower priority - circular gesture
        }
    }

    /// Human-readable description
    var description: String {
        switch self {
        case .signalFracture:
            return "Signal Fracture (Two-Finger Pinch)"
        case .timeScrub:
            return "Time Scrub (Touch-and-Hold)"
        case .modulationOrbit:
            return "Modulation Orbit (Circular)"
        }
    }
}

// MARK: - Gesture State

/// Represents the lifecycle state of a gesture
enum GestureState: Equatable {
    case idle
    case pending(startTime: Date)
    case active(startTime: Date)
    case conflicted(with: GestureType)
    case timedOut
    case completed
    case cancelled

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
}

// MARK: - Gesture Registration

/// Tracks a registered gesture's state and metadata
struct GestureRegistration: Equatable {
    let type: GestureType
    var state: GestureState
    var registeredAt: Date
    var lastUpdated: Date
    var touchCount: Int
    var timeoutDuration: TimeInterval

    init(
        type: GestureType,
        state: GestureState = .idle,
        touchCount: Int = 1,
        timeoutDuration: TimeInterval = 3.0
    ) {
        self.type = type
        self.state = state
        self.touchCount = touchCount
        self.timeoutDuration = timeoutDuration
        self.registeredAt = Date()
        self.lastUpdated = Date()
    }

    /// Check if gesture has timed out
    func hasTimedOut() -> Bool {
        guard case let .active(startTime) = state else { return false }
        return Date().timeIntervalSince(startTime) > timeoutDuration
    }

    /// Duration since last update
    var timeSinceLastUpdate: TimeInterval {
        Date().timeIntervalSince(lastUpdated)
    }
}

// MARK: - Gesture Conflict

/// Represents a conflict between gestures
struct GestureConflict: Equatable {
    let requestingGesture: GestureType
    let activeGesture: GestureType
    let resolvedInFavorOf: GestureType
    let timestamp: Date

    init(
        requesting: GestureType,
        active: GestureType,
        timestamp: Date = Date()
    ) {
        self.requestingGesture = requesting
        self.activeGesture = active
        // Higher priority wins
        self.resolvedInFavorOf = requesting.priority > active.priority ? requesting : active
        self.timestamp = timestamp
    }
}

// MARK: - GestureStateRegistry

/// Centralized registry for managing gesture states and resolving conflicts
@MainActor
final class GestureStateRegistry: ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var registrations: [GestureType: GestureRegistration] = [:]
    @Published private(set) var activeGesture: GestureType?
    @Published private(set) var conflictHistory: [GestureConflict] = []

    // MARK: - Private Properties

    private var timeoutTimers: [GestureType: Timer] = [:]
    private let maxConflictHistory = 50

    // MARK: - Configuration

    /// Default timeout durations for each gesture type
    private let defaultTimeouts: [GestureType: TimeInterval] = [
        .signalFracture: 3.0, // Requirement 4.6: Auto-exit after 3s inactivity
        .timeScrub: 30.0, // Requirement 5.6: Max 30s scrub duration
        .modulationOrbit: 10.0 // Requirement 7.7: Deactivate after 10s
    ]

    // MARK: - Initialization

    init() {
        // Initialize all gesture types as idle
        for gestureType in GestureType.allCases {
            registrations[gestureType] = GestureRegistration(
                type: gestureType,
                state: .idle,
                timeoutDuration: defaultTimeouts[gestureType] ?? 3.0
            )
        }
    }

    // MARK: - Gesture Registration

    /// Register a gesture request and handle conflict resolution
    /// - Parameters:
    ///   - gestureType: The type of gesture requesting activation
    ///   - touchCount: Number of touches involved
    /// - Returns: True if gesture can proceed, false if blocked by conflict
    @discardableResult
    func requestActivation(for gestureType: GestureType, touchCount: Int = 1) -> Bool {
        guard var registration = registrations[gestureType] else { return false }

        // Check for conflicts with active gestures
        if let active = activeGesture, active != gestureType {
            let conflict = GestureConflict(requesting: gestureType, active: active)
            recordConflict(conflict)

            // If requesting gesture has higher priority, deactivate current
            if conflict.resolvedInFavorOf == gestureType {
                cancelGesture(active)
            } else {
                // Request denied, mark as conflicted
                registration.state = .conflicted(with: active)
                registration.lastUpdated = Date()
                registrations[gestureType] = registration
                return false
            }
        }

        // Set gesture to pending state
        registration.state = .pending(startTime: Date())
        registration.touchCount = touchCount
        registration.lastUpdated = Date()
        registrations[gestureType] = registration

        return true
    }

    /// Activate a gesture (transition from pending to active)
    /// - Parameter gestureType: The gesture to activate
    /// - Returns: True if successfully activated
    @discardableResult
    func activateGesture(_ gestureType: GestureType) -> Bool {
        guard var registration = registrations[gestureType] else { return false }
        guard case .pending = registration.state else { return false }

        let startTime = Date()
        registration.state = .active(startTime: startTime)
        registration.lastUpdated = startTime
        registrations[gestureType] = registration

        activeGesture = gestureType

        // Start timeout timer
        startTimeoutTimer(for: gestureType)

        return true
    }

    // MARK: - Gesture State Updates

    /// Update the last activity time for a gesture (resets timeout)
    /// - Parameter gestureType: The gesture to update
    func updateActivity(for gestureType: GestureType) {
        guard var registration = registrations[gestureType] else { return }
        guard case .active = registration.state else { return }

        registration.lastUpdated = Date()
        registrations[gestureType] = registration

        // Reset timeout timer
        resetTimeoutTimer(for: gestureType)
    }

    /// Complete a gesture successfully
    /// - Parameter gestureType: The gesture to complete
    func completeGesture(_ gestureType: GestureType) {
        guard var registration = registrations[gestureType] else { return }

        registration.state = .completed
        registration.lastUpdated = Date()
        registrations[gestureType] = registration

        if activeGesture == gestureType {
            activeGesture = nil
        }

        cancelTimeoutTimer(for: gestureType)

        // Return to idle after brief delay
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            self.resetGesture(gestureType)
        }
    }

    /// Cancel a gesture
    /// - Parameter gestureType: The gesture to cancel
    func cancelGesture(_ gestureType: GestureType) {
        guard var registration = registrations[gestureType] else { return }

        registration.state = .cancelled
        registration.lastUpdated = Date()
        registrations[gestureType] = registration

        if activeGesture == gestureType {
            activeGesture = nil
        }

        cancelTimeoutTimer(for: gestureType)

        // Return to idle immediately
        resetGesture(gestureType)
    }

    /// Reset a gesture to idle state
    /// - Parameter gestureType: The gesture to reset
    func resetGesture(_ gestureType: GestureType) {
        guard var registration = registrations[gestureType] else { return }

        registration.state = .idle
        registration.lastUpdated = Date()
        registrations[gestureType] = registration

        if activeGesture == gestureType {
            activeGesture = nil
        }

        cancelTimeoutTimer(for: gestureType)
    }

    // MARK: - Timeout Handling

    private func startTimeoutTimer(for gestureType: GestureType) {
        guard let registration = registrations[gestureType] else { return }

        cancelTimeoutTimer(for: gestureType)

        let timer = Timer.scheduledTimer(
            withTimeInterval: registration.timeoutDuration,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleTimeout(for: gestureType)
            }
        }

        timeoutTimers[gestureType] = timer
    }

    private func resetTimeoutTimer(for gestureType: GestureType) {
        startTimeoutTimer(for: gestureType)
    }

    private func cancelTimeoutTimer(for gestureType: GestureType) {
        timeoutTimers[gestureType]?.invalidate()
        timeoutTimers[gestureType] = nil
    }

    private func handleTimeout(for gestureType: GestureType) {
        guard var registration = registrations[gestureType] else { return }
        guard case .active = registration.state else { return }

        registration.state = .timedOut
        registration.lastUpdated = Date()
        registrations[gestureType] = registration

        if activeGesture == gestureType {
            activeGesture = nil
        }

        // Return to idle after timeout
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            self.resetGesture(gestureType)
        }
    }

    // MARK: - Conflict Resolution

    private func recordConflict(_ conflict: GestureConflict) {
        conflictHistory.append(conflict)

        // Keep history size manageable
        if conflictHistory.count > maxConflictHistory {
            conflictHistory.removeFirst()
        }
    }

    /// Check if a gesture can be activated given the current state
    /// - Parameter gestureType: The gesture to check
    /// - Returns: True if gesture can activate
    func canActivate(_ gestureType: GestureType) -> Bool {
        guard let registration = registrations[gestureType] else { return false }

        // Must be idle or pending to activate
        guard registration.state == .idle || registration.state.isPending else {
            return false
        }

        // If there's an active gesture, check priority
        if let active = activeGesture, active != gestureType {
            return gestureType.priority > registrations[active]?.type.priority ?? 0
        }

        return true
    }

    /// Get the current state of a gesture
    /// - Parameter gestureType: The gesture to query
    /// - Returns: The current gesture state
    func getState(for gestureType: GestureType) -> GestureState {
        registrations[gestureType]?.state ?? .idle
    }

    /// Check if a specific gesture is currently active
    /// - Parameter gestureType: The gesture to check
    /// - Returns: True if the gesture is active
    func isActive(_ gestureType: GestureType) -> Bool {
        activeGesture == gestureType
    }

    // MARK: - Diagnostics

    /// Get all active registrations
    var activeRegistrations: [GestureRegistration] {
        registrations.values.filter(\.state.isActive)
    }

    /// Get conflict count for a specific gesture type
    /// - Parameter gestureType: The gesture to query
    /// - Returns: Number of conflicts involving this gesture
    func conflictCount(for gestureType: GestureType) -> Int {
        conflictHistory.filter {
            $0.requestingGesture == gestureType || $0.activeGesture == gestureType
        }.count
    }

    /// Reset all gestures to idle state
    func resetAll() {
        for gestureType in GestureType.allCases {
            cancelTimeoutTimer(for: gestureType)
            resetGesture(gestureType)
        }
        activeGesture = nil
        conflictHistory.removeAll()
    }
}

// MARK: - Convenience Extensions

extension GestureStateRegistry {
    /// Check if any gesture is currently active
    var hasActiveGesture: Bool {
        activeGesture != nil
    }

    /// Get recent conflicts (last 10)
    var recentConflicts: [GestureConflict] {
        Array(conflictHistory.suffix(10))
    }
}
