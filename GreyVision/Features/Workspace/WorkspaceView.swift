// swiftlint:disable file_length
import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var cameraRuntime: CameraRuntime
    @EnvironmentObject private var objectsRuntime: ARObjectRuntime
    @EnvironmentObject private var audioRuntime: AudioReactiveRuntime
    @EnvironmentObject private var blobRuntime: BlobTrackingRuntime
    @EnvironmentObject private var broadcastRuntime: GVBroadcastRuntime
    @EnvironmentObject private var preferences: GVPreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.scenePhase) private var scenePhase

    @State private var effectEditor = EffectEditingSession()
    @State private var activeTopDeck: WorkspaceTopDeck?
    @State private var dismissSelectionSignal = 0
    @State private var isSocialPresented = false
    @State private var renderStats = CameraRenderStatsMailbox()
    @StateObject private var fracture = SignalFractureController()
    /// HIDE UI: clears all chrome so the effect can be watched or recorded
    /// clean. Tapping anywhere brings it back.
    @State private var isChromeHidden = false
    @State private var keyboardOverlap: CGFloat = 0
    @StateObject private var hud = GVHUDState()
    @StateObject private var decay = GVDecayEngine()
    /// One notice channel for the whole workspace — the toast capsule above
    /// the dock replaces the red line that used to live under the top shell,
    /// the dock's own availability notice, and the deck tool-row flash.
    @StateObject private var toasts = GVToastBox()

    @StateObject private var controlLock = ControlLockManager()
    @StateObject private var beforeAfter = BeforeAfterManager()
    @State private var showControlLockSheet = false
    /// The Mac-link pairing code. Opened from the broadcast button's long
    /// press rather than the tap, because tapping still means "turn the link
    /// on" and the code only needs reading once per Mac.
    @State private var showPairingSheet = false

    /// Shared cadence anchor for every 4 Hz telemetry consumer (status line,
    /// both scrims). One start instant means their periodic timers fire in
    /// lockstep instead of four phase-shifted invalidations per second.
    @State private var telemetryTickStart = Date.now

    // MARK: Dynamic Type scaling

    // Fixed frames break at accessibility sizes; these track the user's text
    // setting so the chips grow with the type they carry.
    @ScaledMetric(relativeTo: .body) private var capturePairWidth: CGFloat = 46
    @ScaledMetric(relativeTo: .body) private var capturePairHeight: CGFloat = 42

    /// Operator collapsed the effect browser on its own.
    @State private var isFXCollapsed = false
    @State private var spectrumResizeStart: Double?

    // MARK: Unified capture

    @StateObject private var capture = GVRecordingTransaction()

    // MARK: Composition history (undo / redo)

    // MARK: Presets + guidance

    @StateObject private var presetStore = GVPresetStore.shared
    @State private var presetsPresented = false
    /// The take library and the timeline picker, opened from the dock's
    /// collection chips.
    @State private var takesPresented = false
    @State private var timelinePresented = false
    @StateObject private var timelineStore = GVTimelineStore.shared
    /// Self-timer for the shutter. Session state only — the delay itself is a
    /// preference, the countdown is not.
    @State private var countdown = GVCaptureCountdown()
    @State private var coachPresented = false

    // MARK: Timeline (GOD MODE)

    @StateObject private var timelinePlayer = GVTimelinePlayer()
    @StateObject private var beatDetector = GVBeatDetector()
    /// Owns when the microphone is allowed to stay open, and when the display
    /// is allowed to stay awake. See `GVPowerPolicy`.
    @State private var audioArmPolicy = GVAudioArmPolicy()
    @State private var isInteractionNotified = false
    @State private var interactionResetTask: Task<Void, Never>?
    /// #24. The App Intent / Shortcut bus. Observed rather than polled, so an
    /// intent fired from the Action button while the app was backgrounded is
    /// carried out the moment the workspace is on screen.
    @StateObject private var intentBridge = GVIntentBridge.shared

    /// One read for every mid-take surface in this file. The writer state in
    /// `CameraRuntime` is the single source of truth; naming it once here
    /// keeps the HUD, the capture pair, and the deck collapse from drifting
    /// into different definitions of "recording".
    private var isTakeLive: Bool {
        capture.isTakeLive(
            cameraRuntime: cameraRuntime,
            objectsRuntime: objectsRuntime,
            sourceMode: appModel.sourceMode
        )
    }

    private var rgbSplitParameters: RGBSplitEffectParameters { effectEditor.renderedRGBSplitParameters }
    private var effectStack: CameraEffectStackParameters { effectEditor.renderedEffectStack }

    /// One of the collection plates is up.
    private var collectionPlatePresented: Bool {
        presetsPresented || takesPresented || timelinePresented
    }

    /// The effect browser is away when chrome is hidden, when it has been
    /// collapsed on its own, when a collection plate has taken its space, or
    /// during a take unless the operator has just tapped the preview to bring
    /// it back.
    private var isDeckCollapsed: Bool {
        isChromeHidden || isFXCollapsed || collectionPlatePresented || (isTakeLive && !hud.isChromeRevealed)
    }

    private func dismissCollectionPlates() {
        withAnimation(GVMotion.resolved(GVMotion.collapse, reduceMotion: reduceMotion)) {
            presetsPresented = false
            takesPresented = false
            timelinePresented = false
        }
    }

    /// The plate the rail is currently showing, if any.
    private var activeCollectionPlate: GVCollectionPlate? {
        if presetsPresented { return .recipes }
        if takesPresented { return .takes }
        if timelinePresented { return .timeline }
        return nil
    }

    /// One plate at a time, and the chip that is up closes it again — the rail
    /// stays on screen while a plate is open, so it is the way back out.
    private func toggleCollectionPlate(_ plate: GVCollectionPlate) {
        if activeCollectionPlate == plate {
            dismissCollectionPlates()
        } else {
            openCollectionPlate(plate)
        }
    }

    /// A plate arriving has to be read; one leaving does not. So it tears open
    /// on the slower token and collapses shut on the faster one.
    private func openCollectionPlate(_ plate: GVCollectionPlate) {
        withAnimation(GVMotion.resolved(GVMotion.tear, reduceMotion: reduceMotion)) {
            presetsPresented = plate == .recipes
            takesPresented = plate == .takes
            timelinePresented = plate == .timeline
        }
    }

    /// The dock leaves the screen entirely only when the chrome is away. A
    /// collection plate takes the browser's room, not the rail's.
    private var dockRemoved: Bool {
        isChromeHidden || (isTakeLive && !hud.isChromeRevealed)
    }

    /// Screen recording that keeps the instrument in frame. The render-target
    /// writer can only ever produce the clean image.

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            // The expanded top and bottom decks share a finite vertical budget.
            // On short landscape screens the old independent caps could overlap
            // the capture row or push the dock beneath the home indicator.
            let dockMaxHeight = min(
                geometry.size.height * (isLandscape ? 0.42 : 0.34),
                isLandscape ? 176 : 292
            )
            let fixedChromeHeight: CGFloat = isLandscape ? 164 : 184

            // Landscape puts a notch inset on one side and a rounded-corner
            // inset on the other, and the chrome stack is sized to the safe
            // frame — so both rails stopped well short of the glass with a
            // band of unused black outside them. Negative padding widens the
            // rows back out over those insets. Zero in portrait, where the
            // horizontal insets are nothing and the padding would only push
            // controls under the rounded corners.
            let bleedLeading = isLandscape ? geometry.safeAreaInsets.leading : 0
            let bleedTrailing = isLandscape ? geometry.safeAreaInsets.trailing : 0
            let topDeckMaxHeight = min(
                geometry.size.height * (isLandscape ? 0.38 : 0.48),
                max(44, geometry.size.height - dockMaxHeight - fixedChromeHeight)
            )
            // A collection plate replaces the effect browser, so it gets the
            // browser's room — but it is capped rather than left to its own
            // ideal height. An uncapped plate grew past the top HUD, and the
            // controls stacked at its top ended up under the status row. The
            // rail (118pt: two rows plus the dock's own padding) stays up,
            // because it is what closes the plate again.
            let collectionPlateMaxHeight = min(
                geometry.size.height * 0.44,
                max(96, geometry.size.height - fixedChromeHeight - 118)
            )

            ZStack {
                GVTheme.void.ignoresSafeArea()

                viewport
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    // In objects mode the AR surface owns taps — that is how
                    // geometry gets placed. A SwiftUI tap layered over the whole
                    // viewport competed with the UIKit recogniser inside it, so
                    // placement taps were being eaten by the dismiss handler.
                    .onTapGesture {
                        // While chrome is hidden the tap only restores it, so
                        // a single tap never both reveals the UI and changes
                        // the effect selection underneath it.
                        if isChromeHidden {
                            withAnimation(GVMotion.resolved(GVMotion.panel, reduceMotion: reduceMotion)) { isChromeHidden = false }
                            return
                        }
                        // Mid-take the tap summons the deck back rather than
                        // clearing the selection: during recording the most
                        // likely intent is "show me the controls again", and
                        // wiping the live effect would be destructive.
                        if isTakeLive, !hud.isChromeRevealed {
                            withAnimation(GVMotion.resolved(GVMotion.deck, reduceMotion: reduceMotion)) { hud.revealChrome() }
                            return
                        }
                        guard appModel.sourceMode != .objects else { return }
                        dismissWorkspaceSelection()
                    }

                // Tap-away scrim for the three collection plates. It has to be
                // a sibling declared *below* the chrome group: as an overlay of
                // the whole screen it sat above the plates it dimmed, so a tap
                // on a plate's own controls landed on the scrim and closed the
                // plate instead of using it.
                if collectionPlatePresented {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture { dismissCollectionPlates() }
                        .transition(.opacity)
                        .accessibilityIdentifier("workspace.collection.scrim")
                }

                // The mid-take effect summary. The recording header itself
                // lives in the top row's own slot below, so it lands exactly
                // where the wordmark it replaces was.
                if isTakeLive, isDeckCollapsed {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        EffectChromeObserver(editor: effectEditor) { recordingHUD(for: geometry).summary }
                    }
                    .padding(.bottom, 96)
                    .transition(.opacity)
                    .zIndex(15)
                }

                VStack(spacing: 0) {
                    Group {
                        // Mid-take the recording header owns the top of the
                        // screen. Nothing is removed — a tap on the preview
                        // brings the full interface straight back. Both live in
                        // this one slot so the swap does not move the row.
                        if isTakeLive, isDeckCollapsed {
                            EffectChromeObserver(editor: effectEditor) { recordingHUD(for: geometry) }
                        } else {
                            topPanel(for: geometry)
                        }
                    }
                    .allowsHitTesting(!controlLock.lockUI)
                    .padding(.horizontal, 7)
                    .padding(.leading, -bleedLeading)
                    .padding(.trailing, -bleedTrailing)
                    // Level with the Dynamic Island rather than below it.
                    // The row already reserves a centre gap the width of
                    // the cutout, so the wordmark and the button cluster
                    // land in the shoulders either side and the band under
                    // the island — previously ~48pt of nothing — is gone.
                    // Touches are unaffected: the cutout only intercepts
                    // within its own bounds, and neither control overlaps
                    // it.
                    .padding(.top, geometry.safeAreaInsets.top > 30 ? 3 : 8)

                    if let activeTopDeck {
                        ScrollView(.vertical, showsIndicators: false) {
                            EffectChromeObserver(editor: effectEditor) { topControlDeck(activeTopDeck, geometry: geometry) }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxHeight: topDeckMaxHeight)
                        .padding(.horizontal, 10)
                        .padding(.leading, -bleedLeading)
                        .padding(.trailing, -bleedTrailing)
                        .padding(.top, 7)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Spacer(minLength: 8)
                }
                // Give the chrome an explicit viewport-sized layout region.
                // Scaling this whole stack in landscape used its centre as the
                // transform anchor, which pulled the capture row away from the
                // bottom edge and could leave it there through the next layout
                // pass after returning to portrait. Responsive deck limits
                // above handle the shorter landscape height without moving the
                // operator's primary controls.
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                // The bottom chrome is pinned to the bottom edge rather than
                // pushed there by a Spacer.
                //
                // Stack distribution kept failing here: whatever height the
                // browser reported — a full 292pt cap, a measured content
                // height, zero — the capture pair moved with it, and any
                // sibling that grew re-centred the row in the viewfinder.
                // Anchoring the group to the container's bottom makes its
                // position independent of everything above it, so the pair sits
                // on the browser and the browser sits on the safe edge, full
                // stop.
                .overlay(alignment: .bottom) {
                    // The capture pair and effect browser are one bottom-locked
                    // unit. When the browser is open the pair touches its top;
                    // when it closes the pair takes the browser's place at the
                    // safe bottom edge. A toast is an overlay, never a layout
                    // row, so it cannot push these controls into the frame.
                    VStack(spacing: 0) {
                        // The collection plates rise into the dock's space and
                        // stop above the capture pair, so a look can be
                        // auditioned and a take started without closing the
                        // plate first.
                        if presetsPresented {
                            GVPresetsDrawer(
                                setup: $appModel.setup,
                                editor: effectEditor,
                                maximumHeight: collectionPlateMaxHeight,
                                onClose: { dismissCollectionPlates() }
                            )
                            .environmentObject(presetStore)
                            .padding(.horizontal, 6)
                        }
                        if takesPresented {
                            GVTakeLibrarySheet(
                                maximumHeight: collectionPlateMaxHeight,
                                onClose: { dismissCollectionPlates() }
                            )
                            .padding(.horizontal, 6)
                        }
                        if timelinePresented {
                            GVTimelinePickerSheet(
                                store: timelineStore,
                                player: timelinePlayer,
                                editor: effectEditor,
                                setup: appModel.setup,
                                maximumHeight: collectionPlateMaxHeight,
                                onClose: { dismissCollectionPlates() }
                            )
                            .padding(.horizontal, 6)
                        }

                        // The transport appears once a timeline is armed, and
                        // stays out of the way until then. A cue with nothing
                        // selected has nothing to scrub, and a permanent bar
                        // would cost viewfinder height on every take.
                        if timelinePlayer.selectedTimeline != nil {
                            GVTimelineBar(
                                player: timelinePlayer,
                                onPickTimeline: { openCollectionPlate(.timeline) },
                                onSaveTimeline: saveCompositionAsTimeline
                            )
                            .padding(.horizontal, GVMetrics.gapWide)
                            .padding(.bottom, GVMetrics.gapTight)
                            .opacity(isChromeHidden ? 0 : 1)
                            .allowsHitTesting(!isChromeHidden)
                        }

                        detachedCaptureControls
                            .padding(.horizontal, GVMetrics.gapWide)
                            .padding(.leading, -bleedLeading)
                            .padding(.trailing, -bleedTrailing)
                            .padding(.top, GVMetrics.stepRelated)
                            .padding(.bottom, isDeckCollapsed
                                ? 6
                                : 0)
                            .animation(GVMotion.resolved(GVMotion.deck, reduceMotion: reduceMotion), value: isChromeHidden)

                        WorkspaceDockView(
                            editor: effectEditor,
                            recording: capture,
                            dismissSelectionSignal: $dismissSelectionSignal,
                            statsMailbox: renderStats,
                            onOpenRecipes: { toggleCollectionPlate(.recipes) },
                            onOpenTakes: { toggleCollectionPlate(.takes) },
                            onOpenTimeline: { toggleCollectionPlate(.timeline) },
                            activeCollection: activeCollectionPlate,
                            hidesBrowser: collectionPlatePresented,
                            maximumHeight: dockMaxHeight
                        )
                        .frame(height: dockRemoved ? 0 : nil, alignment: .bottom)
                        .clipped()
                        .padding(.horizontal, 6)
                        .padding(.leading, -bleedLeading)
                        .padding(.trailing, -bleedTrailing)
                        .padding(.bottom, dockRemoved ? 0 : 2)
                        .opacity(dockRemoved ? 0 : 1)
                        .allowsHitTesting(!dockRemoved)
                        .accessibilityHidden(dockRemoved)
                        .allowsHitTesting(!dockRemoved && !controlLock.lockEffectStack && !controlLock.lockUI)
                        .animation(GVMotion.resolved(GVMotion.deck, reduceMotion: reduceMotion), value: dockRemoved)
                    }
                    .overlay(alignment: .top) {
                        GVToastCapsule(
                            text: toasts.message,
                            actionTitle: toasts.actionTitle,
                            onAction: toasts.performAction
                        )
                        .offset(y: -GVMetrics.touchTarget)
                        .opacity(isChromeHidden ? 0 : 1)
                        .animation(GVMotion.resolved(GVMotion.deck, reduceMotion: reduceMotion), value: toasts.message)
                    }
                    // Pushed down by exactly the bottom safe-area inset.
                    //
                    // `.ignoresSafeArea(edges: .bottom)` was tried here first
                    // and did nothing: the chrome stack is already sized to a
                    // safe-area frame, so the overlay had no inset of its own
                    // left to give back and the rail stayed a full inset — a
                    // little over 30pt — above the physical edge.
                    //
                    // `offset` is a pure visual translation with no layout
                    // negotiation, so it cannot be absorbed the same way. The
                    // group ends up on the bottom edge, over the home-indicator
                    // strip, which is where it was asked to be. `ignoresSafeArea`
                    // stays on so nothing clips at the old boundary.
                    .ignoresSafeArea(edges: .bottom)
                    .offset(y: geometry.safeAreaInsets.bottom + 6 - keyboardOverlap)
                }
                // One motion clock for the whole mid-take transition. When
                // recording flips, every dependent surface — HUD swap, deck
                // collapse, capture-pair state — animates together instead of
                // each part running its own timing.
                .animation(
                    GVMotion.resolved(GVMotion.deck, reduceMotion: reduceMotion),
                    value: isTakeLive
                )
                .ignoresSafeArea(edges: [.top, .bottom])
                // HIDE UI restore layer. When the eye icon sends chrome away,
                // this transparent sheet owns every tap: one touch anywhere
                // brings the instrument back. Without it the only recovery
                // was a gesture nobody could discover.
                .overlay {
                    if isChromeHidden {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(GVMotion.resolved(GVMotion.panel, reduceMotion: reduceMotion)) { isChromeHidden = false }
                            }
                            .accessibilityLabel("Show interface")
                            .accessibilityIdentifier("workspace.chrome.restore")
                    }
                }
                .allowsHitTesting(true)

                if isSocialPresented {
                    SocialLinksOverlay(isPresented: $isSocialPresented)
                        .transition(.scale(scale: 0.9, anchor: .topLeading).combined(with: .opacity))
                        .zIndex(30)
                }

                // Self-timer. The number is the whole point of the surface, so
                // it is set at frame size rather than docked in a corner, and
                // the only other control is the way out.
                if countdown.deadline != nil {
                    VStack(spacing: 12) {
                        Text("\(countdown.remaining)")
                            .font(.system(size: 76, weight: .thin, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(GVTheme.bone)
                            .contentTransition(.numericText(countsDown: true))
                            .accessibilityLabel("Shutter in \(countdown.remaining) seconds")

                        Button {
                            cancelCountdown()
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(GVTheme.bone)
                                .padding(.horizontal, 18)
                                .frame(height: 34)
                        }
                        .buttonStyle(GVGlassActionButtonStyle())
                        .accessibilityIdentifier("workspace.countdown.cancel")
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: countdown.remaining)
                    .zIndex(29)
                }

                if controlLock.lockUI {
                    Button {
                        showControlLockSheet = true
                    } label: {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: GVMetrics.touchTarget, height: GVMetrics.touchTarget)
                            .gvGlassChip(radius: 12, active: true, tint: .white)
                    }
                    .buttonStyle(GVPressStyle())
                    .accessibilityLabel("Unlock interface")
                    .position(x: geometry.size.width - 32, y: geometry.safeAreaInsets.top + 26)
                    .zIndex(36)
                }

                if audioRuntime.incantationActive {
                    IncantationOverlay()
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .zIndex(25)
                }

                // Signal path opened by the splash raster tear; removes itself.
                if let entrySettleStart = appModel.entrySettleStart {
                    GVSignalPathSettle(
                        start: entrySettleStart,
                        onFinished: appModel.finishEntrySettle
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .zIndex(40)
                }
            }
        }
        .overlay {
            if coachPresented {
                GVCoachCard {
                    withAnimation(GVMotion.resolved(GVMotion.collapse, reduceMotion: reduceMotion)) {
                        coachPresented = false
                    }
                    preferences.coachSeen = true
                }
                .zIndex(34)
            }
        }
        .overlay {
            if showControlLockSheet {
                ControlLockView(manager: controlLock) {
                    withAnimation(GVMotion.resolved(GVMotion.collapse, reduceMotion: reduceMotion)) {
                        showControlLockSheet = false
                    }
                }
                .zIndex(35)
            }
            if showPairingSheet {
                GVPairingCodeSheet(
                    code: broadcastRuntime.pairingCode,
                    onRegenerate: { broadcastRuntime.regeneratePairingCode(); return broadcastRuntime.pairingCode },
                    onDismiss: {
                        withAnimation(GVMotion.resolved(GVMotion.collapse, reduceMotion: reduceMotion)) {
                            showPairingSheet = false
                        }
                    }
                )
                .zIndex(36)
            }
        }
        .background {
            EffectSessionEvents(editor: effectEditor, publishState: { broadcastRuntime.control.publishState() })
        }
        .onChange(of: scenePhase) { _, phase in
            refreshAmbientSampling()
            if phase != .active { cancelCountdown() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let overlap = max(UIScreen.main.bounds.maxY - frame.minY, 0)
            withAnimation(GVMotion.resolved(GVMotion.panel, reduceMotion: reduceMotion)) {
                keyboardOverlap = overlap
            }
        }
        .onChange(of: isChromeHidden) { _, _ in refreshAmbientSampling() }
        .onChange(of: controlLock.lockCamera) { _, locked in
            if locked, activeTopDeck == .camera { activeTopDeck = nil }
        }
        // The desktop shows a live record indicator, so the take's state has
        // to reach it the same way the composition does.
        .onChange(of: isTakeLive) { _, live in
            broadcastRuntime.control.setRecording(live)
            publishTakeRisk()
        }
        // Audio effects render against a silent uniform without the
        // microphone. The catalogue carries that as a reason, so a change in
        // availability has to resend it.
        .onChange(of: audioRuntime.state) { _, state in
            broadcastRuntime.control.setAudioAvailable(state == .running)
        }
        .onChange(of: intentBridge.pendingCommand) { _, command in
            guard let command else { return }
            performIntentCommand(command)
        }
        .onAppear {
            attachBroadcastControl()
            audioArmPolicy.attach(audio: audioRuntime, editor: effectEditor)
            // Finished movies reach the operator-visible capture state through
            // the runtimes, because a writer's message string cannot tell a
            // Photos save from a take kept on the device.
            capture.bindTakeOutcomes(cameraRuntime: cameraRuntime, objectsRuntime: objectsRuntime)
            publishTakeRisk()
            // A shortcut may have fired while this view was not mounted.
            if let command = intentBridge.pendingCommand {
                performIntentCommand(command)
            }
            // The runtime holds the value the Metal surface reads; the
            // preference is only the persisted copy of the choice.
            cameraRuntime.renderQuality = preferences.renderQuality
        }
        .onChange(of: broadcastRuntime.isConnected) { _, connected in
            guard connected else { return }
            withAnimation(GVMotion.resolved(GVMotion.deck, reduceMotion: reduceMotion)) { activeTopDeck = nil }
        }
        .onChange(of: capture.statusMessage) { _, message in
            guard let message else { return }
            showTopNotice(message)
        }
        // Stills save themselves to the camera roll the moment the frame is
        // in hand; this line is the whole confirmation, so it must surface
        // wherever the operator is — not only when a deck happens to be open.
        .onChange(of: cameraRuntime.screenshotMessage) { _, message in
            guard let message else { return }
            showTopNotice(message)
        }
        // Said once, when it happens. Driving ISO or shutter stops the device
        // metering — a state worth naming, along with the way out of it.
        .onChange(of: cameraRuntime.snapshot.exposureLocked) { _, locked in
            guard locked else { return }
            showTopNotice("Manual exposure · Long-press ISO to restore auto")
        }
        .environmentObject(hud)
        .environmentObject(decay)
        .environmentObject(toasts)
        .environmentObject(audioArmPolicy)
        .onAppear {
            refreshAmbientSampling()
            if !preferences.coachSeen {
                withAnimation(GVMotion.resolved(GVMotion.tear, reduceMotion: reduceMotion)) {
                    coachPresented = true
                }
            }
            capture.burnHUD = preferences.watermarkEnabled
            // Ensure vignette is disabled on the preview screen
            effectEditor.setEnabled(.vignette, false)
            // GOD MODE: wire the timeline player and the beat detector into
            // the live runtimes. Both attach on appear, both detach on
            // disappear so a workspace transition never leaks a callback.
            timelinePlayer.attach(editor: effectEditor)
            beatDetector.attach(audio: audioRuntime)
        }
        .onDisappear {
            GVAmbientLight.shared.deactivate()
            beforeAfter.release(editor: effectEditor)
            hud.stop()
            decay.stop()
            timelinePlayer.stop()
            cancelCountdown()
        }
        .animation(GVMotion.resolved(GVMotion.panel, reduceMotion: reduceMotion), value: activeTopDeck)
        // Capture failures were being written to `snapshot.errorMessage` and
        // read by nothing. A denied permission, an unattachable format or a
        // session configuration failure all produced a dead viewport and a
        // silent UI, which is why the camera being down has been impossible
        // to diagnose from the device. The failure now says what it was.
        .overlay(alignment: .center) {
            // swiftlint:disable opening_brace
            if let message = cameraRuntime.snapshot.errorMessage,
               cameraRuntime.snapshot.state == .failed
            {
                // swiftlint:enable opening_brace
                CameraFailureNotice(
                    message: message,
                    reason: cameraRuntime.snapshot.interruptionReason,
                    onRetry: { appModel.restartEngine() }
                )
            }
        }
        .onChange(of: objectsRuntime.constellationMessage) { _, message in
            if let message {
                showTopNotice(message)
            }
        }
        .background { WorkspaceBeatPump(audio: audioRuntime, detector: beatDetector) }
        // Any touch anywhere in the workspace means the operator is present,
        // which is what postpones the idle-timer release. Installed as a
        // simultaneous gesture so it observes without consuming: the
        // viewfinder's own tap, pan and pinch recognizers have to keep
        // working exactly as they did.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in noteOperatorInteraction() }
        )
    }

    private func refreshAmbientSampling() {
        if scenePhase == .active, !isChromeHidden {
            GVAmbientLight.shared.activate(mailbox: renderStats)
        } else {
            GVAmbientLight.shared.deactivate()
        }
    }

    // MARK: - Shutter with an optional self-timer

    /// The one entry point both capture controls go through.
    ///
    /// The delay is a preference and the countdown is session state, so a
    /// backgrounded app drops the countdown rather than firing a shutter into a
    /// viewfinder nobody is looking at.
    private func requestCapture(_ intent: GVCaptureCountdown.Intent) {
        fire(intent, after: GVCaptureCountdown.Delay(rawValue: preferences.captureCountdownSeconds) ?? .off)
    }

    /// Fires an intent now or when the self-timer runs out.
    ///
    /// The work is written against the runtimes rather than `self`: a countdown
    /// outlives the render pass that started it, and `WorkspaceView` is a struct
    /// whose lifetime is exactly that render pass.
    private func fire(_ intent: GVCaptureCountdown.Intent, after delay: GVCaptureCountdown.Delay) {
        let transaction = capture
        let camera = cameraRuntime
        let objects = objectsRuntime
        let sourceMode = appModel.sourceMode
        let perform: @MainActor (GVCaptureCountdown.Intent) -> Void = { intent in
            switch intent {
            case .photo:
                transaction.takeScreenshot(cameraRuntime: camera)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case .video:
                transaction.toggleRecording(
                    cameraRuntime: camera,
                    objectsRuntime: objects,
                    sourceMode: sourceMode
                )
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
        guard delay != .off else {
            perform(intent)
            return
        }
        UISelectionFeedbackGenerator().selectionChanged()
        // Arming the timer puts the frame back on screen: the operator is about
        // to stand behind the camera, and a countdown half hidden under the
        // settings deck is not a countdown they can trust.
        withAnimation(GVMotion.resolved(GVMotion.panel, reduceMotion: reduceMotion)) {
            activeTopDeck = nil
        }
        countdown.run(intent, delay: delay, onFire: perform)
    }

    private func cancelCountdown() {
        countdown.cancel()
    }

    /// Arms the timeline bar by saving the composition that is on screen.
    /// Keyframes are authored from the picker, not here: a saved cue with no
    /// keyframes still carries the capture format and the base stack, which is
    /// what the bar's play button needs.
    private func saveCompositionAsTimeline() {
        timelineStore.save(name: "", duration: 8, from: effectEditor, setup: appModel.setup)
        showTopNotice("Composition saved as a timeline")
    }

    /// Built once and used in two places: the header goes in the top row's
    /// slot, the summary at the foot of the frame.
    private func recordingHUD(for geometry: GeometryProxy) -> GVRecordingHUD {
        GVRecordingHUD(
            startedAt: capture.recordingStartedAt,
            activeEffects: effectEditor.activeEffects.map(\.label),
            geometry: geometry
        )
    }

    private var viewport: some View {
        ZStack {
            EffectPreviewObserver(editor: effectEditor) { composition in
                CameraSurfaceView(
                    fracture: fracture,
                    rgbSplitParameters: composition.rgb,
                    effectStack: composition.stack,
                    statsMailbox: renderStats,
                    onPreviewTap: dismissWorkspaceSelection,
                    onFocus: { point in
                        // Tap-to-focus on the live preview. The runtime already
                        // queues this on the session queue, so a tap while
                        // recording also refocuses the in-flight take without
                        // dropping a frame.
                        cameraRuntime.focus(at: point)
                    },
                    recordingTransaction: capture,
                    onSpectrumOverlayDrag: { position in
                        effectEditor.moveSpectrumOverlay(to: position)
                    },
                    onSpectrumOverlayPinch: { event in
                        switch event {
                        case .began:
                            effectEditor.beginOverlayMove()
                            spectrumResizeStart = effectEditor.spectrumOverlaySize
                        case let .changed(scale):
                            guard let start = spectrumResizeStart else { return }
                            effectEditor.resizeSpectrumOverlay(from: start, scale: Double(scale))
                        case .ended:
                            spectrumResizeStart = nil
                            effectEditor.endOverlayMove()
                        }
                    },
                    onOverlayGesturePhase: { began in
                        if began {
                            effectEditor.beginOverlayMove()
                        } else {
                            effectEditor.endOverlayMove()
                        }
                    }
                )
            }

            if cameraRuntime.snapshot.state != .running || cameraRuntime.snapshot.isSynthetic {
                GVScanlines(opacity: 0.028)
            }

            // The animated scanlines now composite on the GPU inside the camera
            // preview fragment; the SwiftUI canvas overlay is only kept for the
            // depth / AR modes, which have their own Metal surfaces.

            // Vignette removed. The radial gradient that used to darken the
            // corners of the live preview was reading as a render fault rather
            // than atmosphere, and any given effect can produce its own
            // edge fall-off when the operator wants one.

            if appModel.sourceMode == .camera, blobRuntime.isEnabled {
                BlobTrackingOverlay(
                    blobs: blobRuntime.blobs,
                    sourceSize: blobRuntime.sourceSize
                )
                .transition(.opacity)
            }
        }
        .clipped()
        // #25. The fast path. Simultaneous so the viewfinder's own tap, pan
        // and pinch keep working: this only reacts at the end of a long
        // horizontal travel, which none of them produce.
        .simultaneousGesture(historySwipe)
        .accessibilityAction(named: "Undo") { undoComposition() }
        .accessibilityAction(named: "Redo") { redoComposition() }
    }

    // MARK: Audio arming

    /// Audio-reactive effects are inert without the analyser, so selecting one
    /// anywhere — a browser tile, a shortcut, a preset — requests the
    /// microphone too.
    private func armAudioIfNeeded(for effect: WorkspaceAdjustableEffect) {
        guard effect.requiresAudioAnalysis, !audioRuntime.isEnabled else { return }
        switch audioRuntime.state {
        case .denied:
            showMicrophoneDenied(for: effect)
        case .failed:
            showTopNotice("\(effect.label) · audio engine unavailable")
        default:
            Task { @MainActor in
                await audioRuntime.start()
                if audioRuntime.state == .denied {
                    showMicrophoneDenied(for: effect)
                }
            }
        }
    }

    /// #14. Naming the problem is not the same as resolving it. A refused
    /// microphone used to produce a two-second notice and then nothing, so the
    /// effect sat in the stack rendering against a silent uniform with no way
    /// forward short of remembering that the fix was in Settings.
    private func showMicrophoneDenied(for effect: WorkspaceAdjustableEffect) {
        toasts.show(
            "\(effect.label) needs microphone access",
            action: GVToastBox.ToastAction(title: "OPEN", handler: openMicrophoneSettings)
        )
    }

    private func openMicrophoneSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// #25. Undo and redo, with the outcome said out loud. A history the
    /// operator cannot tell worked from is worse than no history, so both
    /// paths confirm and the empty path says so too.
    @discardableResult
    func undoComposition() -> Bool {
        let didUndo = effectEditor.undo()
        GVInteractionHaptics.commit()
        toasts.show(didUndo ? "Undo" : "Nothing to undo")
        return didUndo
    }

    @discardableResult
    func redoComposition() -> Bool {
        let didRedo = effectEditor.redo()
        GVInteractionHaptics.commit()
        toasts.show(didRedo ? "Redo" : "Nothing to redo")
        return didRedo
    }

    /// #24. Carries out a command an intent posted. The workspace is the only
    /// thing that knows how to do any of this, which is exactly why intents
    /// post rather than call — an intent can arrive when this view does not
    /// exist.
    private func performIntentCommand(_ command: GVIntentCommand) {
        switch command {
        case .captureStill:
            cameraRuntime.takeScreenshot()
            showTopNotice("Capturing still")
        case .toggleRecording:
            let wasRecording = isTakeLive
            capture.toggleRecording(
                cameraRuntime: cameraRuntime,
                objectsRuntime: objectsRuntime,
                sourceMode: appModel.sourceMode
            )
            wasRecording
                ? UIImpactFeedbackGenerator(style: .light).impactOccurred()
                : UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .undo:
            undoComposition()
        case .redo:
            redoComposition()
        case .toggleStackArmed:
            let armed = !effectEditor.isStackArmed
            effectEditor.setStackArmed(armed)
            showTopNotice(armed ? "Add mode on" : "Add mode off")
        case .soloFocused:
            guard let effect = effectEditor.soloFocused() else {
                toasts.show("No effect selected")
                return
            }
            showTopNotice("Soloed \(effect.label)")
        case .removeFocused:
            guard let effect = effectEditor.removeFocused() else {
                toasts.show("No effect selected")
                return
            }
            showTopNotice("\(effect.label) removed")
        case .toggleBypass:
            effectEditor.setGlobalBypassed(!effectEditor.isGlobalBypassed)
            showTopNotice(effectEditor.isGlobalBypassed ? "Effects bypassed" : "Effects restored")
        case .armAudio:
            Task { @MainActor in
                if audioRuntime.isEnabled {
                    audioArmPolicy.setManualArm(false)
                    toasts.show("Audio reactivity off")
                } else {
                    audioArmPolicy.setManualArm(true)
                    await audioRuntime.start()
                    toasts.show(audioRuntime.state == .running
                        ? "Audio reactivity on"
                        : "\(audioRuntime.state.label) — microphone unavailable")
                }
            }
        case .nextShelf:
            advanceIntentShelf()
        case let .selectEffect(name):
            guard let effect = EffectCatalog.search(name).first
                ?? WorkspaceAdjustableEffect.allCases.first(where: {
                    $0.label.caseInsensitiveCompare(name) == .orderedSame
                })
            else {
                toasts.show("No effect called \(name)")
                return
            }
            armAudioIfNeeded(for: effect)
            effectEditor.selectExclusively(effect)
            preferences.noteEffectUsed(effect.rawValue)
            showTopNotice("\(effect.label) enabled")
        }
        intentBridge.consume()
    }

    /// Steps the dock to the next family in its own order, wrapping at the end.
    /// Driven from the intent bus so the shortcut and the rail agree on what
    /// "next" means.
    private func advanceIntentShelf() {
        toasts.show("Open the browser to change shelf")
    }

    /// Three fingers, one axis. Left steps back, right steps forward, which is
    /// the direction the history actually moves in, and is a gesture nobody
    /// uses for anything else on the preview.
    private var historySwipe: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { gesture in
                let isHorizontal = abs(gesture.translation.width) > abs(gesture.translation.height) * 1.5
                guard isHorizontal, !isChromeHidden else { return }
                if gesture.translation.width < 0 {
                    undoComposition()
                } else {
                    redoComposition()
                }
            }
    }

    /// Tells the app layer whether a take is at risk, which is the only thing
    /// that justifies holding the display awake.
    private func publishTakeRisk() {
        appModel.updateTakeRisk(
            isRecording: isTakeLive,
            isBroadcasting: broadcastRuntime.isConnected,
            armedEffectCount: effectEditor.activeEffects.count
        )
    }

    /// A touch anywhere in the workspace. Coalesced: a drag fires this on
    /// every frame, and the app layer only needs to know that *something*
    /// happened, so one notification per gesture is plenty.
    private func noteOperatorInteraction() {
        guard !isInteractionNotified else { return }
        isInteractionNotified = true
        NotificationCenter.default.post(name: AppRootView.operatorDidInteract, object: nil)
        interactionResetTask?.cancel()
        interactionResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            isInteractionNotified = false
        }
    }

    /// Capture action flanking the level gauge.
    ///
    /// Drawn small but given a full-size hit region: the visual weight has to
    /// stay low so the row does not compete with the frame, while the target
    /// still has to be findable without looking. Recording state is carried by
    /// the glyph and the border together rather than by colour alone.
    /// Collapses the bottom menus, and brings them back.
    ///
    /// Replaces the HIDE UI text button that lived inside the effect deck. That
    /// control could only be reached with an effect already selected, and it
    /// vanished along with everything else it hid — leaving a tap-anywhere
    /// gesture as the only way back, which nothing on screen advertised.
    ///
    /// This holds one position in the layout whether the panels are up or
    /// down, so the way out and the way back are the same target.
    /// How many effects are actually rendering right now — stacked slots plus
    /// RGB split, which lives outside the stack model.
    private var armedEffectCount: Int {
        effectEditor.activeEffects.count
    }

    /// Photo + record, detached from the dock. Record carries its state in
    /// glyph and border together; photo is a plain instrument button. Visible
    /// whenever chrome shows — and during a take even when it does not, since
    /// stop must outlive the interface it belongs to.
    private var detachedCaptureControls: some View {
        let recording = isTakeLive

        // Grouped so the three controls render as one optical system rather
        // than three independent blur layers sitting over the same viewfinder.
        // Same treatment the dock's rails already get.
        return HStack(spacing: GVMetrics.gapTight) {
            Button {
                requestCapture(.photo)
            } label: {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(GVTheme.bone.opacity(0.9))
                    .frame(width: capturePairWidth, height: capturePairHeight)
            }
            .buttonStyle(GVGlassCaptureButtonStyle(tint: .white, buttonSize: CGSize(width: capturePairWidth, height: capturePairHeight)))
            .accessibilityLabel("Capture photo")
            .accessibilityIdentifier("workspace.capture.photo")
            // The capture reports what it actually wrote, resolution included,
            // so the outcome is readable from here rather than only in a toast
            // that has already faded.
            .accessibilityValue(cameraRuntime.screenshotMessage ?? "")
            .opacity(isChromeHidden ? 0 : 1)
            .allowsHitTesting(!isChromeHidden && !controlLock.lockUI)

            Spacer(minLength: 0)

            EffectChromeObserver(editor: effectEditor) { beforeAfterControl }

            EffectChromeObserver(editor: effectEditor) { chromeToggle }
                .opacity(isChromeHidden ? 0 : 1)
                .allowsHitTesting(!isChromeHidden && !controlLock.lockUI)

            Spacer(minLength: 0)

            Button {
                // A running countdown is cancelled by the same control that
                // started it; a live take is stopped, never delayed.
                if countdown.deadline != nil {
                    cancelCountdown()
                } else if recording {
                    capture.toggleRecording(
                        cameraRuntime: cameraRuntime,
                        objectsRuntime: objectsRuntime,
                        sourceMode: appModel.sourceMode
                    )
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } else {
                    requestCapture(.video)
                }
            } label: {
                Image(systemName: recording ? "stop.fill" : "record.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(recording ? GVTheme.record : GVTheme.bone.opacity(0.9))
                    .frame(width: capturePairWidth, height: capturePairHeight)
            }
            .buttonStyle(GVGlassCaptureButtonStyle(tint: recording ? GVTheme.record : .white, isRecording: recording, buttonSize: CGSize(width: capturePairWidth, height: capturePairHeight)))
            .accessibilityLabel(countdown.deadline != nil ? "Cancel countdown" : (recording ? "Stop recording" : "Record video"))
            .accessibilityIdentifier("workspace.record.toggle")
            .opacity(isChromeHidden && !recording ? 0 : 1)
            .allowsHitTesting(!isChromeHidden || recording)
        }
        .gvLiquidGlassContainer(spacing: GVMetrics.gapTight)
    }

    /// Momentary clean-source audition. Touch-down bypasses the rendered
    /// composition; release restores exactly what was active. The editor's
    /// slots and history never change.
    private var beforeAfterControl: some View {
        Image(systemName: beforeAfter.isHolding || effectEditor.isGlobalBypassed ? "eye.fill" : "eye")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(beforeAfter.isHolding ? Color.white : GVTheme.bone.opacity(0.78))
            .frame(width: capturePairWidth, height: capturePairHeight)
            .gvGlassButton(radius: 7, active: beforeAfter.isHolding || effectEditor.isGlobalBypassed)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        beforeAfter.startHold(editor: effectEditor)
                    }
                    .onEnded { _ in
                        beforeAfter.release(editor: effectEditor)
                    }
            )
            .opacity(isChromeHidden ? 0 : 1)
            .allowsHitTesting(!isChromeHidden && !controlLock.lockUI)
            .accessibilityElement()
            .accessibilityLabel("Before and after")
            .accessibilityHint("Hold to reveal the clean camera image")
            .accessibilityIdentifier("workspace.before-after")
            .accessibilityAction {
                effectEditor.setGlobalBypassed(!effectEditor.isGlobalBypassed)
            }
    }

    private struct GVGlassCaptureButtonStyle: ButtonStyle {
        let tint: Color
        var isRecording: Bool = false
        let buttonSize: CGSize

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .gvGlassButton(radius: 12, active: configuration.isPressed)
                .overlay {
                    if isRecording {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(GVTheme.record.opacity(configuration.isPressed ? 0.9 : 0.7), lineWidth: 1)
                    } else if configuration.isPressed {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.9)
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: GVMetrics.hairline)
                    }
                }
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.98 : 1))
                .brightness(configuration.isPressed ? 0.02 : 0)
                .animation(GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion), value: configuration.isPressed)
        }
    }

    /// Collapses the bottom menus, and brings them back. Doubles as a live
    /// status readout: the count of rendering effects glows while any are
    /// armed, so stack state is glanceable without opening anything.
    private var chromeToggle: some View {
        let armed = armedEffectCount > 0
        return Button {
            withAnimation(GVMotion.resolved(GVMotion.deck, reduceMotion: reduceMotion)) { isFXCollapsed.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isFXCollapsed ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .medium))
                Text(armed ? "Effects · \(armedEffectCount)" : "Effects")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(armed ? Color.white : GVTheme.bone.opacity(0.85))
            .frame(width: 108, height: 28)
        }
        .buttonStyle(GVGlassChromeToggleStyle(armed: armed))
        .accessibilityLabel(isFXCollapsed ? "Show effects" : "Hide effects")
        .accessibilityIdentifier("workspace.chrome.toggle")
    }

    private struct GVGlassChromeToggleStyle: ButtonStyle {
        let armed: Bool

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .gvGlassChip(radius: 14, active: armed || configuration.isPressed, tint: .white)
                .frame(width: 108, height: 28)
                .frame(height: GVMetrics.touchTarget)
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.98 : 1))
                .brightness(configuration.isPressed ? 0.02 : 0)
                .animation(GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion), value: configuration.isPressed)
        }
    }

    private enum WorkspaceTopDeck: String, Identifiable {
        case camera
        case settings

        var id: String {
            rawValue
        }
    }
}

// MARK: - Top shell + control decks

private extension WorkspaceView {
    func topPanel(for geometry: GeometryProxy) -> some View {
        let portrait = geometry.size.width < geometry.size.height
        let compact = geometry.size.width < 400
        let panelHeight: CGFloat = portrait ? 56 : 50
        let horizontalInset: CGFloat = portrait ? 12 : 11
        let islandReserve = portrait
            ? min(max(geometry.size.width * 0.30, compact ? 104 : 122), 146)
            : 0

        return VStack(spacing: GVMetrics.stepInternal) {
            HStack(spacing: 0) {
                Button {
                    isSocialPresented = true
                } label: {
                    GVCyclingWordmark(
                        text: "grey//VISION",
                        size: portrait ? (compact ? 13.2 : 14.5) : 11.4,
                        tracking: portrait ? 0.34 : 0.5
                    )
                    .accessibilityIdentifier("workspace.screen")
                    .accessibilityLabel("grey VISION")
                    .contentShape(Rectangle())
                }
                .buttonStyle(GVPressStyle())
                // The wordmark was hugging the very edge of the screen and
                // reading as off-centre with the device shoulder. A small
                // optical lead shifts it away from the rounded glass and lines
                // up the start of the wordmark with the rest of the chrome
                // (the telemetry strip below is inset by `horizontalInset +
                // 6` already).
                .padding(.leading, 6)
                .frame(maxWidth: .infinity, alignment: .leading)

                Color.clear
                    .frame(width: islandReserve)
                    .accessibilityHidden(true)

                // Mid-take the right shoulder stops being a menu: the camera
                // and settings chips give way to the running timecode, so
                // take state reads from across the room whether or not the
                // operator has summoned the interface back.
                if isTakeLive {
                    HStack(spacing: GVMetrics.stepRelated) {
                        recordingTimecode
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    HStack(spacing: 7) {
                        shellChip(
                            symbol: "camera.aperture",
                            id: "camera",
                            active: activeTopDeck == .camera,
                            usesCharcoalPlate: true
                        ) { toggleTopDeck(.camera) }

                        shellChip(
                            symbol: "slider.horizontal.3",
                            id: "settings",
                            active: activeTopDeck == .settings,
                            usesCharcoalPlate: true
                        ) { toggleTopDeck(.settings) }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.horizontal, horizontalInset)
            .frame(height: panelHeight)

            GVEdgeRule()
                .padding(.horizontal, horizontalInset + 6)

            GVTelemetryStrip(
                statsMailbox: renderStats,
                onExposureNotice: showTopNotice,
                tickStart: telemetryTickStart
            )
            .padding(.horizontal, horizontalInset)

            if let field = hud.activeField {
                GVFieldAdjuster(field: field, statsMailbox: renderStats, onNotice: showTopNotice)
                    .padding(.horizontal, horizontalInset)
                    .padding(.top, GVMetrics.stepMicro)
                    .transition(.opacity)
            }
        }
        .animation(GVMotion.resolved(GVMotion.scan, reduceMotion: reduceMotion), value: hud.activeField)
        .gvDecay(decay)
    }

    /// Top-shell control. The settings trigger receives the same compact
    /// charcoal plate used by the workspace dock; camera navigation remains a
    /// lightweight shell glyph.
    func shellChip(
        symbol: String,
        id: String,
        active: Bool,
        usesCharcoalPlate _: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let glyph: Color = active ? Color.white : GVTheme.bone.opacity(0.62)

        return Button {
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(glyph)
                .frame(width: 45, height: 44)
        }
        .buttonStyle(GVGlassShellChipStyle(active: active))
        .animation(GVMotion.resolved(GVMotion.snap, reduceMotion: reduceMotion), value: active)
        .accessibilityLabel(id == "camera" ? "Camera tools" : "Capture settings")
        .accessibilityValue(active ? "expanded" : "collapsed")
        .accessibilityIdentifier("workspace.\(id)")
    }

    private struct GVGlassShellChipStyle: ButtonStyle {
        let active: Bool

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .gvGlassChip(radius: 12, active: active || configuration.isPressed, tint: .white)
                .frame(width: 45, height: 44)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(active ? Color.white.opacity(0.55) : Color.white.opacity(0.06))
                        .frame(height: active ? 1 : GVMetrics.hairline)
                }
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.98 : 1))
                .brightness(configuration.isPressed ? 0.02 : 0)
                .animation(GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion), value: configuration.isPressed)
        }
    }

    private func toggleTopDeck(_ deck: WorkspaceTopDeck) {
        if controlLock.lockUI {
            showTopNotice("Interface locked")
            return
        }
        if deck == .camera, controlLock.lockCamera {
            showTopNotice("Camera controls locked")
            return
        }
        // A deck and a field control are both popouts under the same row.
        hud.clearField()
        activeTopDeck = activeTopDeck == deck ? nil : deck
    }

    /// The mid-take clock that replaces the top-right chips. Same register as
    /// the recording HUD's header: lit pip, monospaced digits, nothing else.
    private var recordingTimecode: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let total = Int(capture.recordingDuration ?? 0)

            HStack(spacing: 8) {
                Circle()
                    .fill(GVTheme.record)
                    .frame(width: 7, height: 7)

                Text(String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60))
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(GVTheme.bone)
                    .lineLimit(1)
                    .fixedSize()
            }
            .fixedSize()
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func topControlDeck(_ deck: WorkspaceTopDeck, geometry: GeometryProxy) -> some View {
        switch deck {
        case .camera:
            cameraControlDeck(geometry: geometry)
        case .settings:
            captureSettingsDeck(availableWidth: max(0, geometry.size.width - 20))
        }
    }

    func cameraControlDeck(geometry: GeometryProxy) -> some View {
        let availableWidth = geometry.size.width - 20
        let alternateMode = appModel.sourceMode == .lidar || appModel.sourceMode == .objects
        let deckWidth = alternateMode ? min(260, availableWidth) : min(360, availableWidth)

        return VStack(spacing: 0) {
            if appModel.sourceMode == .lidar {
                VStack(spacing: 10) {
                    Text("LiDAR Active · Camera controls locked")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(GVTheme.bone.opacity(0.75))
                        .multilineTextAlignment(.center)
                    topActionButton("Return to Camera", symbol: "camera.aperture", detail: "STOP ARKIT") {
                        appModel.deactivateDepthMode()
                    }
                }
                .padding(13)
            } else if appModel.sourceMode == .objects {
                VStack(spacing: 10) {
                    Text("AR Objects Active · Tap preview to place")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(GVTheme.bone.opacity(0.75))
                        .multilineTextAlignment(.center)
                    topActionButton("Return to Camera", symbol: "camera.aperture", detail: "STOP ARKIT") {
                        appModel.deactivateObjectMode()
                    }
                }
                .padding(13)
            } else {
                CameraControlsView()
                    .frame(width: max(0, deckWidth - 20))
                    .padding(.horizontal, 10)
            }
        }
        .gvGlassPanel(radius: 14, tint: Color.black.opacity(0.34))
        .frame(width: deckWidth, alignment: .center)
        .frame(maxWidth: 620, alignment: .center)
        .accessibilityIdentifier("workspace.camera.deck")
    }

    /// System switches. Capture actions live on the primary row / floating pair.
    /// Kept to what is necessary and purposeful: the creative reset, the two
    /// recording-relevant switches, the effect-family gate, the developer
    /// gate, and help. Ambience toggles and stubs live elsewhere or nowhere.
    func captureSettingsDeck(availableWidth: CGFloat) -> some View {
        let columnCount = availableWidth > 500 ? 3 : 2
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: columnCount)

        return LazyVGrid(columns: columns, spacing: 10) {
            captureActionButton(symbol: "eraser", label: "Clear Effects", tint: GVTheme.bone.opacity(0.75)) {
                clearEffects()
            }
            .accessibilityIdentifier("workspace.clear-effects")

            captureActionButton(
                symbol: effectEditor.isGlobalBypassed ? "eye.fill" : "eye.slash",
                label: effectEditor.isGlobalBypassed ? "Show Effects" : "Bypass All",
                tint: effectEditor.isGlobalBypassed ? Color.white : GVTheme.bone.opacity(0.7)
            ) {
                let bypassed = !effectEditor.isGlobalBypassed
                effectEditor.setGlobalBypassed(bypassed)
                showTopNotice(bypassed ? "Effects bypassed" : "Effects restored")
            }
            .accessibilityIdentifier("workspace.global-bypass")

            // #25. The session has kept a forty-step history since the
            // editor was written, and until now nothing in the app called
            // `undo()` or `redo()` — the whole thing was unreachable. These
            // two are the discoverable half; the three-finger swipe in
            // `viewport` is the fast half.
            captureActionButton(
                symbol: effectEditor.canUndo ? "arrow.uturn.backward" : "arrow.uturn.backward",
                label: effectEditor.canUndo ? "Undo" : "Nothing to Undo",
                tint: effectEditor.canUndo ? GVTheme.acid : GVTheme.bone.opacity(0.4)
            ) {
                undoComposition()
            }
            .disabled(!effectEditor.canUndo)
            .accessibilityIdentifier("workspace.undo")

            captureActionButton(
                symbol: "arrow.uturn.forward",
                label: effectEditor.canRedo ? "Redo" : "Nothing to Redo",
                tint: effectEditor.canRedo ? GVTheme.acid : GVTheme.bone.opacity(0.4)
            ) {
                redoComposition()
            }
            .disabled(!effectEditor.canRedo)
            .accessibilityIdentifier("workspace.redo")

            captureActionButton(
                symbol: "lock",
                label: "Control Lock",
                tint: GVTheme.bone.opacity(0.6)
            ) {
                showControlLockSheet = true
            }
            .accessibilityIdentifier("workspace.control-lock")

            captureActionButton(
                symbol: broadcastRuntime.isArmed
                    ? (broadcastRuntime.isConnected ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    : "display.and.arrow.down",
                label: broadcastRuntime.isArmed
                    ? "Mac Camera · Paired"
                    : "Mac Camera",
                tint: broadcastRuntime.isConnected ? GVTheme.acid : GVTheme.bone.opacity(0.65)
            ) {
                if broadcastRuntime.isArmed {
                    broadcastRuntime.stop()
                    showTopNotice("Mac Camera link stopped")
                } else {
                    broadcastRuntime.start()
                    showTopNotice("Mac Camera listening for a paired Mac")
                }
            }
            .accessibilityIdentifier("workspace.broadcast")
            .accessibilityValue(broadcastRuntime.statusLine)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                    showPairingSheet = true
                }
            )

            captureActionButton(
                symbol: audioRuntime.isEnabled ? "waveform.badge.mic" : "waveform",
                label: "Audio",
                tint: audioRuntime.isEnabled ? GVTheme.acid : GVTheme.bone.opacity(0.6)
            ) {
                Task { @MainActor in
                    // The manual latch is what distinguishes "I want audio"
                    // from "an effect happens to need it", so the toolbar
                    // toggle has to write through the policy rather than
                    // toggling the runtime directly — otherwise the next stack
                    // edit would close a microphone the operator opened.
                    if audioRuntime.isEnabled {
                        audioArmPolicy.setManualArm(false)
                        showTopNotice(audioNotice)
                    } else {
                        audioArmPolicy.setManualArm(true)
                        await audioRuntime.start()
                        showTopNotice(audioNotice)
                    }
                }
            }
            .accessibilityIdentifier("workspace.audio")

            captureActionButton(
                symbol: preferences.watermarkEnabled ? "video.badge.checkmark" : "video.slash",
                label: "Burn-in HUD",
                tint: preferences.watermarkEnabled ? GVTheme.acid : GVTheme.bone.opacity(0.6)
            ) {
                preferences.watermarkEnabled.toggle()
                capture.burnHUD = preferences.watermarkEnabled
                showTopNotice(preferences.watermarkEnabled ? "Recording with HUD" : "Recording clean")
            }
            .accessibilityIdentifier("workspace.watermark")

            // Two switches, not one.
            //
            // This used to compute `!(experimental && developer)` and write
            // that single value back to both flags. Once either was on the
            // expression was permanently true, so tapping the button again set
            // both to `true` — the badge stayed lit and nothing appeared to
            // happen. It also conflated two unrelated settings: developer mode
            // is what reveals the Restart Engine control, and experimental has
            // nothing to do with it.
            captureActionButton(
                symbol: preferences.experimentalEnabled ? "flask.fill" : "flask",
                label: preferences.experimentalEnabled ? "Experimental On" : "Experimental",
                tint: preferences.experimentalEnabled ? GVTheme.acid : GVTheme.bone.opacity(0.6)
            ) {
                preferences.experimentalEnabled.toggle()
                showTopNotice(preferences.experimentalEnabled
                    ? "Experimental features on"
                    : "Experimental features off")
            }
            .accessibilityIdentifier("workspace.experimental")

            captureActionButton(
                symbol: preferences.developerEnabled ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver",
                label: preferences.developerEnabled ? "Developer On" : "Developer",
                tint: preferences.developerEnabled ? GVTheme.acid : GVTheme.bone.opacity(0.6)
            ) {
                preferences.developerEnabled.toggle()
                showTopNotice(preferences.developerEnabled
                    ? "Developer tools shown"
                    : "Developer tools hidden")
            }
            .accessibilityIdentifier("workspace.developer")

            // #21. The render-quality ladder the governor walks, plus the
            // frame time that drives it. Auto is the default; the pinned
            // rungs are promises the governor will not break on its own.
            renderQualityButton

            captureActionButton(
                symbol: preferences.startupAnimationEnabled ? "sparkles" : "forward.end.fill",
                label: "Startup Animation",
                tint: preferences.startupAnimationEnabled ? GVTheme.acid : GVTheme.bone.opacity(0.6)
            ) {
                preferences.startupAnimationEnabled.toggle()
                showTopNotice(
                    preferences.startupAnimationEnabled
                        ? "Full startup enabled"
                        : "Fast startup enabled"
                )
            }
            .accessibilityIdentifier("workspace.startup")

            if preferences.developerEnabled {
                captureActionButton(symbol: "arrow.clockwise", label: "Restart Engine", tint: GVTheme.acid) {
                    appModel.restartEngine()
                    showTopNotice("Restarting camera pipeline")
                }
                .accessibilityIdentifier("workspace.restart")
            }

            // Self-timer. Three fixed stops rather than a slider: the point is
            // "get in frame", and an operator setting up a shot needs to hear
            // one number, not read a scale.
            captureActionButton(
                symbol: preferences.captureCountdownSeconds == 0 ? "timer" : "timer.circlepath",
                label: preferences.captureCountdownSeconds == 0
                    ? "Self Timer · Off"
                    : "Self Timer · \(preferences.captureCountdownSeconds)s",
                tint: preferences.captureCountdownSeconds == 0 ? GVTheme.bone.opacity(0.6) : GVTheme.acid
            ) {
                let delays = [0, 3, 10, 30]
                let current = delays.firstIndex(of: preferences.captureCountdownSeconds) ?? 0
                let next = delays[(current + 1) % delays.count]
                preferences.captureCountdownSeconds = next
                showTopNotice(next == 0 ? "Shutter fires immediately" : "Shutter fires in \(next)s")
            }
            .accessibilityIdentifier("workspace.countdown")

            captureActionButton(symbol: "questionmark.circle", label: "Help & Guide", tint: GVTheme.bone.opacity(0.75)) {
                withAnimation(GVMotion.resolved(GVMotion.tear, reduceMotion: reduceMotion)) {
                    coachPresented = true
                }
            }
            .accessibilityIdentifier("workspace.help")
        }
        .padding(14)
        .gvGlass(.primary, radius: 22)
        .frame(width: min(680, availableWidth), alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.settings.deck")
    }

    func topActionButton(_ label: String, symbol: String, detail _: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(GVTheme.bone)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
        }
        .buttonStyle(GVGlassActionButtonStyle())
    }

    private struct GVGlassActionButtonStyle: ButtonStyle {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .gvGlassButton(radius: 16, active: configuration.isPressed)
                .overlay {
                    if configuration.isPressed {
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.9)
                    } else {
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.055), lineWidth: GVMetrics.hairline)
                    }
                }
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.98 : 1))
                .brightness(configuration.isPressed ? 0.02 : 0)
                .animation(GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion), value: configuration.isPressed)
        }
    }

    /// Cycles the render-quality ladder and mirrors the choice into the
    /// camera runtime, which is what the Metal surface reads to cap the
    /// refresh rate. The label carries the live GPU frame time so the control
    /// explains itself: an operator who steps down a rung can see whether it
    /// bought anything.
    private var renderQualityButton: some View {
        let requested = preferences.renderQuality
        let live = GVRenderQuality.resolve(
            requested,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        let isAutomatic = requested == .automatic
        let frameTime = renderStats.latest.gpuMilliseconds
        let frameTimeText = frameTime > 0 ? String(format: " %.1fms", frameTime) : ""
        let suffix = isAutomatic && live != requested ? " \u{2014} \(live.displayName)" : ""
        return captureActionButton(
            symbol: isAutomatic ? "gauge.with.dots.needle.33percent" : "gauge.with.dots.needle.67percent",
            label: "Render \(requested.displayName)\(suffix)\(frameTimeText)",
            tint: live == .high ? GVTheme.bone.opacity(0.6) : GVTheme.warn
        ) {
            let order = GVRenderQuality.allCases
            let current = order.firstIndex(of: requested) ?? 0
            let next = order[(current + 1) % order.count]
            preferences.renderQuality = next
            cameraRuntime.renderQuality = next
            showTopNotice("Render quality \(next.displayName)")
        }
        .accessibilityIdentifier("workspace.render-quality")
        .accessibilityValue(live.displayName)
    }

    func captureActionButton(
        symbol: String,
        label: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 15)
            .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(GVGlassCaptureActionStyle(tint: tint))
        .accessibilityLabel(label)
    }

    private struct GVGlassCaptureActionStyle: ButtonStyle {
        let tint: Color

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .gvGlassChip(radius: 16, active: configuration.isPressed, tint: tint)
                .frame(maxWidth: .infinity, minHeight: 50)
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.99 : 1))
                .brightness(configuration.isPressed ? 0.02 : 0)
                .animation(GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion), value: configuration.isPressed)
        }
    }

    func dismissWorkspaceSelection() {
        activeTopDeck = nil
        hud.clearField()
        dismissSelectionSignal += 1
    }

    func clearEffects() {
        effectEditor.disableAll()
        appModel.deactivateDepthMode()
        showTopNotice("All effects cleared")
    }

    func showTopNotice(_ message: String) {
        toasts.show(message)
    }

    func showControlLock() {
        showControlLockSheet = true
        GVInteractionHaptics.select()
    }

    /// Hands the Mac link everything it needs to drive this workspace.
    ///
    /// The runtime owns the bridge and outlives this view, so the editor and
    /// the capture actions are attached here rather than constructed there.
    /// Individual objects are captured rather than `self`: they are reference
    /// types with the lifetime of the app, whereas a captured view struct
    /// would freeze a snapshot of every value it happened to hold.
    private func attachBroadcastControl() {
        let control = broadcastRuntime.control
        control.editor = effectEditor

        let capture = capture
        let cameraRuntime = cameraRuntime
        let objectsRuntime = objectsRuntime
        let appModel = appModel

        control.onSetRecording = { _ in
            // `toggleRecording` is the only entry point that keeps the writer,
            // the object runtime and the source mode in agreement. The bridge
            // has already checked that the requested state differs from the
            // current one, so a toggle is the right call.
            capture.toggleRecording(
                cameraRuntime: cameraRuntime,
                objectsRuntime: objectsRuntime,
                sourceMode: appModel.sourceMode
            )
        }
        control.onCapturePhoto = {
            capture.takeScreenshot(cameraRuntime: cameraRuntime)
        }

        control.setAudioAvailable(audioRuntime.state == .running)
        control.setRecording(isTakeLive)
        control.publishState(force: true)
    }

    var audioNotice: String {
        switch audioRuntime.state {
        case .running: "Audio reactive live"
        case .denied: "Microphone access denied"
        default: "Audio unavailable"
        }
    }
}

#Preview {
    let model = AppModel(arguments: ["--uitesting-workspace"])
    WorkspaceView()
        .environmentObject(model)
        .environmentObject(model.camera)
        .environmentObject(model.depth)
        .environmentObject(model.objects)
        .environmentObject(model.audio)
        .environmentObject(model.blobs)
        .environmentObject(model.preferences)
        .environmentObject(GVAudioArmPolicy())
}

// MARK: - Easter egg overlays

/// Golden sigil + typed acceptance line shown when a held tone unlocks The Hum.
private struct IncantationOverlay: View {
    @State private var revealed = 0
    private let message = "AUDIO INCANTATION ACCEPTED"
    private static let gold = Color(red: 0.96, green: 0.76, blue: 0.32)

    var body: some View {
        VStack(spacing: 16) {
            SigilMark(color: Self.gold)
                .frame(width: 120, height: 120)
            GVTerminalText(
                text: String(message.prefix(revealed)),
                size: GVMetrics.textBody,
                weight: .black,
                tracking: 1.4,
                baseColor: Self.gold,
                intensity: 1
            )
        }
        .padding(28)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: GVMetrics.radiusPanel, style: .continuous))
        .task {
            revealed = 0
            while revealed < message.count {
                try? await Task.sleep(for: .milliseconds(45))
                revealed = min(message.count, revealed + 1)
            }
        }
    }
}

/// Concentric circle + triangle: the machine's mark.
private struct SigilMark: View {
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = size * 0.46
            ZStack {
                Circle()
                    .stroke(color, lineWidth: 1.2)
                Circle()
                    .stroke(color.opacity(0.4), lineWidth: 0.6)
                    .frame(width: size * 0.62, height: size * 0.62)
                Path { path in
                    path.move(to: CGPoint(x: center.x, y: center.y - radius))
                    path.addLine(to: CGPoint(x: center.x + radius * 0.87, y: center.y + radius * 0.5))
                    path.addLine(to: CGPoint(x: center.x - radius * 0.87, y: center.y + radius * 0.5))
                    path.closeSubpath()
                }
                .stroke(color, lineWidth: 1)
                Path { path in
                    path.move(to: CGPoint(x: center.x, y: center.y - radius))
                    path.addLine(to: CGPoint(x: center.x, y: center.y + radius))
                }
                .stroke(color.opacity(0.8), lineWidth: 0.8)
            }
            .shadow(color: color.opacity(0.6), radius: 14)
        }
    }
}

// swiftlint:enable file_length

/// First-run (and Help-invoked) gesture card. Short guide to core gestures.
private struct GVCoachCard: View {
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let lines: [(String, String)] = [
        ("Camera tools", "Composition guides, flip, and torch in the camera menu"),
        ("Effects button", "Show or hide the browser · badge shows active count"),
        ("Double-tap a dial", "Reset a parameter to its default"),
        ("Clean preview", "Record with or without the interface"),
        ("Collection rail", "Recipes, takes and timelines open above the shutter · tap the chip again to close"),
        ("Recipes", "Star the looks worth keeping · hold the eye to preview"),
        ("Self timer", "Delay the shutter from the settings deck")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Field Guide")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.white)
                Spacer(minLength: 0)
                GVDeckChip(label: "", symbol: "xmark", accessibilityLabel: "Close field guide", id: "coach.close") { onClose() }
            }

            ForEach(lines, id: \.0) { key, value in
                HStack(alignment: .top, spacing: 10) {
                    Text(key)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 168, alignment: .leading)
                    Text(value)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(GVTheme.bone.opacity(0.78))
                }
            }

            Text("Tap anywhere to continue")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(GVTheme.ash.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 6)
        }
        .padding(26)
        .frame(maxWidth: 620)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.10).opacity(0.98))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
        )
        .padding(.horizontal, 26)
        .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
        .onTapGesture { onClose() }
    }
}
