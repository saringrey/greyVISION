import SwiftUI

@main
struct GreyVisionApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(appModel)
                .environmentObject(appModel.camera)
                .environmentObject(appModel.depth)
                .environmentObject(appModel.objects)
                .environmentObject(appModel.audio)
                .environmentObject(appModel.blobs)
                .environmentObject(appModel.preferences)
        }
    }
}
