// swiftlint:disable file_length
import SwiftUI


/// Tiny signal bus between the floating dock and the effects browser.
@MainActor
/// One committed state of the composition (stack + RGB split).
struct CompositionSnapshot: Equatable {
    let stack: CameraEffectStackParameters
    let rgb: RGBSplitEffectParameters
}

struct WorkspaceView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var cameraRuntime: CameraRuntime
    @EnvironmentObject private var objectsRuntime: ARObjectRuntime
    @EnvironmentObject private var audioRuntime: AudioReactiveRuntime
    @EnvironmentObject private var blobRuntime: BlobTrackingRuntime
    @EnvironmentObject private var preferences: GVPreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var rgbSplitParameters = RGBSplitEffectParameters()
    @State private var effectStack = CameraEffectStackParameters()
    @State private var activeTopDeck: WorkspaceTopDeck?
    /// Hidden sigil sequence state: non-nil while the signature effect flash
    /// and chromatic overlay play after a recognised stroke.
    @State private var sigilSequence: String?
    @State private var dismissSelectionSignal = 0
    @State private var isSocialPresented = false
    @State private var isQuickTakePresented = false
    @State private var renderStats = CameraRenderStatsMailbox()
    @StateObject private var fracture = SignalFractureController()
    /// HIDE UI: clears all chrome so the effect can be watched or recorded
    /// clean. Tapping anywhere brings it back.
    @State private var isChromeHidden = false
    /// One motion source for both gauges. Two managers would run the sensor
    /// twice and could disagree about level.
    @StateObject private var levelMotion = CameraLevelMotion()
    @StateObject private var hud = GVHUDState()
    @StateObject private var decay = GVDecayEngine()
    /// One notice channel for the whole workspace — the toast capsule above
    /// the dock replaces the red line that used to live under the top shell,
    /// the dock's own availability notice, and the deck tool-row flash.
    @StateObject private var toasts = GVToastBox()

    /// Shared cadence anchor for every 4 Hz telemetry consumer (status line,
    /// both scrims). One start instant means their periodic timers fire in
    /// lockstep instead of four phase-shifted invalidations per second.
    @State private var telemetryTickStart = Date.now

    // MARK: Dynamic Type scaling
    // Fixed frames break at accessibility sizes; these track the user's text
    // setting so the chips grow with the type they carry.
    @ScaledMetric(relativeTo: .caption2) private var settingsChipWidth: CGFloat = 52
    @ScaledMetric(relativeTo: .caption2) private var settingsChipHeight: CGFloat = 54
    @ScaledMetric(relativeTo: .body) private var capturePairWidth: CGFloat = 46
    @ScaledMetric(relativeTo: .body) private var capturePairHeight: CGFloat = 42

    /// Radial hold instrument. `radialOrigin` doubles as the presented flag.
    @State private var radialOrigin: CGPoint?
    @State private var radialCurrent: CGPoint = .zero
    @State private var radialProgress: Double = 0
    @State private var radialArmTask: Task<Void, Never>?
    @State private var radialDriver = GVRadialDriver()

    /// Operator collapsed the effect browser on its own.
    @State private var isFXCollapsed = false

    // MARK: Unified capture
    @StateObject private var capture = GVCaptureCoordinator()

    // MARK: Composition history (undo / redo)

    // MARK: Presets + guidance
    @StateObject private var presetStore = GVPresetStore.shared
    @State private var presetsPresented = false
    @State private var coachPresented = false
    @State private var sessionRestored = false

    /// One read for every mid-take surface in this file. The writer state in
    /// `CameraRuntime` is the single source of truth; naming it once here
    /// keeps the HUD, the capture pair, and the deck collapse from drifting
    /// into different definitions of "recording".
    private var isTakeLive: Bool { cameraRuntime.isRecording }

    /// The effect browser is away when chrome is hidden, when it has been
    /// collapsed on its own, or during a take unless the operator has just
    /// tapped the preview to bring it back.
    private var isDeckCollapsed: Bool {
        isChromeHidden || isFXCollapsed || (isTakeLive && !hud.isChromeRevealed)
    }

    /// Screen recording that keeps the instrument in frame. The render-target
    /// writer can only ever produce the clean image.


    // MARK: - Composition history

    @State private var undoStack: [CompositionSnapshot] = []
    @State private var redoStack: [CompositionSnapshot] = []
    @State private var lastCommitted: CompositionSnapshot?
    @State private var bypassStash: CompositionSnapshot?

    private func currentSnapshot() -> CompositionSnapshot {
        CompositionSnapshot(stack: effectStack, rgb: rgbSplitParameters)
    }

    private func recordHistory(_ ignored: Any) {
        let snapshot = currentSnapshot()
        if snapshot == lastCommitted { return }
        if let previous = lastCommitted {
            undoStack.append(previous)
            if undoStack.count > 40 { undoStack.removeFirst() }
        }
        redoStack.removeAll()
        lastCommitted = snapshot
    }

    private func undo() {
        guard let previous = undoStack.popLast() else {
            showTopNotice("HISTORY // NOTHING TO UNDO")
            return
        }
        redoStack.append(currentSnapshot())
        applySnapshot(previous)
        showTopNotice("HISTORY // UNDONE")
    }

    private func redo() {
        guard let next = redoStack.popLast() else {
            showTopNotice("HISTORY // NOTHING TO REDO")
            return
        }
        undoStack.append(currentSnapshot())
        applySnapshot(next)
        showTopNotice("HISTORY // REDONE")
    }

    private func applySnapshot(_ snapshot: CompositionSnapshot) {
        effectStack = snapshot.stack
        rgbSplitParameters = snapshot.rgb
        lastCommitted = snapshot
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                GVTheme.void.ignoresSafeArea()
                viewport
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .simultaneousGesture(radialGesture)
                    // In objects mode the AR surface owns taps — that is how
                    // geometry gets placed. A SwiftUI tap layered over the whole
                    // viewport competed with the UIKit recogniser inside it, so
                    // placement taps were being eaten by the dismiss handler.
                    .onTapGesture {
                        // While chrome is hidden the tap only restores it, so
                        // a single tap never both reveals the UI and changes
                        // the effect selection underneath it.
                        if isChromeHidden {
                            withAnimation(GVMotion.panel) { isChromeHidden = false }
                            return
                        }
                        // Mid-take the tap summons the deck back rather than
                        // clearing the selection: during recording the most
                        // likely intent is "show me the controls again", and
                        // wiping the live effect would be destructive.
                        if isTakeLive, !hud.isChromeRevealed {
                            withAnimation(GVMotion.deck) { hud.revealChrome() }
                            return
                        }
                        guard appModel.sourceMode != .objects else { return }
                        dismissWorkspaceSelection()
                    }

                // Neon tubes bounded to the bands the panels occupy: the top
                // lights down over the header, the bottom lights up under the
                // dock, and neither reaches the middle of the viewport.
                if !isChromeHidden {
                    VStack(spacing: 0) {
                        GVNeonEdge(
                            edge: .top,
                            reach: max(geometry.safeAreaInsets.top, 12) + 96,
                            intensity: 0.9
                        )
                        Spacer(minLength: 0)
                        GVNeonEdge(edge: .bottom, reach: 150, intensity: 0.9)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                // Violet port ring around the Dynamic Island.
                GVIslandHalo(topInset: geometry.safeAreaInsets.top)

                // The mid-take effect summary. The recording header itself
                // lives in the top row's own slot below, so it lands exactly
                // where the wordmark it replaces was.
                if isTakeLive, isDeckCollapsed {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        recordingHUD(for: geometry).summary
                    }
                    .padding(.bottom, 96)
                    .transition(.opacity)
                    .zIndex(15)
                }

                if let radialOrigin {
                    GVRadialInstrument(
                        origin: radialOrigin,
                        current: radialCurrent,
                        progress: radialProgress
                    )
                    .transition(.opacity)
                    .zIndex(20)
                }

                // The rail is deliberately unplated now, which reads well over
                // a dark frame and disappears over a bright one. A gradient
                // under the dock gives the type something to sit on without
                // handing every chip its border back.
                // Both bands, driven by what the renderer measured under
                // them. Over a dark subject these are nearly invisible; over a
                // bright one they are what keeps the interface readable.
                VStack(spacing: 0) {
                    GVAdaptiveScrim(
                        edge: .top,
                        height: max(geometry.safeAreaInsets.top, 12) + 148,
                        statsMailbox: renderStats,
                        tickStart: telemetryTickStart
                    )
                    Spacer(minLength: 0)
                    GVAdaptiveScrim(
                        edge: .bottom,
                        height: 310,
                        statsMailbox: renderStats,
                        tickStart: telemetryTickStart
                    )
                }
                .overlay(alignment: .leading) {
                    // Side scrims: the vertical HUD and the level rails sit on
                    // raw footage, and shadows alone lose to a blown sky.
                    LinearGradient(
                        colors: [.black.opacity(0.40), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 30)
                    .frame(maxHeight: .infinity)
                }
                .overlay(alignment: .trailing) {
                    LinearGradient(
                        colors: [.black.opacity(0.40), .clear],
                        startPoint: .trailing,
                        endPoint: .leading
                    )
                    .frame(width: 30)
                    .frame(maxHeight: .infinity)
                }
                .ignoresSafeArea()
                .opacity(isChromeHidden ? 0 : 1)
                .allowsHitTesting(false)

                VStack(spacing: 0) {
                    Group {
                        // Mid-take the recording header owns the top of the
                        // screen. Nothing is removed — a tap on the preview
                        // brings the full interface straight back. Both live in
                        // this one slot so the swap does not move the row.
                        if isTakeLive, isDeckCollapsed {
                            recordingHUD(for: geometry)
                        } else {
                            topPanel(for: geometry)
                        }
                    }
                    .padding(.horizontal, 7)
                    // Level with the Dynamic Island rather than below it.
                    // The row already reserves a centre gap the width of
                    // the cutout, so the wordmark and the button cluster
                    // land in the shoulders either side and the band under
                    // the island — previously ~48pt of nothing — is gone.
                    // Touches are unaffected: the cutout only intercepts
                    // within its own bounds, and neither control overlaps
                    // it.
                    .padding(.top, geometry.safeAreaInsets.top > 30 ? 8 : 12)

                    if let activeTopDeck {
                        topControlDeck(activeTopDeck, geometry: geometry)
                            .padding(.horizontal, 10)
                            .padding(.top, 7)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Spacer(minLength: 8)

                    // One line above the dock: the FX collapse toggle on the
                    // left, the detached capture pair on the right. Photo and
                    // record live outside the dock because mid-take the dock
                    // collapses with the rest of the chrome, and a stop
                    // control that disappears with the UI it controls is not
                    // a control. Visibility is per-control so a running take
                    // keeps its stop switch even when everything else hides.
                    HStack(spacing: GVMetrics.gapTight) {
                        chromeToggle
                            .opacity(isChromeHidden ? 0 : 1)
                            .allowsHitTesting(!isChromeHidden)

                        Spacer(minLength: 0)

                        detachedCaptureControls
                            .opacity(isChromeHidden && !isTakeLive ? 0 : 1)
                            .allowsHitTesting(!(isChromeHidden && !isTakeLive))
                    }
                    .padding(.horizontal, GVMetrics.gapWide)
                    .padding(.top, GVMetrics.stepRelated)
                    .padding(.bottom, 6)
                    .animation(GVMotion.deck, value: isChromeHidden)

                    // The single notice channel. Anchored just above the dock
                    // so feedback lands beside where the hands already are,
                    // instead of three unrelated places at once.
                    GVToastCapsule(text: toasts.message)
                        .padding(.bottom, GVMetrics.gapTight)
                        .opacity(isChromeHidden ? 0 : 1)
                        .animation(GVMotion.resolved(GVMotion.deck, reduceMotion: reduceMotion), value: toasts.message)

                    // Recording focus: the effect browser is not what the
                    // operator is looking at mid-take. Stop, the timecode and
                    // the frame telemetry stay; the rest collapses until the
                    // preview is tapped. It anchors the very bottom of the
                    // screen so the parameter rail lands in the thumb zone.
                    WorkspaceDockView(
                        rgbSplitParameters: $rgbSplitParameters,
                        effectStack: $effectStack,
                        dismissSelectionSignal: $dismissSelectionSignal,
                        statsMailbox: renderStats,
                        onHideChrome: { withAnimation(GVMotion.panel) { isChromeHidden = true } },
                        presetsPresented: $presetsPresented
                    )
                    .padding(.horizontal, 6)
                    .padding(.top, GVMetrics.gapTight)
                    // Clears the frame telemetry pinned along the very bottom.
                    .padding(.bottom, max(20, geometry.safeAreaInsets.bottom + 2))
                    .frame(height: isDeckCollapsed ? 0 : nil)
                    .opacity(isDeckCollapsed ? 0 : 1)
                    .allowsHitTesting(!isDeckCollapsed)
                    .clipped()
                    .animation(GVMotion.deck, value: isDeckCollapsed)
                }
                .frame(width: geometry.size.width)
                // One motion clock for the whole mid-take transition. When
                // recording flips, every dependent surface — HUD swap, deck
                // collapse, capture-pair state — animates together instead of
                // each part running its own timing.
                .animation(
                    GVMotion.resolved(GVMotion.deck, reduceMotion: reduceMotion),
                    value: cameraRuntime.isRecording
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
                                withAnimation(GVMotion.panel) { isChromeHidden = false }
                            }
                            .accessibilityLabel("Show interface")
                            .accessibilityIdentifier("workspace.chrome.restore")
                    }
                }
                // Pitch rides the right edge, clear of both decks. Both gauges
                // are chrome, so HIDE UI takes them with everything else.
                .overlay(alignment: .leading) {
                    GVSideRail(edge: .leading)
                        .padding(.leading, GVMetrics.stepInternal)
                        .opacity(isChromeHidden ? 0 : 1)
                }
                .overlay(alignment: .trailing) {
                    VStack(alignment: .trailing, spacing: GVMetrics.stepSection) {
                        GVSideRail(edge: .trailing)
                    }
                    .padding(.trailing, GVMetrics.stepInternal)
                    .opacity(isChromeHidden ? 0 : 1)
                }
                // Sideways telemetry rail. The same live values the top strip
                // polls, printed as a vertical column you tilt your head to —
                // half transparent, so it reads as burn-in on the tube rather
                // than as chrome floating over the frame.
                .allowsHitTesting(true)

                if isSocialPresented {
                    SocialLinksOverlay(isPresented: $isSocialPresented)
                        .transition(.scale(scale: 0.9, anchor: .topLeading).combined(with: .opacity))
                        .zIndex(30)
                }
                if isQuickTakePresented, let capture = cameraRuntime.lastCapture {
                    QuickTakeViewerSheet(capture: capture, isPresented: $isQuickTakePresented)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                        .zIndex(32)
                }

                if let sigilSequence {
                    SigilSequenceOverlay(kind: sigilSequence)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .zIndex(25)
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
        // Recipes drawer. Sits over the dock; tap outside closes.
        .overlay(alignment: .bottom) {
            if presetsPresented {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(GVMotion.deck) { presetsPresented = false } }

                GVPresetsDrawer(
                    setup: $appModel.setup,
                    rgbSplitParameters: $rgbSplitParameters,
                    effectStack: $effectStack,
                    onClose: { withAnimation(GVMotion.deck) { presetsPresented = false } }
                )
                .zIndex(26)
            }
        }
        .overlay {
            if coachPresented {
                GVCoachCard {
                    coachPresented = false
                    preferences.coachSeen = true
                }
                .zIndex(34)
            }
        }
        .onChange(of: effectStack) { _, newValue in
            recordHistory(newValue)
        }
        .onChange(of: rgbSplitParameters) { _, newValue in
            recordHistory(newValue)
        }
        .onChange(of: capture.statusMessage) { _, message in
            guard let message else { return }
            showTopNotice(message)
        }
        // A finished still opens the quick-take viewer. Videos surface the
        // same way once the renderer hands the exported clip back.
        .onChange(of: cameraRuntime.lastCapture) { _, lastCapture in
            guard lastCapture != nil else { return }
            withAnimation(GVMotion.panel) { isQuickTakePresented = true }
        }
        .onChange(of: cameraRuntime.recordingMessage) { _, value in
            guard let value else { return }
            showTopNotice(value)
        }
        // Said once, when it happens. Driving ISO or shutter stops the device
        // metering — a state worth naming, along with the way out of it.
        .onChange(of: cameraRuntime.snapshot.exposureLocked) { _, locked in
            guard locked else { return }
            showTopNotice("EXPOSURE // MANUAL · HOLD ISO OR SHUT FOR AUTO")
        }
        .environmentObject(levelMotion)
        .environmentObject(hud)
        .environmentObject(decay)
        .environmentObject(toasts)
        .onAppear {
            levelMotion.start()
            if !sessionRestored {
                sessionRestored = true
                // Sessions are not carried across launches: every start is a
                // clean instrument. The baseline snapshot still seeds undo.
                lastCommitted = CompositionSnapshot(stack: effectStack, rgb: rgbSplitParameters)
                if !preferences.coachSeen { coachPresented = true }
            }
        }
        .onDisappear { levelMotion.stop(); hud.stop(); decay.stop() }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: activeTopDeck)
                // Capture failures were being written to `snapshot.errorMessage` and
        // read by nothing. A denied permission, an unattachable format or a
        // session configuration failure all produced a dead viewport and a
        // silent UI, which is why the camera being down has been impossible
        // to diagnose from the device. The failure now says what it was.
        .overlay(alignment: .center) {
            if let message = cameraRuntime.snapshot.errorMessage,
               cameraRuntime.snapshot.state == .failed
            {
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
    }

    /// Hidden sigil sequence: a recognised stroke briefly arms the signature
    /// effect combo (datamosh + signal tear + rgb split) and plays the
    /// chromatic acceptance overlay, then restores the user's stack.
    private func runSigilSequence(_ kind: String) {
        guard sigilSequence == nil else { return }
        let savedStack = effectStack
        let savedRGB = rgbSplitParameters
        sigilSequence = kind
        var armed = effectStack
        armed.disableAll()
        armed.setEnabled(true, for: .datamosh)
        armed.setEnabled(true, for: .signalTear)
        effectStack = armed
        var rgb = RGBSplitEffectParameters(isEnabled: true)
        rgb.amount = 0.035
        rgbSplitParameters = rgb
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        GVLog.analysis.notice("SIGIL ACCEPTED // \(kind)")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.4))
            effectStack = savedStack
            rgbSplitParameters = savedRGB
            withAnimation(.easeOut(duration: 0.4)) {
                sigilSequence = nil
            }
        }
    }

    /// Built once and used in two places: the header goes in the top row's
    /// slot, the summary at the foot of the frame.
    private func recordingHUD(for geometry: GeometryProxy) -> GVRecordingHUD {
        GVRecordingHUD(
            startedAt: cameraRuntime.recordingStartedAt,
            activeEffects: effectStack.activeEffects.map(\.0.label),
            geometry: geometry
        )
    }

    private var viewport: some View {
        ZStack {
            CameraSurfaceView(
                fracture: fracture,
                onSigil: { kind in runSigilSequence(kind) },
                sigilsEnabled: preferences.sigilsEnabled,
                rgbSplitParameters: rgbSplitParameters,
                effectStack: effectStack,
                statsMailbox: renderStats,
                onPreviewTap: dismissWorkspaceSelection
            )

            if cameraRuntime.snapshot.state != .running || cameraRuntime.snapshot.isSynthetic {
                GVScanlines(opacity: 0.028)
            }

            // The animated scanlines now composite on the GPU inside the camera
            // preview fragment; the SwiftUI canvas overlay is only kept for the
            // depth / AR modes, which have their own Metal surfaces.

            RadialGradient(
                colors: [.clear, .black.opacity(0.36)],
                center: .center,
                startRadius: 170,
                endRadius: 640
            )
            .allowsHitTesting(false)

            if appModel.sourceMode == .camera {
                CameraFrameHUD(
                    touchPoint: fracture.isEngaged ? fracture.telemetry.midpoint : nil
                )

                FractureTelemetryOverlay(
                    telemetry: fracture.telemetry,
                    layerAges: TemporalFrameBuffer.ageMilliseconds(
                        framesPerSecond: cameraRuntime.snapshot.framesPerSecond
                    )
                )
            }

            if appModel.sourceMode == .camera, blobRuntime.isEnabled {
                BlobTrackingOverlay(
                    blobs: blobRuntime.blobs,
                    sourceSize: blobRuntime.sourceSize
                )
                .transition(.opacity)
            }
        }
        .clipped()
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
        effectStack.activeEffects.count + (rgbSplitParameters.isEnabled ? 1 : 0)
    }

    /// Photo + record, detached from the dock. Record carries its state in
    /// glyph and border together; photo is a plain instrument button. Visible
    /// whenever chrome shows — and during a take even when it does not, since
    /// stop must outlive the interface it belongs to.
    private var detachedCaptureControls: some View {
        let recording = isTakeLive

        return HStack(spacing: 9) {
            Button {
                capture.takeScreenshot(cameraRuntime: cameraRuntime)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } label: {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(GVTheme.bone.opacity(0.9))
                    .frame(width: capturePairWidth, height: capturePairHeight)
                    .background(
                        GVChamferedPlate(cut: 7)
                            .fill(Color(white: 0.105).opacity(0.92))
                    )
                    .overlay(
                        GVChamferedPlate(cut: 7)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(GVPressStyle())
            .accessibilityLabel("Capture photo")
            .accessibilityIdentifier("workspace.capture.photo")

            Button {
                let wasRecording = recording
                capture.toggleRecording(cameraRuntime: cameraRuntime)
                if wasRecording {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } else {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } label: {
                Image(systemName: recording ? "stop.fill" : "record.circle")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(recording ? GVTheme.record : GVTheme.bone.opacity(0.9))
                    .shadow(color: recording ? GVTheme.record.opacity(0.6) : .clear, radius: 4)
                    .frame(width: capturePairWidth, height: capturePairHeight)
                    .background(
                        GVChamferedPlate(cut: 7)
                            .fill(recording ? GVTheme.record.opacity(0.14) : Color(white: 0.105).opacity(0.92))
                    )
                    .overlay(
                        GVChamferedPlate(cut: 7)
                            .strokeBorder(
                                recording ? GVTheme.record.opacity(0.8) : Color.white.opacity(0.18),
                                lineWidth: 1
                            )
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(GVPressStyle())
            .accessibilityLabel(recording ? "Stop recording" : "Record video")
            .accessibilityIdentifier("workspace.record.toggle")
        }
    }

    /// Collapses the bottom menus, and brings them back. Doubles as a live
    /// status readout: the count of rendering effects glows while any are
    /// armed, so stack state is glanceable without opening anything.
    private var chromeToggle: some View {
        let armed = armedEffectCount > 0
        return Button {
            withAnimation(GVMotion.deck) { isFXCollapsed.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isFXCollapsed ? "chevron.up" : "chevron.down")
                    .font(.system(size: GVMetrics.textBody, weight: .bold))
                Text("FX")
                    .gvMono(GVMetrics.textBody, .black)
                    .tracking(0.8)
                if armed {
                    Text("\(armedEffectCount)")
                        .gvMono(GVMetrics.textBody, .black)
                        .foregroundStyle(.white)
                        .shadow(color: .white.opacity(0.75), radius: 4)
                        .shadow(color: .white.opacity(0.3), radius: 8)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .foregroundStyle(armed ? Color.white : GVTheme.bone.opacity(0.85))
            .frame(width: 64, height: 28)
            .background(
                Capsule(style: .continuous)
                    .fill(GVTheme.surfaceSecondary)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                armed ? Color.white.opacity(0.35) : GVTheme.separator,
                                lineWidth: armed ? 1.2 : GVMetrics.hairline
                            )
                    )
                    .shadow(color: armed ? .white.opacity(0.16) : .clear, radius: 9)
            )
            .frame(height: GVMetrics.touchTarget)
            .contentShape(Rectangle())
            .animation(GVMotion.micro, value: armedEffectCount)
        }
        .buttonStyle(GVPressStyle())
        .accessibilityLabel(isFXCollapsed ? "Show effects" : "Hide effects")
        .accessibilityIdentifier("workspace.chrome.toggle")
    }




private enum WorkspaceTopDeckPlaceholder {}

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
                .buttonStyle(.plain)
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
                        shellChip(symbol: "camera.aperture", id: "camera",
                                  active: activeTopDeck == .camera) { toggleTopDeck(.camera) }

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
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
        usesCharcoalPlate: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let glyph: Color = active ? Color.white : GVTheme.bone.opacity(0.62)

        return Button {
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(glyph)
                .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                .shadow(color: active ? Color.white.opacity(0.55) : .clear, radius: 4)
                .frame(width: 40, height: 40)
                .background {
                    if usesCharcoalPlate {
                        GVChamferedPlate(cut: 7)
                            .fill(Color(red: 0.135, green: 0.135, blue: 0.143))
                            .overlay {
                                GVChamferedPlate(cut: 7)
                                    .strokeBorder(Color.white.opacity(active ? 0.18 : 0.08), lineWidth: 1)
                            }
                            .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                    }
                }
                // Selection lights the lower rule and glyph; the charcoal
                // plate keeps the settings entry in the dock's material family.
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(active ? Color.white : Color.white.opacity(0.16))
                        .frame(height: active ? 1.5 : 1)
                        .shadow(color: active ? Color.white.opacity(0.8) : .clear, radius: 4)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        .animation(GVMotion.snap, value: active)
        .accessibilityIdentifier("workspace.\(id)")
    }

    private func toggleTopDeck(_ deck: WorkspaceTopDeck) {
        // A deck and a field control are both popouts under the same row.
        hud.clearField()
        activeTopDeck = activeTopDeck == deck ? nil : deck
    }

    /// The mid-take clock that replaces the top-right chips. Same register as
    /// the recording HUD's header: lit pip, monospaced digits, nothing else.
    private var recordingTimecode: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let total = cameraRuntime.recordingStartedAt.map { total in
                Int(timeline.date.timeIntervalSince(total))
            } ?? 0

            HStack(spacing: GVMetrics.stepRelated) {
                Circle()
                    .fill(GVTheme.record)
                    .frame(width: 8, height: 8)
                    .shadow(color: GVTheme.record.opacity(0.8), radius: 5)

                Text(String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60))
                    .gvFont(.control)
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

        return GVAnimatedGlassPanel(cornerRadius: 14, fillOpacity: 0, isTransparent: true) {
            if appModel.sourceMode == .lidar {
                ScrollView {
                    VStack(spacing: 10) {
                        GVTerminalText(
                            text: "LIDAR OWNS CAMERA // AVFOUNDATION CONTROLS LOCKED",
                            size: GVMetrics.textMicro,
                            weight: .black,
                            tracking: 0.85,
                            baseColor: GVTheme.record,
                            intensity: 0.82
                        )
                        topActionButton("RETURN CAMERA", symbol: "camera.aperture", detail: "STOP ARKIT") {
                            appModel.deactivateDepthMode()
                        }
                    }
                    .padding(13)
                }
            } else if appModel.sourceMode == .objects {
                ScrollView {
                    VStack(spacing: 10) {
                        GVTerminalText(
                            text: "AR OBJECTS OWNS CAMERA // TAP PREVIEW TO PLACE GEOMETRY",
                            size: GVMetrics.textMicro,
                            weight: .black,
                            tracking: 0.85,
                            baseColor: GVTheme.violet,
                            intensity: 0.82
                        )
                        topActionButton("RETURN CAMERA", symbol: "camera.aperture", detail: "STOP ARKIT") {
                            appModel.deactivateObjectMode()
                        }
                    }
                    .padding(13)
                }
            } else {
                // The controls are laid out at their natural design width and
                // the deck scrolls sideways when the viewport is narrower —
                // the same containment as the settings deck. Without this a
                // compact width compressed the row past its minimum and the
                // outermost controls were severed by the panel edge.
                ScrollView(.horizontal, showsIndicators: false) {
                    CameraControlsView()
                        .frame(width: 340)
                        .padding(.horizontal, 10)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }
        }
        .frame(
            width: deckWidth,
            // Landscape guard: the chrome VStack does not scroll, so on short
            // viewports the fixed deck height would crowd out the capture
            // row and dock below it.
            height: alternateMode ? nil : min(318, geometry.size.height * 0.5),
            alignment: .center
        )
        .frame(maxWidth: 620, alignment: .center)
        .accessibilityIdentifier("workspace.camera.deck")
    }

    /// System switches. Capture actions live on the primary row / floating pair.
    /// Kept to what is necessary and purposeful: the creative reset, the two
    /// recording-relevant switches, the effect-family gate, the developer
    /// gate, and help. Ambience toggles and stubs live elsewhere or nowhere.
    func captureSettingsDeck(availableWidth: CGFloat) -> some View {
        GVAnimatedGlassPanel(
            cornerRadius: 14,
            tint: Color(red: 0.078, green: 0.078, blue: 0.085),
            fillOpacity: 0.42
        ) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    captureActionButton(symbol: "eraser", label: "Clear FX", tint: GVTheme.violet) {
                        clearEffects()
                    }
                    .accessibilityIdentifier("workspace.clear-effects")

                    captureActionButton(
                        symbol: audioRuntime.isEnabled ? "waveform.badge.mic" : "waveform",
                        label: "Audio",
                        tint: audioRuntime.isEnabled ? GVTheme.acid : GVTheme.bone.opacity(0.6)
                    ) {
                        Task { @MainActor in
                            await audioRuntime.toggle()
                            showTopNotice(audioNotice)
                        }
                    }
                    .accessibilityIdentifier("workspace.audio")

                    captureActionButton(
                        symbol: preferences.watermarkEnabled ? "video.badge.checkmark" : "video.slash",
                        label: "Burn HUD",
                        tint: preferences.watermarkEnabled ? GVTheme.acid : GVTheme.bone.opacity(0.6)
                    ) {
                        preferences.watermarkEnabled.toggle()
                        showTopNotice(preferences.watermarkEnabled ? "RECORDING // BURN HUD" : "RECORDING // CLEAN")
                    }
                    .accessibilityIdentifier("workspace.watermark")

                    captureActionButton(
                        symbol: preferences.experimentalEnabled ? "flask.fill" : "flask",
                        label: "Experimental",
                        tint: preferences.experimentalEnabled ? GVTheme.acid : GVTheme.bone.opacity(0.6)
                    ) {
                        preferences.experimentalEnabled.toggle()
                        showTopNotice(preferences.experimentalEnabled ? "EXPERIMENTAL // ON" : "EXPERIMENTAL // OFF")
                    }
                    .accessibilityIdentifier("workspace.experimental")

                    captureActionButton(
                        symbol: preferences.startupAnimationEnabled ? "sparkles" : "forward.end.fill",
                        label: "Startup",
                        tint: preferences.startupAnimationEnabled ? GVTheme.acid : GVTheme.bone.opacity(0.6)
                    ) {
                        preferences.startupAnimationEnabled.toggle()
                        showTopNotice(
                            preferences.startupAnimationEnabled
                                ? "STARTUP // FULL CEREMONY"
                                : "STARTUP // FAST ENTRY"
                        )
                    }
                    .accessibilityIdentifier("workspace.startup")

                    captureActionButton(
                        symbol: "wrench.and.screwdriver",
                        label: preferences.developerEnabled ? "Dev ON" : "Dev OFF",
                        tint: preferences.developerEnabled ? GVTheme.acid : GVTheme.bone.opacity(0.6)
                    ) {
                        preferences.developerEnabled.toggle()
                        showTopNotice(preferences.developerEnabled ? "DEV // TOOLS REVEALED" : "DEV // TOOLS HIDDEN")
                    }
                    .accessibilityIdentifier("workspace.devmode")

                    if preferences.developerEnabled {
                        captureActionButton(symbol: "arrow.clockwise", label: "Restart", tint: GVTheme.acid) {
                            appModel.restartEngine()
                            showTopNotice("CAMERA PIPELINE // RESTARTING")
                        }
                        .accessibilityIdentifier("workspace.restart")
                    }

                    captureActionButton(symbol: "questionmark.circle", label: "Help", tint: GVTheme.violet) {
                        coachPresented = true
                    }
                    .accessibilityIdentifier("workspace.help")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .frame(width: min(620, availableWidth), alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.settings.deck")
        .onChange(of: cameraRuntime.screenshotMessage) { _, message in
            if let message { showTopNotice(message) }
        }
    }

    func topActionButton(_ label: String, symbol: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: GVMetrics.textValue, weight: .bold))
                Text(label)
                    .gvMono(GVMetrics.textSmall, .bold)
                    .tracking(1.0)
            }
            .foregroundStyle(GVTheme.bone)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .overlay(Capsule().strokeBorder(GVTheme.separator, lineWidth: 1))
        }
        .buttonStyle(GVPressStyle())
    }

    func captureActionButton(
        symbol: String,
        label: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: GVMetrics.textValue + 2, weight: .bold))
                    .shadow(color: tint.opacity(0.45), radius: 3)
                Text(label.uppercased())
                    .gvMono(GVMetrics.textMicro, .black)
                    .tracking(0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(tint)
            .frame(width: settingsChipWidth, height: settingsChipHeight)
            .background(
                GVChamferedPlate(cut: 8)
                    .fill(Color(red: 0.175, green: 0.175, blue: 0.183))
            )
            .overlay(
                GVChamferedPlate(cut: 8)
                    .strokeBorder(tint.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.48), radius: 4, y: 2)
        }
        .buttonStyle(GVPressStyle())
        .accessibilityLabel(label)
    }

    /// Hold the image to summon the radial; keep dragging to drive it.
    ///
    /// One `DragGesture` rather than a `LongPressGesture.sequenced(before:)`:
    /// the sequenced form restarts the drag translation at zero on hand-off,
    /// so the finger's travel during the press was lost and the first
    /// adjustment jumped. Here the press is a timer armed on touch-down and
    /// cancelled if the finger travels first, which also keeps a scrub or a
    /// two-finger fracture from being read as a hold.
    private var radialGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard appModel.sourceMode != .objects else { return }

                if radialOrigin == nil {
                    if radialArmTask == nil {
                        let start = value.startLocation
                        radialDriver.prepare()
                        radialArmTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(340))
                            guard !Task.isCancelled else { return }
                            radialOrigin = start
                            radialCurrent = start
                            radialDriver.reset()
                            withAnimation(GVMotion.tear) { radialProgress = 1 }
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
                        }
                    }
                    // Travelling before the timer fires means this was a drag,
                    // not a hold.
                    if hypot(value.translation.width, value.translation.height) > 12 {
                        radialArmTask?.cancel()
                        radialArmTask = nil
                    }
                    return
                }

                radialCurrent = value.location
                let spoke = GVRadialInstrument.spoke(
                    from: radialOrigin ?? value.startLocation,
                    to: value.location,
                    deadZone: 34
                )
                radialDriver.spokeChanged(to: spoke, runtime: cameraRuntime)
                if let spoke, spoke.isContinuous, let origin = radialOrigin {
                    let travel = spoke == .zoom
                        ? origin.y - value.location.y
                        : value.location.x - origin.x
                    radialDriver.drive(spoke, travel: travel - 34, runtime: cameraRuntime)
                }
            }
            .onEnded { value in
                radialArmTask?.cancel()
                radialArmTask = nil
                guard let origin = radialOrigin else { return }
                let spoke = GVRadialInstrument.spoke(from: origin, to: value.location, deadZone: 34)
                if let spoke, !spoke.isContinuous {
                    radialDriver.commitLatch(spoke, runtime: cameraRuntime)
                }
                radialDriver.reset()
                withAnimation(GVMotion.collapse) {
                    radialProgress = 0
                    radialOrigin = nil
                }
            }
    }

    func dismissWorkspaceSelection() {
        activeTopDeck = nil
        hud.clearField()
        dismissSelectionSignal += 1
    }

    func clearEffects() {
        rgbSplitParameters.isEnabled = false
        effectStack.disableAll()
        appModel.deactivateDepthMode()
        showTopNotice("LIVE HUD EFFECT LIST CLEARED")
    }

    func showTopNotice(_ message: String) {
        toasts.show(message)
    }

    var audioNotice: String {
        switch audioRuntime.state {
        case .running: "AUDIO REACTIVE // LIVE"
        case .denied: "AUDIO REACTIVE // MICROPHONE DENIED"
        default: "AUDIO REACTIVE // UNAVAILABLE"
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

/// Chromatic acceptance overlay for a recognised sigil: RGB-split terminal
/// text with a static glitch flash while the signature effect combo plays.
private struct SigilSequenceOverlay: View {
    let kind: String
    @State private var revealed = 0
    @State private var glitchOffset: CGFloat = 0

    private var message: String {
        "SIGIL ACCEPTED // \(kind)"
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.22))
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ZStack {
                    chromaticText(offset: -glitchOffset - 2, color: .red.opacity(0.55))
                    chromaticText(offset: glitchOffset + 2, color: .cyan.opacity(0.55))
                    Text(String(message.prefix(revealed)))
                        .gvMono(GVMetrics.textValue, .black)
                        .tracking(2)
                        .foregroundStyle(GVTheme.bone)
                }
                GVTerminalText(
                    text: "DRAW ANOTHER SIGIL TO RESIGN",
                    size: GVMetrics.textMicro,
                    weight: .bold,
                    tracking: 0.9,
                    baseColor: GVTheme.ash,
                    intensity: 0.7
                )
            }
        }
        .task {
            revealed = 0
            while revealed < message.count {
                try? await Task.sleep(for: .milliseconds(40))
                revealed = min(message.count, revealed + 2)
            }
        }
        .task {
            while true {
                try? await Task.sleep(for: .milliseconds(110))
                withAnimation(.easeOut(duration: 0.05)) {
                    glitchOffset = CGFloat.random(in: -6 ... 6)
                }
            }
        }
    }

    private func chromaticText(offset: CGFloat, color: Color) -> some View {
        Text(String(message.prefix(revealed)))
            .gvMono(GVMetrics.textValue, .black)
            .tracking(2)
            .offset(x: offset, y: 0)
            .foregroundStyle(color)
    }
}

// swiftlint:enable file_length


/// First-run (and Help-invoked) gesture card. Terminal-styled, deliberately
/// short: six lines that turn invisible interactions into known ones.
private struct GVCoachCard: View {
    let onClose: () -> Void

    private let lines: [(String, String)] = [
        ("HOLD FRAME", "Radial instrument — exposure, zoom, focus"),
        ("TAP FX PILL", "Collapse browser · count shows armed effects"),
        ("DOUBLE-TAP SLIDER", "Parameter returns to factory default"),
        ("CLEAN / HUD", "Recording with or without the interface"),
        ("HOLD BYPASS", "Peek the untouched frame while held"),
        ("PRESETS", "Save looks · hold eye icon to preview"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                GVTerminalText(
                    text: "FIELD MANUAL",
                    size: GVMetrics.textSmall,
                    weight: .black,
                    tracking: 2.0,
                    alignment: .leading,
                    intensity: 1.15
                )
                Spacer(minLength: 0)
                GVDeckChip(label: "", symbol: "xmark", id: "coach.close") { onClose() }
            }

            ForEach(lines, id: \.0) { key, value in
                HStack(alignment: .top, spacing: 8) {
                    Text(key)
                        .gvMono(GVMetrics.textSmall, .black)
                        .tracking(1.0)
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 128, alignment: .leading)
                    Text(value)
                        .gvMono(GVMetrics.textSmall, .bold)
                        .tracking(0.4)
                        .foregroundStyle(GVTheme.bone.opacity(0.7))
                }
            }

            Text("TAP ANYWHERE TO RESUME")
                .gvMono(GVMetrics.textMicro, .bold)
                .tracking(1.6)
                .foregroundStyle(GVTheme.ash.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.075, green: 0.075, blue: 0.082).opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                        .shadow(color: .white.opacity(0.18), radius: 10)
                )
                .shadow(color: .black.opacity(0.65), radius: 24, y: 12)
        )
        .padding(.horizontal, 26)
        .transition(.scale(scale: 0.94).combined(with: .opacity))
        .onTapGesture { onClose() }
    }
}
