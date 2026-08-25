import SwiftUI

/// Which telemetry field the operator is currently driving.
///
/// What each one can actually do is `GVFieldControl`'s business — some have
/// live setters, some need the session reconfigured, and one has no setter
/// anywhere. This is only the identity and the names.
enum GVTelemetryField: String, CaseIterable, Sendable {
    case frameRate
    case resolution
    case shutter
    case iso
    case whiteBalance
    case dynamicRange
    case codec
    case zoom
    case exposure

    /// True for the fields whose setters drop the device out of continuous
    /// auto-exposure. These are the ones that have to show they are manual and
    /// the ones that hand metering back.
    var holdsExposure: Bool {
        switch self {
        case .iso, .shutter: true
        default: false
        }
    }

    /// Short form. Used where the label sits beside the value in a dense row.
    var railLabel: String {
        switch self {
        case .frameRate: "FPS"
        case .resolution: "RES"
        case .shutter: "SHUT"
        case .iso: "ISO"
        case .whiteBalance: "WB"
        case .dynamicRange: "RANGE"
        case .codec: "CODEC"
        case .zoom: "ZOOM"
        case .exposure: "EXP"
        }
    }

    /// Long form. Used at the head of the field's own control, where there is
    /// room to say what it is rather than abbreviate it.
    var controlLabel: String {
        switch self {
        case .frameRate: "FRAME RATE"
        case .resolution: "RESOLUTION"
        case .shutter: "SHUTTER"
        case .iso: "ISO"
        case .whiteBalance: "WHITE BALANCE"
        case .dynamicRange: "DYNAMIC RANGE"
        case .codec: "CODEC"
        case .zoom: "ZOOM"
        case .exposure: "EXPOSURE"
        }
    }
}

/// Presentation state for the camera HUD.
///
/// Deliberately narrow. Capture state lives in `CameraRuntime` and effect
/// state in the workspace bindings; this owns only what the interface is
/// currently showing, so there is no second copy of anything the engine knows.
@MainActor
final class GVHUDState: ObservableObject {
    /// Field the operator tapped. Nil when no field control is open.
    @Published var activeField: GVTelemetryField?

    /// Set while a scrub is in flight, so the idle timer holds off rather than
    /// closing the control under the operator's finger.
    @Published var isAdjusting = false

    /// Collapses secondary chrome during a take.
    @Published var recordingFocus = false

    /// Momentarily reveals full chrome during recording focus.
    @Published var revealUntil: Date?

    private var dismissTask: Task<Void, Never>?
    /// When the operator last touched the open control. A scrub writes on
    /// every frame of the gesture, so the idle timer reads this rather than
    /// being torn down and rebuilt sixty times a second.
    private var lastTouch = Date.now
    /// How long an untouched control stays open.
    private static let idleTimeout: TimeInterval = 4

    var isChromeRevealed: Bool {
        guard let revealUntil else { return false }
        return revealUntil > .now
    }

    /// Selecting the field already selected clears it, so a second tap on ISO
    /// puts the rail back to idle rather than requiring a tap elsewhere.
    func select(_ field: GVTelemetryField) {
        withAnimation(GVMotion.scan) {
            activeField = activeField == field ? nil : field
        }
        scheduleIdle()
    }

    func clearField() {
        dismissTask?.cancel()
        dismissTask = nil
        withAnimation(GVMotion.collapse) {
            activeField = nil
            isAdjusting = false
        }
    }

    /// Controls fall back to idle on their own. Without this the instrument
    /// sits showing a parameter the operator stopped touching a minute ago.
    ///
    /// One task, which waits out whatever is left of the window each time it
    /// wakes. `keepAlive` only moves the deadline.
    private func scheduleIdle() {
        dismissTask?.cancel()
        lastTouch = .now
        guard activeField != nil else {
            dismissTask = nil
            return
        }
        dismissTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                let remaining = Self.idleTimeout - Date.now.timeIntervalSince(lastTouch)
                guard remaining > 0 || isAdjusting else {
                    clearField()
                    return
                }
                try? await Task.sleep(for: .seconds(max(remaining, 0.25)))
            }
        }
    }

    /// Pushes the idle deadline out without rebuilding the timer. Safe to call
    /// on every frame of a drag.
    func keepAlive() {
        lastTouch = .now
        if dismissTask == nil, activeField != nil {
            scheduleIdle()
        }
    }

    func revealChrome(for seconds: TimeInterval = 3) {
        revealUntil = .now.addingTimeInterval(seconds)
    }

    func stop() {
        dismissTask?.cancel()
        dismissTask = nil
    }
}
