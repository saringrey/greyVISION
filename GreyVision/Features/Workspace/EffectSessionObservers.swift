import Combine
import SwiftUI

/// Only pixel-affecting edits reach the preview. Selection, focus, menus and
/// undo bookkeeping never invalidate the camera representable.
@MainActor
final class EffectRenderProjection: ObservableObject {
    @Published private(set) var composition: CompositionSnapshot
    private var subscription: AnyCancellable?

    init(editor: EffectEditingSession) {
        composition = editor.renderedComposition
        // No `combineLatest`, no `removeDuplicates`, and deliberately nothing
        // here that reads a field off a delivered value. A subscriber to a
        // `@Published` property receives a borrow into storage that is still
        // inside its `modify` accessor; touching a field through that borrow
        // traps as a simultaneous access. The editor has already resolved
        // bypass, already discarded no-op edits, and already derived the
        // snapshot on a turn where nothing is being written, so this is a
        // straight mirror.
        subscription = editor.renderedCompositionPublisher
            .sink { [weak self] value in self?.composition = value }
    }
}

struct EffectPreviewObserver<Content: View>: View {
    @StateObject private var projection: EffectRenderProjection
    private let content: (CompositionSnapshot) -> Content

    init(editor: EffectEditingSession, @ViewBuilder content: @escaping (CompositionSnapshot) -> Content) {
        _projection = StateObject(wrappedValue: EffectRenderProjection(editor: editor))
        self.content = content
    }

    var body: some View { content(projection.composition) }
}

/// Small chrome regions subscribe independently of the workspace layout.
struct EffectChromeObserver<Content: View>: View {
    @ObservedObject var editor: EffectEditingSession
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}

struct EffectSessionEvents: View {
    @ObservedObject var editor: EffectEditingSession
    let publishState: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: editor.effectStack) { _, _ in changed() }
            .onChange(of: editor.rgbSplitParameters) { _, _ in changed() }
            .onChange(of: editor.isStackArmed) { _, _ in publishState() }
            .accessibilityHidden(true)
    }

    private func changed() {
        editor.recordHistory()
        publishState()
    }
}

/// Audio cadence stays in this leaf, and stops when analysis or the scene is
/// inactive. It cannot redraw the workspace's geometry tree sixty times/sec.
struct WorkspaceBeatPump: View {
    @ObservedObject var audio: AudioReactiveRuntime
    let detector: GVBeatDetector
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: scenePhase != .active || !audio.isEnabled)) { context in
            Color.clear
                .onChange(of: context.date, initial: true) { _, date in
                    guard scenePhase == .active, audio.isEnabled else { return }
                    detector.tick(snapshot: audio.snapshot, now: date.timeIntervalSinceReferenceDate)
                }
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
