import CoreMotion
import Foundation
import QuartzCore
import simd

/// Camera pose, published for world-anchored rendering.
///
/// ## Why device attitude and not ARKit
///
/// ARKit and AVFoundation cannot both own the capture device. The effect chain
/// runs on AVFoundation, so an `ARSession` started underneath it would take the
/// camera away and the preview would go dark — the exact failure the app is
/// already carrying elsewhere.
///
/// Device attitude gives orientation without touching the camera. That is 3DoF
/// rather than 6DoF, and the honest limitation is stated in
/// `CameraWorldPose.isTranslationTracked`: trails stick to the room when the
/// phone turns, and drift when it is carried across the room.
///
/// The trade is worth taking because rotation is the case that matters. Panning
/// is what makes a world-locked trail legible, and a rotation-only reprojection
/// is an exact homography — no depth required, no parallax error. Reprojecting
/// translation without depth is ill-posed and would smear, so the choice is
/// between correct-for-rotation and wrong-for-everything.
struct CameraWorldPose: Sendable, Equatable {
    /// Device orientation as a rotation matrix in the reference frame.
    var rotation: simd_float3x3 = matrix_identity_float3x3
    /// Vertical field of view in radians, for the reprojection intrinsics.
    var verticalFieldOfView: Float = 1.0472
    /// True once attitude has been received at least once.
    var isValid = false
    /// Always false on this path. Present so consumers can branch rather than
    /// silently assuming full 6DoF, and so a later ARKit-backed source can set
    /// it without changing call sites.
    var isTranslationTracked = false

    static let idle = CameraWorldPose()
}

/// Thread-safe handoff of pose from the motion queue to the render thread.
///
/// Same pattern as `CameraTouchMailbox`: the renderer pulls the newest value
/// when it is ready rather than being pushed into, so a burst of motion samples
/// cannot schedule render work.
final class CameraWorldPoseMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = CameraWorldPose.idle

    var latest: CameraWorldPose {
        lock.withLock { value }
    }

    func publish(_ pose: CameraWorldPose) {
        lock.withLock { value = pose }
    }

    func reset() {
        lock.withLock { value = .idle }
    }
}

/// Drives the pose mailbox from Core Motion.
///
/// Runs on its own operation queue, never the main queue: attitude arrives at
/// 60Hz and has no business waking the UI. Nothing here publishes to SwiftUI.
final class CameraWorldAnchor: @unchecked Sendable {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let mailbox: CameraWorldPoseMailbox

    init(mailbox: CameraWorldPoseMailbox) {
        self.mailbox = mailbox
        queue.name = "greyVISION.worldAnchor"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1 / 60
        // Reference frame is arbitrary but must be *fixed*: the whole point is
        // that the buffer is anchored to something that does not move with the
        // phone. `.xArbitraryZVertical` keeps gravity as the vertical axis
        // without waiting on a magnetometer fix, which would stall the first
        // seconds of the effect.
        manager.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: queue
        ) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let matrix = motion.attitude.rotationMatrix
            let rotation = simd_float3x3(
                SIMD3<Float>(Float(matrix.m11), Float(matrix.m21), Float(matrix.m31)),
                SIMD3<Float>(Float(matrix.m12), Float(matrix.m22), Float(matrix.m32)),
                SIMD3<Float>(Float(matrix.m13), Float(matrix.m23), Float(matrix.m33))
            )
            mailbox.publish(
                CameraWorldPose(
                    rotation: rotation,
                    verticalFieldOfView: 1.0472,
                    isValid: true,
                    isTranslationTracked: false
                )
            )
        }
    }

    func stop() {
        guard manager.isDeviceMotionActive else { return }
        manager.stopDeviceMotionUpdates()
        mailbox.reset()
    }
}

/// Builds the frame-to-frame reprojection used by world-anchored effects.
///
/// Holds the previous frame's rotation and produces the homography that maps a
/// pixel in this frame to where the same ray sat in the previous frame. For a
/// pure rotation this is exact:
///
///     H = K · R_prev · R_currᵀ · K⁻¹
///
/// Applied to the accumulation buffer each frame, the buffer stops being
/// screen-space and starts being anchored to the world.
struct CameraWorldReprojection {
    private var previousRotation: simd_float3x3?

    /// Returns the homography for this frame and stores the pose for the next.
    ///
    /// Returns identity until two poses have been seen, so the first frame
    /// composites without warping instead of against an undefined reference.
    mutating func update(pose: CameraWorldPose, aspect: Float) -> simd_float3x3 {
        guard pose.isValid else {
            previousRotation = nil
            return matrix_identity_float3x3
        }
        defer { previousRotation = pose.rotation }
        guard let previous = previousRotation else { return matrix_identity_float3x3 }

        // Intrinsics in normalised device coordinates. Only the focal terms
        // matter; principal point is the centre because the shader works in
        // centred UV.
        let focal = 1 / tan(pose.verticalFieldOfView * 0.5)
        let intrinsics = simd_float3x3(
            SIMD3<Float>(focal / max(aspect, 0.0001), 0, 0),
            SIMD3<Float>(0, focal, 0),
            SIMD3<Float>(0, 0, 1)
        )
        let inverse = simd_float3x3(
            SIMD3<Float>(max(aspect, 0.0001) / focal, 0, 0),
            SIMD3<Float>(0, 1 / focal, 0),
            SIMD3<Float>(0, 0, 1)
        )
        let delta = previous * pose.rotation.transpose
        return intrinsics * delta * inverse
    }

    mutating func reset() {
        previousRotation = nil
    }
}
