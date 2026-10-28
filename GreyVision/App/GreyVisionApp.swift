import SwiftUI

@main
struct GreyVisionApp: App {
    @StateObject private var appModel = AppModel()

    init() {
        #if DEBUG
        GVEffectKernelProbe.runIfRequested()
        GVLogExport.runIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(appModel)
                .environmentObject(appModel.camera)
                .environmentObject(appModel.depth)
                .environmentObject(appModel.objects)
                .environmentObject(appModel.audio)
                .environmentObject(appModel.blobs)
                .environmentObject(appModel.broadcast)
                .environmentObject(appModel.preferences)
                // A 3D file shared to the app — "Open in greyVISION" from
                // Files, Safari, AirDrop or Mail — goes into the AR library.
                .onOpenURL { url in appModel.importSharedModel(url) }
        }
    }
}
