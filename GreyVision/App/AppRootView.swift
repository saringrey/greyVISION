import SwiftUI
import UIKit

struct AppRootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        ZStack {
            GVTheme.void.ignoresSafeArea()

            switch appModel.route {
            case .gate:
                GVAccessGate {
                    withAnimation(GVMotion.deck) { appModel.unlockAccess() }
                }
                .transition(routeTransition)
            case .boot:
                BootView()
                    .transition(routeTransition)
            case .workspace:
                WorkspaceView()
                    .transition(routeTransition)
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
        .animation(reduceMotion ? nil : .snappy(duration: 0.48), value: appModel.route)
        .onChange(of: scenePhase, initial: true) { _, phase in
            appModel.handleScenePhase(phase)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            appModel.updateCaptureRotation()
        }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            // An instrument being framed through a viewfinder must not sleep
            // mid-shot. The screen stays awake for as long as the app is open;
            // iOS reclaims its normal behaviour the moment we resign.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
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
