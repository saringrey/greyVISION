import Combine
import Foundation
import SwiftUI

@MainActor
final class ControlLockManager: ObservableObject {
    @Published var lockCamera = false
    @Published var lockEffectStack = false
    @Published var lockUI = false

    enum LockType: String, CaseIterable, Identifiable {
        case camera = "LOCK CAMERA"
        case effectStack = "LOCK FX STACK"
        case ui = "LOCK UI"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .camera: "camera.aperture"
            case .effectStack: "slider.horizontal.3"
            case .ui: "eye.slash"
            }
        }
    }

    var isAnyLocked: Bool {
        lockCamera || lockEffectStack || lockUI
    }

    func value(for lock: LockType) -> Bool {
        switch lock {
        case .camera: lockCamera
        case .effectStack: lockEffectStack
        case .ui: lockUI
        }
    }

    func set(_ lock: LockType, enabled: Bool) {
        switch lock {
        case .camera: lockCamera = enabled
        case .effectStack: lockEffectStack = enabled
        case .ui: lockUI = enabled
        }
    }

    func unlockAll() {
        lockCamera = false
        lockEffectStack = false
        lockUI = false
    }
}

struct ControlLockView: View {
    @ObservedObject var manager: ControlLockManager
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives its own arrival so the scrim can fade while the card settles in
    /// from just under full size. Scaling the scrim too would pull a
    /// full-bleed layer off the screen edges mid-travel.
    @State private var hasArrived = false

    var body: some View {
        ZStack {
            Color.black.opacity(hasArrived ? 0.48 : 0)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 8) {
                HStack {
                    Text("CONTROL LOCK")
                        .gvMono(GVMetrics.textSmall, .black)
                        .tracking(1.1)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .frame(width: GVMetrics.touchTarget, height: GVMetrics.touchTarget)
                    }
                    .buttonStyle(GVPressStyle())
                    .accessibilityLabel("Close control lock")
                }

                ForEach(ControlLockManager.LockType.allCases) { lock in
                    Button {
                        manager.set(lock, enabled: !manager.value(for: lock))
                        GVInteractionHaptics.commit()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: lock.symbol)
                                .frame(width: 20)
                            Text(lock.rawValue)
                                .gvMono(GVMetrics.textSmall, .bold)
                                .tracking(0.7)
                            Spacer()
                            Text(manager.value(for: lock) ? "LOCKED" : "OPEN")
                                .gvMono(GVMetrics.textMicro, .black)
                                .foregroundStyle(manager.value(for: lock) ? Color.white : GVTheme.ash)
                        }
                        .foregroundStyle(manager.value(for: lock) ? Color.white : GVTheme.bone.opacity(0.72))
                        .padding(.horizontal, 12)
                        .frame(minHeight: GVMetrics.touchTarget)
                        .gvGlassChip(radius: 10, active: manager.value(for: lock), tint: .white)
                    }
                    .buttonStyle(GVPressStyle())
                    .accessibilityValue(manager.value(for: lock) ? "locked" : "open")
                }

                Button {
                    manager.unlockAll()
                    onDismiss()
                    GVInteractionHaptics.select()
                } label: {
                    Text("UNLOCK ALL")
                        .gvMono(GVMetrics.textSmall, .bold)
                        .tracking(0.8)
                        .frame(maxWidth: .infinity, minHeight: GVMetrics.touchTarget)
                }
                .buttonStyle(.gvPress)
            }
            .padding(14)
            .frame(maxWidth: 360)
            .gvGlass(.primary, radius: 18)
            .padding(24)
            .opacity(hasArrived ? 1 : 0)
            .scaleEffect(reduceMotion || hasArrived ? 1 : 0.96)
        }
        .animation(GVMotion.resolved(GVMotion.tear, reduceMotion: reduceMotion), value: hasArrived)
        .onAppear { hasArrived = true }
    }
}

@MainActor
final class BeforeAfterManager: ObservableObject {
    @Published var isHolding = false
    private var wasBypassed = false

    func startHold(editor: EffectEditingSession) {
        guard !isHolding else { return }
        wasBypassed = editor.isGlobalBypassed
        isHolding = true
        editor.setGlobalBypassed(true)
        GVInteractionHaptics.select()
    }

    func release(editor: EffectEditingSession) {
        guard isHolding else { return }
        editor.setGlobalBypassed(wasBypassed)
        isHolding = false
    }
}
