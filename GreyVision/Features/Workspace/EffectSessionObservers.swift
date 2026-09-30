import Combine
import SwiftUI

/// Only pixel-affecting edits reach the preview. Selection, focus, menus and
/// undo bookkeeping never invalidate the camera representable.
@MainActor
final class EffectRenderProjection: ObservableObject {
    @Published private(set) var composition: CompositionSnapshot
    private var subscription: AnyCancellable?

    init(editor: EffectEditingSession) {
        composition = CompositionSnapshot(
            stack: editor.renderedEffectStack,
            rgb: editor.renderedRGBSplitParameters
        )
        subscription = editor.$effectStack.combineLatest(editor.$rgbSplitParameters, editor.$isGlobalBypassed)
            .map { stack, rgb, bypassed in
                var stack = stack
                var rgb = rgb
                if bypassed {
                    rgb.isEnabled = false
                    for slot in stack.orderedSlots {
                        stack.setEnabled(false, slot: slot.id)
                    }
                }
                return CompositionSnapshot(stack: stack, rgb: rgb)
            }
            // Identity, not value. The synthesized `Equatable` this replaced
            // walked every slot and every parameter on each edit — dozens of
            // floating-point comparisons per slider frame to learn that one
            // number had moved. Identity answers that in constant time, and
            // because it is derived from the snapshot itself it cannot say two
            // states are the same when they are not.
            .removeDuplicates { $0.identity == $1.identity }
            .sink { [weak self] in self?.composition = $0 }
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
