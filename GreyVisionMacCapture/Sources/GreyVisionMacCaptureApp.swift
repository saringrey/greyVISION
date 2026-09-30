import AppKit
import CoreImage
import CoreMedia
import CryptoKit
import Foundation
import Network
import SwiftUI
import VideoToolbox

@main
struct GreyVisionMacCaptureApp: App {
    @StateObject private var session = CaptureSession()

    var body: some Scene {
        Window("GreyVision Capture", id: "main") {
            RootView(session: session)
                .frame(minWidth: 1280, minHeight: 820)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

struct RootView: View {
    @ObservedObject var session: CaptureSession
    @State private var didRequestFullscreen = false

    var body: some View {
        CaptureView(session: session, receiver: session.receiver, continuity: session.continuity)
            .frame(minWidth: 1120, idealWidth: 1360)
            .preferredColorScheme(.dark)
            .background(WindowFullscreenConfigurator(didRequestFullscreen: $didRequestFullscreen))
    }
}

/// Enters macOS fullscreen once after the SwiftUI Window has materialized.
/// Escape and Control-Command-F retain the standard macOS exit paths.
private struct WindowFullscreenConfigurator: NSViewRepresentable {
    @Binding var didRequestFullscreen: Bool

    func makeNSView(context _: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        guard !didRequestFullscreen else { return }
        DispatchQueue.main.async {
            guard !didRequestFullscreen,
                  let window = nsView.window ?? NSApp.keyWindow else { return }
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.collectionBehavior.formUnion([.fullScreenPrimary, .ignoresCycle])
            if let screen = window.screen ?? NSScreen.main {
                window.setFrame(screen.frame, display: true, animate: false)
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            NSApp.presentationOptions = [.fullScreen, .autoHideMenuBar, .autoHideDock]
            didRequestFullscreen = true
            // Allow SwiftUI/AppKit to finish materializing the borderless window
            // before starting the animated fullscreen transition.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard !window.styleMask.contains(.fullScreen) else { return }
                window.toggleFullScreen(nil)
            }
        }
    }
}

/// Glue between the network source and the SwiftUI model objects.
///
/// The source (`GVPhoneLink`) and the remote control
/// (`GVRemoteControl`) are otherwise independent — one is a non-MainActor
/// transport, the other is `@MainActor` UI state. This type owns both, owns
/// the connection callbacks, and exposes the two halves the views bind to.
@MainActor
final class CaptureSession: ObservableObject {
    /// The two ways this Mac can see the iPhone.
    ///
    /// Not variations of one thing. LINK carries GreyVision's processed output
    /// over the app's own connection and can be driven from the FX panel.
    /// CONTINUITY is the system service: the raw iPhone camera as an
    /// `AVCaptureDevice`, no pairing, no effects — macOS produces those pixels,
    /// not GreyVision.
    enum Source: String, CaseIterable, Identifiable {
        case link
        case continuity

        var id: String { rawValue }

        var label: String {
            switch self {
            case .link: "LINK // PROCESSED"
            case .continuity: "CONTINUITY // RAW"
            }
        }
    }

    /// Always boot into the processed GreyVision LINK. Continuity is an explicit
    /// user choice from the source picker and is never selected automatically.
    @Published var source: Source = .link {
        didSet {
            guard oldValue != source else { return }
            // Only one source drives the preview at a time. Leaving the other
            // running would keep a camera light on, or keep decoding a stream
            // nobody is looking at.
            switch source {
            case .link:
                continuity.stop()
                receiver.start()
            case .continuity:
                receiver.stop()
            }
        }
    }

    let receiver: CaptureReceiver
    let remote: GVRemoteControl
    let continuity = GVContinuityCamera()

    private let link = GVPhoneLink()

    init() {
        let receiver = CaptureReceiver()
        let remote = GVRemoteControl()
        self.receiver = receiver
        self.remote = remote

        link.onImage = { [weak receiver] image in
            Task { @MainActor in receiver?.frame = image }
        }
        link.onStatus = { [weak receiver] text, isError in
            Task { @MainActor in
                receiver?.status = text
                receiver?.isError = isError
            }
        }
        link.onPixelBuffer = { [weak receiver] pixelBuffer, timestamp in
            receiver?.appendLocalFrame(pixelBuffer, timestamp: timestamp)
        }
        link.onHealth = { [weak receiver] health in
            Task { @MainActor in receiver?.health = health }
        }
        link.onHello = { [weak receiver] hello in
            Task { @MainActor in
                receiver?.requestedProfile = "REQUESTED \(hello.width)×\(hello.height) // \(hello.frameRate) FPS // \(hello.requestedCodec.uppercased())"
            }
        }
        link.onVideoFormat = { [weak receiver] format in
            Task { @MainActor in
                receiver?.streamDescription = "ACTUAL \(format.width)×\(format.height) // \(format.codec.uppercased())"
                receiver?.hasReceivedVideoFormat = true
            }
        }
        link.onLinkState = { [weak receiver] state in
            Task { @MainActor in receiver?.applyLinkState(state) }
        }
        remote.attach(to: link)
        receiver.link = link
        // LINK is the default mode: begin browsing as soon as the app opens.
        receiver.start()
    }
}

// MARK: - Receiver (display only — transport lives in GVPhoneLink)

/// UI-side state for the live preview. Holds the last decoded frame and the
/// connection status, but the network side is owned by
/// `GVPhoneLink`. The source publishes to it through closures.
final class CaptureReceiver: ObservableObject {
    @Published var linkPeer = ""
    @Published var frame: NSImage?
    @Published var status = "Arm Mac Cam on the iPhone; this Mac pairs automatically."
    @Published var isRunning = false
    @Published var isError = false
    @Published var hasReceivedVideoFormat = false
    @Published var quality: CaptureQuality = .archive
    @Published var streamDescription = "ACTUAL // READY"
    @Published var requestedProfile = "REQUESTED // WAITING FOR PROFILE"
    @Published var health = GVLinkHealth()
    @Published var isLocallyRecording = false
    @Published var lastRecordingURL: URL?
    private let localRecorder = GVLocalRecorder()
    private var wantsLocalRecording = false

    weak var link: GVPhoneLink?
    private var wantsConnection = false
    private var retryTask: Task<Void, Never>?

    deinit {
        retryTask?.cancel()
    }

    func start() {
        wantsConnection = true
        retryTask?.cancel()
        retryTask = nil
        isRunning = true
        isError = false
        hasReceivedVideoFormat = false
        link?.start(
            passcode: GVBroadcastProtocol.automaticPairingSecret,
            bitrate: quality.bitrate
        )
    }

    func setQuality(_ quality: CaptureQuality) {
        self.quality = quality
        guard isRunning else { return }
        link?.setBitrate(quality.bitrate)
    }

    func requestKeyframe() {
        link?.requestKeyframe()
    }

    func toggleLocalRecording() {
        if wantsLocalRecording {
            wantsLocalRecording = false
            localRecorder.stop { [weak self] url in
                Task { @MainActor in
                    self?.isLocallyRecording = false
                    self?.lastRecordingURL = url
                }
            }
        } else {
            wantsLocalRecording = true
            isLocallyRecording = true
        }
    }

    func appendLocalFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard wantsLocalRecording else { return }
        if !localRecorder.isRecording {
            _ = localRecorder.start(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer),
                frameRate: max(Int(health.framesPerSecond.rounded()), 1)
            )
        }
        localRecorder.append(pixelBuffer, timestamp: timestamp)
    }

    func stop() {
        wantsConnection = false
        wantsLocalRecording = false
        if localRecorder.isRecording { localRecorder.stop { _ in } }
        isLocallyRecording = false
        retryTask?.cancel()
        retryTask = nil
        link?.stop()
        isRunning = false
        hasReceivedVideoFormat = false
        frame = nil
        health = GVLinkHealth(decoderStatus: "IDLE")
        linkPeer = ""
        status = "Link stopped."
        isError = false
    }

    func applyLinkState(_ state: GVPhoneLink.LinkState) {
        switch state {
        case .idle:
            // A transport failure returns to idle. Keep the user's intent alive
            // and let Bonjour recover without requiring a button press.
            if wantsConnection {
                status = "Waiting for the iPhone; retrying automatically…"
                scheduleRetry()
            } else if isRunning == false, isError == false {
                status = "Link offline."
            }
        case .searching:
            status = "Searching the local network for the iPhone…"
        case let .connecting(peer):
            linkPeer = peer
            status = "Connecting to \(peer)…"
        case let .connected(peer):
            linkPeer = peer
            link?.setBitrate(quality.bitrate)
            status = "Connected. MAX QUALITY // awaiting video format…"
        case let .failed(reason):
            isError = true
            status = "Link failed: \(reason) — retrying automatically…"
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard wantsConnection, retryTask == nil else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.wantsConnection else { return }
                self.retryTask = nil
                self.start()
            }
        }
    }
}

// MARK: - Quality

enum CaptureQuality: String, CaseIterable, Identifiable {
    case lite
    case studio
    case archive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lite: "LITE"
        case .studio: "STUDIO"
        case .archive: "ARCHIVE"
        }
    }

    var bitrate: Int {
        switch self {
        case .lite: 4_000_000
        case .studio: 12_000_000
        case .archive: 120_000_000
        }
    }

    var detail: String {
        switch self {
        case .lite: "4 Mbps // 1080p proxy"
        case .studio: "12 Mbps // 1080p master"
        case .archive: "120 Mbps // MAX QUALITY"
        }
    }
}

// MARK: - Capture window

struct CaptureView: View {
    @ObservedObject var session: CaptureSession
    @ObservedObject var receiver: CaptureReceiver
    @ObservedObject var continuity: GVContinuityCamera
    @State private var previewExposure = 0.0
    @State private var captureMessage = ""
    @State private var isInterfaceHidden = false
    @State private var isNotchCalibrationPresented = false
    @State private var isNotchExpanded = false
    @AppStorage("gv.notch.width") private var notchWidth = 248.0
    @AppStorage("gv.notch.height") private var notchHeight = 54.0
    @AppStorage("gv.notch.offset") private var notchOffset = 14.0
    private let automaticBrightness = 0.28

    private var isLive: Bool {
        session.source == .link ? receiver.isRunning : continuity.isRunning
    }

    private var currentFrame: NSImage? {
        session.source == .link ? receiver.frame : continuity.frame
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.black)
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(.white.opacity(isLive ? 0.34 : 0.14), lineWidth: 1)
                        }

                    if let frame = currentFrame {
                        Image(nsImage: frame)
                            .resizable()
                            .scaledToFit()
                            .brightness(automaticBrightness + previewExposure)
                            .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                    } else {
                        emptyPreview
                    }

                    SignalAccent()
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .allowsHitTesting(false)
                        .opacity(isLive ? 1 : 0)

                    if session.source == .link {
                        linkHealthHUD
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(18)
                            .opacity(isInterfaceHidden ? 0 : 1)
                            .allowsHitTesting(!isInterfaceHidden)
                    }
                }
                .overlay(alignment: .top) {
                    captureHeader
                        .padding(.top, 10)
                        .padding(.horizontal, 14)
                        .opacity(isInterfaceHidden ? 0 : 1)
                        .allowsHitTesting(!isInterfaceHidden)
                }
                .overlay(alignment: .top) {
                    notchSourcePicker
                        .padding(.top, 14)
                        .opacity(isInterfaceHidden ? 0 : 1)
                        .allowsHitTesting(!isInterfaceHidden)
                }
                .overlay(alignment: .topTrailing) {
                    if isNotchCalibrationPresented, !isInterfaceHidden {
                        notchCalibrationPanel
                            .padding(.top, 68)
                            .padding(.trailing, 28)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                    }
                }
                .overlay(alignment: .bottom) {
                    if session.source == .link {
                        linkControlRail
                            .padding(.horizontal, 14)
                            .padding(.bottom, 14)
                            .opacity(isInterfaceHidden ? 0 : 1)
                            .allowsHitTesting(!isInterfaceHidden)
                    } else {
                        previewControlRail
                            .padding(.horizontal, 14)
                            .padding(.bottom, 14)
                            .opacity(isInterfaceHidden ? 0 : 1)
                            .allowsHitTesting(!isInterfaceHidden)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            }
            .padding(.top, 20)

            if isInterfaceHidden {
                Button {
                    toggleInterface()
                } label: {
                    Label("SHOW UI", systemImage: "rectangle.expand.vertical")
                }
                .buttonStyle(GVCaptureButtonStyle(isPrimary: true))
                .keyboardShortcut("h", modifiers: [.shift])
                .accessibilityLabel("Show capture interface")
                .help("Show capture controls (Shift-H)")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(24)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.24), value: isInterfaceHidden)
        .preferredColorScheme(.dark)
    }

    private func toggleInterface() {
        isInterfaceHidden.toggle()
    }

    private var linkHealthHUD: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("\(receiver.health.decoderStatus) // \(Int(receiver.health.framesPerSecond.rounded())) FPS")
            Text("\(Int(receiver.health.kilobitsPerSecond.rounded())) KBPS // \(receiver.health.receivedFrames) FRAMES")
        }
        .gvCaptureMono(9, weight: .medium)
        .tracking(0.7)
        .foregroundStyle(.white.opacity(0.72))
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var captureHeader: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isLive ? .white : .white.opacity(0.25))
                .frame(width: 7, height: 7)
                .shadow(color: .white.opacity(isLive ? 0.7 : 0), radius: 6)
            Text("GREY//VISION")
                .gvCaptureMono(16, weight: .bold)
                .tracking(1.8)
            Text("MAC CAPTURE")
                .gvCaptureMono(11, weight: .medium)
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.43))

            Spacer()
            Text(session.source == .link ? receiver.requestedProfile : "SYSTEM // RAW")
                .gvCaptureMono(10, weight: .medium)
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.58))
            Button {
                isNotchCalibrationPresented.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(GVCaptureButtonStyle())
            .accessibilityLabel("Calibrate Dynamic Island pill")
            .help("Adjust Dynamic Island pill size and position")

            Button {
                toggleInterface()
            } label: {
                Image(systemName: "rectangle.compress.vertical")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(GVCaptureButtonStyle())
            .keyboardShortcut("h", modifiers: [.shift])
            .accessibilityLabel("Hide capture interface")
            .help("Hide capture controls (Shift-H)")

            Text(isLive ? "LIVE" : "OFFLINE")
                .gvCaptureMono(10, weight: .bold)
                .tracking(1.2)
                .foregroundStyle(isLive ? .white : .white.opacity(0.35))
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 18)
    }

    private var notchSourcePicker: some View {
        Group {
            if isNotchExpanded {
                HStack(spacing: 2) {
                    notchSourceButton("PROCESSED", systemImage: "sparkles", source: .link)
                    notchSourceButton("CONTINUITY", systemImage: "video.circle", source: .continuity)
                }
                .padding(5)
                .frame(width: notchWidth, height: notchHeight)
            } else {
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        isNotchExpanded = true
                    }
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(.white)
                            .frame(width: 6, height: 6)
                            .shadow(color: .white.opacity(0.8), radius: 5)
                        Text(session.source == .link ? "PROCESSED" : "CONTINUITY")
                            .gvCaptureMono(9, weight: .bold)
                            .tracking(1.0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .frame(width: 164, height: 42)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Expand source selector")
            }
        }
        .background(
            LinearGradient(
                colors: [Color.black, Color(white: 0.035), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: Capsule(style: .continuous)
        )
        .overlay {
            Capsule(style: .continuous)
                .stroke(.white.opacity(isNotchExpanded ? 0.22 : 0.16), lineWidth: 1)
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(.black.opacity(0.9), lineWidth: 5)
                .blur(radius: 2)
                .mask(Capsule(style: .continuous).fill(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)))
        }
        .shadow(color: .black.opacity(0.7), radius: 20, y: 10)
        .shadow(color: .white.opacity(0.06), radius: 1, y: -1)
        .offset(y: notchOffset)
        .contentShape(Capsule(style: .continuous))
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: isNotchExpanded)
    }

    private var notchCalibrationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ISLAND CALIBRATION")
                    .gvCaptureMono(10, weight: .bold)
                    .tracking(1.1)
                Spacer()
                Button("RESET") {
                    notchWidth = 248
                    notchHeight = 54
                    notchOffset = 14
                }
                .gvCaptureMono(9, weight: .bold)
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.72))
            }
            calibrationSlider("WIDTH", value: $notchWidth, range: 180 ... 360, suffix: "PX")
            calibrationSlider("HEIGHT", value: $notchHeight, range: 42 ... 86, suffix: "PX")
            calibrationSlider("TOP OFFSET", value: $notchOffset, range: 0 ... 80, suffix: "PX")
        }
        .padding(16)
        .frame(width: 290)
        .background(.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.55), radius: 22, y: 10)
    }

    private func calibrationSlider(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .gvCaptureMono(9, weight: .bold)
                    .tracking(0.9)
                    .foregroundStyle(.white.opacity(0.58))
                Spacer()
                Text("\(Int(value.wrappedValue)) \(suffix)")
                    .gvCaptureMono(9, weight: .medium)
                    .foregroundStyle(.white.opacity(0.78))
            }
            Slider(value: value, in: range)
                .tint(.white)
        }
    }

    private func notchSourceButton(
        _ title: String,
        systemImage: String,
        source: CaptureSession.Source
    ) -> some View {
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                session.source = source
                isNotchExpanded = false
            }
        } label: {
            Label(title, systemImage: systemImage)
                .gvCaptureMono(9, weight: .bold)
                .tracking(0.9)
                .frame(minWidth: 112, minHeight: 40)
        }
        .buttonStyle(MacNotchButtonStyle(isActive: session.source == source))
        .accessibilityLabel("Use \(title.lowercased()) source")
    }

    @ViewBuilder
    private var emptyPreview: some View {
        VStack(spacing: 12) {
            Image(systemName: "viewfinder")
                .font(.system(size: 30, weight: .ultraLight))
            if session.source == .link {
                Text("ARM MAC CAM ON IPHONE")
                    .gvCaptureMono(12, weight: .semibold)
                    .tracking(1.6)
                Text("Automatic local pairing — waiting for the iPhone.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                Text("SELECT A CONTINUITY CAMERA")
                    .gvCaptureMono(12, weight: .semibold)
                    .tracking(1.6)
                Text(continuity.devices.isEmpty
                    ? "Wake a nearby iPhone and keep it unlocked."
                    : "Raw system camera — no GreyVision effects.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .foregroundStyle(.white.opacity(0.78))
    }

    private var linkControlRail: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                GVIdentityField(label: "DEVICE", value: receiver.linkPeer.isEmpty ? "AUTO DISCOVERY" : receiver.linkPeer, width: 210)
                Picker("Quality", selection: $receiver.quality) {
                    ForEach(CaptureQuality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
                .tint(.white)
                .onChange(of: receiver.quality) { quality in receiver.setQuality(quality) }

                Spacer(minLength: 0)

                Button(receiver.isLocallyRecording ? "STOP REC" : "REC MAC") {
                    receiver.toggleLocalRecording()
                }
                .buttonStyle(GVCaptureButtonStyle(isPrimary: receiver.isLocallyRecording))
                .help("Record the decoded LINK stream locally")

                if receiver.isRunning {
                    Button(action: receiver.requestKeyframe) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(GVCaptureButtonStyle())
                    .help("Request a fresh video keyframe")
                    .disabled(!receiver.hasReceivedVideoFormat)
                }

                Button(receiver.isRunning ? "DISCONNECT" : "CONNECT") {
                    receiver.isRunning ? receiver.stop() : receiver.start()
                }
                .buttonStyle(GVCaptureButtonStyle(isPrimary: !receiver.isRunning))
                .keyboardShortcut(.defaultAction)
                .disabled(!receiver.isRunning)
            }

            HStack(spacing: 8) {
                Text(receiver.requestedProfile)
                    .gvCaptureMono(9, weight: .regular)
                    .foregroundStyle(.white.opacity(0.58))
                Text(receiver.streamDescription)
                    .gvCaptureMono(9, weight: .bold)
                    .foregroundStyle(.white.opacity(0.82))
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Text(receiver.isError ? "LINK ERROR" : "STATUS")
                    .gvCaptureMono(9, weight: .bold)
                    .tracking(1.0)
                    .foregroundStyle(.white.opacity(receiver.isError ? 0.95 : 0.55))
                Text(receiver.status.uppercased())
                    .gvCaptureMono(9, weight: .regular)
                    .foregroundStyle(.white.opacity(receiver.isError ? 0.95 : 0.62))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }

            if receiver.isRunning {
                GVControlPanelView(remote: session.remote, receiver: receiver)
                    .frame(maxWidth: .infinity, maxHeight: 440)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.96), Color(white: 0.08).opacity(0.9)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        }
    }

    private var previewControlRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: captureCurrentFrame) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 34, height: 28)
                }
                .buttonStyle(GVCaptureButtonStyle(isPrimary: true))
                .help("Save a still frame to Pictures")
                .disabled(currentFrame == nil)

                Text("EXPOSURE")
                    .gvCaptureMono(9, weight: .bold)
                    .tracking(1.0)
                    .foregroundStyle(.white.opacity(0.55))
                Slider(value: $previewExposure, in: -0.35 ... 0.65)
                    .tint(.white)
                    .frame(maxWidth: 180)
                Text(String(format: "%+.2f", previewExposure))
                    .gvCaptureMono(9, weight: .regular)
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 36, alignment: .trailing)

                if !captureMessage.isEmpty {
                    Text(captureMessage)
                        .gvCaptureMono(9, weight: .medium)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }

            continuityControls
        }
        .padding(10)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
    }

    private func captureCurrentFrame() {
        guard let currentFrame,
              let tiffData = currentFrame.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            captureMessage = "NO FRAME"
            return
        }
        let directory = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        let filename = "GreyVision-\(Int(Date().timeIntervalSince1970)).png"
        do {
            try pngData.write(to: directory.appendingPathComponent(filename))
            captureMessage = "SAVED TO PICTURES"
        } catch {
            captureMessage = "SAVE FAILED"
        }
    }

    private var continuityControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Picker("Camera", selection: Binding(
                    get: { continuity.selectedDeviceID ?? continuity.preferredDevice?.id ?? "" },
                    set: { id in
                        guard !id.isEmpty else { return }
                        continuity.start(deviceID: id)
                    }
                )) {
                    if continuity.devices.isEmpty {
                        Text("NO CAMERAS FOUND").tag("")
                    }
                    ForEach(continuity.devices) { device in
                        // macOS only tells .continuityCamera apart from a
                        // generic USB camera on 14+, so the suffix appears only
                        // where it is actually known.
                        Text(device.isContinuity ? "\(device.name) — CONTINUITY" : device.name)
                            .tag(device.id)
                    }
                }
                .labelsHidden()
                .frame(width: 320)
                .tint(.white)
                .disabled(continuity.devices.isEmpty)

                Spacer(minLength: 0)

                Button(continuity.isRunning ? "STOP" : "START") {
                    if continuity.isRunning {
                        continuity.stop()
                    } else if let id = continuity.selectedDeviceID ?? continuity.preferredDevice?.id {
                        continuity.start(deviceID: id)
                    }
                }
                .buttonStyle(GVCaptureButtonStyle(isPrimary: !continuity.isRunning))
                .disabled(continuity.devices.isEmpty)
            }

            HStack(spacing: 8) {
                Text(continuity.isError ? "CAMERA ERROR" : "STATUS")
                    .gvCaptureMono(10, weight: .bold)
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(continuity.isError ? 0.95 : 0.45))
                Text(continuity.status.uppercased())
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(continuity.isError ? 0.95 : 0.52))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Text("SYSTEM CAMERA // NO FX")
                    .gvCaptureMono(10, weight: .medium)
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }
}

private struct MacNotchButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isActive ? .black : .white.opacity(0.62))
            .background(
                Capsule(style: .continuous)
                    .fill(isActive ? .white : .white.opacity(configuration.isPressed ? 0.12 : 0.04))
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(.white.opacity(isActive ? 0.9 : 0.12), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

// MARK: - Visual primitives

private struct SignalAccent: View {
    @State private var scans = false

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(.white.opacity(0.32))
                .frame(width: 1)
                .blur(radius: 0.6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(x: scans ? proxy.size.width * 0.9 : -proxy.size.width * 0.9)
                .animation(.linear(duration: 5.5).repeatForever(autoreverses: false), value: scans)
        }
        .onAppear { scans = true }
    }
}

private struct GVIdentityField: View {
    let label: String
    let value: String
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .gvCaptureMono(9, weight: .bold)
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.45))
            HStack(spacing: 6) {
                Circle()
                    .fill(.white.opacity(0.72))
                    .frame(width: 5, height: 5)
                Text(value)
                    .gvCaptureMono(12, weight: .medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 11)
            .frame(width: width, alignment: .leading)
            .background(.white.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.18), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}

private struct GVField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .gvCaptureMono(9, weight: .bold)
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.45))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .gvCaptureMono(12, weight: .medium)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.18), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(width: width, alignment: .leading)
    }
}

private struct GVCaptureButtonStyle: ButtonStyle {
    var isPrimary: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .gvCaptureMono(10, weight: .bold)
            .tracking(1.3)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.white.opacity(isPrimary ? (configuration.isPressed ? 0.18 : 0.12) : (configuration.isPressed ? 0.1 : 0.05)))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(.white.opacity(isPrimary ? 0.45 : 0.2), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

extension View {
    func gvCaptureMono(_ size: CGFloat, weight: Font.Weight) -> some View {
        font(.system(size: size, weight: weight, design: .monospaced))
    }
}
