import SwiftUI
import UIKit

/// Single-action entry gate. The old keypad implied a secret that was only a
/// source constant; the requested interaction is now honestly one button.
struct GVAccessGate: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isActivating = false

    let onUnlocked: () -> Void

    var body: some View {
        ZStack {
            GVSplashBackdrop()
                .ignoresSafeArea()

            VStack(spacing: GVMetrics.stepRelated) {
                Spacer()

                Button(action: activate) {
                    ZStack {
                        RoundedRectangle(cornerRadius: GVMetrics.radiusPanel, style: .continuous)
                            .fill(Color.black.opacity(0.72))
                        RoundedRectangle(cornerRadius: GVMetrics.radiusPanel, style: .continuous)
                            .fill(.ultraThinMaterial.opacity(0.18))

                        HStack(spacing: GVMetrics.gap) {
                            Image(systemName: isActivating ? "lock.open" : "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
                            Text(isActivating ? "OPENING // SESSION" : "OPEN // GREYVISION")
                                .gvMono(10, .semibold)
                                .tracking(0.5)
                        }
                        .foregroundStyle(GVTheme.bone)
                        .opacity(isActivating ? 0.72 : 1)
                    }
                    .frame(width: 168, height: GVMetrics.touchTarget)
                    .overlay {
                        GVScrollingPerimeter(radius: GVMetrics.radiusPanel, active: isActivating)
                    }
                }
                .buttonStyle(GVPressStyle(scale: 0.97))
                .disabled(isActivating)
                .accessibilityLabel("Enter GreyVision")
                .accessibilityValue(isActivating ? "Opening session" : "Closed")
                .accessibilityHint(isActivating ? "Session is opening." : "Opens the launch sequence.")
                .accessibilityIdentifier("access.enter")
            }
            .padding(.bottom, GVMetrics.stepSection)
        }
        .background(GVTheme.void.ignoresSafeArea())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("access.gate")
    }

    private func activate() {
        guard !isActivating else { return }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.55)
        GVSoundEngine.shared.play(.keypad)

        guard !reduceMotion else {
            onUnlocked()
            return
        }

        isActivating = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            onUnlocked()
        }
    }
}

private struct GVScrollingPerimeter: View {
    let radius: CGFloat
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30, paused: reduceMotion)) { timeline in
            let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate * 0.22
            let angle = phase.truncatingRemainder(dividingBy: 1) * 360
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

            shape
                .stroke(.white.opacity(active ? 0.48 : 0.24), lineWidth: 1)
                .overlay {
                    AngularGradient(
                        colors: [.clear, .clear, .white, .clear, .clear],
                        center: .center,
                        angle: .degrees(angle)
                    )
                    .mask(shape.stroke(.white, lineWidth: 2))
                }
                .shadow(color: .white.opacity(active ? 0.56 : 0.28), radius: active ? 12 : 7)
                .shadow(color: .white.opacity(active ? 0.28 : 0.12), radius: active ? 24 : 14)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
