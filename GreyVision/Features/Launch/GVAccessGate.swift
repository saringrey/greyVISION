import SwiftUI
import UIKit

/// Single-action entry gate. Pointer motion moves the plate, never the cursor
/// or its hit region; touch and keyboard activation retain the same action.
struct GVAccessGate: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isActivating = false
    @State private var activationTask: Task<Void, Never>?

    let onUnlocked: () -> Void

    var body: some View {
        ZStack {
            GVSplashBackdrop()
                .ignoresSafeArea()

            VStack(spacing: GVMetrics.stepRelated) {
                Spacer()
                Button(action: activate) {
                    HStack(spacing: 12) {
                        Image(systemName: isActivating ? "lock.open" : "power")
                            .font(.subheadline.weight(.medium))
                        Text(isActivating ? "OPENING // SESSION" : "OPEN // GREYVISION")
                            .gvMono(11, .medium)
                            .tracking(0.6)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .layoutPriority(1)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(GVTheme.bone)
                    .padding(.horizontal, 18)
                    .frame(width: 252, height: 54)
                    .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        GVScrollingPerimeter(radius: 14, active: isActivating)
                    }
                    .gvDecay(isActivating, seed: 8)
                }
                .buttonStyle(GVAccessMagneticStyle(active: isActivating))
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
        .onDisappear {
            activationTask?.cancel()
            activationTask = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("access.gate")
    }

    private func activate() {
        guard !isActivating else { return }
        isActivating = true
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.55)
        GVSoundEngine.shared.play(.keypad)
        guard !reduceMotion else {
            onUnlocked()
            return
        }
        activationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            onUnlocked()
        }
    }
}

/// Pure, bounded geometry shared with regression tests. The attraction fades
/// near the edge so entering/leaving the stationary hit region cannot jump.
enum GVButtonMagnetism {
    static func offset(at point: CGPoint, in size: CGSize, reduceMotion: Bool = false) -> CGSize {
        guard !reduceMotion, size.width > 0, size.height > 0,
              point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.x <= size.width, point.y >= 0, point.y <= size.height else { return .zero }
        let x = (point.x - size.width / 2) / (size.width / 2)
        let y = (point.y - size.height / 2) / (size.height / 2)
        let falloff = max(1 - max(abs(x), abs(y)), 0)
        return CGSize(width: x * falloff * 24, height: y * falloff * 16)
    }
}

private struct GVAccessMagneticStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        GVAccessMagneticFeedback(label: configuration.label, pressed: configuration.isPressed, active: active)
    }
}

private struct GVAccessMagneticFeedback<Label: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pointer: CGPoint?
    let label: Label
    let pressed: Bool
    let active: Bool
    private let size = CGSize(width: 288, height: 90)

    private var attraction: CGSize {
        guard let pointer, !pressed, !active else { return .zero }
        return GVButtonMagnetism.offset(at: pointer, in: size, reduceMotion: reduceMotion)
    }

    var body: some View {
        ZStack {
            Color.clear
            label
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(GVTheme.bone.opacity(pointer != nil || pressed ? 0.7 : 0), lineWidth: 1)
                }
                .brightness(pressed ? 0.13 : (pointer != nil ? 0.04 : 0))
                .scaleEffect(reduceMotion ? 1 : (pressed ? 0.96 : (pointer != nil ? 1.025 : 1)))
                .offset(attraction)
                .shadow(color: .black.opacity(0.28), radius: 12, y: pointer == nil ? 4 : 8)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case let .active(location): pointer = location
            case .ended: pointer = nil
            }
        }
        .onDisappear { pointer = nil }
        .animation(GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion), value: attraction)
        .animation(GVMotion.resolved(GVMotion.press, reduceMotion: reduceMotion), value: pressed)
        .animation(GVMotion.resolved(GVMotion.press, reduceMotion: reduceMotion), value: pointer != nil)
    }
}

private struct GVScrollingPerimeter: View {
    let radius: CGFloat
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.strokeBorder(GVTheme.bone.opacity(active ? 0.65 : 0.28), lineWidth: 1)
            .overlay {
                if active, !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate * 1.8
                        AngularGradient(colors: [.clear, .clear, GVTheme.bone, .clear],
                                        center: .center, angle: .degrees(phase * 360))
                            .mask(shape.strokeBorder(lineWidth: 1.5))
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
