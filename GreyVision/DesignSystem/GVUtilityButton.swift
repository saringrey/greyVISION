import SwiftUI

/// A utility control drawn small and tapped large.
///
/// Replaces the three 62pt violet-ringed circles across the top of the camera.
/// Those read as an app's toolbar; an instrument's utility controls are etched
/// marks with generous invisible targets around them. The visible glyph here
/// is ~17pt inside a 44pt content shape, so the hit area is unchanged — only
/// the drawn weight comes down.
struct GVUtilityButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let symbol: String
    let label: String
    var state: GVTheme.State = .normal
    var isActive = false
    let action: () -> Void

    private var tint: Color {
        isActive ? GVTheme.violet : GVTheme.color(state)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                // The mark itself carries the state. No plate, no ring: an
                // inactive utility control should be a glyph on the camera,
                // not a button sitting on top of it.
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(tint.opacity(isActive ? 1 : 0.72))
                    .shadow(color: .black.opacity(0.85), radius: 3)
                    .shadow(
                        color: isActive ? GVTheme.violet.opacity(0.5) : .clear,
                        radius: 7
                    )

                // Selection is the only thing that draws geometry, and it
                // draws the minimum that reads: an underscore, not a ring.
                if isActive {
                    Rectangle()
                        .fill(GVTheme.violet)
                        .frame(width: 16, height: 1.4)
                        .offset(y: 14)
                        .shadow(color: GVTheme.violet.opacity(0.7), radius: 4)
                }
            }
            .frame(width: GVMetrics.touchTarget, height: GVMetrics.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        .animation(GVMotion.resolved(GVMotion.snap, reduceMotion: reduceMotion), value: isActive)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

/// A value the operator can read at a glance and tap to adjust.
///
/// The label is quiet and the value is not — the reverse of how the old
/// readouts were set, where wide tracking on the label made `ISO` louder than
/// the number after it.
struct GVReadout: View {
    let label: String
    let value: String
    var state: GVTheme.State = .normal
    var isInteractive = false

    var body: some View {
        HStack(spacing: GVMetrics.gapHair) {
            if !label.isEmpty {
                Text(label)
                    .gvFont(.diagnostic)
                    .tracking(GVTheme.TypeLevel.diagnostic.tracking)
                    .foregroundStyle(GVTheme.ash)
            }

            Text(value)
                .gvFont(.telemetry)
                .monospacedDigit()
                .tracking(GVTheme.TypeLevel.telemetry.tracking)
                .foregroundStyle(GVTheme.color(state))
        }
        .shadow(color: .black.opacity(0.8), radius: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value)")
        .accessibilityAddTraits(isInteractive ? [.isButton] : [])
    }
}
