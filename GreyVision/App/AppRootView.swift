import SwiftUI
import UIKit

struct AppRootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appModel: AppModel
    /// Geometry updates cover portrait ⇄ landscape, but not a turn between the
    /// two landscape directions. Keep a short reconciliation task so every
    /// capture source receives the window's final interface orientation.
    @State private var rotationRefreshTask: Task<Void, Never>?
    @State private var idleTimerPolicy = GVIdleTimerPolicy()
    @State private var idleTimerTask: Task<Void, Never>?
    /// Posted by the workspace whenever the operator touches the viewfinder.
    static let operatorDidInteract = Notification.Name("GVOperatorDidInteract")

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                GVTheme.void.ignoresSafeArea()

                switch appModel.route {
                case .gate, .boot:
                    GVLaunchSplash()
                        .transition(routeTransition)
                case .workspace:
                    WorkspaceView()
                        .transition(routeTransition)
                }
            }
            .onChange(of: geometry.size, initial: true) { _, _ in
                scheduleCaptureOrientationRefresh()
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        // Type tracks the user's preference on a compressed scale (see
        // GVDynamicType). Clamped once here rather than per screen: the top
        // shell has a fixed hardware-free zone and the rails are sized to the
        // frame, so beyond accessibility2 the instrument stops laying out at
        // all rather than degrading.
        .dynamicTypeSize(...GVTheme.maximumDynamicTypeSize)
        .animation(GVMotion.resolved(GVMotion.deck, reduceMotion: reduceMotion), value: appModel.route)
        .onChange(of: scenePhase, initial: true) { _, phase in
            appModel.handleScenePhase(phase)
            refreshIdleTimerPolicy()
        }
        .onChange(of: appModel.route) { _, _ in
            refreshIdleTimerPolicy()
        }
        .onChange(of: appModel.isTakeAtRisk) { _, _ in
            refreshIdleTimerPolicy()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // A landscape-left ⇄ landscape-right turn preserves geometry, so
            // it must not rely on the size observer above.
            scheduleCaptureOrientationRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppRootView.operatorDidInteract)) { _ in
            idleTimerPolicy.noteInteraction()
            refreshIdleTimerPolicy()
        }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            refreshIdleTimerPolicy()
            scheduleCaptureOrientationRefresh()
            startIdleTimerTicker()
        }
        .onDisappear {
            rotationRefreshTask?.cancel()
            rotationRefreshTask = nil
            idleTimerTask?.cancel()
            idleTimerTask = nil
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            UIApplication.shared.isIdleTimerDisabled = false
            appModel.stopAll()
        }
    }

    private var routeTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 1.015)),
                removal: .opacity.combined(with: .scale(scale: 0.985))
            )
    }

    private func refreshCaptureOrientation() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }
        appModel.updateCaptureRotation(interfaceOrientation: scene.interfaceOrientation)
    }

    /// UIKit can post the device notification and resize SwiftUI before the
    /// window scene has committed its new interface orientation. Apply once
    /// immediately, then once after that commit; cancelling the prior task
    /// makes a continuous turn settle on only its final orientation.
    private func scheduleCaptureOrientationRefresh() {
        refreshCaptureOrientation()
        rotationRefreshTask?.cancel()
        rotationRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            refreshCaptureOrientation()
        }
    }

    private func refreshIdleTimerPolicy() {
        // Keep the viewfinder awake, but let the entry ceremony and inactive
        // scenes use the system timeout. Holding the panel open at the gate or
        // boot screen wastes display power without protecting a take.
        //
        // Inside the workspace the hold is conditional: it applies only while a
        // take could actually be lost, and it lapses after an idle window so a
        // phone left on a desk with nothing armed goes to sleep. See
        // `GVIdleTimerPolicy`.
        let isWorkspace = appModel.route == .workspace
        idleTimerPolicy.setLive(isWorkspace && appModel.isTakeAtRisk)
        UIApplication.shared.isIdleTimerDisabled =
            scenePhase == .active && idleTimerPolicy.shouldHoldScreen
    }

    /// The idle window has to be noticed, not just measured, so something has
    /// to ask. One slow task, only while the workspace is holding the screen
    /// for a reason; it costs a wake every ten seconds and no per-frame work.
    private func startIdleTimerTicker() {
        idleTimerTask?.cancel()
        idleTimerTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                refreshIdleTimerPolicy()
            }
        }
    }
}

#Preview {
    let model = AppModel(arguments: ["--uitesting"])
    AppRootView()
        .environmentObject(model)
        .environmentObject(model.camera)
        .environmentObject(model.depth)
        .environmentObject(model.objects)
        .environmentObject(model.audio)
        .environmentObject(model.blobs)
        .environmentObject(model.broadcast)
        .environmentObject(model.preferences)
}
