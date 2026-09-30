// swiftlint:disable file_length
import SwiftUI

struct BootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appModel: AppModel

    @StateObject private var sequence = GVBootSequence()
    @StateObject private var motion = GVBootMotion()

    @State private var isSocialPresented = false
    @State private var launchTask: Task<Void, Never>?
    @State private var hasPlayedGlitchCue = false
    @State private var readyCueTask: Task<Void, Never>?
    @State private var hasPlayedReadyCue = false
    @State private var identityRowDates: [Int: Date] = [:]

    private var isReady: Bool {
        sequence.isReady
    }

    private var isInterfaceVisible: Bool {
        sequence.isInterfaceVisible
    }

    private var isDeparting: Bool {
        sequence.isDeparting
    }

    var body: some View {
        GeometryReader { geometry in
            let compactHeight = geometry.size.height < 760
            // Keep the artwork within the display; identity has its own inset.
            let logoWidth = min(geometry.size.width, compactHeight ? 430 : 520)
            let logoHeight = min(geometry.size.height * (compactHeight ? 0.42 : 0.46), compactHeight ? 340 : 460)

            splashContent(
                geometry: geometry,
                logoWidth: logoWidth,
                logoHeight: logoHeight,
                compactHeight: compactHeight
            )
        }
        .onDisappear {
            GVSoundEngine.shared.stopStings()
            launchTask?.cancel()
            launchTask = nil
            readyCueTask?.cancel()
            readyCueTask = nil
            sequence.cancel()
            motion.stop()
        }
        .task {
            motion.start()
            // Looping corruption bed under the whole sequence. It is a sting,
            // so the existing `stopStings()` on launch and on disappear both
            // kill it; there is no separate teardown to forget.
            // The ready discharge is state-driven, not scheduled: the ceremony
            // runs 12-15s with its randomised void/spark/discovery holds, so a
            // fixed 12s timer routinely fired before `isReady` armed.
            readyCueTask?.cancel()
            readyCueTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled, !hasPlayedReadyCue, sequence.isReady else { return }
                hasPlayedReadyCue = true
                GVSoundEngine.shared.stop(.sceneLoad)
                GVSoundEngine.shared.play(.systemReady)
            }

            // No cue at t=0. The screen is still black at that point, so a
            // sound there reads as a stray discharge rather than as the
            // instrument coming up.

            // Keep the artwork reveal, respecting the system motion preference.
            sequence.isAccelerated = appModel.isUITesting
            sequence.start(
                lineCount: appModel.bootTelemetry.terminalLines.count,
                reduceMotion: reduceMotion
            )
        }
        .onChange(of: sequence.revealedIdentityRows) { _, revealed in
            let now = Date()
            for index in revealed where identityRowDates[index] == nil {
                identityRowDates[index] = now
            }
        }
        .onChange(of: sequence.glitchedElement) { previous, current in
            // One shot, on the first corruption only. Retriggering per glitch
            // would stack copies of the same cue over each other.
            // (Explicit `GVBootElement?` annotations: inference of the
            // optional comparisons stalled the type-checker inside this very
            // large body.)
            let previousElement: GVBootElement? = previous
            let currentElement: GVBootElement? = current
            guard currentElement != nil, previousElement == nil, !hasPlayedGlitchCue else { return }
            hasPlayedGlitchCue = true
            GVSoundEngine.shared.play(.bootGlitch)
        }
        .onChange(of: sequence.isReady) { _, ready in
            guard ready else { return }
            motion.stop()
            // State-driven discharge: fires with ARMED even when the ceremony
            // runs long. The 12s watchdog above is the fallback for the rare
            // case it is already armed at that mark.
            if !hasPlayedReadyCue {
                hasPlayedReadyCue = true
                GVSoundEngine.shared.stop(.sceneLoad)
                GVSoundEngine.shared.play(.systemReady)
            }
        }
        .animation(GVMotion.resolved(GVMotion.panel, reduceMotion: reduceMotion), value: isSocialPresented)
    }

    /// The full splash stack. Its own method rather than inline in `body`:
    /// this view is large enough that keeping everything in one expression
    /// stalls the type-checker.
    private func splashContent(
        geometry: GeometryProxy,
        logoWidth: CGFloat,
        logoHeight: CGFloat,
        compactHeight: Bool
    ) -> some View {
        ZStack {
            GVTheme.void.ignoresSafeArea()

            // PHASE 0-2: Void → Spark → Bloom (dramatic opening)
            if sequence.phase <= .bloom {
                Color.black.ignoresSafeArea()
                openingField
            }

            BootAmbientField(
                reach: max(geometry.size.width, geometry.size.height) * 0.82,
                compactHeight: compactHeight
            )
            .opacity(isInterfaceVisible ? 1 : 0)
            .animation(.easeOut(duration: 0.9), value: isInterfaceVisible)

            // The workspace tubes, carried onto the splash so the two
            // screens are lit the same way. Held back until the interface
            // is up: during the void and spark they would be the only
            // light on screen and would give the spark away.
            VStack(spacing: 0) {
                GVNeonEdge(
                    edge: .top,
                    reach: max(geometry.safeAreaInsets.top, 12) + 128,
                    tint: BootPalette.glow,
                    intensity: 0.55
                )
                Spacer(minLength: 0)
                GVNeonEdge(edge: .bottom, reach: 110, tint: BootPalette.glow, intensity: 0.55)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .opacity(isInterfaceVisible ? 1 : 0)

            // PHASE 1 — sensors discovering signal in darkness.
            wakeLayer
                .ignoresSafeArea()
                .opacity(sequence.phase >= .wake ? 1 : 0)
                .animation(.easeInOut(duration: 0.6), value: sequence.phase)

            GVDualScanner(isActive: sequence.phase >= .discovery)
                .ignoresSafeArea()

            // Weather behind the mark. Two storms, offset and mirrored,
            // so the lightning reads as a field around the sigil rather
            // than a single strike in one place.
            if sequence.isMarkVisible {
                ZStack {
                    GVStormCloud()
                        .frame(width: logoWidth * 1.5, height: logoHeight * 0.9)
                        .offset(x: -logoWidth * 0.16, y: -logoHeight * 0.10)
                    GVStormCloud()
                        .frame(width: logoWidth * 1.3, height: logoHeight * 0.78)
                        .scaleEffect(x: -1, y: 1)
                        .offset(x: logoWidth * 0.18, y: logoHeight * 0.06)
                }
                .blendMode(.plusLighter)
                .opacity(0.35)
                .allowsHitTesting(false)
                // Pinned to the display and clipped. Without this the
                // wider cloud — logoWidth * 1.5, larger than the screen —
                // set the root ZStack's width, and every other layer then
                // centred inside those oversized bounds and shifted right.
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .transition(.opacity)
            }

            VStack(spacing: 0) {
                VStack(spacing: 1) {
                    // The mark leads. It is the subject of the screen, so
                    // it takes the top rather than sitting under a block
                    // of version text that is only there to be read once.
                    if sequence.revealedIdentityRows.contains(1) {
                        GVASCIIWordmark(
                            text: "grey//VISION",
                            glyphSize: min(compactHeight ? 5.3 : 5.8, (geometry.size.width - 36) / (112 * 0.62)),
                            columns: 112,
                            tint: .white,
                            accent: .white,
                            revealStart: identityRowDate(1),
                            revealDuration: 1.8
                        )
                        .gvBlackHalo(radius: 30, opacity: 0.66)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: presentSocialLinks)
                        .accessibilityIdentifier("boot.screen")
                        .padding(.top, max(geometry.safeAreaInsets.top - 48, 4))
                    }
                }
                Spacer(minLength: 0)
            }

            markLayer(
                logoWidth: logoWidth,
                logoHeight: logoHeight
            )

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                SplashCaptureDock(
                    setup: $appModel.setup,
                    isReady: isReady,
                    isCollapsing: isDeparting,
                    bottomInset: geometry.safeAreaInsets.bottom,
                    onLaunch: launchWorkspace
                )
                .padding(.horizontal, GVMetrics.screenInset)
            }
            .ignoresSafeArea(edges: .bottom)
            // Staged onto the same clock as everything above it. The rail
            // used to switch on in one frame while the manifest was still
            // resolving row by row, which made the most important control
            // on the screen look like it had been pasted in.
            .opacity(dockReveal)
            .offset(y: (1 - dockReveal) * GVMetrics.stepSection)
            .animation(GVMotion.resolved(GVMotion.cinematic, reduceMotion: reduceMotion), value: dockReveal)
            .gvDecay(sequence.glitchedElement == .dock, seed: 4)
            // Above the CRT glass (12) and the sync sweep (15): the dock is
            // the one control surface on this screen and must not be seen
            // through the tube.
            .zIndex(16)

            if isSocialPresented {
                SocialLinksOverlay(isPresented: $isSocialPresented)
                    .transition(
                        .scale(scale: 0.88, anchor: .center)
                            .combined(with: .opacity)
                    )
                    .zIndex(20)
            }

            // Global CRT glass. Sits above every layer including the mark,
            // so the artwork is seen *through* the same tube as the rest of
            // the interface rather than sitting on top of it — which is
            // what stopped it reading as a pasted-on image.
            GVBootCRTGlass()
                .opacity(0.18)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .zIndex(12)

            // PHASE 4 — CRT synchronisation beam.
            GVSyncSweep(isActive: sequence.phase == .sync, start: sequence.phaseStart)
                .ignoresSafeArea()
                .zIndex(15)
        }
        .saturation(0)
        .gvChromaticLock(isActive: sequence.phase == .sync, start: sequence.phaseStart)
        .gvRasterTear(isActive: isDeparting, start: sequence.phaseStart)
        .scaleEffect(isDeparting && !reduceMotion ? 1.006 : 1)
    }

    /// Centre the artwork independently of the title and capture dock.
    /// Kept separate from `body` to bound SwiftUI type-checking work.
    private func markLayer(
        logoWidth: CGFloat,
        logoHeight: CGFloat
    ) -> some View {
        ZStack {
            ZStack {
                GVLogoReconstruction(
                    isActive: sequence.isMarkVisible,
                    start: markStart
                ) {
                    LogoTreatment(
                        imageName: "CreatorMark",
                        decay: isReady ? 0.12 : 0.28,
                        interactive: isReady,
                        accessibilityIdentifier: "boot.social",
                        onActivate: presentSocialLinks
                    )
                    .frame(width: logoWidth, height: logoHeight)
                    .overlay {
                        RadialGradient(
                            colors: [.clear, .black.opacity(0.08), .black.opacity(0.48)],
                            center: .center,
                            startRadius: logoWidth * 0.20,
                            endRadius: logoWidth * 0.56
                        )
                        .allowsHitTesting(false)
                    }
                    .overlay {
                        // Masked to the mark's own alpha. Unmasked the
                        // band would sweep a rectangle across the void,
                        // which is the tell that it is a gradient rather
                        // than light on an object.
                        GVLogoGlint(start: markStart)
                            .mask(
                                Image("CreatorMark")
                                    .resizable()
                                    .scaledToFit()
                            )
                    }
                }
                .frame(width: logoWidth, height: logoHeight)
                // Applied outside GVLogoReconstruction on purpose. The
                // reconstruction wraps the mark in a layerEffect, and a
                // layerEffect rasterises and clips to its own bounds, so a
                // feather applied inside LogoTreatment was being squared
                // off again one level up. That hard bottom edge is the
                // seam that kept cutting through the manifest.
                .mask(
                    LinearGradient(
                        stops: [
                            // Both ends feather. The previous version was
                            // opaque at location 0, so the top of the
                            // mark's frame terminated on a hard line — the
                            // seam sitting under THERMAL.STATE.
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.55), location: 0.14),
                            .init(color: .black, location: 0.34),
                            .init(color: .black, location: 0.62),
                            .init(color: .black.opacity(0.55), location: 0.82),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .gvBlackHalo(radius: 44, opacity: 0.55)
                .background {
                    // The violet bloom lives here rather than full-bleed
                    // behind the whole screen. Centred on the display it
                    // washed the entire lower block; anchored to the mark
                    // it lights the rabbit and reaches just far enough to
                    // catch the wordmark, which is where the glow belongs.
                    //
                    // Sized well beyond the mark on purpose: a background
                    // takes the frame it is given, and one matching the
                    // mark would terminate the gradient on a hard edge.
                    GVAtmosphericBloom(
                        progress: sequence.phase >= .wake ? 1 : 0,
                        falloff: sequence.phase >= .sync ? 1 : 0
                    )
                    .frame(width: logoWidth * 1.5, height: logoHeight * 1.5)
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.9), value: sequence.phase)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .ignoresSafeArea()
    }

    /// Dramatic phosphor spark and bloom. A separate property so the generic
    /// TimelineView closure is type-checked outside the (very large) body.
    private var openingField: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: false)) { timeline in
            BootOpeningField(
                sequence: sequence,
                elapsed: timeline.date.timeIntervalSince(sequence.phaseStart)
            )
        }
        .ignoresSafeArea()
    }

    /// PHASE 3+ star field. Hidden during void/spark/bloom phases
    @ViewBuilder private var wakeLayer: some View {
        if sequence.phase >= .wake, sequence.phase < .armed {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
                GVStarfieldWake(
                    progress: wakeProgress(now: timeline.date),
                    elapsed: timeline.date.timeIntervalSince(wakeStart),
                    tilt: motion.tilt
                )
            }
        }
    }

    private var wakeStart: Date {
        sequence.phase == .wake ? sequence.phaseStart : sequence.sequenceStart
    }

    private var markStart: Date {
        sequence.phase == .materialize ? sequence.phaseStart : sequence.sequenceStart
    }

    private func wakeProgress(now: Date) -> Double {
        guard sequence.phase >= .wake else { return 0 }
        let elapsed = now.timeIntervalSince(wakeStart)
        return min(max(elapsed / 1.4, 0), 1)
    }

    private var dockReveal: Double {
        sequence.revealedElements.contains(.dock) ? 1 : 0
    }

    private func identityRowDate(_ index: Int) -> Date {
        identityRowDates[index] ?? sequence.phaseStart
    }

    /// Collapses the control into a point, tears the raster, and only then
    /// hands over to `AppModel.startEngine()`. The engine start itself is
    /// unchanged, so there is still exactly one capture session.
    @MainActor
    private func launchWorkspace() {
        guard isReady, !isDeparting else { return }
        GVSoundEngine.shared.stopStings()
        if reduceMotion || appModel.isUITesting {
            appModel.startEngine()
            return
        }

        guard sequence.beginDeparture() else { return }
        launchTask?.cancel()
        launchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(190 + Int(GVBootTiming.departSeconds * 1000)))
            guard !Task.isCancelled else { return }
            motion.stop()
            appModel.startEngine()
        }
    }

    private func presentSocialLinks() {
        guard isReady else { return }
        withAnimation(GVMotion.resolved(GVMotion.panel, reduceMotion: reduceMotion)) {
            isSocialPresented = true
        }
    }
}

/// The splash's standing atmosphere: deep veil, aurora, starfield, snow,
/// grid, scanlines and corner registration marks. Extracted from `BootView`
/// purely to keep that body type-checkable; behaviour is unchanged.
private struct BootAmbientField: View {
    let reach: CGFloat
    let compactHeight: Bool

    var body: some View {
        Group {
            RadialGradient(
                stops: Self.veilStops(reach: reach),
                center: .center,
                startRadius: 18,
                endRadius: reach
            )
            // The veil is a light field, not a drawn shape — a soft blur
            // across the whole gradient removes the banding rings that read
            // as seams where the stops met.
            .blur(radius: 22)
            .ignoresSafeArea()

            // Top edge only. These three field layers were the only ones
            // respecting the safe area, so the starfield, snow and grid all
            // stopped short of the top of the display and left a bare band
            // across the notch. The bottom inset is kept: the capture dock
            // sits there and needs the room.
            GVAurora()
                .ignoresSafeArea()

            DeterministicStarfield(starCount: 420, shootingStarInterval: 3.6)
                .opacity(0.85)
                .ignoresSafeArea(edges: .top)

            GVSnowField()
                .opacity(0.88)
                .ignoresSafeArea(edges: .top)

            GVGridField()
                .opacity(0.46)
                .ignoresSafeArea(edges: .top)

            GVScanlines(opacity: 0.05)
                .ignoresSafeArea()

            // Registration marks for the display, not for the content: they
            // sit at the physical corners so the whole panel reads as one
            // framed instrument.
            GVBrackets(
                color: GVTheme.bone.opacity(0.34),
                length: compactHeight ? 34 : 44,
                lineWidth: 1.4,
                // The display's own corner radius less the inset, so the
                // elbows follow the glass instead of cutting the corner off.
                // 62pt is the 6.9" Pro Max radius; the smaller value keeps
                // 6.1" and 6.3" honest too.
                cornerRadius: (compactHeight ? 55 : 62) - 9
            )
            .padding(9)
            .ignoresSafeArea()
        }
    }

    private static func veilStops(reach _: CGFloat) -> [Gradient.Stop] {
        [
            .init(color: BootPalette.deep.opacity(0.19), location: 0),
            .init(color: BootPalette.deep.opacity(0.12), location: 0.22),
            .init(color: BootPalette.deep.opacity(0.055), location: 0.46),
            .init(color: GVTheme.void.opacity(0.30), location: 0.68),
            .init(color: .black, location: 1)
        ]
    }
}

/// PHASE 0-2 opening field: the spark pixel and the bloom detonating out of
/// it. Extracted from `BootView` because gradient literals this size inside
/// the boot timeline stalled the type-checker; it also keeps each ramp in one
/// readable place.
private struct BootOpeningField: View {
    let sequence: GVBootSequence
    let elapsed: TimeInterval

    var body: some View {
        ZStack {
            // Phase 1: Spark pixel
            if sequence.isSparkVisible, !sequence.isBloomActive {
                BootSpark(elapsed: elapsed)
            }

            // Phase 2: Bloom explosion
            if sequence.isBloomActive {
                BootBloomLayer(elapsed: elapsed)
                    .compositingGroup()
                    .blendMode(.plusLighter)
            }
        }
    }
}

/// Phase 1: a single hot pixel igniting in the void.
private struct BootSpark: View {
    let elapsed: TimeInterval

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [.white, BootPalette.glow.opacity(0.85), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 2
                )
            )
            .frame(width: 4, height: 4)
            .blur(radius: 0.5)
            .shadow(color: BootPalette.glow, radius: 8)
            .shadow(color: BootPalette.ember.opacity(0.6), radius: 14)
            .opacity(min(elapsed / 0.3, 1.0))
    }
}

/// Phase 2 of the boot opening: the bloom detonating out of the spark.
///
/// Extracted from `BootView` because a gradient literal this size inside the
/// boot timeline stalled the type-checker; it also keeps the stop ramp in one
/// readable place.
private struct BootBloomLayer: View {
    let elapsed: TimeInterval

    /// Feathered: many small steps rather than four wide ones. Four stops
    /// over a 2000pt radius put visible rings in the falloff, and the
    /// outermost jump to clear read as a hard disc edge sweeping outward.
    private static func stops(_ intensity: Double) -> [Gradient.Stop] {
        [
            .init(color: .white.opacity(intensity * 0.95), location: 0.00),
            .init(color: BootPalette.glow.opacity(intensity * 0.78), location: 0.14),
            .init(color: BootPalette.glow.opacity(intensity * 0.50), location: 0.28),
            .init(color: BootPalette.deep.opacity(intensity * 0.36), location: 0.42),
            .init(color: BootPalette.deep.opacity(intensity * 0.21), location: 0.56),
            .init(color: BootPalette.ember.opacity(intensity * 0.09), location: 0.70),
            .init(color: BootPalette.deep.opacity(intensity * 0.04), location: 0.82),
            .init(color: BootPalette.deep.opacity(intensity * 0.01), location: 0.92),
            .init(color: .clear, location: 1.00)
        ]
    }

    var body: some View {
        let progress = min(elapsed / GVBootTiming.bloomSeconds, 1.0)
        let radius: CGFloat = 2000 * progress
        let intensity = progress < 0.3 ? progress / 0.3 : 1.0 - ((progress - 0.3) / 0.7) * 0.85

        RadialGradient(
            stops: Self.stops(intensity),
            center: .center,
            startRadius: 0,
            endRadius: radius * 0.4
        )
        .blur(radius: max(18 * (1 - progress * 0.7), 5))
    }
}

private struct SplashCaptureDock: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var setup: CaptureSetupDraft
    let isReady: Bool
    let isCollapsing: Bool
    let bottomInset: CGFloat
    let onLaunch: () -> Void

    @State private var activeSection: SplashDockSection?
    /// Leading visible card of the open format rail. Every submenu opens from
    /// its first option so the beginning of the list is never clipped.
    @State private var optionScrollID: String?

    /// The basics only. The enum still spells every codec it ever did for
    /// draft decoding, but the chooser offers five.
    private let codecChoices: [CaptureSetupDraft.VideoCodec] = CaptureSetupDraft.VideoCodec.curated

    /// Height of the dock's button row, and the gap the open rail leaves above
    /// it. The rail hangs off these: its readout makes it taller than the old
    /// strip, and an overlay pinned to the row's top edge would have grown
    /// downwards over the controls it belongs to. Anchored to the bottom it
    /// grows the only direction there is room for.
    private let rowHeight: CGFloat = 52
    private let railGap: CGFloat = GVMetrics.gap

    var body: some View {
        VStack(spacing: GVMetrics.gap) {
            HStack(spacing: GVMetrics.gap) {
                dockButton(.codec, value: setup.videoCodec.compactLabel)
                dockButton(.frameRate, value: "\(setup.frameRate.rawValue)")
                dockButton(.resolution, value: setup.resolution.rawValue)
                launchButton
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                if let activeSection {
                    choiceRail(for: activeSection)
                        .offset(y: -(rowHeight + railGap))
                        .transition(
                            .move(edge: .bottom)
                                .combined(with: .opacity)
                                .combined(with: .scale(scale: 0.96, anchor: .bottom))
                        )
                }
            }

            GVTerminalText(
                text: isReady ? "FORMAT ARMED // LAUNCH" : "LOCAL PROBE IN PROGRESS",
                size: 9.5,
                weight: .bold,
                tracking: 1.2,
                baseColor: isReady ? GVTheme.bone.opacity(0.72) : GVTheme.bone.opacity(0.42),
                intensity: 0.42
            )
            Text("MADE WITH LOVE BY GREY")
                .gvMono(9, .medium)
                .tracking(1.2)
                .foregroundStyle(GVTheme.bone.opacity(0.82))
                .accessibilityIdentifier("boot.attribution")
                .padding(.bottom, max(bottomInset, GVMetrics.stepInternal))
        }
        .frame(maxWidth: 560)
        .zIndex(2)
        .animation(GVMotion.resolved(GVMotion.normal, reduceMotion: reduceMotion), value: activeSection)
    }

    /// Every option in a section, built once.
    ///
    /// The cards, the footer readout, the scroll anchor and the accessibility
    /// identifiers all read off this list, so the rail cannot describe a format
    /// the chooser does not offer — which is what three hand-kept card groups
    /// kept doing at the edges.
    private func options(for section: SplashDockSection) -> [GVSplashOption] {
        switch section {
        case .codec:
            codecChoices.map { codec in
                GVSplashOption(
                    id: "codec-\(codec.rawValue)",
                    identifier: "boot.codec.\(optionSlug(codec.rawValue))",
                    label: codec.rawValue,
                    spec: "\(codec.chromaLabel) · \(codec.bitDepthLabel)",
                    note: codec.availabilityNote,
                    meter: codec.fidelityClass,
                    chips: [
                        GVSplashSpecChip(caption: "CHROMA", value: codec.chromaLabel),
                        GVSplashSpecChip(caption: "DEPTH", value: codec.bitDepthLabel),
                        GVSplashSpecChip(caption: "TIER", value: codec.tierLabel),
                        GVSplashSpecChip(
                            caption: "FIDELITY",
                            value: codec.fidelityLabel,
                            meter: codec.fidelityClass
                        )
                    ],
                    enabled: codec.isOperatingSystemAvailable,
                    apply: { setup.videoCodec = codec }
                )
            }
        case .frameRate:
            CaptureSetupDraft.FrameRate.allCases.map { frameRate in
                GVSplashOption(
                    id: "fps-\(frameRate.rawValue)",
                    identifier: "boot.fps.\(optionSlug(frameRate.label))",
                    label: frameRate.label,
                    spec: frameRate.cadenceLabel,
                    note: frameRate.availabilityNote,
                    meter: frameRate.motionClass,
                    chips: [
                        GVSplashSpecChip(caption: "CADENCE", value: frameRate.label),
                        GVSplashSpecChip(
                            caption: "MOTION",
                            value: frameRate.cadenceLabel,
                            meter: frameRate.motionClass
                        )
                    ],
                    enabled: true,
                    apply: { setup.frameRate = frameRate }
                )
            }
        case .resolution:
            CaptureSetupDraft.Resolution.allCases.map { resolution in
                GVSplashOption(
                    id: "res-\(resolution.rawValue)",
                    identifier: "boot.res.\(optionSlug(resolution.rawValue))",
                    label: resolution.rawValue,
                    spec: resolution.pixelLabel,
                    note: resolution.availabilityNote,
                    meter: resolution.detailClass,
                    chips: [
                        GVSplashSpecChip(caption: "PIXELS", value: resolution.pixelLabel),
                        GVSplashSpecChip(
                            caption: "DETAIL",
                            value: resolution.detailLabel,
                            meter: resolution.detailClass
                        )
                    ],
                    enabled: true,
                    apply: { setup.resolution = resolution }
                )
            }
        }
    }

    /// Scroll anchor of the option currently in force, so the rail's inverted
    /// plate and its footer readout always describe the same thing.
    private func selectedID(for section: SplashDockSection) -> String {
        switch section {
        case .codec: "codec-\(setup.videoCodec.rawValue)"
        case .frameRate: "fps-\(setup.frameRate.rawValue)"
        case .resolution: "res-\(setup.resolution.rawValue)"
        }
    }

    /// The open section's rail. All of its presentation lives in
    /// `GVSplashChoiceRail`; what stays here is the state machine — which
    /// section is open, what a choice does to the draft, and when the rail
    /// closes.
    private func choiceRail(for section: SplashDockSection) -> some View {
        GVSplashChoiceRail(
            section: section,
            options: options(for: section),
            selectedID: selectedID(for: section),
            scrollID: $optionScrollID,
            onSelect: { option in
                // Animated, so the footer readout crossfades to the format the
                // operator just chose instead of snapping while the rail is
                // still open.
                withAnimation(GVMotion.resolved(GVMotion.normal, reduceMotion: reduceMotion)) { option.apply() }
                // The rail stays open just long enough for the choice to be
                // seen landing on the card before it collapses.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(230))
                    withAnimation(GVMotion.resolved(GVMotion.panel, reduceMotion: reduceMotion)) {
                        activeSection = nil
                    }
                }
            }
        )
    }

    private func dockButton(_ section: SplashDockSection, value: String) -> some View {
        let isActive = activeSection == section
        return Button {
            if isActive {
                activeSection = nil
            } else {
                optionScrollID = firstOptionID(for: section)
                activeSection = section
            }
        } label: {
            VStack(spacing: GVMetrics.gapTight) {
                GVTerminalText(
                    text: section.label,
                    size: 9.5,
                    weight: .bold,
                    tracking: 1.6,
                    baseColor: isActive ? GVTheme.violet : GVTheme.bone.opacity(0.76),
                    intensity: 0.55
                )
                GVTerminalText(
                    text: value,
                    size: 15,
                    weight: .medium,
                    tracking: 0.7,
                    baseColor: GVTheme.bone,
                    intensity: 0.2
                )
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                // A lit rule under the value, so the dock says which section
                // the rail above it belongs to without the operator having to
                // read the header over the cards.
                Rectangle()
                    .fill(isActive ? GVTheme.violet : GVTheme.bone.opacity(0.16))
                    .frame(width: 22, height: 0.75)
                    .shadow(color: GVTheme.violet.opacity(isActive ? 0.7 : 0), radius: 3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(GVSplashButtonStyle(active: isActive))
        .animation(GVMotion.resolved(GVMotion.normal, reduceMotion: reduceMotion), value: value)
        .accessibilityLabel("\(section.label), \(value)")
        .accessibilityHint(isActive ? "Closes the format chooser." : "Opens the format chooser.")
        .accessibilityIdentifier("boot.\(section.rawValue)")
    }

    /// First option of a section, because opening one always starts at its
    /// beginning. Read off the same list the rail draws, so a reordered
    /// chooser cannot leave the scroll pinned to an anchor that no longer
    /// exists.
    private func firstOptionID(for section: SplashDockSection) -> String {
        options(for: section).first?.id ?? ""
    }

    private var launchButton: some View {
        Button(action: onLaunch) {
            VStack(spacing: GVMetrics.gapTight) {
                GVTerminalText(
                    text: "ARM",
                    size: 9.5,
                    weight: .bold,
                    tracking: 1.6,
                    baseColor: isReady ? GVTheme.bone : GVTheme.bone.opacity(0.5),
                    intensity: 0.95
                )
                Image(systemName: "arrow.right")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(isReady ? GVTheme.bone : GVTheme.faint)
                    .shadow(color: isReady ? GVTheme.bone.opacity(0.85) : .clear, radius: 6)
                    .shadow(color: isReady ? GVTheme.bone.opacity(0.45) : .clear, radius: 12)
            }
            .frame(maxWidth: .infinity)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(GVSplashButtonStyle(active: isReady))
        .disabled(!isReady)
        .opacity(isReady ? 1 : 0.72)
        .accessibilityLabel("Launch workspace")
        .accessibilityHint(isReady ? "Enters the camera workspace." : "Unavailable until the probe completes.")
        .accessibilityIdentifier("boot.launch")
    }

    private func optionSlug(_ label: String) -> String {
        label
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }
}

/// Thin monochrome plates shared by the format dock and its options.
struct GVSplashButtonStyle: ButtonStyle {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .background(Color.black.opacity(active || pressed ? 0.94 : 0.76))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(GVTheme.bone.opacity(active || pressed ? 0.85 : 0.28), lineWidth: 0.75)
            }
            .brightness(pressed ? 0.14 : 0)
            .scaleEffect(reduceMotion ? 1 : (pressed ? 0.95 : (active ? 1.02 : 1)))
            .animation(GVMotion.resolved(GVMotion.press, reduceMotion: reduceMotion), value: pressed)
            .animation(GVMotion.resolved(GVMotion.normal, reduceMotion: reduceMotion), value: active)
    }
}

#Preview {
    BootView()
        .environmentObject(AppModel(arguments: ["--uitesting"]))
}

// swiftlint:enable file_length
