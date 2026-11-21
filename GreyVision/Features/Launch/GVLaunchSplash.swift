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
                    .buttonStyle(.plain)
                    .accessibilityLabel("grey vision")
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("boot.social")
                    .padding(.top, max(proxy.safeAreaInsets.top, 20) - 10)

                    Spacer()

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
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { isOpening = false }
        }
    }

    private func openCamera() {
        guard !isOpening else { return }
        isOpening = true
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
            .animation(.spring(response: 0.16, dampingFraction: 0.7), value: pressed)
    }
}
