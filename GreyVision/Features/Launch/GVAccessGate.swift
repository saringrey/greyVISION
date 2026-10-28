import SwiftUI
import UIKit

/// The entry action uses the reference's scramble and mirrored scan on touch,
/// pointer hover, and activation, with a stable accessible button label.
struct GVAccessGate: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isTouching = false
    @State private var isHovered = false
    @State private var isActivating = false
    @State private var activationTask: Task<Void, Never>?

    private static let targetText = "OPEN // GREYVISION"
    let onUnlocked: () -> Void

    var body: some View {
        ZStack {
            GVSplashBackdrop()
                .ignoresSafeArea()

            VStack(spacing: GVMetrics.stepSection) {
                Spacer()
                VStack(spacing: GVMetrics.gap) {
                    Text("grey//VISION")
                        .font(GVTheme.mono(28, .semibold))
                        .tracking(-1)
                        .foregroundStyle(GVTheme.bone)
                    Text("LIVE VISUAL INSTRUMENT")
                        .font(GVTheme.mono(10, .medium))
                        .tracking(2)
                        .foregroundStyle(GVTheme.ash)
                }
                Button(action: activate) {
                    GVEncryptButtonFace(
                        target: Self.targetText,
                        engaged: isHovered || isTouching || isActivating,
                        opening: isActivating
                    )
                }
                .buttonStyle(GVAccessMagneticStyle(active: isActivating, isTouching: $isTouching))
                .onHover { isHovered = $0 }
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
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            activationTask?.cancel()
            activationTask = nil
            isActivating = false
            isHovered = false
            isTouching = false
        }
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
            try? await Task.sleep(for: .seconds(GVEncryptText.duration(for: Self.targetText)))
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
    @Binding var isTouching: Bool

    func makeBody(configuration: Configuration) -> some View {
        GVAccessMagneticFeedback(label: configuration.label, pressed: configuration.isPressed, active: active)
            .onChange(of: configuration.isPressed) { _, pressed in isTouching = pressed }
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
                .scaleEffect(reduceMotion ? 1 : (pressed ? 0.975 : (pointer != nil ? 1.025 : 1)))
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

struct GVEncryptButtonFace: View {
    let target: String
    let engaged: Bool
    let opening: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var startedAt = Date.now
    @ScaledMetric(relativeTo: .callout) private var textSize: CGFloat = 12

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !engaged || reduceMotion || scenePhase != .active)) { timeline in
            let elapsed = max(timeline.date.timeIntervalSince(startedAt), 0)
            HStack(spacing: 12) {
                Image(systemName: opening ? "lock.open" : "lock")
                    .font(.subheadline.weight(.medium))
                Text(GVEncryptText.frame(target: target, elapsed: elapsed, animated: engaged && !reduceMotion))
                    .font(GVTheme.mono(textSize, .medium))
                    .tracking(0.6)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(engaged ? GVSplashPalette.cyan : GVTheme.bone)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.88))
                    .overlay {
                        GeometryReader { geometry in
                            let travel = 1 - abs(elapsed.truncatingRemainder(dividingBy: 2) - 1)
                            LinearGradient(
                                colors: [.clear, GVSplashPalette.cyan.opacity(0.22), GVSplashPalette.violet.opacity(0.16), .clear],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                            .scaleEffect(1.25)
                            .offset(y: geometry.size.height * (1 - 2 * travel))
                        }
                        .opacity(engaged && !reduceMotion ? 1 : 0)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .modifier(GVSplashBorder(active: engaged))
        }
        .onChange(of: engaged, initial: true) { _, _ in startedAt = .now }
    }
}

enum GVEncryptText {
    private static let characters = Array("!@#$%^&*():{};|,.<>/?")
    static let shuffleTime = 0.05
    static let cyclesPerLetter = 2

    static func duration(for target: String) -> Double {
        Double(target.count * cyclesPerLetter) * shuffleTime
    }

    static func frame(target: String, elapsed: Double, animated: Bool) -> String {
        guard animated, elapsed.isFinite, elapsed >= 0, elapsed < duration(for: target) else { return target }
        let step = Int(elapsed / shuffleTime)
        return String(target.enumerated().map { index, character in
            if character.isWhitespace || step / cyclesPerLetter > index { return character }
            return characters[(step * 7 + index * 11) % characters.count]
        })
    }
}
