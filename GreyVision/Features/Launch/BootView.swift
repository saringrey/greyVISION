import SwiftUI

/// A tilt-responsive nebula frames the title and compact capture-format controls.
struct BootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.gvBootCeremonyActive) private var bootCeremonyActive
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var motion = GVBootMotion()
    @State private var isSocialPresented = false
    @State private var isOpening = false
    @State private var launchTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            let titleWidth = min(landscape ? geometry.size.width * 0.48 : geometry.size.width - 48, 560)
            let identity = GVLaunchIdentity(
                width: titleWidth,
                animated: appModel.preferences.startupAnimationEnabled,
                onSocial: { isSocialPresented = true }
            )
            let controls = GVLaunchControls(setup: $appModel.setup, isOpening: isOpening, onOpen: openCamera)
            ZStack {
                GVSplashBackdrop(
                    animated: appModel.preferences.startupAnimationEnabled,
                    tilt: motion.smoothedTilt
                )
                .ignoresSafeArea()

                if landscape {
                    HStack(spacing: 28) {
                        identity.frame(maxWidth: .infinity)
                        controls.frame(maxWidth: 400)
                    }
                    .padding(24)
                } else {
                    VStack(spacing: 24) {
                        Spacer(minLength: 24)
                        identity
                        Spacer(minLength: 24)
                        controls.frame(maxWidth: 440)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }

                if isSocialPresented {
                    SocialLinksOverlay(isPresented: $isSocialPresented)
                        .transition(.opacity)
                }
            }
        }
        .background(GVTheme.void)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("boot.screen")
        .task(id: bootCeremonyActive) {
            // Permissions still serve capture; the splash never starts an audio analyzer.
            // Held until the cold-start terminal finishes, so the system
            // prompt lands on the splash instead of over the boot log.
            guard !appModel.isUITesting, !bootCeremonyActive else { return }
            _ = await GVLaunchPermissions.requestAll()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                if !reduceMotion && appModel.preferences.startupAnimationEnabled { motion.start() }
            } else {
                motion.stop()
                launchTask?.cancel()
                isOpening = false
            }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { motion.stop() }
            else if scenePhase == .active && appModel.preferences.startupAnimationEnabled { motion.start() }
        }
        .onDisappear {
            launchTask?.cancel()
            motion.stop()
        }
    }

    private func openCamera() {
        guard !isOpening else { return }
        isOpening = true
        GVInteractionHaptics.select()
        if reduceMotion || !appModel.preferences.startupAnimationEnabled || appModel.isUITesting {
            appModel.startEngine()
        } else {
            launchTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled else { return }
                appModel.startEngine()
            }
        }
    }
}

private struct GVLaunchControls: View {
    @Binding var setup: CaptureSetupDraft
    let isOpening: Bool
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            SplashCaptureDock(setup: $setup, isOpening: isOpening, onOpen: onOpen)

            Text("MADE WITH LOVE BY GREY")
                .font(GVTheme.mono(11, .medium))
                .tracking(1.2)
                .foregroundStyle(GVTheme.bone.opacity(0.7))
                .padding(.top, 4)
                .accessibilityIdentifier("boot.attribution")
        }
    }
}

private struct GVLaunchIdentity: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var cycleStart = Date()

    let width: CGFloat
    let animated: Bool
    let onSocial: () -> Void

    var body: some View {
        let glyphSize = min(max(width, 1) / (96 * 0.62), 9)
        let running = animated && !reduceMotion && scenePhase == .active
        Button(action: onSocial) {
            TimelineView(GVAmbientClock.ambient(hertz: 30, scenePhase: scenePhase, isActive: running)) { clock in
                let decryption = running
                    ? GVLetterDecryption.frame(elapsed: clock.date.timeIntervalSince(cycleStart), letterCount: 10)
                    : nil
                VStack(spacing: 10) {
                    GVASCIIWordmark(
                        text: "grey", glyphSize: glyphSize * 0.52, columns: 48,
                        enableWaves: false, animated: false, interactive: false,
                        accent: GVSplashPalette.glow,
                        decryption: decryption?.forWord(start: 0, length: 4)
                    )
                    GVASCIIWordmark(
                        text: "VISION", glyphSize: glyphSize, columns: 96,
                        enableWaves: false, animated: false, interactive: false,
                        accent: GVSplashPalette.glow,
                        decryption: decryption?.forWord(start: 4, length: 6)
                    )
                }
                .frame(width: width, alignment: .center)
                .padding(.vertical, 12)
                // A pool of black under the title, so the white wordmark
                // glows against dark instead of sinking into the bright cloud.
                .background {
                    // Larger than the title so the ellipse fades to nothing
                    // before any edge; clipped, it drew a hard line.
                    EllipticalGradient(colors: [.black.opacity(0.82), .black.opacity(0.42), .clear],
                                       center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
                        .frame(width: width * 1.35, height: width * 1.0)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(GVPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("grey VISION")
        .accessibilityHint("Opens creator links.")
        .accessibilityIdentifier("boot.social")
    }
}


private struct SplashCaptureDock: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var setup: CaptureSetupDraft
    let isOpening: Bool
    let onOpen: () -> Void

    @State private var activeSection: SplashDockSection?
    /// Leading visible card of the open format rail. Every submenu opens from
    /// its first option so the beginning of the list is never clipped.
    @State private var optionScrollID: String?
    @State private var selectionTask: Task<Void, Never>?

    /// The basics only. The enum still spells every codec it ever did for
    /// draft decoding, but the chooser offers five.
    private let codecChoices: [CaptureSetupDraft.VideoCodec] = CaptureSetupDraft.VideoCodec.curated

    /// Height of the dock's button row, and the gap the open rail leaves above
    /// it. The rail hangs off these: its readout makes it taller than the old
    /// strip, and an overlay pinned to the row's top edge would have grown
    /// downwards over the controls it belongs to. Anchored to the bottom it
    /// grows the only direction there is room for.
    @State private var rowHeight: CGFloat = 44
    private let minimumRowHeight: CGFloat = 44
    private let railGap: CGFloat = GVMetrics.gap

    var body: some View {
        VStack(spacing: GVMetrics.gap) {
            HStack(spacing: GVMetrics.gap) {
                dockButton(.codec, value: setup.videoCodec.compactLabel)
                dockButton(.frameRate, value: "\(setup.frameRate.rawValue)")
                dockButton(.resolution, value: setup.resolution.rawValue)
                openButton
            }
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 400)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if abs(rowHeight - height) > 0.5 { rowHeight = height }
            }
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

        }
        .frame(maxWidth: 560)
        .zIndex(2)
        .animation(GVMotion.resolved(GVMotion.normal, reduceMotion: reduceMotion), value: activeSection)
        .accessibilityAction(.escape) { activeSection = nil }
        .onDisappear { selectionTask?.cancel() }
    }

    /// Every option in a section, built once.
    ///
    /// The cards, the scroll anchor and the accessibility identifiers all read
    /// off this list, so the rail cannot describe a format the chooser does not
    /// offer — which is what three hand-kept card groups kept doing at the edges.
    ///
    /// Identifiers keep deriving from `rawValue` rather than the displayed
    /// label, because the UI tests address the cards by those strings.
    private func options(for section: SplashDockSection) -> [GVSplashOption] {
        switch section {
        case .codec:
            codecChoices.map { codec in
                GVSplashOption(
                    id: "codec-\(codec.rawValue)",
                    identifier: "boot.codec.\(optionSlug(codec.rawValue))",
                    label: codec.compactLabel,
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
                    enabled: true,
                    apply: { setup.resolution = resolution }
                )
            }
        }
    }

    /// Scroll anchor of the option currently in force, so the rail always
    /// opens on the format that is actually selected.
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
                // Animated, so the checkmark and border crossfade onto the card
                // the operator just chose instead of snapping while the rail is
                // still open.
                withAnimation(GVMotion.resolved(GVMotion.normal, reduceMotion: reduceMotion)) { option.apply() }
                // The rail stays open just long enough for the choice to be
                // seen landing on the card before it collapses.
                selectionTask?.cancel()
                selectionTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(230))
                    guard !Task.isCancelled else { return }
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
            selectionTask?.cancel()
            if isActive {
                activeSection = nil
            } else {
                optionScrollID = firstOptionID(for: section)
                activeSection = section
            }
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 5) {
                    Text(section.label)
                        .tracking(0.8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isActive ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(GVTheme.bone.opacity(isActive ? 1 : 0.75))
                Text(value)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(GVTheme.bone)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minHeight: minimumRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(GVSplashButtonStyle(active: isActive))
        .animation(GVMotion.resolved(GVMotion.normal, reduceMotion: reduceMotion), value: value)
        .accessibilityLabel("\(section.label), \(value)")
        .accessibilityValue(isActive ? "Expanded" : "Collapsed")
        .accessibilityHint(isActive ? "Closes the format chooser." : "Opens the format chooser.")
        .accessibilityIdentifier("boot.\(section.rawValue)")
    }

    /// Open Camera sits in the format row as its fourth plate, built like
    /// the other three — a caption over a value — but solid white with black
    /// type, so the one action on the screen is unmistakable.
    private var openButton: some View {
        Button {
            activeSection = nil
            onOpen()
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 5) {
                    Text(isOpening ? "OPENING" : "OPEN")
                        .tracking(0.8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Image(systemName: isOpening ? "lock.open" : "arrow.up.right")
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)
                }
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                Text("CAMERA")
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minHeight: minimumRowHeight)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .white.opacity(isOpening ? 0.7 : 0.4), radius: isOpening ? 14 : 9)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        .disabled(isOpening)
        .accessibilityLabel("Open camera")
        .accessibilityIdentifier("boot.launch")
        .accessibilityHint("Starts the camera using the selected capture format.")
    }

    /// First option of a section, because opening one always starts at its
    /// beginning. Read off the same list the rail draws, so a reordered
    /// chooser cannot leave the scroll pinned to an anchor that no longer
    /// exists.
    private func firstOptionID(for section: SplashDockSection) -> String {
        options(for: section).first?.id ?? ""
    }


    private func optionSlug(_ label: String) -> String {
        label
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }
}

/// Nebula-tinted plates shared by the format dock and its options.
struct GVSplashButtonStyle: ButtonStyle {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .background { GVSplashPlate(active: active || pressed) }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .modifier(GVSplashBorder(active: active || pressed))
            .brightness(pressed ? 0.08 : 0)
            .scaleEffect(reduceMotion ? 1 : (pressed ? 0.97 : 1))
            .animation(GVMotion.resolved(GVMotion.press, reduceMotion: reduceMotion), value: pressed)
            .animation(GVMotion.resolved(GVMotion.normal, reduceMotion: reduceMotion), value: active)
    }
}

#Preview {
    BootView()
        .environmentObject(AppModel(arguments: ["--uitesting"]))
}

// swiftlint:enable file_length
