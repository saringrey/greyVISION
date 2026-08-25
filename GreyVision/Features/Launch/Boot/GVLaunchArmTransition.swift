import SwiftUI

/// The LAUNCH control as a capacitor filling with charge.
///
/// Dormant until the sequence arms. A point of light appears at the centre,
/// expands outward through the body, and the outer ring illuminates last. The
/// geometry, size and accessibility identity of the original control are
/// unchanged — only its energisation is new.
struct GVLaunchArmButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isArmed: Bool
    let isCollapsing: Bool
    let action: () -> Void

    @State private var charge: Double = 0
    @State private var ringCharge: Double = 0
    @State private var collapse: Double = 0

    private let diameter: CGFloat = 60

    var body: some View {
        Button(action: action) {
            content(charge: charge, ring: ringCharge, collapse: collapse)
        }
        .buttonStyle(.plain)
        .disabled(!isArmed)
        .accessibilityLabel("Launch camera workspace")
        .accessibilityIdentifier("boot.launch")
        .onChange(of: isArmed, initial: true) { _, armed in
            guard armed else {
                charge = 0
                ringCharge = 0
                return
            }
            guard !reduceMotion else {
                charge = 1
                ringCharge = 1
                return
            }
            // Charge fills the body first; the outer ring illuminates last.
            withAnimation(.easeOut(duration: GVBootTiming.armSeconds)) {
                charge = 1
            }
            withAnimation(.easeOut(duration: 0.2).delay(GVBootTiming.armSeconds * 0.72)) {
                ringCharge = 1
            }
        }
        .onChange(of: isCollapsing) { _, collapsing in
            guard collapsing else { return }
            guard !reduceMotion else {
                collapse = 1
                return
            }
            withAnimation(.easeIn(duration: 0.19)) {
                collapse = 1
            }
        }
    }

    private func content(charge: Double, ring ringValue: Double, collapse: Double) -> some View {
        let ring = max(ringValue - collapse, 0)
        let label = max(smoothstep(0.52, 0.94, charge) - collapse * 1.6, 0)
        let fillRadius = collapse > 0
            ? max(1 - collapse, 0.02)
            : charge
        let flash = collapse > 0.55 ? (collapse - 0.55) / 0.45 : 0

        return VStack(spacing: 3) {
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .black))
                .opacity(label)
            GVTerminalText(
                text: "LAUNCH",
                size: 6.2,
                weight: .black,
                tracking: 0.72,
                baseColor: .black,
                intensity: 0.82
            )
            .opacity(label)
        }
        .foregroundStyle(.black)
        .frame(width: diameter, height: diameter)
        .background {
            ZStack {
                GVChamferedPlate(cut: 11).fill(Color.white.opacity(0.025))

                // Charge filling the capacitor from the centre outward.
                GVChamferedPlate(cut: 11)
                    .fill(
                        RadialGradient(
                            colors: [
                                GVTheme.acid,
                                GVTheme.acid.opacity(0.92),
                                GVTheme.acid.opacity(0.0)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: max(diameter * 0.5 * fillRadius, 0.8)
                        )
                    )
                    .opacity(charge > 0.001 || collapse > 0 ? 1 : 0)

                // The single point that survives the collapse, then flashes.
                if collapse > 0 {
                    GVChamferedPlate(cut: 11)
                        .fill(GVTheme.acid)
                        .frame(width: 3.5 + flash * 26, height: 3.5 + flash * 26)
                        .opacity(1 - flash * 0.35)
                        .blur(radius: flash * 5)
                }
            }
        }
        .overlay {
            GVChamferedPlate(cut: 11)
                .stroke(
                    GVTheme.acid.opacity(ring),
                    lineWidth: 1
                )
                .background(
                    GVChamferedPlate(cut: 11).stroke(GVTheme.violetDeep.opacity(0.32 * (1 - ring)), lineWidth: 1)
                )
        }
        .shadow(color: GVTheme.acid.opacity(0.34 * ring + flash * 0.6), radius: 8 + flash * 14)
        .scaleEffect(1 - collapse * 0.06)
    }

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        let ramp = min(max((value - edge0) / max(edge1 - edge0, 0.0001), 0), 1)
        return ramp * ramp * (3 - 2 * ramp)
    }
}

/// Splits the departing splash into horizontal slices that displace by a few
/// pixels, revealing the live camera surface behind them.
struct GVRasterTear: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isActive: Bool
    let start: Date

    func body(content: Content) -> some View {
        if reduceMotion {
            content.opacity(isActive ? 0 : 1)
        } else if !isActive {
            content
        } else {
            GeometryReader { geometry in
                TimelineView(.animation(minimumInterval: 1 / 60, paused: false)) { timeline in
                    let progress = min(
                        max(timeline.date.timeIntervalSince(start) / GVBootTiming.departSeconds, 0),
                        1
                    )
                    content
                        .layerEffect(
                            ShaderLibrary.bootRasterTear(
                                .float2(geometry.size),
                                .float(Float(progress))
                            ),
                            maxSampleOffset: CGSize(width: geometry.size.width * 0.07, height: 2)
                        )
                }
            }
        }
    }
}

extension View {
    func gvRasterTear(isActive: Bool, start: Date) -> some View {
        modifier(GVRasterTear(isActive: isActive, start: start))
    }
}

/// The corruption that settles over the workspace as the signal path opens.
///
/// Runs for roughly 380 ms after entry and then removes itself entirely, so no
/// continuous work survives into the live camera session.
struct GVSignalPathSettle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let start: Date
    let onFinished: () -> Void

    private let duration = 0.4

    var body: some View {
        Group {
            if reduceMotion {
                Color.clear
            } else {
                TimelineView(.animation(minimumInterval: 1 / 60, paused: false)) { timeline in
                    let progress = min(max(timeline.date.timeIntervalSince(start) / duration, 0), 1)
                    let energy = 1 - progress

                    ZStack {
                        GVScanlines(opacity: 0.10 * energy, frequency: 60, speed: 1.4)

                        ForEach(0 ..< 5, id: \.self) { index in
                            Rectangle()
                                .fill(.white.opacity(0.035 * energy))
                                .frame(height: 2 + CGFloat(index) * 1.4)
                                .offset(
                                    x: CGFloat(index.isMultiple(of: 2) ? 1 : -1) * energy * 14,
                                    y: CGFloat(index - 2) * 62
                                )
                        }

                        Rectangle()
                            .fill(GVTheme.violet.opacity(0.14 * energy))
                            .blendMode(.screen)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .accessibilityHidden(true)
        .task {
            try? await Task.sleep(for: .milliseconds(420))
            onFinished()
        }
    }
}
