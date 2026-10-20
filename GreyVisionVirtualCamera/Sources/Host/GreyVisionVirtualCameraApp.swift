import SwiftUI
import SystemExtensions

@main
struct GreyVisionVirtualCameraApp: App {
    @StateObject private var controller = GVVirtualCameraHostController()

    var body: some Scene {
        WindowGroup("grey//visionCAM") {
            ContentView(controller: controller)
                .frame(minWidth: 520, minHeight: 460)
        }
    }
}

struct ContentView: View {
    @ObservedObject var controller: GVVirtualCameraHostController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("grey//visionCAM")
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                Text("MAC VIRTUAL CAMERA")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(.secondary)
            }

            // Single line the operator can scan in two seconds: what is
            // connected, what the camera is doing right now, and what (if
            // anything) needs to be done.
            StatusBar(controller: controller)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("PAIR WITH IPHONE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(.secondary)

                TextField("Service name", text: $controller.serviceName)
                    .textFieldStyle(.roundedBorder)
                    .help("Bonjour service name the iPhone advertises under. Leave at greyVISION unless you changed it on the iPhone.")

                HStack(spacing: 6) {
                    SecureField("Pairing code from iPhone", text: $controller.pairingCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button("Paste") {
                        if let clip = NSPasteboard.general.string(forType: .string) {
                            controller.pairingCode = GVBroadcastKeyMaterial.normalizeCode(clip)
                        }
                    }
                    .controlSize(.regular)
                }

                Toggle("Receive processed iPhone feed", isOn: $controller.isEnabled)
                    .onChange(of: controller.isEnabled) { _ in controller.persistPairing() }
                    .help("When off, the camera extension stops looking for the iPhone on the network.")

                HStack {
                    Button("Save Pairing") { controller.persistPairing() }
                        .keyboardShortcut("s", modifiers: [.command])
                    Spacer()
                    Button("Install Camera Extension") { controller.installExtension() }
                    Button("Remove Extension", role: .destructive) { controller.removeExtension() }
                }
            }

            Spacer(minLength: 0)

            // Errors and status. Long lines wrap; selection is on so the
            // operator can copy a code or error verbatim.
            VStack(alignment: .leading, spacing: 4) {
                Text("STATUS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(.secondary)
                Text(controller.status)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(controller.statusIsError ? .red : .secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .preferredColorScheme(.dark)
    }
}

/// A small status strip at the top of the window. One line, always current,
/// always tells the operator whether the link is up, the extension is
/// installed, and where frames are going.
private struct StatusBar: View {
    @ObservedObject var controller: GVVirtualCameraHostController

    var body: some View {
        HStack(spacing: 10) {
            pill(label: extensionLabel, color: extensionColor)
            pill(label: pairingLabel, color: pairingColor)
            pill(label: streamLabel, color: streamColor)
            Spacer()
        }
    }

    private var extensionLabel: String {
        switch controller.extensionState {
        case .unknown: "EXT // ?"
        case .installing: "EXT // INSTALLING"
        case .installed: "EXT // LIVE"
        case .removed: "EXT // OFF"
        case .failed: "EXT // ERROR"
        }
    }

    private var extensionColor: Color {
        switch controller.extensionState {
        case .installed: .green
        case .installing: .yellow
        case .failed: .red
        default: .secondary
        }
    }

    private var pairingLabel: String {
        if GVBroadcastKeyMaterial.isValidCode(controller.pairingCode), controller.isEnabled {
            return "PAIR // \(controller.pairingCode)"
        }
        return "PAIR // --"
    }

    private var pairingColor: Color {
        if GVBroadcastKeyMaterial.isValidCode(controller.pairingCode), controller.isEnabled {
            return .green
        }
        return .secondary
    }

    private var streamLabel: String {
        switch controller.streamState {
        case .idle: "STREAM // IDLE"
        case .waiting: "STREAM // WAITING"
        case .live: "STREAM // LIVE"
        }
    }

    private var streamColor: Color {
        switch controller.streamState {
        case .live: .green
        case .waiting: .yellow
        case .idle: .secondary
        }
    }

    private func pill(label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
                    .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 0.8))
            )
    }
}

@MainActor
final class GVVirtualCameraHostController: NSObject, ObservableObject {
    enum ExtensionState: Equatable { case unknown, installing, installed, removed, failed }
    enum StreamState: Equatable { case idle, waiting, live }

    @Published var serviceName: String
    @Published var pairingCode: String
    @Published var isEnabled: Bool
    @Published private(set) var status = "Long-press Mac Camera on the iPhone to read its pairing code, then paste it here."
    @Published private(set) var statusIsError = false
    @Published private(set) var extensionState: ExtensionState = .unknown
    @Published private(set) var streamState: StreamState = .idle

    private let extensionIdentifier = "com.saringrey.greyvision.virtualcamera.cameraextension"

    override init() {
        let pairing = GVVirtualCameraConfiguration.load()
        serviceName = pairing.serviceName
        pairingCode = pairing.pairingCode
        isEnabled = pairing.isEnabled
        super.init()
        if isEnabled, GVBroadcastKeyMaterial.isValidCode(pairingCode) {
            streamState = .waiting
        }
    }

    func persistPairing() {
        let normalizedCode = GVBroadcastKeyMaterial.normalizeCode(pairingCode)
        guard GVBroadcastKeyMaterial.isValidCode(normalizedCode) || !isEnabled else {
            setStatus("Paste the \(GVBroadcastKeyMaterial.codeLength)-character pairing code shown on the iPhone before enabling the feed.", error: true)
            return
        }
        pairingCode = normalizedCode
        GVVirtualCameraConfiguration.save(serviceName: serviceName, pairingCode: pairingCode, isEnabled: isEnabled)
        streamState = isEnabled && GVBroadcastKeyMaterial.isValidCode(pairingCode) ? .waiting : .idle
        setStatus(isEnabled
            ? "Pairing saved. Open FaceTime, Photo Booth, OBS, or Zoom and select grey//visionCAM."
            : "Pairing disabled.")
    }

    func installExtension() {
        persistPairing()
        extensionState = .installing
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        setStatus("Requesting Camera Extension activation…")
    }

    func removeExtension() {
        extensionState = .installing
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        setStatus("Requesting Camera Extension removal…")
    }

    private func setStatus(_ value: String, error: Bool = false) {
        status = value
        statusIsError = error
    }
}

extension GVVirtualCameraHostController: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _: OSSystemExtensionRequest,
        actionForReplacingExtension _: OSSystemExtensionProperties,
        withExtension _: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_: OSSystemExtensionRequest) {
        Task { @MainActor in
            extensionState = .unknown
            setStatus("macOS needs administrator approval in System Settings → Privacy & Security before the camera can appear.")
        }
    }

    nonisolated func request(_: OSSystemExtensionRequest, didFinishWithResult _: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            extensionState = .installed
            streamState = isEnabled && GVBroadcastKeyMaterial.isValidCode(pairingCode) ? .waiting : .idle
            setStatus("Camera Extension activated. Select grey//visionCAM in FaceTime, Photo Booth, OBS, Zoom, or any other camera client.")
        }
    }

    nonisolated func request(_: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            extensionState = .failed
            setStatus("Camera Extension request failed: \(error.localizedDescription)", error: true)
        }
    }
}
