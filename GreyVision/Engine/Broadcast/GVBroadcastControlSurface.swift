import Foundation

// What the desktop is allowed to drive, and what it is currently driving.
//
// Shared verbatim with the macOS target. Like `GVBroadcastProtocol` this file
// imports nothing but Foundation, because the moment it needs UIKit or Metal
// the Mac has to reimplement it and the two descriptions drift apart.
//
// ## Why a catalogue rather than a shared enum
//
// `WorkspaceAdjustableEffect` has upwards of two hundred cases and gains more
// with every session. Copying it to the Mac would mean every new effect is a
// two-target change and an older Mac build silently fails to decode a stack
// containing anything it has not heard of.
//
// So the phone describes itself instead. It sends the effect identities, the
// labels it draws them with, the names of their three parameter channels and
// their defaults. The Mac renders whatever arrives. A phone that grows a new
// effect gains a new card on a desktop build that predates it, with correct
// labels, and no recompile.

// MARK: - Catalogue

/// One effect, as the desktop needs to draw it.
struct GVEffectDescriptor: Codable, Equatable, Sendable, Identifiable {
    /// `WorkspaceAdjustableEffect.rawValue`. The only identity that crosses
    /// the wire.
    var id: String
    /// The phone's own display label, so both screens name the effect the
    /// same way.
    var label: String
    /// Names for the primary/secondary/tertiary channels, in that order.
    /// Fewer than three means the effect genuinely has fewer knobs — the
    /// desktop draws what it is given rather than padding with "PARAM 3".
    var parameterLabels: [String]
    /// Defaults for primary, secondary, tertiary, blend — always four values,
    /// so the desktop can render a detent at the effect's home position and
    /// offer a meaningful reset.
    var defaults: [Double]
    /// Needs the microphone armed. The desktop greys these out when the phone
    /// reports audio unavailable rather than offering a control that renders
    /// against a silent uniform.
    var requiresAudioAnalysis: Bool
    /// Composited as a movable overlay, so `overlayX`/`overlayY` are real
    /// controls for this effect rather than inert fields.
    var isSpectrumOverlay: Bool
}

/// A named group of effects, mirroring the phone's dock families.
struct GVEffectFamily: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var label: String
    var effectIDs: [String]
}

/// Sent once per connection.
struct GVBroadcastControlSurface: Codable, Equatable, Sendable {
    /// Bumped when the *shape* of this payload changes. A Mac that does not
    /// recognise the value refuses to render controls rather than drawing a
    /// half-decoded surface.
    ///
    /// A constant rather than only a default, so the receiving side has
    /// something to compare against without constructing a whole surface.
    static let currentVersion = 1

    var surfaceVersion = GVBroadcastControlSurface.currentVersion
    var families: [GVEffectFamily]
    var effects: [GVEffectDescriptor]

    /// Effects that the phone cannot currently run, by id, with a reason.
    /// Audio effects with the microphone denied are the common case.
    var unavailable: [String: String] = [:]

    func descriptor(for id: String) -> GVEffectDescriptor? {
        effects.first { $0.id == id }
    }
}

// MARK: - Live state

/// One placed effect, flattened for the wire.
///
/// Deliberately not `CameraEffectStackParameters.Slot`: that type carries the
/// phone's enum, which the Mac does not have. The id is the same `UUID`
/// though, which is what makes a slot addressable from the desktop.
struct GVBroadcastSlotState: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var effect: String
    var isEnabled: Bool
    var primary: Double
    var secondary: Double
    var tertiary: Double
    var blend: Double
    var overlayX: Double
    var overlayY: Double

    func value(for channel: GVBroadcastParameterChannel) -> Double {
        switch channel {
        case .primary: primary
        case .secondary: secondary
        case .tertiary: tertiary
        case .blend: blend
        case .overlayX: overlayX
        case .overlayY: overlayY
        }
    }
}

struct GVBroadcastRGBSplitState: Codable, Equatable, Sendable {
    var isEnabled = false
    var amount = 0.0
    var angleDegrees = 0.0
    var mix = 1.0
}

/// The phone's composition as it stands. Published after every committed
/// change, and once on connect.
struct GVBroadcastControlState: Codable, Equatable, Sendable {
    /// Render order. Index 0 is applied first.
    var slots: [GVBroadcastSlotState] = []
    /// ADD mode on the phone.
    var isStackArmed = false
    var rgbSplit = GVBroadcastRGBSplitState()
    var isRecording = false
    /// Set when the phone denied or failed to arm the microphone, so the
    /// desktop can explain why an audio effect is doing nothing.
    var isAudioAvailable = true

    static let empty = GVBroadcastControlState()
}
