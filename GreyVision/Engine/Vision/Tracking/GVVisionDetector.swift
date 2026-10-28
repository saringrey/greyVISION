import CoreGraphics
import Foundation
import simd
import Vision

/// Vision-backed detection for the face, hand, body and salient modes.
///
/// Runs on the analysis frame — the same upright, pre-effect image the field
/// modes segment — so every mode shares one coordinate space. Vision's
/// bottom-left normalised coordinates are flipped to the top-left convention
/// once, here. Joints Vision is unsure of are kept as `missing` so a skeleton
/// keeps its indexing and simply skips those bones.
///
/// Requests are built once and reused; owned by the tracker's serial queue.
final class GVVisionDetector {
    static let missing = CGPoint(x: -1, y: -1)

    struct Output {
        let detections: [GVTrackingDetection]
        let error: String?
    }

    private let faceRequest = VNDetectFaceLandmarksRequest()
    private let handRequest = VNDetectHumanHandPoseRequest()
    private let bodyRequest = VNDetectHumanBodyPoseRequest()
    private let salientRequest = VNGenerateObjectnessBasedSaliencyImageRequest()

    func detect(_ frame: GVTrackingFrame, parameters: BlobTrackingParameters) -> Output {
        guard let image = frame.makeCGImage() else {
            return Output(detections: [], error: "NO FRAME")
        }
        let parameters = parameters.sanitized
        let floor = Float(parameters.confidence)
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        do {
            switch parameters.mode {
            case .face:
                try handler.perform([faceRequest])
                return Output(detections: faces(floor: floor, frame: frame), error: nil)
            case .hand:
                handRequest.maximumHandCount = Int(parameters.maxTracks)
                try handler.perform([handRequest])
                return Output(detections: hands(floor: floor, frame: frame), error: nil)
            case .body:
                try handler.perform([bodyRequest])
                return Output(detections: bodies(floor: floor, frame: frame), error: nil)
            case .salient:
                try handler.perform([salientRequest])
                return Output(detections: salient(floor: floor, frame: frame), error: nil)
            default:
                return Output(detections: [], error: nil)
            }
        } catch {
            // Hand and body pose need the Neural Engine and are unavailable on
            // some simulators; say so rather than reporting an empty room.
            return Output(detections: [], error: "VISION UNAVAILABLE")
        }
    }

    // MARK: - Requests

    private func faces(floor: Float, frame: GVTrackingFrame) -> [GVTrackingDetection] {
        (faceRequest.results ?? []).compactMap { face in
            guard face.confidence >= floor else { return nil }
            let rect = Self.flip(face.boundingBox)
            let joints = (face.landmarks?.allPoints?.normalizedPoints ?? []).map { point in
                CGPoint(x: rect.minX + point.x * rect.width, y: rect.maxY - point.y * rect.height)
            }
            return detection(rect: rect, confidence: face.confidence, joints: joints, bones: [], frame: frame)
        }
    }

    private func hands(floor: Float, frame: GVTrackingFrame) -> [GVTrackingDetection] {
        (handRequest.results ?? []).compactMap { hand in
            guard hand.confidence >= floor,
                  let points = try? hand.recognizedPoints(.all)
            else { return nil }
            let joints = Self.handJoints.map { Self.point(points[$0], floor: floor) }
            return pose(joints: joints, bones: Self.handBones, confidence: hand.confidence, frame: frame)
        }
    }

    private func bodies(floor: Float, frame: GVTrackingFrame) -> [GVTrackingDetection] {
        (bodyRequest.results ?? []).compactMap { body in
            guard body.confidence >= floor,
                  let points = try? body.recognizedPoints(.all)
            else { return nil }
            let joints = Self.bodyJoints.map { Self.point(points[$0], floor: floor) }
            return pose(joints: joints, bones: Self.bodyBones, confidence: body.confidence, frame: frame)
        }
    }

    private func salient(floor: Float, frame: GVTrackingFrame) -> [GVTrackingDetection] {
        (salientRequest.results ?? []).flatMap { observation in
            (observation.salientObjects ?? []).compactMap { object -> GVTrackingDetection? in
                guard object.confidence >= floor * 0.5 else { return nil }
                return detection(rect: Self.flip(object.boundingBox), confidence: object.confidence,
                                 joints: [], bones: [], frame: frame)
            }
        }
    }

    // MARK: - Helpers

    private func pose(joints: [CGPoint], bones: [[Int]], confidence: Float, frame: GVTrackingFrame) -> GVTrackingDetection? {
        let found = joints.filter { $0 != Self.missing }
        guard found.count >= 3 else { return nil }
        let xs = found.map(\.x), ys = found.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        // A skeleton's joints sit inside the limb, so the subject is a little
        // larger than the hull of its joints.
        let rect = bounds.insetBy(dx: -max(bounds.width * 0.12, 0.02), dy: -max(bounds.height * 0.12, 0.02))
        return detection(rect: rect, confidence: confidence, joints: joints, bones: bones, frame: frame)
    }

    private func detection(rect: CGRect, confidence: Float, joints: [CGPoint], bones: [[Int]],
                           frame: GVTrackingFrame) -> GVTrackingDetection
    {
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let safe = clamped.isNull ? CGRect(x: rect.midX, y: rect.midY, width: 0.01, height: 0.01) : clamped
        return GVTrackingDetection(
            rect: safe,
            color: Self.meanColor(in: safe, frame: frame),
            area: Float(safe.width * safe.height),
            confidence: confidence,
            joints: joints,
            bones: bones
        )
    }

    private static func point(_ point: VNRecognizedPoint?, floor: Float) -> CGPoint {
        guard let point, point.confidence >= max(floor * 0.5, 0.1) else { return missing }
        return CGPoint(x: point.location.x, y: 1 - point.location.y)
    }

    private static func flip(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Mean colour over a 5×5 lattice inside the rect — enough to tint a mark
    /// with its subject without walking every pixel.
    private static func meanColor(in rect: CGRect, frame: GVTrackingFrame) -> SIMD3<Float> {
        var sum = SIMD3<Float>.zero
        for j in 0 ..< 5 {
            for i in 0 ..< 5 {
                let x = Int((rect.minX + rect.width * (CGFloat(i) + 0.5) / 5) * CGFloat(frame.width))
                let y = Int((rect.minY + rect.height * (CGFloat(j) + 0.5) / 5) * CGFloat(frame.height))
                sum += frame.rgb(min(max(x, 0), frame.width - 1), min(max(y, 0), frame.height - 1))
            }
        }
        return sum / 25
    }

    // MARK: - Skeletons

    static let handJoints: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip
    ]

    /// Wrist to each fingertip, joint by joint.
    static let handBones: [[Int]] = {
        var bones: [[Int]] = []
        for base in stride(from: 1, to: 21, by: 4) {
            bones.append([0, base])
            bones.append([base, base + 1])
            bones.append([base + 1, base + 2])
            bones.append([base + 2, base + 3])
        }
        return bones
    }()

    static let bodyJoints: [VNHumanBodyPoseObservation.JointName] = [
        .nose, .leftEye, .rightEye, .leftEar, .rightEar, .neck,
        .leftShoulder, .rightShoulder, .leftElbow, .rightElbow, .leftWrist, .rightWrist,
        .root, .leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle
    ]

    static let bodyBones: [[Int]] = [
        [5, 0], [0, 1], [0, 2], [1, 3], [2, 4],
        [5, 6], [5, 7], [6, 8], [8, 10], [7, 9], [9, 11],
        [5, 12], [12, 13], [12, 14], [13, 15], [15, 17], [14, 16], [16, 18]
    ]
}
