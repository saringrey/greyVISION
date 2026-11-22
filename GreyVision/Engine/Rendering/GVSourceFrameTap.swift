import CoreGraphics
import Foundation

/// One clean frame from the live source, on request.
///
/// The effect browser previews every effect on what the camera is pointed at
/// right now rather than on a stock test card. The frame is the renderer's
/// working texture before any effect runs — the same picture the tracker
/// reads — cropped square from the centre. It is held in memory only.
final class GVSourceFrameTap: @unchecked Sendable {
    static let shared = GVSourceFrameTap()
    /// Square edge of the tapped frame. Sharp at three columns on a Pro Max,
    /// small enough that re-rendering a page of previews stays in budget.
    static let longEdge = 320

    /// The renderer's side. Active only while a request is outstanding, so an
    /// idle tap costs one lock per frame and no GPU work.
    let feed = GVTrackingFeed()

    /// Callers waiting for the next frame. Several can wait at once (the
    /// live accent samples several times a second while the effect browser
    /// asks for thumbnail frames), so they share one feed attachment and the
    /// one frame that arrives answers all of them.
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<CGImage?, Never>] = [:]

    /// The next clean frame, or nil when nothing is rendering (camera denied,
    /// app backgrounded) within the timeout.
    func nextFrame(timeout: Duration = .seconds(1.5)) async -> CGImage? {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            // Attach and detach happen under this lock so a frame arriving
            // as a new caller registers can never strand that caller. The
            // feed calls its consumer outside its own lock, so the order
            // (this lock, then the feed's) cannot invert.
            lock.withLock {
                waiters[id] = continuation
                if waiters.count == 1 {
                    feed.attach(rate: 60) { [weak self] frame in
                        self?.deliver(frame.makeCGImage())
                    }
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                self.expire(id)
            }
        }
    }

    private func deliver(_ image: CGImage?) {
        let ready = lock.withLock { () -> [CheckedContinuation<CGImage?, Never>] in
            let all = Array(waiters.values)
            waiters.removeAll()
            feed.detach()
            return all
        }
        for continuation in ready { continuation.resume(returning: image) }
    }

    private func expire(_ id: UUID) {
        let continuation = lock.withLock { () -> CheckedContinuation<CGImage?, Never>? in
            let removed = waiters.removeValue(forKey: id)
            if removed != nil, waiters.isEmpty { feed.detach() }
            return removed
        }
        continuation?.resume(returning: nil)
    }
}
