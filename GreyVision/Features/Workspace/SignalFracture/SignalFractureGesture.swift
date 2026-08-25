import UIKit

/// Two-finger membrane gesture.
///
/// It only claims a touch sequence once **exactly two** contacts are down, so
/// the existing single-finger tap-to-focus and press-and-hold recognisers are
/// untouched. Zoom in this app is driven by the camera deck's explicit
/// controls rather than a pinch, so nothing is displaced by this gesture.
final class SignalFractureGestureRecognizer: UIGestureRecognizer {
    /// Normalised contact points (0...1, origin top-left of the view).
    private(set) var normalizedA = CGPoint(x: 0.5, y: 0.5)
    private(set) var normalizedB = CGPoint(x: 0.5, y: 0.5)

    private var trackedTouches: [UITouch] = []

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        for touch in touches where trackedTouches.count < 2 {
            trackedTouches.append(touch)
        }
        guard trackedTouches.count == 2 else { return }
        updatePoints()
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard state == .began || state == .changed, trackedTouches.count == 2 else { return }
        updatePoints()
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        release(touches)
        guard state == .began || state == .changed else {
            if trackedTouches.isEmpty {
                state = .failed
            }
            return
        }
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        release(touches)
        guard state == .began || state == .changed else { return }
        state = .cancelled
    }

    override func reset() {
        super.reset()
        trackedTouches.removeAll(keepingCapacity: true)
    }

    private func release(_ touches: Set<UITouch>) {
        trackedTouches.removeAll { touches.contains($0) }
    }

    private func updatePoints() {
        guard let view, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let size = view.bounds.size
        let points = trackedTouches.map { touch -> CGPoint in
            let location = touch.location(in: view)
            return CGPoint(
                x: min(max(location.x / size.width, 0), 1),
                y: min(max(location.y / size.height, 0), 1)
            )
        }
        guard points.count == 2 else { return }
        normalizedA = points[0]
        normalizedB = points[1]
    }
}
