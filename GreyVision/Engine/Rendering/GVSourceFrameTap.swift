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

    /// The next clean frame, or nil when nothing is rendering (camera denied,
    /// app backgrounded) within the timeout.
    func nextFrame(timeout: Duration = .seconds(1.5)) async -> CGImage? {
        let once = GVResumeOnce()
        return await withCheckedContinuation { continuation in
            feed.attach(rate: 60) { [feed] frame in
                feed.detach()
                once.run { continuation.resume(returning: frame.makeCGImage()) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                once.run {
                    self.feed.detach()
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

/// Guards a continuation that two paths race to resume.
private final class GVResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
