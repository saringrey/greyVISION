import SwiftUI

/// Where a photo is, as told by the renderer's own messages.
///
/// The shutter used to fire silently: the only sign a photo was taken was a
/// haptic. The renderer already reports every stage — rendering, filing,
/// saved, failed — so the button reads that rather than guessing from the tap.
enum GVShutterState: Equatable {
    case idle
    case capturing
    case saved
    case failed

    init(message: String?) {
        guard let message, message.hasPrefix("PHOTO //") else {
            self = .idle
            return
        }
        if message.contains("FAILED") || message.contains("UNAVAILABLE") || message.contains("DID NOT RESPOND") {
            self = .failed
        } else if message.contains("SAVED") {
            self = .saved
        } else {
            self = .capturing
        }
    }
}

/// The Photo button face: camera at rest, a pulsing shutter while the frame
/// renders and files, a checkmark once it is in Photos, a cross on failure.
struct GVShutterButtonFace: View {
    let state: GVShutterState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(GVTheme.bone.opacity(state == .capturing ? 0.22 : 0))
                    .frame(width: 34, height: 34)
                    .scaleEffect(pulse && !reduceMotion ? 1.15 : 0.9)
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .regular))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: state == .saved)
            }
            .frame(height: 24)
            Text(label)
                .font(GVTheme.mono(10, .medium))
                .contentTransition(.opacity)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, minHeight: 56)
        .contentShape(Rectangle())
        .animation(GVMotion.resolved(GVMotion.normal, reduceMotion: reduceMotion), value: state)
        .onChange(of: state, initial: true) { _, state in
            guard state == .capturing, !reduceMotion else {
                pulse = false
                return
            }
            withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var symbol: String {
        switch state {
        case .idle: "camera"
        case .capturing: "camera.aperture"
        case .saved: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private var label: String {
        switch state {
        case .idle: "Photo"
        case .capturing: "Saving"
        case .saved: "Saved"
        case .failed: "Failed"
        }
    }

    private var tint: Color {
        switch state {
        case .failed: GVTheme.record
        case .saved: Color.mint
        default: GVTheme.bone
        }
    }
}

/// The Video button face. At rest a camera; while recording, a red circle
/// with a stop square, a slow pulse ring, and the running timecode — the
/// button itself says a take is rolling, wherever the operator is looking.
struct GVRecordButtonFace: View {
    let recording: Bool
    let startedAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 5) {
            if recording {
                TimelineView(GVAmbientClock.ambient(hertz: 4, scenePhase: scenePhase)) { clock in
                    let elapsed = max(clock.date.timeIntervalSince(startedAt ?? clock.date), 0)
                    let breath = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(elapsed * .pi * 1.6)
                    VStack(spacing: 5) {
                        ZStack {
                            Circle()
                                .stroke(GVTheme.record.opacity(0.55 * (1 - breath)), lineWidth: 2)
                                .frame(width: 30 + 8 * breath, height: 30 + 8 * breath)
                            Circle()
                                .fill(GVTheme.record)
                                .frame(width: 28, height: 28)
                                .shadow(color: GVTheme.record.opacity(0.6), radius: 6)
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(Color.white)
                                .frame(width: 10, height: 10)
                        }
                        .frame(height: 24)
                        Text("REC \(Self.timecode(elapsed))")
                            .font(GVTheme.mono(10, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(GVTheme.record)
                    }
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Image(systemName: "video")
                    .font(.system(size: 20, weight: .regular))
                    .frame(height: 24)
                Text("Video")
                    .font(GVTheme.mono(10, .medium))
            }
        }
        .foregroundStyle(GVTheme.bone)
        .frame(maxWidth: .infinity, minHeight: 56)
        .contentShape(Rectangle())
        .animation(GVMotion.resolved(.spring(response: 0.32, dampingFraction: 0.7), reduceMotion: reduceMotion), value: recording)
    }

    static func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
