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

                    GVBracketButton(title: "+CAMERA", action: openCamera)
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

/// A label framed by four corner brackets and nothing else. Pressing snaps the
/// brackets in tight around the label; Reduce Motion keeps them still and only
/// changes brightness.
struct GVBracketButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .tracking(2.4)
                .padding(.horizontal, 28)
                .frame(minWidth: 172, minHeight: 58)
                .contentShape(Rectangle())
        }
        .buttonStyle(GVBracketStyle())
    }
}

private struct GVBracketStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GVBracketFace(label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct GVBracketFace<Label: View>: View {
    let label: Label
    let pressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let still = reduceMotion
        let inset: CGFloat = still ? 0 : (pressed ? 7 : 0)
        let arm: CGFloat = still ? 12 : (pressed ? 9 : 12)
        label
            .foregroundStyle(.white.opacity(pressed ? 1 : 0.88))
            .scaleEffect(pressed && !still ? 0.96 : 1)
            .overlay {
                GVCornerBrackets(inset: inset, arm: arm)
                    .stroke(.white.opacity(pressed ? 1 : 0.8),
                            style: StrokeStyle(lineWidth: pressed ? 2 : 1.5, lineCap: .square))
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.spring(response: 0.16, dampingFraction: 0.7), value: pressed)
    }
}

/// Four L-shaped corners. `inset` moves them toward the centre.
private struct GVCornerBrackets: Shape {
    var inset: CGFloat
    var arm: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(inset, arm) }
        set { inset = newValue.first; arm = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: inset)
        let length = min(arm, box.width / 2, box.height / 2)
        var path = Path()
        for (corner, dx, dy) in [(CGPoint(x: box.minX, y: box.minY), 1.0, 1.0), (CGPoint(x: box.maxX, y: box.minY), -1.0, 1.0),
                                 (CGPoint(x: box.minX, y: box.maxY), 1.0, -1.0), (CGPoint(x: box.maxX, y: box.maxY), -1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * length))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * length, y: corner.y))
        }
        return path
    }
}
