import Combine
import Foundation

/// One committed state of the operator's composition.
struct CompositionSnapshot: Equatable, Sendable {
    let stack: CameraEffectStackParameters
    let rgb: RGBSplitEffectParameters
    /// Answers "is this the same composition as that one?" in constant time.
    ///
    /// The preview projection used to answer that with a synthesized
    /// `Equatable` walk over every slot and every parameter, on every edit —
    /// which for a full stack is dozens of floating-point comparisons per
    /// slider frame, purely to discover that a number had moved.
    ///
    /// The stack's own `revision` answers the stack half: every mutation path
    /// advances it, so it moves if and only if the stack moved. The RGB
    /// split is four scalars, so it is folded in directly rather than given a
    /// counter of its own.
    ///
    /// Identity is derived from the snapshot's contents, never from a counter
    /// held beside them. A counter cannot be correct here: `@Published`
    /// publishes from `willSet`, so a subscriber that reads it sees the
    /// *previous* value and concludes a real edit changed nothing. Two
    /// snapshots of one composition also have to agree, or a history entry
    /// records a difference that is not there.
    let identity: UInt64

    init(stack: CameraEffectStackParameters, rgb: RGBSplitEffectParameters) {
        self.stack = stack
        self.rgb = rgb
        var hasher = Hasher()
        hasher.combine(stack.revision)
        // Fold in key rgb fields explicitly to avoid requiring Hashable conformance
        hasher.combine(rgb.isEnabled)
        hasher.combine(rgb.amount)
        hasher.combine(rgb.angleDegrees)
        hasher.combine(rgb.mix)
        // Reinterpreted, not converted. `finalize()` returns a signed Int and the
        // conversion trap — "not enough bits to represent a signed value" — fires
        // on any negative hash, which is roughly half of all process launches,
        // because Hasher is seeded per process. Bit-reinterpretation keeps every
        // bit of entropy and cannot trap; identity only has to be comparable.
        self.identity = UInt64(bitPattern: Int64(hasher.finalize()))
    }
}

/// Owns effect selection, stack mutation, focused-slot identity, and history.
///
/// Views render and forward intent. They do not independently decide what
/// exclusive selection, ADD mode, SOLO, remove, or undo means.
@MainActor
final class EffectEditingSession: ObservableObject {
    @Published var rgbSplitParameters: RGBSplitEffectParameters {
        didSet { scheduleRenderedCompositionPublish() }
    }

    @Published var effectStack: CameraEffectStackParameters {
        didSet { scheduleRenderedCompositionPublish() }
    }

    /// The composition exactly as the renderer should see it, republished only
    /// when that changes.
    ///
    /// This exists so no subscriber ever has to read through a value that
    /// `@Published` is handing out mid-mutation. A Combine subscriber to
    /// `$effectStack` receives the stack as a borrow into storage that is
    /// still inside its `modify` accessor; reading a field through that borrow
    /// is a simultaneous access to memory already being written, and Swift
    /// traps it. Deriving the snapshot here — on the writer's side, from
    /// owned values — means the preview receives a finished value and has
    /// nothing to inspect.
    ///
    /// The derivation is also deferred a turn, and not merely moved onto the
    /// writer's side. An observer on a stored property runs *inside* that
    /// property's write access, so deriving from a `didSet` reads back the
    /// very storage being written and traps in exactly the same way. One
    /// runloop turn later the write has landed, the storage is idle, and
    /// everything derived from it is safe to read.
    ///
    /// Delivery goes through a subject rather than a second `@Published`, for
    /// one more reason. `@Published` hands its subscriber whatever the
    /// compiler decided to pass — a `@guaranteed` borrow into its own storage
    /// is a legal choice, and reading that borrow is the trap this whole
    /// arrangement exists to avoid. A subject is handed the value that was
    /// passed to `send`, so a subscriber can only ever see a finished copy
    /// that belongs to nobody else.
    private(set) var renderedComposition: CompositionSnapshot

    private let renderedCompositionSubject = PassthroughSubject<CompositionSnapshot, Never>()

    /// The finished composition, republished only when it changes.
    var renderedCompositionPublisher: AnyPublisher<CompositionSnapshot, Never> {
        renderedCompositionSubject.eraseToAnyPublisher()
    }

    /// True while at least one armed effect reads the live spectrum.
    ///
    /// Derived here, on the writing side, for the same reason
    /// `renderedComposition` is: a subscriber to `@Published` is invoked while
    /// `Published.withMutation` still holds an exclusive access to the storage
    /// it is publishing. A consumer that reaches back into `effectStack` from
    /// inside that delivery to work this out for itself re-enters storage that
    /// is mid-write, and Swift traps it. Publishing the answer as a `Bool`
    /// means the consumer has nothing to look up.
    @Published private(set) var isAudioAnalysisRequired = false

    @Published private(set) var selectedEffect: WorkspaceAdjustableEffect?
    @Published var focusedSlot: CameraEffectStackParameters.Slot.ID?
    @Published private(set) var isStackArmed = false
    /// Presentation-only clean view. The committed composition and every slot
    /// remain untouched while this is active, so before/after never becomes an
    /// edit and never clears temporal history.
    @Published private(set) var isGlobalBypassed = false {
        didSet { scheduleRenderedCompositionPublish() }
    }

    @Published private(set) var isPreviewing = false
    /// Whether there is anything to step back to. Published because the
    /// affordances that offer undo — the toolbar pair and the swipe gesture —
    /// need to know, and re-deriving it from the private stacks would mean
    /// exposing them.
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var undoStack: [CompositionSnapshot] = []
    private var redoStack: [CompositionSnapshot] = []
    private var lastCommitted: CompositionSnapshot?
    private var lastFamilyVariant: [WorkspaceAdjustableEffect: WorkspaceAdjustableEffect] = [:]
    private var variantParameters: [UUID: [WorkspaceAdjustableEffect: CameraEffectParameters]] = [:]
    private var previewStash: (composition: CompositionSnapshot, selection: WorkspaceAdjustableEffect?, slot: UUID?)?
    /// True between `beginContinuousEdit` and `endContinuousEdit`.
    private var isContinuousEditInFlight = false
    /// The composition as it stood when the current gesture began.
    private var gestureAnchor: CompositionSnapshot?
    /// True while a deferred publish is queued, so a burst of writes — a
    /// slider scrub, an undo, a preset apply — costs one derivation, not one
    /// per write.
    private var isRepublishPending = false

    init(
        rgbSplitParameters: RGBSplitEffectParameters = .init(),
        effectStack: CameraEffectStackParameters = .init()
    ) {
        self.rgbSplitParameters = rgbSplitParameters
        self.effectStack = effectStack
        // Seeded from the arguments, never from `self`. Reading a property
        // back through this type during initialisation has trapped twice: once
        // because the derived getter touched storage that was still being
        // initialised, and once because it ran against an access the compiler
        // still considered open. Bypass starts off, so the rendered
        // composition *is* the committed one, and nothing else is derived here.
        let initial = CompositionSnapshot(stack: effectStack, rgb: rgbSplitParameters)
        lastCommitted = initial
        renderedComposition = initial
        isAudioAnalysisRequired = Self.requiresAudio(stack: effectStack, rgb: rgbSplitParameters)
        publishHistoryDepth()
    }

    /// Whether this composition needs the microphone open.
    ///
    /// A free function of its arguments so it can be answered from `init`
    /// without reading anything back out of the session.
    private static func requiresAudio(
        stack: CameraEffectStackParameters,
        rgb: RGBSplitEffectParameters
    ) -> Bool {
        if rgb.isEnabled, WorkspaceAdjustableEffect.rgbSplit.requiresAudioAnalysis { return true }
        return stack.orderedSlots.contains { slot in
            slot.parameters.isEnabled && slot.effect.requiresAudioAnalysis
        }
    }

    var snapshot: CompositionSnapshot {
        CompositionSnapshot(stack: effectStack, rgb: rgbSplitParameters)
    }

    var renderedRGBSplitParameters: RGBSplitEffectParameters {
        guard isGlobalBypassed else { return rgbSplitParameters }
        var clean = rgbSplitParameters
        clean.isEnabled = false
        return clean
    }

    var renderedEffectStack: CameraEffectStackParameters {
        guard isGlobalBypassed else { return effectStack }
        var clean = effectStack
        for slot in clean.orderedSlots {
            clean.setEnabled(false, slot: slot.id)
        }
        return clean
    }

    /// Queues the derivation for the next runloop turn.
    ///
    /// Safe to call from an observer: it touches only its own flag and the
    /// main queue, neither of which is the storage being written.
    private func scheduleRenderedCompositionPublish() {
        guard !isRepublishPending else { return }
        isRepublishPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRepublishPending = false
            self.publishRenderedComposition()
        }
    }

    /// Recomputes what the renderer should see and publishes it if it moved.
    ///
    /// Never call this from a property observer. Observers run inside the
    /// write access of the property they observe, so the reads below would
    /// collide with it. `scheduleRenderedCompositionPublish` is the only path
    /// that an observer may take.
    ///
    /// The identity comparison lives here, on the writing side, rather than in
    /// a Combine operator: it runs against values this type owns, and it costs
    /// one UInt64 comparison instead of a walk over every slot and parameter.
    private func publishRenderedComposition() {
        publishAudioRequirement()
        let next = CompositionSnapshot(
            stack: renderedEffectStack,
            rgb: renderedRGBSplitParameters
        )
        guard next.identity != renderedComposition.identity else { return }
        renderedComposition = next
        renderedCompositionSubject.send(next)
    }

    /// Republishes the microphone requirement only when it actually moves.
    ///
    /// Bypassed slots are ignored here: the bypass is a preview-only clean
    /// view, and it must not open or close the microphone behind the operator's
    /// back.
    private func publishAudioRequirement() {
        let required = Self.requiresAudio(stack: effectStack, rgb: rgbSplitParameters)
        guard required != isAudioAnalysisRequired else { return }
        isAudioAnalysisRequired = required
    }

    var activeEffects: [WorkspaceAdjustableEffect] {
        var result: [WorkspaceAdjustableEffect] = rgbSplitParameters.isEnabled ? [.rgbSplit] : []
        result.append(contentsOf: effectStack.orderedSlots.compactMap { slot in
            slot.parameters.isEnabled ? slot.effect : nil
        })
        return result
    }

    func isEnabled(_ effect: WorkspaceAdjustableEffect) -> Bool {
        effect == .rgbSplit ? rgbSplitParameters.isEnabled : effectStack[effect].isEnabled
    }

    /// Selects an effect using the current exclusive / ADD policy.
    /// Returns true when the effect was powered on.
    @discardableResult
    func select(_ effect: WorkspaceAdjustableEffect) -> Bool {
        if selectedEffect == effect {
            setEnabled(effect, false)
            selectedEffect = nil
            focusedSlot = nil
            return false
        }
        if !isStackArmed { disableAll() }
        setEnabled(effect, true)
        selectedEffect = effect
        focusedSlot = effectStack.firstSlotID(for: effect)
        lastFamilyVariant[EffectCatalog.canonical(effect)] = effect
        return true
    }

    /// Browser choices apply a look; tapping the current look must not toggle it off.
    func applyFromBrowser(_ effect: WorkspaceAdjustableEffect) {
        focus(nil)
        selectFamily(effect, preferExactVariant: true)
        if let selectedEffect {
            if !isStackArmed {
                enableOnly(selectedEffect)
                focus(selectedEffect)
            } else if !isEnabled(selectedEffect) {
                setEnabled(selectedEffect, true)
            }
        }
    }

    /// A grouped card focuses a placed variant. It never powers off an
    /// arbitrary sibling just because that sibling is not the default label.
    @discardableResult
    func selectFamily(_ effect: WorkspaceAdjustableEffect, preferExactVariant: Bool = false) -> Bool {
        let canonical = EffectCatalog.canonical(effect)
        let variants = EffectCatalog.variants(for: effect)
        guard variants.count > 1 else { return select(effect) }
        let candidates = effectStack.orderedSlots.filter {
            variants.contains($0.effect) && (!isStackArmed || !preferExactVariant || $0.effect == effect)
        }
        let chosen = candidates.first { $0.id == focusedSlot }
            ?? (preferExactVariant ? candidates.first { $0.effect == effect } : nil)
            ?? candidates.first
        if let chosen {
            focusedSlot = chosen.id
            selectedEffect = chosen.effect
            if preferExactVariant, chosen.effect != effect { changeVariant(to: effect) }
            lastFamilyVariant[canonical] = selectedEffect
            return true
        }
        let variant = preferExactVariant ? effect : (lastFamilyVariant[canonical] ?? canonical)
        // A disabled selected slot must reactivate rather than follow the
        // single-effect toggle-off path in select(_:).
        selectedEffect = nil
        return select(variant)
    }

    func isFamilyEnabled(_ effect: WorkspaceAdjustableEffect) -> Bool {
        let variants = EffectCatalog.variants(for: effect)
        if variants == [.rgbSplit] { return rgbSplitParameters.isEnabled }
        return effectStack.orderedSlots.contains { variants.contains($0.effect) && $0.parameters.isEnabled }
    }

    /// Changing algorithms is an edit to the focused slot, not a remove/add.
    /// Only algorithm controls are cached; power and mix belong to the slot.
    func changeVariant(to effect: WorkspaceAdjustableEffect) {
        guard let focusedSlot, let current = effectStack.slot(focusedSlot),
              current.effect != effect,
              EffectCatalog.canonical(current.effect) == EffectCatalog.canonical(effect)
        else { return }
        recordHistory()
        variantParameters[focusedSlot, default: [:]][current.effect] = current.parameters
        var parameters = variantParameters[focusedSlot]?[effect] ?? effect.defaultCameraParameters
        parameters.blend = current.parameters.blend
        parameters.isEnabled = current.parameters.isEnabled
        parameters.overlayX = current.parameters.overlayX
        parameters.overlayY = current.parameters.overlayY
        guard effectStack.replace(slot: focusedSlot, with: effect, parameters: parameters) else { return }
        selectedEffect = effect
        lastFamilyVariant[EffectCatalog.canonical(effect)] = effect
        recordHistory()
    }

    func beginPreview(_ composition: CompositionSnapshot) {
        if previewStash == nil {
            recordHistory()
            previewStash = (snapshot, selectedEffect, focusedSlot)
        }
        isPreviewing = true
        effectStack = composition.stack
        rgbSplitParameters = composition.rgb
    }

    func endPreview() {
        guard let stash = previewStash else { return }
        effectStack = stash.composition.stack
        rgbSplitParameters = stash.composition.rgb
        selectedEffect = stash.selection
        focusedSlot = stash.slot
        previewStash = nil
        isPreviewing = false
    }

    /// Auditions a browser choice against the live picture without leaving
    /// the browser. The first audition stashes the composition, so closing
    /// the browser over an unkept audition restores it through `endPreview`.
    /// An exclusive audition swaps — each tap re-applies over the stash
    /// instead of accumulating looks the operator never chose — while an
    /// additive (ADD-mode) audition stacks onto the previous one.
    func auditionFromBrowser(_ effect: WorkspaceAdjustableEffect) {
        if previewStash == nil {
            beginPreview(snapshot)
        } else if !isStackArmed, let stash = previewStash {
            effectStack = stash.composition.stack
            rgbSplitParameters = stash.composition.rgb
        }
        applyFromBrowser(effect)
    }

    /// Keeps the auditioned composition as the operator's edit: the stash is
    /// dropped and the whole audition lands as exactly one undo step, the
    /// same contract a preset preview keeps when it is committed.
    func commitPreview() {
        guard previewStash != nil else { return }
        previewStash = nil
        isPreviewing = false
        recordHistory()
    }

    /// Commits a choice that explicitly replaces the current composition,
    /// regardless of the ADD toggle. Radial browsing calls this only after the
    /// finger releases over an effect, so merely opening or cancelling the
    /// menu never mutates the live stack.
    @discardableResult
    func selectExclusively(_ effect: WorkspaceAdjustableEffect) -> Bool {
        isStackArmed = false
        if selectedEffect == effect {
            setEnabled(effect, false)
            selectedEffect = nil
            focusedSlot = nil
            return false
        }
        enableOnly(effect)
        selectedEffect = effect
        focusedSlot = effectStack.firstSlotID(for: effect)
        return true
    }

    func focus(_ effect: WorkspaceAdjustableEffect?) {
        selectedEffect = effect
        if let focusedSlot, effectStack.slot(focusedSlot)?.effect == effect { return }
        focusedSlot = effect.flatMap { effectStack.firstSlotID(for: $0) }
    }

    func dismissSelection() {
        selectedEffect = nil
        focusedSlot = nil
    }

    func setStackArmed(_ armed: Bool) {
        isStackArmed = armed
    }

    func setEnabled(_ effect: WorkspaceAdjustableEffect, _ enabled: Bool) {
        if effect == .rgbSplit {
            rgbSplitParameters.isEnabled = enabled
        } else {
            effectStack.setEnabled(enabled, for: effect)
        }
    }

    func disableAll() {
        rgbSplitParameters.isEnabled = false
        effectStack.disableAll()
        focusedSlot = nil
    }

    func enableOnly(_ effect: WorkspaceAdjustableEffect) {
        disableAll()
        setEnabled(effect, true)
        focusedSlot = effectStack.firstSlotID(for: effect)
    }

    func moveFocused(by offset: Int) -> Int? {
        guard let focusedSlot,
              let index = effectStack.orderedSlots.firstIndex(where: { $0.id == focusedSlot })
        else { return nil }
        let target = index + offset
        guard effectStack.orderedSlots.indices.contains(target) else { return nil }
        effectStack.move(
            fromOffsets: IndexSet(integer: index),
            toOffset: offset > 0 ? target + 1 : target
        )
        return target + 1
    }

    func toggleFocused() {
        guard let focusedSlot, let parameters = effectStack[slot: focusedSlot] else { return }
        effectStack.setEnabled(!parameters.isEnabled, slot: focusedSlot)
    }

    @discardableResult
    func duplicateFocused() -> WorkspaceAdjustableEffect? {
        guard let focusedSlot,
              let slot = effectStack.slot(focusedSlot),
              let copy = effectStack.duplicate(focusedSlot)
        else { return nil }
        self.focusedSlot = copy
        recordHistory()
        return slot.effect
    }

    func setGlobalBypassed(_ bypassed: Bool) {
        guard isGlobalBypassed != bypassed else { return }
        isGlobalBypassed = bypassed
    }

    func soloFocused() -> WorkspaceAdjustableEffect? {
        guard let focusedSlot, let selected = effectStack.slot(focusedSlot) else { return nil }
        for slot in effectStack.orderedSlots {
            effectStack.setEnabled(slot.id == focusedSlot, slot: slot.id)
        }
        rgbSplitParameters.isEnabled = false
        return selected.effect
    }

    func removeFocused() -> WorkspaceAdjustableEffect? {
        guard let focusedSlot, let slot = effectStack.slot(focusedSlot) else { return nil }
        effectStack.remove(focusedSlot)
        variantParameters[focusedSlot] = nil
        self.focusedSlot = nil
        if selectedEffect == slot.effect { selectedEffect = nil }
        return slot.effect
    }

    /// Called when a preview drag or pinch begins on a spectrum overlay, so
    /// the whole move lands as one undo step rather than one per frame.
    func beginOverlayMove() {
        beginContinuousEdit()
    }

    func endOverlayMove() {
        endContinuousEdit()
    }

    /// Preview drag commits a spectrum overlay's centre to its focused slot.
    /// The guard keeps ordinary focus and touch gestures from moving filters.
    func moveSpectrumOverlay(to position: SIMD2<Float>) {
        guard let effect = selectedEffect, effect.isSpectrumOverlay else { return }
        let slotID = focusedSlot ?? effectStack.firstSlotID(for: effect)
        guard let slotID, var parameters = effectStack[slot: slotID] else { return }
        parameters.overlayX = Double(min(max(position.x, 0.05), 0.95))
        parameters.overlayY = Double(min(max(position.y, 0.05), 0.95))
        effectStack[slot: slotID] = parameters
        focusedSlot = slotID
    }

    var spectrumOverlaySize: Double? {
        guard let effect = selectedEffect, effect.isSpectrumOverlay else { return nil }
        let slotID = focusedSlot ?? effectStack.firstSlotID(for: effect)
        return slotID.flatMap { effectStack[slot: $0]?.primary }
    }

    /// Pinch is relative to its start value, preventing cumulative scale drift
    /// while UIKit reports the recognizer's scale from the gesture origin.
    func resizeSpectrumOverlay(from start: Double, scale: Double) {
        guard let effect = selectedEffect, effect.isSpectrumOverlay else { return }
        let slotID = focusedSlot ?? effectStack.firstSlotID(for: effect)
        guard let slotID, var parameters = effectStack[slot: slotID] else { return }
        parameters.primary = min(max(start * scale, 0.15), 1)
        effectStack[slot: slotID] = parameters
        focusedSlot = slotID
    }

    /// Records one undo step.
    ///
    /// This used to be called from `EffectSessionEvents` on *every* mutation,
    /// and a scrub writes a parameter on every frame of the gesture — so a
    /// two-second drag pushed around a hundred and twenty full deep copies of
    /// the composition into a forty-entry ring. Two things broke at once: the
    /// copies were pure waste, and because the oldest entries were evicted
    /// first, undo could only rewind a fraction of the drag the operator was
    /// still holding.
    ///
    /// A gesture is now the unit. `beginContinuousEdit` freezes history for
    /// the duration; every write in between is free, and `endContinuousEdit`
    /// commits exactly one entry. Discrete edits — a tap, a menu, a reorder —
    /// call `recordHistory()` directly and behave exactly as before.
    func recordHistory() {
        guard !isPreviewing, !isContinuousEditInFlight else { return }
        commitHistoryIfChanged()
    }

    /// Opens a continuous edit. Everything until the matching
    /// `endContinuousEdit` collapses into a single undo entry.
    func beginContinuousEdit() {
        isContinuousEditInFlight = true
        // Anchor the gesture to the state it started from, so the first write
        // after this point is the one that will be restored by an undo.
        gestureAnchor = lastCommitted
    }

    /// Closes a continuous edit and commits it as one step.
    func endContinuousEdit() {
        guard isContinuousEditInFlight else { return }
        isContinuousEditInFlight = false
        gestureAnchor = nil
        commitHistoryIfChanged()
    }

    /// Commits whatever the current composition is, if it differs from the last
    /// committed one. Skips straight past the value the gesture started from,
    /// so a drag that ends where it began records nothing at all.
    private func commitHistoryIfChanged() {
        let current = snapshot
        guard current != lastCommitted else { return }
        // `gestureAnchor` is the pre-gesture state; falling back to
        // `lastCommitted` keeps discrete edits working unchanged.
        let anchor = gestureAnchor ?? lastCommitted
        if let anchor {
            undoStack.append(anchor)
            if undoStack.count > 40 { undoStack.removeFirst() }
        }
        redoStack.removeAll()
        gestureAnchor = nil
        self.lastCommitted = current
        publishHistoryDepth()
    }

    /// Pushes the stack depths to the UI. Called from every path that can move
    /// either stack.
    private func publishHistoryDepth() {
        let canStepBack = !undoStack.isEmpty
        let canStepForward = !redoStack.isEmpty
        if canUndo != canStepBack { canUndo = canStepBack }
        if canRedo != canStepForward { canRedo = canStepForward }
    }

    @discardableResult
    func undo() -> Bool {
        endPreview()
        endContinuousEdit()
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(snapshot)
        apply(previous)
        publishHistoryDepth()
        return true
    }

    @discardableResult
    func redo() -> Bool {
        endPreview()
        endContinuousEdit()
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(snapshot)
        apply(next)
        publishHistoryDepth()
        return true
    }

    func apply(_ snapshot: CompositionSnapshot) {
        // Advancing the revision on the way in keeps every state the session
        // visits on a strictly increasing counter. Without it a restored
        // snapshot could carry a revision the composition has already used,
        // and two different stacks would share an identity.
        var restored = snapshot.stack
        restored.markChanged()
        effectStack = restored
        rgbSplitParameters = snapshot.rgb
        lastCommitted = snapshot
        if let focusedSlot {
            if let slot = effectStack.slot(focusedSlot) {
                selectedEffect = slot.effect
            } else {
                self.focusedSlot = nil
                selectedEffect = nil
            }
        }
    }

    func apply(
        _ preset: GVPreset,
        using store: GVPresetStore,
        setup: inout CaptureSetupDraft
    ) {
        endPreview()
        store.apply(
            preset,
            to: &setup,
            rgb: &rgbSplitParameters,
            stack: &effectStack
        )
        recordHistory()
    }
}
