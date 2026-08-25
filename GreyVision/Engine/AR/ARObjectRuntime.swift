// swiftlint:disable file_length
@preconcurrency import ARKit
import Combine
import CoreVideo
import Foundation
import QuartzCore
import simd
import UIKit

// MARK: - Model

enum ARObjectShape: UInt32, CaseIterable, Identifiable, Sendable {
    case icosahedron
    case box
    case cone
    case cylinder
    case ellipsoid
    case sphere
    case plate
    case torus
    case capsule
    case prism
    /// Scanned USDZ marks. Rendered through the same untextured
    /// position+normal pipeline as the primitives, so they read as captured
    /// geometry inside the instrument rather than as imported product art.
    case hemisphere
    case ring
    case spike
    case slab
    case baby
    case melissa

    var id: UInt32 {
        rawValue
    }

    var label: String {
        switch self {
        case .icosahedron: "ICOSAHEDRON"
        case .box: "CUBE"
        case .cone: "CONE"
        case .cylinder: "CYLINDER"
        case .ellipsoid: "ELLIPSOID"
        case .sphere: "SPHERE"
        case .plate: "PLATE"
        case .torus: "TORUS"
        case .capsule: "CAPSULE"
        case .prism: "PRISM"
        case .hemisphere: "HEMISPHERE"
        case .ring: "RING"
        case .spike: "SPIKE"
        case .slab: "SLAB"
        case .baby: "BABY.SCAN"
        case .melissa: "MELISSA.SCAN"
        }
    }
}

/// Lifecycle of a direct-manipulation gesture, decoupled from UIKit so the
/// runtime does not depend on `UIGestureRecognizer`.
enum ARManipulationPhase: Sendable {
    case began
    case changed
    case ended
}

struct ARObjectDescriptor: Identifiable, Equatable, Sendable {
    let id: UUID
    var shape: ARObjectShape
    var position: SIMD3<Float>
    var scale: Float
    var spinSpeed: Float
    var phase: Float
    var wire: Bool
    var tintIndex: Int
    var birthTime: TimeInterval
    /// Hidden constellation easter egg: when true, the object renders as a
    /// dark violet "black hole" that gravitationally pulls the others in.
    var isBlackHole: Bool

    init(
        id: UUID = UUID(),
        shape: ARObjectShape,
        position: SIMD3<Float>,
        scale: Float,
        spinSpeed: Float,
        phase: Float,
        wire: Bool,
        tintIndex: Int,
        birthTime: TimeInterval,
        isBlackHole: Bool = false
    ) {
        self.id = id
        self.shape = shape
        self.position = position
        self.scale = scale
        self.spinSpeed = spinSpeed
        self.phase = phase
        self.wire = wire
        self.tintIndex = tintIndex
        self.birthTime = birthTime
        self.isBlackHole = isBlackHole
    }

    static let maxObjects = 12
}

struct ARObjectParameters: Equatable, Sendable {
    /// Object scale 0.35...1.8.
    var size = 0.9
    /// Spin speed 0...2.
    var spin = 0.6
    /// Emissive glow 0.1...1.6.
    var glow = 0.9

    static let defaults = ARObjectParameters()

    var sanitized: ARObjectParameters {
        ARObjectParameters(
            size: min(max(size, 0.35), 1.8),
            spin: min(max(spin, 0), 2),
            glow: min(max(glow, 0.1), 1.6)
        )
    }
}

enum ARObjectPalette {
    static let colors: [SIMD3<Float>] = [
        SIMD3(0.72, 0.28, 1.0), // violet hot
        SIMD3(0.30, 0.55, 1.0), // ice
        SIMD3(0.62, 0.94, 0.36), // acid
        SIMD3(0.98, 0.46, 0.12), // ember
        SIMD3(0.12, 0.88, 0.72), // cyan
        SIMD3(1.0, 0.42, 0.62) // rose
    ]
}

struct ARObjectCapability: Equatable, Sendable {
    let isSupported: Bool
    let reason: String

    static func discover() -> ARObjectCapability {
        #if targetEnvironment(simulator)
            return ARObjectCapability(
                isSupported: false,
                reason: "SIMULATOR HAS NO ARKIT WORLD TRACKING"
            )
        #else
            guard ARWorldTrackingConfiguration.isSupported else {
                return ARObjectCapability(
                    isSupported: false,
                    reason: "WORLD TRACKING IS NOT SUPPORTED"
                )
            }
            return ARObjectCapability(
                isSupported: true,
                reason: "WORLD TRACKING READY"
            )
        #endif
    }
}

enum ARObjectRecordingState: Equatable, Sendable {
    case idle
    case recording
    case finalizing
    case saved
    case failed(String)

    var label: String {
        switch self {
        case .idle: "IDLE"
        case .recording: "REC"
        case .finalizing: "SAVING"
        case .saved: "SAVED"
        case let .failed(message): "FAILED \(message)"
        }
    }
}

enum ARObjectRuntimeState: String, Equatable, Sendable {
    case idle
    case starting
    case running
    case interrupted
    case unsupported
    case failed

    var label: String {
        rawValue.uppercased()
    }
}

struct ARObjectSnapshot: Equatable, Sendable {
    var state: ARObjectRuntimeState
    var sourceLabel: String
    var formatLabel: String
    var objectCount: Int
    var orientation: CapturedFrameOrientation
    var errorMessage: String?

    static let idle = ARObjectSnapshot(
        state: .idle,
        sourceLabel: "AR OBJECTS OFFLINE",
        formatLabel: "NO WORLD TRACKING",
        objectCount: 0,
        orientation: .portrait,
        errorMessage: nil
    )
}

// MARK: - Frame transport

struct ARObjectFrame: @unchecked Sendable {
    let capturedImage: CVPixelBuffer
    let camera: ARCamera
    let orientation: CapturedFrameOrientation
    let timestamp: TimeInterval
}

struct ARObjectFrameMetadata: Equatable, Sendable {
    let sequence: UInt64
    let timestamp: TimeInterval
    let trackingState: Int
    let cameraTransform: simd_float4x4
}

enum ARObjectSourceEvent: Sendable {
    case tracking(ARObjectFrameMetadata)
    case interrupted(String)
    case resumed
    case failed(String)
}

final class LatestARObjectFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latestFrame: ARObjectFrame?

    func publish(_ frame: ARObjectFrame) {
        lock.withLock {
            latestFrame = frame
        }
    }

    func consumeLatest() -> ARObjectFrame? {
        lock.withLock {
            defer { latestFrame = nil }
            return latestFrame
        }
    }

    func clear() {
        lock.withLock {
            latestFrame = nil
        }
    }
}

// MARK: - AR session source

private struct ARObjectSourceState {
    let isRunning: Bool
    let orientation: CapturedFrameOrientation
}

private typealias ARRaycastContinuation = CheckedContinuation<simd_float4x4?, Never>

/// Owns the ARSession for placed geometry. Delivers every frame to the render
/// mailbox and emits a single `tracking` event once world tracking goes normal.
final class ARObjectSource: NSObject, @unchecked Sendable {
    let mailbox: LatestARObjectFrameMailbox

    private let session = ARSession()
    private let sessionQueue = DispatchQueue(
        label: "com.saringrey.greyvision.objects.session",
        qos: .userInteractive
    )
    private let handlerLock = NSLock()
    private let stateLock = NSLock()

    private var eventHandler: (@Sendable (ARObjectSourceEvent) -> Void)?
    private var orientation = CapturedFrameOrientation.portrait
    private var isRunning = false
    private var didEmitTracking = false
    private var frameSequence: UInt64 = 0

    init(mailbox: LatestARObjectFrameMailbox) {
        self.mailbox = mailbox
        super.init()
        session.delegate = self
        session.delegateQueue = sessionQueue
    }

    deinit {
        session.pause()
    }

    func setEventHandler(_ handler: (@Sendable (ARObjectSourceEvent) -> Void)?) {
        handlerLock.withLock {
            eventHandler = handler
        }
    }

    func updateOrientation(_ orientation: CapturedFrameOrientation) {
        stateLock.withLock {
            self.orientation = orientation
        }
    }

    func start() async -> Bool {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                guard ARWorldTrackingConfiguration.isSupported else {
                    continuation.resume(returning: false)
                    return
                }
                mailbox.clear()
                let configuration = ARWorldTrackingConfiguration()
                configuration.worldAlignment = .gravity
                configuration.planeDetection = [.horizontal, .vertical]
                configuration.environmentTexturing = .none
                configuration.providesAudioData = false
                configuration.frameSemantics = []

                stateLock.withLock {
                    isRunning = true
                    didEmitTracking = false
                    frameSequence = 0
                }
                session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
                GVLog.capture.notice("ARKit objects source started: world tracking")
                continuation.resume(returning: true)
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                stopOnSessionQueue()
                continuation.resume()
            }
        }
    }

    func stopSoon() {
        sessionQueue.async { [weak self] in
            self?.stopOnSessionQueue()
        }
    }

    private func stopOnSessionQueue() {
        stateLock.withLock {
            isRunning = false
            didEmitTracking = false
            frameSequence = 0
        }
        session.pause()
        mailbox.clear()
        GVLog.capture.notice("ARKit objects source stopped and detached")
    }

    /// Places geometry at the tapped screen point. Prefers a real plane hit,
    /// then an estimated plane, then a 1.3 m camera-ray fallback so taps always
    /// produce an object even before a plane has been discovered.
    func raycast(
        from point: CGPoint,
        viewportSize: CGSize,
        orientation: CapturedFrameOrientation
    ) async -> simd_float4x4? {
        await withCheckedContinuation { (continuation: ARRaycastContinuation) in
            sessionQueue.async { [self] in
                guard let frame = session.currentFrame else {
                    continuation.resume(returning: nil)
                    return
                }
                let query = frame.raycastQuery(
                    from: point,
                    allowing: .estimatedPlane,
                    alignment: .any
                )
                let transform = session.raycast(query).first?.worldTransform
                    ?? fallbackTransform(
                        point: point,
                        viewportSize: viewportSize,
                        orientation: orientation,
                        frame: frame
                    )
                continuation.resume(returning: transform)
            }
        }
    }

    private func fallbackTransform(
        point: CGPoint,
        viewportSize: CGSize,
        orientation: CapturedFrameOrientation,
        frame: ARFrame
    ) -> simd_float4x4? {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        let interfaceOrientation = Self.interfaceOrientation(for: orientation)
        let projection = frame.camera.projectionMatrix(
            for: interfaceOrientation,
            viewportSize: viewportSize,
            zNear: 0.001,
            zFar: 20
        )
        let view = frame.camera.viewMatrix(for: interfaceOrientation)
        let normalized = SIMD4<Float>(
            Float(point.x / viewportSize.width) * 2 - 1,
            1 - Float(point.y / viewportSize.height) * 2,
            0.5,
            1
        )
        var worldPoint = projection.inverse * normalized
        guard abs(worldPoint.w) > 0.0001 else { return nil }
        worldPoint /= worldPoint.w
        worldPoint = view.inverse * worldPoint
        let origin = SIMD3(worldPoint.x, worldPoint.y, worldPoint.z)
        let direction = normalize(origin)
        let position = origin + direction * 1.3
        var transform = frame.camera.transform
        transform.columns.3 = SIMD4(position, 1)
        return transform
    }

    private static func interfaceOrientation(for orientation: CapturedFrameOrientation) -> UIInterfaceOrientation {
        switch orientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        }
    }

    private func emit(_ event: ARObjectSourceEvent) {
        let handler = handlerLock.withLock { eventHandler }
        handler?(event)
    }
}

extension ARObjectSource: ARSessionDelegate {
    func session(_: ARSession, didUpdate frame: ARFrame) {
        let state = stateLock.withLock {
            ARObjectSourceState(isRunning: isRunning, orientation: orientation)
        }
        guard state.isRunning else { return }

        mailbox.publish(ARObjectFrame(
            capturedImage: frame.capturedImage,
            camera: frame.camera,
            orientation: state.orientation,
            timestamp: frame.timestamp
        ))

        let metadata = stateLock.withLock { () -> ARObjectFrameMetadata? in
            frameSequence &+= 1
            guard !didEmitTracking, frame.camera.trackingState == .normal else {
                return nil
            }
            didEmitTracking = true
            return ARObjectFrameMetadata(
                sequence: frameSequence,
                timestamp: frame.timestamp,
                trackingState: 1,
                cameraTransform: frame.camera.transform
            )
        }
        if let metadata {
            emit(.tracking(metadata))
        }
    }

    func session(_: ARSession, didFailWithError error: Error) {
        stateLock.withLock {
            isRunning = false
        }
        emit(.failed(error.localizedDescription))
    }

    func sessionWasInterrupted(_: ARSession) {
        emit(.interrupted("ARKIT SESSION INTERRUPTED"))
    }

    func sessionInterruptionEnded(_: ARSession) {
        emit(.resumed)
    }
}

// MARK: - Runtime

@MainActor
final class ARObjectRuntime: ObservableObject {
    @Published private(set) var snapshot = ARObjectSnapshot.idle
    @Published private(set) var objects: [ARObjectDescriptor] = []
    @Published var parameters = ARObjectParameters.defaults
    @Published private(set) var recordingState = ARObjectRecordingState.idle
    @Published private(set) var startRequested = false
    /// One-shot notice surfaced as a top line when the constellation easter egg
    /// fires ("CONSTELLATION WITNESSED" / "CONSTELLATION CONSUMED").
    @Published private(set) var constellationMessage: String?

    let capability: ARObjectCapability
    let mailbox: LatestARObjectFrameMailbox

    private let source: ARObjectSource
    private var hasSeededField = false
    private var recordingSession: GVRealtimeRecordingSession?
    private var blackHoleActive = false

    var isRecording: Bool {
        recordingState == .recording
    }

    var activeRecordingSession: GVRealtimeRecordingSession? {
        recordingSession
    }

    init(capability: ARObjectCapability = .discover()) {
        self.capability = capability
        let mailbox = LatestARObjectFrameMailbox()
        self.mailbox = mailbox
        source = ARObjectSource(mailbox: mailbox)
        source.setEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                self?.consume(event)
            }
        }
    }

    var isActive: Bool {
        switch snapshot.state {
        case .starting, .running, .interrupted:
            true
        case .idle, .unsupported, .failed:
            false
        }
    }

    func start() async -> Bool {
        guard capability.isSupported else {
            snapshot = ARObjectSnapshot(
                state: .unsupported,
                sourceLabel: "AR OBJECTS UNAVAILABLE",
                formatLabel: capability.reason,
                objectCount: 0,
                orientation: snapshot.orientation,
                errorMessage: capability.reason
            )
            return false
        }

        refreshOrientation()
        hasSeededField = false
        snapshot = ARObjectSnapshot(
            state: .starting,
            sourceLabel: "AR OBJECTS STARTING",
            formatLabel: capability.reason,
            objectCount: 0,
            orientation: snapshot.orientation,
            errorMessage: nil
        )

        let started = await source.start()
        guard started else {
            snapshot.state = .failed
            snapshot.sourceLabel = "AR OBJECTS FAILURE"
            snapshot.errorMessage = "ARKit failed to start world tracking."
            return false
        }

        for _ in 0 ..< 40 {
            guard !Task.isCancelled else {
                await source.stop()
                snapshot = .idle
                return false
            }
            if snapshot.state == .running {
                return true
            }
            if snapshot.state == .failed {
                await source.stop()
                return false
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        await source.stop()
        snapshot.state = .failed
        snapshot.sourceLabel = "AR OBJECTS TIMEOUT"
        snapshot.errorMessage = "ARKit did not deliver a world-tracking frame within four seconds."
        return false
    }

    func stop() async {
        if isRecording {
            stopRecording()
        }
        await source.stop()
        snapshot = .idle
        hasSeededField = false
    }

    func stopSoon() {
        source.stopSoon()
        snapshot = .idle
    }

    func refreshOrientation() {
        let interfaceOrientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .interfaceOrientation ?? .portrait
        let orientation: CapturedFrameOrientation = switch interfaceOrientation {
        case .portrait:
            .portrait
        case .portraitUpsideDown:
            .portraitUpsideDown
        case .landscapeLeft:
            .landscapeLeft
        case .landscapeRight:
            .landscapeRight
        default:
            .portrait
        }
        snapshot.orientation = orientation
        source.updateOrientation(orientation)
    }

    func placeObject(at point: CGPoint, viewportSize: CGSize) async {
        guard snapshot.state == .running, objects.count < ARObjectDescriptor.maxObjects else { return }
        let orientation = snapshot.orientation
        guard let transform = await source.raycast(
            from: point,
            viewportSize: viewportSize,
            orientation: orientation
        ) else {
            return
        }
        let position = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        appendObject(position: position)
    }

    // MARK: - Direct manipulation

    /// Index of the object being dragged, plus its scale/phase when the
    /// gesture began. Held for the duration of one gesture only.
    private var grabbedIndex: Int?
    private var grabbedScale: Float = 1
    private var grabbedPhase: Float = 0

    /// Picks the object nearest the touch.
    ///
    /// Hit-tests in world space rather than screen space: the touch is
    /// raycast onto the scene, and the closest object to that world point
    /// wins. This reuses the raycast the placement path already depends on
    /// instead of needing a separate camera projection.
    private func nearestObject(to point: CGPoint, viewportSize: CGSize) async -> Int? {
        guard !objects.isEmpty else { return nil }
        guard let transform = await source.raycast(
            from: point,
            viewportSize: viewportSize,
            orientation: snapshot.orientation
        ) else { return nil }

        let target = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        var best: (index: Int, distance: Float)?
        for (index, object) in objects.enumerated() {
            let distance = simd_distance(object.position, target)
            // Radius scales with the object so large geometry is easier to
            // grab than a small marker sitting next to it.
            guard distance < max(0.18, object.scale * 0.35) else { continue }
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    /// Drag an existing object across the world plane.
    func dragObject(at point: CGPoint, viewportSize: CGSize, phase: ARManipulationPhase) async {
        switch phase {
        case .began:
            grabbedIndex = await nearestObject(to: point, viewportSize: viewportSize)
        case .changed:
            guard let index = grabbedIndex, objects.indices.contains(index) else { return }
            guard let transform = await source.raycast(
                from: point,
                viewportSize: viewportSize,
                orientation: snapshot.orientation
            ) else { return }
            objects[index].position = SIMD3(
                transform.columns.3.x,
                transform.columns.3.y,
                transform.columns.3.z
            )
        case .ended:
            if grabbedIndex != nil { detectConstellation() }
            grabbedIndex = nil
        }
    }

    /// Pinch scale. Applies to the grabbed object, or to the most recent one
    /// when the pinch did not start on anything.
    func scaleObject(_ factor: CGFloat, phase: ARManipulationPhase) {
        let index = grabbedIndex ?? objects.indices.last
        guard let index, objects.indices.contains(index) else { return }
        switch phase {
        case .began:
            grabbedScale = objects[index].scale
        case .changed:
            objects[index].scale = min(max(grabbedScale * Float(factor), 0.1), 4.0)
        case .ended:
            grabbedScale = objects[index].scale
        }
    }

    /// Two-finger twist, folded into the object's spin phase.
    func rotateObject(_ radians: CGFloat, phase: ARManipulationPhase) {
        let index = grabbedIndex ?? objects.indices.last
        guard let index, objects.indices.contains(index) else { return }
        switch phase {
        case .began:
            grabbedPhase = objects[index].phase
        case .changed:
            objects[index].phase = grabbedPhase + Float(radians)
        case .ended:
            grabbedPhase = objects[index].phase
        }
    }

    /// Long press removes the object under the finger.
    func removeObject(at point: CGPoint, viewportSize: CGSize) async {
        guard let index = await nearestObject(to: point, viewportSize: viewportSize),
              objects.indices.contains(index)
        else { return }
        objects.remove(at: index)
        blackHoleActive = objects.contains(where: \.isBlackHole)
        detectConstellation()
    }

    func clearObjects() {
        objects = []
        blackHoleActive = false
        constellationMessage = nil
    }

    /// The dock requests a recording; the surface supplies the actual drawable
    /// size on its next update so the writer's pixel buffer pool matches the
    /// rendered frame exactly.
    func requestStartRecording() {
        startRequested = true
    }

    /// Dock REC toggle: starts (writer boots on the surface's next drawable
    /// size) or stops and exports to the photo library.
    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            requestStartRecording()
        }
    }

    func consumeStartRequest(size: CGSize) {
        guard startRequested else { return }
        startRequested = false
        startRecording(size: size)
    }

    private func startRecording(size: CGSize) {
        guard snapshot.state == .running, recordingSession == nil,
              size.width > 0, size.height > 0
        else {
            return
        }
        let timestamp = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("greyvision-ar-\(timestamp).mp4")
        let session = GVRealtimeRecordingSession(outputURL: url, size: size, saveToPhotos: true)
        guard session.start() else {
            recordingState = .failed(GVRecordingError.writerSetupFailed.localizedDescription)
            return
        }
        recordingSession = session
        recordingState = .recording
        UISelectionFeedbackGenerator().selectionChanged()
        GVLog.recording.notice("AR objects recording started")
    }

    func stopRecording() {
        guard let session = recordingSession else { return }
        recordingSession = nil
        recordingState = .finalizing
        session.finish { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    recordingState = .saved
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                case let .failure(error):
                    recordingState = .failed(error.localizedDescription)
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }

    private func appendObject(position: SIMD3<Float>) {
        let shape = ARObjectShape.allCases[objects.count % ARObjectShape.allCases.count]
        let tintIndex = objects.count % ARObjectPalette.colors.count
        let phase = Float(objects.count) * 0.6180339
        objects.append(ARObjectDescriptor(
            shape: shape,
            position: position,
            scale: Float(parameters.size),
            spinSpeed: Float(parameters.spin),
            phase: phase,
            wire: objects.count.isMultiple(of: 2),
            tintIndex: tintIndex,
            birthTime: CACurrentMediaTime()
        ))
        detectConstellation()
    }

    /// Hidden easter egg: when any three objects form an Orion-like belt
    /// (nearly collinear with roughly equal spacing), a black hole materialises
    /// beside them and begins pulling the constellation apart.
    private func detectConstellation() {
        guard !blackHoleActive, objects.count >= 3 else { return }
        let candidates = objects.filter { !$0.isBlackHole }
        for firstIndex in 0 ..< candidates.count {
            for secondIndex in (firstIndex + 1) ..< candidates.count {
                for thirdIndex in (secondIndex + 1) ..< candidates.count {
                    let first = candidates[firstIndex]
                    let second = candidates[secondIndex]
                    let third = candidates[thirdIndex]
                    let ab = second.position - first.position
                    let ac = third.position - first.position
                    let abLength = length(ab)
                    let acLength = length(ac)
                    guard abLength > 0.05, acLength > 0.05 else { continue }
                    // Collinear check: the normalised cross product is sin(angle).
                    guard length(cross(ab, ac)) / (abLength * acLength) < 0.14 else { continue }
                    // Project the three onto the line and compare the two gaps.
                    let axis = ab / abLength
                    let projections = [
                        dot(first.position - first.position, axis),
                        dot(second.position - first.position, axis),
                        dot(third.position - first.position, axis)
                    ].sorted()
                    let gap1 = projections[1] - projections[0]
                    let gap2 = projections[2] - projections[1]
                    let larger = max(gap1, gap2)
                    guard larger > 0.04 else { continue }
                    let spacingRatio = min(gap1, gap2) / larger
                    guard spacingRatio > 0.55 else { continue }
                    spawnBlackHole(belt: [first, second, third])
                    return
                }
            }
        }
    }

    private func spawnBlackHole(belt: [ARObjectDescriptor]) {
        let midpoint = belt.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(belt.count)
        blackHoleActive = true
        objects.append(ARObjectDescriptor(
            shape: .icosahedron,
            position: midpoint + SIMD3(0, 0.28, 0),
            scale: 0.38,
            spinSpeed: 0.16,
            phase: 0.5,
            wire: false,
            tintIndex: 0,
            birthTime: CACurrentMediaTime(),
            isBlackHole: true
        ))
        constellationMessage = "CONSTELLATION WITNESSED"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        GVLog.capture.notice("AR objects: black hole born from a collinear field")
    }

    /// Stepped from every world-tracking frame while a black hole exists:
    /// objects spiral in, spin up as they fall, and are absorbed on contact.
    private func updateGravity() {
        guard let blackHole = objects.first(where: \.isBlackHole) else {
            blackHoleActive = false
            return
        }
        var survivors: [ARObjectDescriptor] = []
        for object in objects where !object.isBlackHole {
            let delta = blackHole.position - object.position
            let distance = max(length(delta), 0.0001)
            if distance < 0.05 {
                UISelectionFeedbackGenerator().selectionChanged()
                continue // absorbed
            }
            var falling = object
            let pull = 0.9 / 60.0 * min(1.0, 0.22 / max(distance * 0.5, 0.03))
            falling.position = object.position + delta / distance * min(pull, 0.05)
            falling.spinSpeed = min(falling.spinSpeed * 1.03, 2.4)
            survivors.append(falling)
        }
        survivors.append(blackHole)
        objects = survivors
        if survivors.count == 1 {
            objects = []
            blackHoleActive = false
            constellationMessage = "CONSTELLATION CONSUMED"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    /// Places the opening constellation relative to the first tracked camera
    /// pose so the environment immediately has geometry to find.
    private func seedInitialField(cameraTransform: simd_float4x4) {
        guard !hasSeededField, objects.isEmpty else { return }
        hasSeededField = true
        let cameraPosition = SIMD3(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        let forward = SIMD3(
            -cameraTransform.columns.2.x,
            -cameraTransform.columns.2.y,
            -cameraTransform.columns.2.z
        )
        let right = SIMD3(
            cameraTransform.columns.0.x,
            cameraTransform.columns.0.y,
            cameraTransform.columns.0.z
        )
        let up = SIMD3(
            cameraTransform.columns.1.x,
            cameraTransform.columns.1.y,
            cameraTransform.columns.1.z
        )
        let placements: [SIMD3<Float>] = [
            SIMD3(1.0, -0.55, 0.85),
            SIMD3(1.45, 0.62, 0.30),
            SIMD3(1.2, 0.05, 1.15),
            SIMD3(1.8, -0.30, 0.55),
            SIMD3(0.9, 0.42, 1.05)
        ]
        for placement in placements {
            let position = cameraPosition + forward * placement.x +
                right * placement.y + up * placement.z
            appendObject(position: position)
        }
        GVLog.capture.notice("AR objects: seeded \(self.objects.count) objects in environment")
    }

    private func consume(_ event: ARObjectSourceEvent) {
        switch event {
        case let .tracking(metadata):
            snapshot.state = .running
            snapshot.sourceLabel = "AR OBJECTS WORLD"
            snapshot.formatLabel = "TRACKING NORMAL"
            snapshot.objectCount = objects.count
            snapshot.errorMessage = nil
            seedInitialField(cameraTransform: metadata.cameraTransform)
            if blackHoleActive {
                updateGravity()
            }
        case let .interrupted(reason):
            snapshot.state = .interrupted
            snapshot.errorMessage = reason
        case .resumed:
            snapshot.state = .starting
            snapshot.errorMessage = nil
        case let .failed(message):
            snapshot.state = .failed
            snapshot.sourceLabel = "AR OBJECTS FAILURE"
            snapshot.errorMessage = message
        }
    }
}

// swiftlint:enable file_length
