import CoreGraphics
import Foundation
import simd

/// Gives detections identity over time.
///
/// Each pass predicts every live track forward on its velocity, pairs tracks
/// with detections greedily by cost (distance from the prediction relative to
/// the match radius, plus a size-change penalty), and updates matched tracks
/// with an alpha-beta filter — the smoothing control is the filter's gain.
/// New detections start tentative and are shown once they have been seen
/// `confirm` passes in a row, which is what stops one-frame noise from
/// flashing a mark. Lost tracks coast on their velocity for `persistence`
/// seconds before they drop, so a subject passing behind something keeps its
/// name when it comes out.
///
/// Not thread-safe: owned by the tracker's serial queue.
final class GVTrackAssociator {
    private struct Track {
        let id: UInt64
        var center: CGPoint
        var size: CGSize
        var velocity: CGVector
        var color: SIMD3<Float>
        var area: Float
        var confidence: Float
        var joints: [CGPoint]
        var bones: [[Int]]
        var hits: Int
        var confirmed: Bool
        var born: Double
        var lastSeen: Double
        var trail: [CGPoint]
    }

    private var tracks: [Track] = []
    private var nextID: UInt64 = 1
    private var lastTime: Double?
    private let seed: UInt64 = 0xB10B_5EED_2026

    func reset() {
        tracks = []
        lastTime = nil
    }

    // swiftlint:disable:next function_body_length
    func update(_ detections: [GVTrackingDetection], at time: Double, parameters: BlobTrackingParameters) -> [TrackedBlob] {
        let parameters = parameters.sanitized
        let dt = min(max(time - (lastTime ?? time - 1 / parameters.rate), 1 / 120), 0.5)
        lastTime = time
        let alpha = CGFloat(max(1 - parameters.smoothing, 0.05))
        let beta = alpha * alpha / (2 - alpha)
        let radius = CGFloat(parameters.matchRadius)

        // Predict.
        for index in tracks.indices {
            tracks[index].center.x += tracks[index].velocity.dx * dt
            tracks[index].center.y += tracks[index].velocity.dy * dt
        }

        // Associate, cheapest pair first.
        var pairs: [(cost: CGFloat, track: Int, detection: Int)] = []
        for (t, track) in tracks.enumerated() {
            for (d, detection) in detections.enumerated() {
                let center = CGPoint(x: detection.rect.midX, y: detection.rect.midY)
                let distance = hypot(center.x - track.center.x, center.y - track.center.y)
                guard distance <= radius else { continue }
                let areaRatio = CGFloat(max(detection.area, 1e-5) / max(track.area, 1e-5))
                pairs.append((distance / radius + abs(log(areaRatio)) * 0.35, t, d))
            }
        }
        pairs.sort { $0.cost < $1.cost }
        var usedTracks = Set<Int>()
        var usedDetections = Set<Int>()
        for pair in pairs where !usedTracks.contains(pair.track) && !usedDetections.contains(pair.detection) {
            usedTracks.insert(pair.track)
            usedDetections.insert(pair.detection)
            let detection = detections[pair.detection]
            var track = tracks[pair.track]
            let measured = CGPoint(x: detection.rect.midX, y: detection.rect.midY)
            let residual = CGVector(dx: measured.x - track.center.x, dy: measured.y - track.center.y)
            track.center.x += alpha * residual.dx
            track.center.y += alpha * residual.dy
            track.velocity.dx += beta * residual.dx / dt
            track.velocity.dy += beta * residual.dy / dt
            // A coasting track that is found again should not inherit a
            // velocity built up while it was being guessed at.
            track.velocity.dx = max(min(track.velocity.dx, 3), -3)
            track.velocity.dy = max(min(track.velocity.dy, 3), -3)
            track.size.width += alpha * (detection.rect.width - track.size.width)
            track.size.height += alpha * (detection.rect.height - track.size.height)
            track.color += Float(alpha) * (detection.color - track.color)
            track.area += Float(alpha) * (detection.area - track.area)
            track.confidence = detection.confidence
            track.joints = Self.blend(track.joints, toward: detection.joints, alpha: alpha)
            track.bones = detection.bones
            track.hits += 1
            track.lastSeen = time
            if track.hits >= Int(parameters.confirm) { track.confirmed = true }
            tracks[pair.track] = track
        }

        // Retire the lost: tentative tracks immediately, confirmed ones after
        // their coast window.
        tracks = tracks.enumerated().compactMap { index, track in
            if usedTracks.contains(index) { return track }
            guard track.confirmed, time - track.lastSeen <= parameters.persistence else { return nil }
            var coasting = track
            // Coasting decays velocity so a dropped subject drifts to a stop
            // instead of sailing off the edge.
            coasting.velocity.dx *= 0.85
            coasting.velocity.dy *= 0.85
            coasting.hits = 0
            return coasting
        }

        // Spawn tentative tracks for what nothing claimed.
        for (index, detection) in detections.enumerated() where !usedDetections.contains(index) {
            guard tracks.count < Int(parameters.maxTracks) * 3 else { break }
            tracks.append(Track(
                id: nextID,
                center: CGPoint(x: detection.rect.midX, y: detection.rect.midY),
                size: detection.rect.size,
                velocity: .zero,
                color: detection.color,
                area: detection.area,
                confidence: detection.confidence,
                joints: detection.joints,
                bones: detection.bones,
                hits: 1,
                confirmed: parameters.confirm <= 1,
                born: time,
                lastSeen: time,
                trail: []
            ))
            nextID &+= 1
        }

        // Trails.
        let capacity = parameters.trailCapacity
        for index in tracks.indices {
            if capacity == 0 {
                tracks[index].trail = []
            } else {
                tracks[index].trail.append(tracks[index].center)
                if tracks[index].trail.count > capacity {
                    tracks[index].trail.removeFirst(tracks[index].trail.count - capacity)
                }
            }
        }

        return tracks
            .filter(\.confirmed)
            .sorted { $0.area > $1.area }
            .prefix(Int(parameters.maxTracks))
            .map { track in
                TrackedBlob(
                    id: track.id,
                    rect: CGRect(x: track.center.x - track.size.width / 2, y: track.center.y - track.size.height / 2,
                                 width: track.size.width, height: track.size.height),
                    velocity: track.velocity,
                    color: track.color,
                    area: track.area,
                    confidence: track.confidence,
                    label: EsotericLabelGenerator.label(for: seed, index: Int(track.id)),
                    age: time - track.born,
                    isCoasting: track.lastSeen < time,
                    trail: track.trail,
                    joints: track.joints,
                    bones: track.bones
                )
            }
    }

    /// Joints follow the same smoothing as the box, matched by index; a joint
    /// missing in either set snaps to the newest reading.
    private static func blend(_ current: [CGPoint], toward next: [CGPoint], alpha: CGFloat) -> [CGPoint] {
        guard current.count == next.count else { return next }
        return zip(current, next).map { old, new in
            guard old != GVVisionDetector.missing, new != GVVisionDetector.missing else { return new }
            return CGPoint(x: old.x + (new.x - old.x) * alpha, y: old.y + (new.y - old.y) * alpha)
        }
    }
}
