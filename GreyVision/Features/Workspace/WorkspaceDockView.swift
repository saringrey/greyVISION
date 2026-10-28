import SwiftUI

/// Collections live in Settings; the viewfinder dock contains only live adjustments.
enum GVCollectionPlate: String, CaseIterable, Identifiable, Hashable {
    case recipes
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .recipes: "bookmark"
        }
    }

    var label: String {
        switch self {
        case .recipes: "Recipes"
        }
    }

    var identifier: String { "workspace.\(rawValue)" }
}

struct WorkspaceDockView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var depthRuntime: DepthRuntime
    @EnvironmentObject private var blobRuntime: BlobTrackingRuntime
    @ObservedObject var editor: EffectEditingSession
    @ObservedObject var recording: GVRecordingTransaction
    @Binding var dismissSelectionSignal: Int
    let isBrowserPresented: Bool
    let maximumHeight: CGFloat
    /// Bumped by the Adjust button; reopens a source deck closed with its ✕.
    var revealSignal = 0
    @State private var contentHeight: CGFloat = 0
    @State private var hidesSourceControls = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            WorkspaceLiveAdjustments(editor: editor, recording: recording, hidesSourceControls: $hidesSourceControls)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: DockContentHeightKey.self, value: proxy.size.height)
                    }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight, maximumHeight))
        .onPreferenceChange(DockContentHeightKey.self) { contentHeight = $0 }
        .onChange(of: dismissSelectionSignal) { _, _ in
            editor.focus(nil)
            hidesSourceControls = true
        }
        .onChange(of: appModel.sourceMode) { _, _ in hidesSourceControls = false }
        .onChange(of: depthRuntime.effect) { _, _ in hidesSourceControls = false }
        .onChange(of: blobRuntime.isEnabled) { _, _ in hidesSourceControls = false }
        .onChange(of: revealSignal) { _, _ in hidesSourceControls = false }
        .onChange(of: isBrowserPresented) { _, presented in
            if !presented { hidesSourceControls = false }
        }
        .animation(GVMotion.resolved(GVMotion.panel, reduceMotion: reduceMotion), value: editor.selectedEffect)
        .accessibilityIdentifier("workspace.adjustments")
    }
}

private struct WorkspaceLiveAdjustments: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var cameraRuntime: CameraRuntime
    @EnvironmentObject private var depthRuntime: DepthRuntime
    @EnvironmentObject private var objectsRuntime: ARObjectRuntime
    @EnvironmentObject private var blobRuntime: BlobTrackingRuntime
    @EnvironmentObject private var preferences: GVPreferences
    @ObservedObject var editor: EffectEditingSession
    @ObservedObject var recording: GVRecordingTransaction
    @Binding var hidesSourceControls: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let effect = editor.selectedEffect {
                WorkspaceEffectParameterDeck(
                    effect: effect, editor: editor,
                    isFavorite: preferences.isFavorite(effect.rawValue),
                    onFavoriteToggled: { preferences.toggleFavorite(effect.rawValue) },
                    onSelectEffect: { editor.focus($0) },
                    onClose: { editor.focus(nil) }
                )
            } else if !hidesSourceControls {
                if appModel.sourceMode == .lidar {
                    DepthEffectParameterDeck(
                        effect: depthRuntime.effect, parameters: $depthRuntime.parameters,
                        onClose: { hidesSourceControls = true },
                        onExitDepth: appModel.deactivateDepthMode
                    )
                } else if appModel.sourceMode == .objects {
                    ARObjectsParameterDeck(
                        parameters: $objectsRuntime.parameters,
                        objectCount: objectsRuntime.objects.count,
                        status: objectsRuntime.snapshot.formatLabel,
                        isRecording: objectsRuntime.isRecording,
                        onRecordToggle: {
                            recording.toggleRecording(cameraRuntime: cameraRuntime, objectsRuntime: objectsRuntime, sourceMode: appModel.sourceMode)
                        },
                        onClear: { objectsRuntime.clearObjects() },
                        onExit: appModel.deactivateObjectMode,
                        onClose: { hidesSourceControls = true }
                    )
                } else if blobRuntime.isEnabled {
                    GVTrackingDeck(runtime: blobRuntime, onClose: { hidesSourceControls = true })
                }
            }
        }
    }
}

private struct DockContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
