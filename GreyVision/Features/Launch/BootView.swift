// swiftlint:disable file_length
import SwiftUI

struct BootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appModel: AppModel

    @StateObject private var sequence = GVBootSequence()
    @StateObject private var motion = GVBootMotion()

    @State private var isSocialPresented = false
    @State private var launchTask: Task<Void, Never>?
    @State private var lineRevealDates: [Int: Date] = [:]
    @State private var hasPlayedGlitchCue = false
    @State private var readyCueTask: Task<Void, Never>?
    @State private var hasPlayedReadyCue = false
    @State private var identityRowDates: [Int: Date] = [:]
    /// Measured height of the fixed version/signature labels, so the scrolling
    /// manifest below them can take exactly the rest of the window.
    @State private var identityHeaderHeight: CGFloat = 0

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
            // The mark is the screen's subject, so it takes the full width and
            // a little over half the height. The balancing block shrinks to
            // buy that space back from the console and identity blocks.
            // Fits the screen exactly. At 1.12x the branches were cropped on
            // both edges and, worse, the identity overlay inherited that
            // oversized frame and ran off the right side of the display.
            let logoWidth = min(geometry.size.width, compactHeight ? 430 : 520)
            let logoHeight = min(geometry.size.height * (compactHeight ? 0.42 : 0.46), compactHeight ? 340 : 460)

            ZStack {
                GVTheme.void.ignoresSafeArea()

                // PHASE 0-2: Void → Spark → Bloom (dramatic opening)
                if sequence.phase <= .bloom {
                    Color.black.ignoresSafeArea()

                    // Dramatic phosphor spark and bloom
                    TimelineView(.animation(minimumInterval: 1 / 60, paused: false)) { timeline in
                        let elapsed = timeline.date.timeIntervalSince(sequence.phaseStart)

                        ZStack {
                            // Phase 1: Spark pixel
                            if sequence.isSparkVisible, !sequence.isBloomActive {
                                Circle()
                                    .fill(
                                        RadialGradient(
                                            colors: [GVTheme.violet, GVTheme.violetDeep.opacity(0.8), .clear],
                                            center: .center,
                                            startRadius: 0,
                                            endRadius: 2
                                        )
                                    )
                                    .frame(width: 4, height: 4)
                                    .blur(radius: 0.5)
                                    .shadow(color: GVTheme.violet, radius: 8)
                                    .opacity(min(elapsed / 0.3, 1.0))
                            }

                            // Phase 2: Bloom explosion
                            if sequence.isBloomActive {
                                let progress = min(elapsed / GVBootTiming.bloomSeconds, 1.0)
                                let radius: CGFloat = 2000 * progress
                                let intensity = progress < 0.3 ? progress / 0.3 : 1.0 - ((progress - 0.3) / 0.7) * 0.85

                                // Feathered: many small steps rather than four
                                // wide ones. Four stops over a 2000pt radius
                                // put visible rings in the falloff, and the
                                // outermost jump to clear read as a hard disc
                                // edge sweeping outward.
                                RadialGradient(
                                    stops: [
                                        .init(color: GVTheme.violet.opacity(intensity * 0.90), location: 0.00),
                                        .init(color: GVTheme.violet.opacity(intensity * 0.72), location: 0.14),
                                        .init(color: GVTheme.violetDeep.opacity(intensity * 0.52), location: 0.28),
                                        .init(color: GVTheme.violetDeep.opacity(intensity * 0.34), location: 0.42),
                                        .init(color: GVTheme.violetDeep.opacity(intensity * 0.20), location: 0.56),
                                        .init(color: GVTheme.violetDeep.opacity(intensity * 0.10), location: 0.70),
                                        .init(color: GVTheme.violetDeep.opacity(intensity * 0.04), location: 0.82),
                                        .init(color: GVTheme.violetDeep.opacity(intensity * 0.01), location: 0.92),
                                        .init(color: .clear, location: 1.00)
                                    ],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: radius * 0.4
                                )
                                // Heavier blur held for longer keeps the edge
                                // soft across the whole expansion.
                                .blur(radius: max(18 * (1 - progress * 0.7), 5))
                                .compositingGroup()
                                .blendMode(.plusLighter)
                            }
                        }
                    }
                    .ignoresSafeArea()
                }

                Group {
                    RadialGradient(
                        stops: [
                            .init(color: GVTheme.violetDeep.opacity(0.26), location: 0),
                            .init(color: GVTheme.violetDeep.opacity(0.17), location: 0.22),
                            .init(color: GVTheme.violetDeep.opacity(0.08), location: 0.46),
                            .init(color: GVTheme.void.opacity(0.22), location: 0.68),
                            .init(color: .black, location: 1)
                        ],
                        center: .center,
                        startRadius: 18,
                        endRadius: max(geometry.size.width, geometry.size.height) * 0.82
                    )
                    // The veil is a light field, not a drawn shape — a soft
                    // blur across the whole gradient removes the banding rings
                    // that read as seams where the stops met.
                    .blur(radius: 22)
                    .ignoresSafeArea()

                    // Top edge only. These three field layers were the only
                    // ones respecting the safe area, so the starfield, snow
                    // and grid all stopped short of the top of the display and
                    // left a bare band across the notch. The bottom inset is
                    // kept: the capture dock sits there and needs the room.
                    GVAurora()
                        .ignoresSafeArea()

                    DeterministicStarfield()
                        .opacity(0.58)
                        .ignoresSafeArea(edges: .top)

                    GVSnowField()
                        .opacity(0.88)
                        .ignoresSafeArea(edges: .top)

                    GVGridField()
                        .opacity(0.46)
                        .ignoresSafeArea(edges: .top)

                    GVScanlines(opacity: 0.05)
                        .ignoresSafeArea()

                    // Registration marks for the display, not for the
                    // content: they sit at the physical corners so the whole
                    // panel reads as one framed instrument.
                    GVBrackets(
                        color: GVTheme.bone.opacity(0.34),
                        length: compactHeight ? 34 : 44,
                        lineWidth: 1.4,
                        // The display's own corner radius less the inset, so
                        // the elbows follow the glass instead of cutting the
                        // corner off. 62pt is the 6.9" Pro Max radius; the
                        // smaller value keeps 6.1" and 6.3" honest too.
                        cornerRadius: (compactHeight ? 55 : 62) - 9
                    )
                    .padding(9)
                    .ignoresSafeArea()
                }
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
                        intensity: 1.65
                    )
                    Spacer(minLength: 0)
                    GVNeonEdge(edge: .bottom, reach: 190, intensity: 1.65)
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
                                glyphSize: compactHeight ? 4.6 : 5.4,
                                columns: compactHeight ? 104 : 118,
                                tint: GVTheme.bone,
                                accent: GVTheme.violet,
                                revealStart: identityRowDate(1),
                                revealDuration: 2.8
                            )
                            .gvBlackHalo(radius: 30, opacity: 0.66)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: presentSocialLinks)
                            .accessibilityIdentifier("boot.screen")
                            .padding(.top, max(geometry.safeAreaInsets.top - 48, 4))
                        }

                        // Gated on the phase, not just faded: during the void
                        // and spark the console still laid out its rows, and
                        // the separator dots in them showed as a grey matrix
                        // floating in the black above the spark.
                        if sequence.phase > .bloom {
                            bootConsole(compactHeight: compactHeight)
                                .padding(.top, compactHeight ? 3 : 6)
                        }
                    }
                    Spacer(minLength: 0)
                }

                // Mark centred on the display; identity overlaid on its
                // lower half.
                //
                // Stacking the two in a VStack tied the mark's position to the
                // height of the text under it, so growing the manifest from
                // four rows to twelve silently pushed the rabbit upward — it
                // was never repositioned, it was displaced. They are separate
                // layers now: the mark holds the centre of the screen and the
                // text is offset down over it, which is also the overlap that
                // was wanted.
                //
                // The identity keeps its own width constraint. It must never
                // inherit the mark's frame, which is wider than the display
                // and once pushed the wordmark off the right edge.
                ZStack {
                    GVLogoReconstruction(
                        isActive: sequence.isMarkVisible,
                        start: markStart
                    ) {
                        LogoTreatment(
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
                                    Image("OfficialLogo")
                                        .resizable()
                                        .scaledToFit()
                                )
                        }
                    }
                    .frame(width: logoWidth, height: logoHeight)
                    // Incantation orbiting the mark. Sits behind it in the
                    // stack and stays under a third opacity: it is an
                    // inscription around the sigil, not a second headline.
                    // Radius is derived from the mark so it clears the
                    // artwork on any device rather than being tuned to one.
                    .background {
                        GVCircularText(
                            text: "I CAN SUMMON ANY SPIRIT. I CAN SUMMON ANY SPIRIT. ",
                            radius: min(logoWidth, logoHeight) * 0.46,
                            spinDuration: 34,
                            fontSize: compactHeight ? 9 : 10.5,
                            color: GVTheme.bone,
                            opacity: 0.24
                        )
                        .opacity(sequence.isMarkVisible ? 1 : 0)
                        .animation(.easeOut(duration: 1.1), value: sequence.isMarkVisible)
                    }
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

                    // The block is top-anchored, not centred.
                    //
                    // It used to be centred and dropped, which meant growing it
                    // pushed its top edge up into the rabbit and its bottom
                    // down through the format dock in equal measure. Pinning
                    // the top and deriving the height from the dock clearance
                    // lets the window fill the gap without eating either.
                    //
                    // The top still sits inside the mark's lower spikes on
                    // purpose — the feather is what keeps that reading as depth
                    // rather than as a collision.
                    let identityTop = logoHeight * (compactHeight ? 0.36 : 0.34)
                    let identityWindow = max(
                        geometry.size.height / 2 - (compactHeight ? 74 : 84) - identityTop,
                        150
                    )

                    splashIdentity(compactHeight: compactHeight, availableHeight: identityWindow)
                        .frame(maxWidth: geometry.size.width - 16)
                        // `offset` moves the centre, and the block is exactly
                        // `identityWindow` tall, so half of it puts the top
                        // edge on `identityTop`.
                        .offset(y: identityTop + identityWindow / 2)
                        .gvDecay(sequence.glitchedElement == .identity, seed: 3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    SplashCaptureDock(
                        setup: $appModel.setup,
                        isReady: isReady,
                        isCollapsing: isDeparting,
                        bottomInset: geometry.safeAreaInsets.bottom,
                        onLaunch: launchWorkspace
                    )
                    .padding(.horizontal, 12)
                }
                .ignoresSafeArea(edges: .bottom)
                // Staged onto the same clock as everything above it. The rail
                // used to switch on in one frame while the manifest was still
                // resolving row by row, which made the most important control
                // on the screen look like it had been pasted in.
                .opacity(dockReveal)
                .offset(y: (1 - dockReveal) * 26)
                .animation(.easeOut(duration: 0.55), value: dockReveal)
                .gvDecay(sequence.glitchedElement == .dock, seed: 4)

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
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .zIndex(12)

                // PHASE 4 — CRT synchronisation beam.
                GVSyncSweep(isActive: sequence.phase == .sync, start: sequence.phaseStart)
                    .ignoresSafeArea()
                    .zIndex(15)
            }
            .gvChromaticLock(isActive: sequence.phase == .sync, start: sequence.phaseStart)
            .gvRasterTear(isActive: isDeparting, start: sequence.phaseStart)
            .scaleEffect(isDeparting && !reduceMotion ? 1.006 : 1)
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
            // Discharge is scheduled, not triggered by state. It marks the
            // moment the splash is fully assembled, and no published flag
            // corresponds to that: `isReady` arms as soon as capture can
            // start, which is seconds earlier.
            readyCueTask?.cancel()
            readyCueTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled, !hasPlayedReadyCue else { return }
                hasPlayedReadyCue = true
                GVSoundEngine.shared.stop(.sceneLoad)
                GVSoundEngine.shared.play(.systemReady)
            }

            // No cue at t=0. The screen is still black at that point, so a
            // sound there reads as a stray discharge rather than as the
            // instrument coming up; the only launch sound is the 12s one.

            // Force full boot sequence (ignore reduceMotion for now)
            sequence.isAccelerated = appModel.isUITesting
            sequence.start(
                lineCount: appModel.bootTelemetry.terminalLines.count,
                reduceMotion: false // Force dramatic sequence
            )
        }
        .onChange(of: sequence.revealedIdentityRows) { _, revealed in
            let now = Date()
            for index in revealed where identityRowDates[index] == nil {
                identityRowDates[index] = now
            }
        }
        .onChange(of: sequence.revealedLines) { _, revealed in
            // Stamp only the newly-resolved indices; order is shuffled, so a
            // count-based assumption would attribute the wrong timestamp.
            let now = Date()
            for index in revealed where lineRevealDates[index] == nil {
                lineRevealDates[index] = now
            }
        }
        .onChange(of: sequence.glitchedElement) { previous, current in
            // One shot, on the first corruption only. Retriggering per glitch
            // would stack copies of the same cue over each other.
            guard previous == nil, current != nil, !hasPlayedGlitchCue else { return }
            hasPlayedGlitchCue = true
            GVSoundEngine.shared.play(.bootGlitch)
        }
        .onChange(of: sequence.isReady) { _, ready in
            guard ready else { return }
            motion.stop()
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: isSocialPresented)
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

    /// Rows below the title. Each has its own decay behaviour so the block
    /// reads as several failing sources rather than one animation.
    private var identityRows: [(String, GVDecayMode)] {
        // One capability per row, dot-led to a common width so every closing
        // bracket lands in the same column. Ragged terminators would read as
        // an accident; a column reads as a manifest.
        //
        // Modes cycle rather than repeat so no two adjacent rows resolve the
        // same way — the block should look like several failing sources, not
        // one animation played twelve times.
        let modes: [GVDecayMode] = [.forward, .reverse, .cycling, .dropout]
        return Self.capabilities.enumerated().map { index, capability in
            (Self.leaders(capability), modes[index % modes.count])
        }
    }

    private static let capabilities = [
        "LOCAL CAMERA INSTRUMENT",
        "METAL DEVICE ONLINE",
        "CAMERA NODES",
        "DEPTH SENSING",
        "VISION PIPELINE",
        "AUDIO DSP",
        "FRAME HISTORY",
        "FEEDBACK ROUTING",
        "TOUCH ROUTING",
        "LOCAL ONLY",
        "ZERO CLOUD",
        "SENSOR BOUNDED"
    ]

    /// Pads a label with dot leaders and terminates it.
    ///
    /// Line lengths are deliberately uneven. Padding every row to one width
    /// produced a perfect column of brackets, which read as typeset rather
    /// than printed — and the telemetry block above the mark is not like that:
    /// its rows end wherever their value ends, so the whole group sits ragged
    /// inside the centred column. This mirrors that.
    ///
    /// The variance is hashed from the label, so it is stable across launches
    /// rather than reshuffling every frame, and derived from the longest entry
    /// so a longer capability added later cannot break the block.
    private static func leaders(_ label: String) -> String {
        let width = (capabilities.map(\.count).max() ?? 0) + 6
        let jitter = abs(label.unicodeScalars.reduce(0) { $0 &+ Int($1.value) &* 31 }) % 6
        let dots = String(repeating: ".", count: max(width - label.count - jitter, 2))
        return "\(label) \(dots) <"
    }

    /// The lower block: version header, signature, capability manifest.
    ///
    /// Only the capability rows travel. The version header and the signature
    /// are fixed labels — they name the build and sign the work, and neither is
    /// a feed. The manifest is the part that reads as a machine listing what it
    /// has, so it is the only part that scrolls.
    private func splashIdentity(compactHeight: Bool, availableHeight: CGFloat) -> some View {
        VStack(spacing: compactHeight ? 2 : 4) {
            identityStaticHeader(compactHeight: compactHeight)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    identityHeaderHeight = height
                }

            if manifestResolved {
                // The window is what is left after the fixed labels, so the
                // rows fill the gap down to the format dock instead of showing
                // seven of twelve inside a short pane.
                GVInfiniteColumn(
                    windowHeight: max(availableHeight - identityHeaderHeight, 90)
                ) {
                    settledManifest(compactHeight: compactHeight)
                }
                .transition(.opacity)
            } else {
                identityManifest(compactHeight: compactHeight)
            }
        }
        .frame(height: availableHeight, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Capability manifest")
        .accessibilityValue(identityRows.map(\.0).joined(separator: ", "))
    }

    private func identityStaticHeader(compactHeight: Bool) -> some View {
        VStack(spacing: compactHeight ? 2 : 4) {
            // Attribution sits above the title now, so the title is the last
            // thing read before the mark and clearly terminates the block.
            if sequence.phase > .bloom {
                telemetryHeader
                    .opacity(sequence.revealedElements.contains(.header) ? 1 : 0)
                    .gvDecay(sequence.glitchedElement == .header, seed: 1)
                    .padding(.bottom, compactHeight ? 3 : 6)
            }

            if sequence.revealedIdentityRows.contains(0) {
                // Deliberately not a GVDecayText. Every other line here is a
                // failing terminal readout; the signature is the one human
                // thing on the screen, so it resolves cleanly and is set in
                // SF rather than the monospace the machine speaks in. Same
                // type family, different voice.
                //
                // Decay would also warp it: the noise glyphs are chosen to
                // hold a constant width, which only holds in a monospaced
                // face, so a proportional font would visibly change length
                // while it settled.
                // The draw-on treatment lives here now: the signature is the
                // one human line on the screen, so watching it get written is
                // the right place for a hand-drawn reveal.
                HStack(alignment: .firstTextBaseline, spacing: compactHeight ? 5 : 6) {
                    GVStrokeText(
                        text: "MADE WITH LOVE BY",
                        fontSize: compactHeight ? 10.5 : 12,
                        tracking: 1.2,
                        strokeColor: GVTheme.violet,
                        fillColor: GVTheme.bone.opacity(0.78),
                        strokeWidth: 0.9,
                        drawDuration: 3.4,
                        fillDelay: 0.5,
                        stagger: 0.11,
                        start: identityRowDate(0)
                    )

                    // The name carries the chromatic glitch rather than the
                    // whole sentence, so the corruption reads as being about
                    // the signature and not about the machine.
                    GVGlitchText(
                        text: "GREY",
                        size: compactHeight ? 17 : 19.5,
                        tracking: 1.4,
                        speed: 0.6
                    )
                }
                .gvBlackHalo(radius: 26, opacity: 0.62)
                // The line was reading as a sticker laid over the splash: full
                // white at full width, hard on both ends. Feathering the ends
                // and pulling the contrast down settles it into the field
                // without losing the draw-on.
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.00),
                            .init(color: .white.opacity(0.45), location: 0.05),
                            .init(color: .white, location: 0.16),
                            .init(color: .white, location: 0.84),
                            .init(color: .white.opacity(0.45), location: 0.95),
                            .init(color: .clear, location: 1.00)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .opacity(0.84)
                .padding(.bottom, compactHeight ? 3 : 6)
            }
        }
    }

    /// The manifest after it has resolved: no decay, no per-row reveal, just
    /// the rows. Rendered inside `GVInfiniteColumn`, which supplies the travel.
    private func settledManifest(compactHeight: Bool) -> some View {
        let size: CGFloat = compactHeight ? 8.2 : 9.5
        return VStack(spacing: compactHeight ? 2 : 3) {
            ForEach(Array(identityRows.enumerated()), id: \.offset) { _, row in
                Text(row.0)
                    .gvMono(size, .bold)
                    .tracking(1.05)
                    .foregroundStyle(GVTheme.bone)
                    .shadow(color: .black.opacity(0.85), radius: 2)
                    .fixedSize()
            }
        }
        // Sits directly under the signature with the same gap the decoding
        // manifest had, so the swap to the settled rows does not shift the
        // block.
        .padding(.top, compactHeight ? 2 : 4)
    }

    /// True once every capability row has resolved.
    private var manifestResolved: Bool {
        let rows = GVBootSequence.identityCapabilityCount
        return sequence.revealedIdentityRows.filter { $0 >= 2 }.count >= rows
    }

    /// The decoding manifest, before it starts travelling.
    @ViewBuilder
    private func identityManifest(compactHeight: Bool) -> some View {
        VStack(spacing: compactHeight ? 2 : 4) {
            ForEach(Array(identityRows.enumerated()), id: \.offset) { index, row in
                let revealed = sequence.revealedIdentityRows.contains(index + 2)
                // Top rows sit closest to the mark's own falloff, so they are
                // held back slightly. Without it the manifest starts at full
                // brightness exactly where the artwork ends, which reinstates
                // the edge the feather removed.
                let proximity = 1.0 - min(Double(index) / 3.0, 1.0)
                Group {
                    GVDecayText(
                        // The top block opens every line with `>`. These close
                        // with `<` on the right, so the two blocks bracket the
                        // mark rather than repeating the same gesture twice.
                        text: row.0,
                        mode: row.1,
                        revealDate: identityRowDate(index + 2),
                        // Smaller than the single-line version it replaced:
                        // twelve rows at 11.2 would run into the capture dock.
                        // Dense is also the correct register here — this is a
                        // manifest, and the top block is set the same way.
                        size: compactHeight ? 8.2 : 9.5,
                        weight: .bold,
                        tracking: 1.05,
                        // `ink`, matching GVBootTelemetryLine above the mark.
                        // At `dim` (white 0.48 against the telemetry's 0.94)
                        // the lower block read as a second-class caption.
                        color: GVTheme.bone,
                        seed: index * 7 + 3
                    )
                    .frame(maxWidth: 400)
                }
                .opacity(revealed ? (1.0 - proximity * 0.55) : 0)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Stamped the first time a row appears so its decay animation starts from
    /// its own reveal rather than a shared phase origin.
    /// Rail reveal, 0...1.
    ///
    /// Held back until the manifest has finished resolving, then eased in over
    /// its own beat rather than switching on with the rest of the chrome.
    private var dockReveal: Double {
        guard sequence.revealedElements.contains(.dock) else { return 0 }
        let rows = GVBootSequence.identityCapabilityCount
        let resolved = sequence.revealedIdentityRows.filter { $0 >= 2 }.count
        return resolved >= rows ? 1 : 0
    }

    private func identityRowDate(_ index: Int) -> Date {
        identityRowDates[index] ?? sequence.phaseStart
    }

    private var telemetryHeader: some View {
        VStack(spacing: 4) {
            GVTerminalText(
                text: "VERSION 3.3",
                size: 19,
                weight: .black,
                tracking: 4.2,
                intensity: 1.3
            )
            .padding(.bottom, 2)

            GVTerminalText(
                text: "GV.CORE // CLEAN ROOM",
                size: 12.4,
                weight: .black,
                tracking: 2.1,
                intensity: 1.15
            )
            GVTerminalText(
                text: "BUILD \(buildNumber) // LOCAL RUNTIME",
                size: 10.0,
                weight: .bold,
                tracking: 1.45,
                baseColor: GVTheme.ash,
                intensity: 0.65
            )
            GVTerminalText(
                text: isReady ? "● READY" : "○ PROBING",
                size: 9.7,
                weight: .black,
                tracking: 1.2,
                baseColor: isReady ? GVTheme.acid : GVTheme.ash,
                intensity: 0.9
            )
            .padding(.top, 1)
        }
    }

    /// True once every telemetry line has decoded.
    private var consoleResolved: Bool {
        sequence.revealedLines.count >= appModel.bootTelemetry.terminalLines.count
    }

    private func bootConsole(compactHeight: Bool) -> some View {
        Group {
            if consoleResolved {
                // Travels in place: no window height, so it occupies exactly
                // the room the static block did and wraps inside it. The
                // manifest at the bottom of the screen already reads as a live
                // feed; a fixed console above it read as a caption.
                GVInfiniteColumn(speed: 9) {
                    consoleColumn(compactHeight: compactHeight)
                }
                .transition(.opacity)
            } else {
                consoleColumn(compactHeight: compactHeight)
            }
        }
        .frame(maxWidth: 430)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live device boot telemetry")
    }

    private func consoleColumn(compactHeight: Bool) -> some View {
        VStack(spacing: compactHeight ? 1 : 3) {
            ForEach(Array(appModel.bootTelemetry.terminalLines.enumerated()), id: \.offset) { index, line in
                GVBootTelemetryLine(
                    text: line,
                    index: index,
                    isRevealed: sequence.revealedLines.contains(index),
                    revealDate: lineRevealDates[index] ?? sequence.phaseStart,
                    isGlitching: sequence.glitchIndex == index,
                    size: compactHeight ? 8.6 : 10.2,
                    tracking: compactHeight ? 0.5 : 0.82
                )
            }
        }
    }

    private var buildNumber: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0001"
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
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            isSocialPresented = true
        }
    }
}

/// The signature line above the wordmark.
///
/// Set in SF rather than the monospace used everywhere else on this screen, so
/// it reads as a person's hand inside a machine readout. It is lifted off the
/// surrounding rows by a violet bloom instead of by size alone — at a size big
/// enough to separate on its own it would start competing with the wordmark
/// directly beneath it.
private struct GVSplashAttribution: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let text: String
    let size: CGFloat
    let revealDate: Date

    var body: some View {
        let storm = GVStormCloud()
            .frame(height: size * 7.2)
            .scaleEffect(x: 1.5, y: 1.0)
            .offset(y: -size * 0.85)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)

        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 20, paused: reduceMotion)) { timeline in
            let elapsed = max(timeline.date.timeIntervalSince(revealDate), 0)
            // Breathes only after it has settled, so the reveal is clean and
            // the glow is what keeps it alive afterwards.
            let settle = min(elapsed / 0.7, 1)
            let pulse = reduceMotion ? 0.5 : (sin(elapsed * 1.5) + 1) / 2
            let bloom = 0.32 + pulse * 0.26

            Text(text)
                .font(.system(size: size, weight: .semibold, design: .default))
                .tracking(size * 0.22)
                .foregroundStyle(
                    LinearGradient(
                        colors: [GVTheme.bone, GVTheme.bone.opacity(0.86)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .background {
                    storm.opacity(0.68 * settle)
                }
                .shadow(color: GVTheme.violet.opacity(bloom * settle), radius: 7)
                .shadow(color: GVTheme.violetDeep.opacity(bloom * 0.7 * settle), radius: 15)
                .shadow(color: .black.opacity(0.75), radius: 2, y: 1)
                .opacity(settle)
                .blur(radius: (1 - settle) * 3)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityLabel(text)
    }
}

private struct SplashCaptureDock: View {
    @Binding var setup: CaptureSetupDraft
    let isReady: Bool
    let isCollapsing: Bool
    let bottomInset: CGFloat
    let onLaunch: () -> Void

    @State private var activeSection: SplashDockSection?
    /// Leading visible card of the FORMAT rail. Survives open/close cycles,
    /// so reopening drops you where you left off — at 60FPS, not at H.264.
    @State private var formatScrollID: String?

    /// The basics only. The enum still spells every codec it ever did for
    /// draft decoding, but the chooser offers five.
    private let codecChoices: [CaptureSetupDraft.VideoCodec] = CaptureSetupDraft.VideoCodec.curated

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                dockButton(
                    .format,
                    value: "\(setup.videoCodec.compactLabel) \u{00B7} \(setup.frameRate.rawValue) \u{00B7} \(setup.resolution.rawValue)"
                )
                launchButton
            }
            .fixedSize(horizontal: true, vertical: true)

            GVTerminalText(
                text: isReady ? "FORMAT ARMED // LAUNCH" : "LOCAL PROBE IN PROGRESS",
                size: 6.8,
                weight: .bold,
                tracking: 1.0,
                baseColor: isReady ? GVTheme.bone.opacity(0.72) : GVTheme.bone.opacity(0.42),
                intensity: 0.42
            )
            .padding(.bottom, max(bottomInset, 5))
        }
        // The dock is white type on a transparent plate over a violet field,
        // which at the bottom of the splash is close to white on white. The
        // halo sinks it into a dark pocket without giving any of the four
        // controls a border back.
        .gvBlackHalo(radius: 34, opacity: 0.72)
        .frame(maxWidth: 560)
        .overlay(alignment: .top) {
            if let activeSection {
                choiceRail(for: activeSection)
                    .offset(y: -76)
                    // Same reason as the dock below it: the option cards are
                    // unplated type over the splash field.
                    .gvBlackHalo(radius: 30, opacity: 0.7)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .zIndex(2)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: activeSection)
    }

    private func choiceRail(for section: SplashDockSection) -> some View {
        // 21 matches the workspace effect rail exactly; 27 was close enough to
        // look like a mistake rather than a different component.
        //
        // Opaque, unlike the workspace rails. Those sit over a live camera the
        // operator needs to keep seeing; this one sits over the splash, where
        // the violet field behind it was reading straight through the option
        // cards. A chooser is a modal surface — it should stop the background,
        // not sample it.
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    groupHeader("CODEC")
                    ForEach(codecChoices) { codec in
                        optionCard(
                            label: codec.rawValue,
                            detail: codec.availabilityNote,
                            selected: setup.videoCodec == codec,
                            enabled: codec.isOperatingSystemAvailable
                        ) {
                            setup.videoCodec = codec
                        }
                        .id("codec-\(codec.rawValue)")
                    }

                    segmentDivider

                    groupHeader("FPS")
                    ForEach(CaptureSetupDraft.FrameRate.allCases) { frameRate in
                        optionCard(
                            label: frameRate.label,
                            detail: frameRate.availabilityNote,
                            selected: setup.frameRate == frameRate,
                            enabled: true
                        ) {
                            setup.frameRate = frameRate
                        }
                        .id("fps-\(frameRate.rawValue)")
                    }

                    segmentDivider

                    groupHeader("RES")
                    ForEach(CaptureSetupDraft.Resolution.allCases) { resolution in
                        optionCard(
                            label: resolution.rawValue,
                            detail: resolution.availabilityNote,
                            selected: setup.resolution == resolution,
                            enabled: resolution.isSelectable
                        ) {
                            setup.resolution = resolution
                        }
                        .id("res-\(resolution.rawValue)")
                    }
                }
                .padding(.vertical, 7)
                .scrollTargetLayout()
            }
            // Two-way binding: reading gives the leading visible card while
            // the operator scrolls; writing on re-open restores that spot.
            .scrollPosition(id: $formatScrollID)
            .contentMargins(.horizontal, 10, for: .scrollContent)
            // Was `scrollClipDisabled`, which let cards draw straight through
            // the panel's own border as they scrolled — the hard vertical cut
            // in the middle of a plate. Cards now clip to the rail and the
            // edge fade makes a partly visible card read as "more this way"
            // rather than as a rendering fault. Same treatment as the
            // workspace effect rail.
            .gvHorizontalEdgeFade()
            // Clipped to the rail's own shape, so a card scrolling out ends
            // at the rail's rounded edge instead of being cut by the display.
            // The fade sits inside the clip, so the last visible card reads
            // as "more this way" rather than as a severed plate.
            .clipShape(RoundedRectangle(cornerRadius: GVMetrics.radiusPanel, style: .continuous))
            .accessibilityIdentifier("boot.choices.\(section.rawValue)")
        }
        .background(
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [SplashPalette.charcoal, SplashPalette.deep],
                    startPoint: .top,
                    endPoint: .bottom
                )
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 1 / UIScreen.main.scale)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 14, y: 8)
        // Matches the dock beneath it. At 680 the rail was wider than both its
        // parent and the display, so its right-hand end — and any card under
        // it — was cut off by the screen edge rather than by the rail. That is
        // the hard vertical slice through the fourth plate.
        .frame(maxWidth: .infinity)
    }

    private var segmentDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.10))
            .frame(width: 1, height: GVMetrics.cardHeight)
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .gvMono(GVMetrics.textMicro, .bold)
            .tracking(1.4)
            .foregroundStyle(GVTheme.ash.opacity(0.85))
            .frame(width: 34)
    }

    private func dockButton(_ section: SplashDockSection, value: String) -> some View {
        let isActive = activeSection == section
        return Button {
            activeSection = isActive ? nil : section
        } label: {
            VStack(spacing: 3) {
                // `ash` is calibrated against the workspace's near-black.
                // The splash lays these over a lit violet field, where the
                // same grey drops to roughly a third of its contrast — hence
                // bone held back rather than ash. The value below stays at
                // full bone, so the size and weight still carry the hierarchy.
                GVTerminalText(
                    text: section.label,
                    size: 6,
                    weight: .bold,
                    tracking: 1.1,
                    baseColor: isActive ? GVTheme.violet : GVTheme.bone.opacity(0.76),
                    intensity: 0.55
                )
                GVTerminalText(
                    text: value,
                    size: 9,
                    weight: .black,
                    tracking: 0.75,
                    baseColor: GVTheme.bone,
                    intensity: 0.8
                )
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            }
            // Column of type over a rule, not a plate. Selection lights the
            // rule and the label; nothing is enclosed. Three chamfered plates
            // in a row repeated the workspace dock's gesture on a screen with
            // no camera behind it to justify the weight.
            .frame(width: isActive ? 158 : 96, height: 40)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isActive ? Color.white : Color.white.opacity(0.14))
                    .frame(height: isActive ? 1.6 : 1)
                    .shadow(color: isActive ? Color.white.opacity(0.8) : .clear, radius: 5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(section.label), \(value)")
        .accessibilityIdentifier("boot.\(section.rawValue)")
    }

    private var launchButton: some View {
        Button(action: onLaunch) {
            VStack(spacing: 3) {
                GVTerminalText(
                    text: "ARM",
                    size: 6,
                    weight: .bold,
                    tracking: 1.1,
                    baseColor: isReady ? .white : GVTheme.bone.opacity(0.5),
                    intensity: 0.85
                )
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(isReady ? Color.white : GVTheme.faint)
                    .shadow(color: isReady ? Color.white.opacity(0.65) : .clear, radius: 4)
            }
            // The one committing control on the screen, so it is the only one
            // that emits. Still no plate: it reads as a lit marking rather
            // than as a button laid on top of the splash.
            .frame(width: 62, height: 40)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isReady ? Color.white : Color.white.opacity(0.14))
                    .frame(height: isReady ? 2 : 1)
                    .shadow(color: isReady ? Color.white.opacity(0.9) : .clear, radius: 7)
            }
            .contentShape(Rectangle())
            .shadow(color: isReady ? Color.white.opacity(0.35) : .clear, radius: 9)
        }
        .buttonStyle(GVPressStyle())
        .disabled(!isReady)
        .accessibilityLabel("Launch workspace")
        .accessibilityIdentifier("boot.launch")
    }

    private func optionCard(
        label: String,
        detail: String,
        selected: Bool,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(230))
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    activeSection = nil
                }
            }
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    if !enabled {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(GVTheme.ash)
                    }
                    GVTerminalText(
                        text: label,
                        size: 9,
                        weight: .black,
                        tracking: 1.0,
                        baseColor: selected ? GVTheme.violet : GVTheme.bone,
                        intensity: 0.78
                    )
                    .lineLimit(1)
                }
                GVTerminalText(
                    text: detail,
                    size: 6.2,
                    weight: .bold,
                    tracking: 0.65,
                    baseColor: selected ? GVTheme.violet.opacity(0.8) : GVTheme.bone.opacity(0.74),
                    intensity: 0.48
                )
                .lineLimit(1)
            }
            .frame(width: 94, height: 46)
            // Same plate language as the workspace effect rail: chamfered
            // charcoal, hairline structure, and one glowing white accent that
            // only the committed option earns.
            .background(
                GVChamferedPlate(cut: 8)
                    .fill(
                        selected ? Color.white.opacity(0.13) : Color(white: 0.10).opacity(0.94)
                    )
                    .overlay(
                        GVChamferedPlate(cut: 8)
                            .stroke(
                                selected ? Color.white.opacity(0.85) : Color.white.opacity(0.08),
                                lineWidth: selected ? 1.2 : 1.0
                            )
                    )
            )
            .overlay {
                if selected {
                    GVScanlines(opacity: 0.16)
                        .padding(2)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .shadow(color: .black.opacity(0.5), radius: 5, y: 3)
            .shadow(color: selected ? Color.white.opacity(0.42) : .clear, radius: 7)
            .shadow(color: selected ? Color.white.opacity(0.18) : .clear, radius: 16)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.42)
        .accessibilityHint(enabled ? detail : "Unavailable. \(detail)")
        .accessibilityIdentifier(
            "boot.\(activeSection?.rawValue ?? "option").\(optionSlug(label))"
        )
    }

    private func optionSlug(_ label: String) -> String {
        label
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }
}

/// The splash chooser's material — same charcoal family as the workspace
/// dock and parameter decks, so boot and camera read as one instrument.
private enum SplashPalette {
    static let charcoal = Color(red: 0.135, green: 0.135, blue: 0.143)
    static let deep = Color(red: 0.078, green: 0.078, blue: 0.085)
}

/// One consolidated selector. Codec, cadence and sensor format used to be
/// three separate popovers; they are one FORMAT surface now, summarised as a
/// single line in the dock button.
private enum SplashDockSection: String, CaseIterable, Identifiable {
    case format

    var id: String {
        rawValue
    }

    var label: String {
        "FORMAT"
    }
}

#Preview {
    BootView()
        .environmentObject(AppModel(arguments: ["--uitesting"]))
}

// swiftlint:enable file_length
