import SwiftUI

/// The launch screen: the shared Splash.mp4 shown as an x-ray, with tracked
/// "object" boxes that reveal the true colour beneath, the mark at the top and
/// one bracketed button to open the camera. Ported from the splash the
/// operator's other apps open with (venicesarin's x-ray stage, NorahX's
/// bracket button), adapted for touch: a finger drives the cursor box, and
/// when nothing touches the glass a ghost cursor wanders the frame.
struct GVLaunchSplash: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appModel: AppModel
    @State private var pointer = GVSplashPointer()
    @State private var isSocialPresented = false
    @State private var isOpening = false
    /// The +CAMERA button's frame, shared with the stage (which reveals the
    /// true-colour film inside it) and the bottom shade (which leaves it out).
    @State private var lensFrame: CGRect = .zero

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                GVSplashStage(
                    pointer: pointer,
                    playing: !reduceMotion && scenePhase == .active,
                    reduceMotion: reduceMotion
                )
                .accessibilityHidden(true)

                LinearGradient(stops: [
                    .init(color: .black.opacity(0.50), location: 0),
                    .init(color: .clear, location: 0.24),
                    .init(color: .clear, location: 0.70),
                    .init(color: .black.opacity(0.58), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                // The shade would dull the lens; punch the button out of it.
                .mask {
                    ZStack {
                        Rectangle()
                        Rectangle()
                            .frame(width: lensFrame.width, height: lensFrame.height)
                            .position(x: lensFrame.midX, y: lensFrame.midY)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
                .allowsHitTesting(false)

                VStack(spacing: 0) {
                    Button { isSocialPresented = true } label: {
                        GVNeonLoopTitle(still: reduceMotion)
                            .frame(width: proxy.size.width, height: proxy.size.height * 0.36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(GVPressStyle())
                    .accessibilityLabel("grey vision")
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("boot.social")
                    .padding(.top, max(proxy.safeAreaInsets.top, 20) - 10)

                    Spacer()

                    GVSplashFormatRow()
                        .padding(.bottom, 26)

                    GVBracketButton(title: "+CAMERA", tag: "CAM 00  LIVE", action: openCamera)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                            lensFrame = frame
                            pointer.lensRect = frame
                        }
                        .disabled(isOpening)
                        .accessibilityLabel("Open camera")
                        .accessibilityIdentifier("boot.launch")
                        .padding(.bottom, max(proxy.safeAreaInsets.bottom, 16) + 16)
                }
                .frame(maxWidth: .infinity)

                if isSocialPresented {
                    SocialLinksOverlay(isPresented: $isSocialPresented)
                        .transition(.opacity)
                }
            }
            .ignoresSafeArea()
        }
        .background(Color.black)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("boot.screen")
        .task {
            // Permissions still serve capture; asked on the splash so the
            // system prompt never lands over the viewfinder.
            guard !appModel.isUITesting else { return }
            _ = await GVLaunchPermissions.requestAll()
        }
        // The glitch bed loops for as long as the splash is on screen, pauses
        // with the app and fades out the moment the camera opens.
        .onAppear { startSplashSound() }
        .onDisappear { GVSoundEngine.shared.stopMenuMusic(fadeDuration: 0.35) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { isOpening = false }
            if phase == .active {
                startSplashSound()
            } else {
                GVSoundEngine.shared.stopMenuMusic(fadeDuration: 0.2)
            }
        }
    }

    private func startSplashSound() {
        guard !appModel.isUITesting, scenePhase == .active else { return }
        GVSoundEngine.shared.startMenuMusic()
    }

    private func openCamera() {
        guard !isOpening else { return }
        isOpening = true
        GVSoundEngine.shared.stopMenuMusic(fadeDuration: 0.35)
        GVInteractionHaptics.select()
        appModel.startEngine()
    }
}

// MARK: - Bracket button

/// A label framed by four lime tracker brackets, with a tracker tag hanging
/// off its corner — the splash's own "tracked object", made pressable.
///
/// The inside is a lens: the stage keeps the button's rect revealed, so while
/// the whole splash plays as an x-ray, the button shows the film in true
/// colour, inverted against everything around it, with a scan line sweeping
/// through. The label is set dark to read on that light image. Pressing snaps
/// the brackets in tight; Reduce Motion keeps them still.
struct GVBracketButton: View {
    let title: String
    var tag: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .tracking(2.4)
                .padding(.horizontal, 28)
                .frame(minWidth: 172, minHeight: 58)
                .contentShape(Rectangle())
        }
        .buttonStyle(GVBracketStyle(tag: tag))
    }
}

private struct GVBracketStyle: ButtonStyle {
    let tag: String?

    func makeBody(configuration: Configuration) -> some View {
        GVBracketFace(label: configuration.label, tag: tag, pressed: configuration.isPressed)
    }
}

private struct GVBracketFace<Label: View>: View {
    let label: Label
    let tag: String?
    let pressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let still = reduceMotion
        let inset: CGFloat = still ? 0 : (pressed ? 7 : 0)
        let arm: CGFloat = still ? 12 : (pressed ? 9 : 12)
        label
            .foregroundStyle(Color.black.opacity(pressed ? 1 : 0.88))
            // A pale halo keeps the dark label legible on the film's darker
            // shots.
            .shadow(color: .white.opacity(0.7), radius: 1.5)
            .scaleEffect(pressed && !still ? 0.96 : 1)
            .overlay {
                GVTrackerBrackets(inset: inset, arm: arm)
                    .stroke(GVSplashDock.lime.opacity(pressed ? 1 : 0.95),
                            style: StrokeStyle(lineWidth: pressed ? 2 : 1.5, lineCap: .square))
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                if let tag {
                    GVTrackerTag(text: tag)
                        .offset(y: -13)
                        .allowsHitTesting(false)
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : GVMotion.softPress(pressed), value: pressed)
    }
}


// MARK: - Format row

/// Resolution, frame rate and codec, picked before the camera opens. Three
/// small tracker plates in the splash's own language; a tap steps each to its
/// next value. They write the capture draft, which the session reads when it
/// starts, so the camera opens already in the chosen format.
private struct GVSplashFormatRow: View {
    @EnvironmentObject private var appModel: AppModel

    private static let resolutions: [CaptureSetupDraft.Resolution] = [.ultraHD, .fullHD, .hd720]

    private var codecs: [CaptureSetupDraft.VideoCodec] {
        CaptureSetupDraft.VideoCodec.curated.filter(\.isOperatingSystemAvailable)
    }

    var body: some View {
        HStack(spacing: 12) {
            chip(label: "RES", value: appModel.setup.resolution.rawValue) {
                appModel.setup.resolution = Self.next(after: appModel.setup.resolution, in: Self.resolutions)
            }
            .accessibilityIdentifier("boot.format.resolution")

            chip(label: "FPS", value: "\(appModel.setup.frameRate.rawValue)") {
                appModel.setup.frameRate = Self.next(after: appModel.setup.frameRate,
                                                     in: CaptureSetupDraft.FrameRate.allCases)
            }
            .accessibilityIdentifier("boot.format.framerate")

            chip(label: "CODEC", value: appModel.setup.videoCodec.compactLabel) {
                guard !codecs.isEmpty else { return }
                appModel.setup.videoCodec = Self.next(after: appModel.setup.videoCodec, in: codecs)
            }
            .accessibilityIdentifier("boot.format.codec")
        }
    }

    private func chip(label: String, value: String, action: @escaping () -> Void) -> some View {
        Button {
            GVInteractionHaptics.select()
            action()
        } label: {
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(GVTheme.bone.opacity(0.55))
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(GVTheme.bone)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
            }
            .frame(width: 84, height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        // See-through: only the tracker brackets and a faint hairline, with a
        // soft shadow on the type so it reads over any shot of the film.
        .shadow(color: .black.opacity(0.75), radius: 3)
        .overlay {
            RoundedRectangle(cornerRadius: GVSplashDock.radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.6)
                .allowsHitTesting(false)
        }
        .overlay {
            GVTrackerBrackets(arm: 9)
                .stroke(GVSplashDock.lime.opacity(0.9), style: StrokeStyle(lineWidth: 1, lineCap: .square))
                .padding(-1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .animation(.easeOut(duration: 0.15), value: value)
        .accessibilityLabel(label == "RES" ? "Resolution" : (label == "FPS" ? "Frame rate" : "Codec"))
        .accessibilityValue(value)
    }

    private static func next<T: Equatable>(after current: T, in order: [T]) -> T {
        guard let index = order.firstIndex(of: current) else { return order.first ?? current }
        return order[(index + 1) % order.count]
    }
}
