import CoreVideo
import CoreText
import Foundation
import CoreGraphics
import UIKit

/// Renders the branding, signature and running duration into the final video
/// frame's CPU pixel buffer. Bypasses the SwiftUI layer for offline/background
/// rendering of final media, ensuring no HUD layout or interactive buttons are
/// captured.
///
/// Orientation: a CGBitmapContext over CVPixelBuffer memory needs NO flip —
/// Quartz already maps its bottom-left origin onto the top-down scanline order
/// video uses. The translate/scale(1,-1) this file once applied inverted the
/// CTM under the glyph rasteriser, which is exactly why burned-in overlays
/// came out mirrored; drawing straight into the native context is upright.
///
/// Size: every element is scaled from the frame's longest edge against a
/// 1080p reference, so the mark reads identically on 720p captures and 4K.
final class RecordingOverlayRenderer: @unchecked Sendable {
    /// Longest-edge value the point sizes below were designed against.
    private static let referenceEdge: CGFloat = 1080

    private let lock = NSLock()
    private let durationCache = NSCache<NSString, CGImage>()
    private let textCache = NSCache<NSString, CGImage>()

    func composite(into pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue // BGRA

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return }

        // Resolution scale: 1x at 1080p, proportionally larger above it.
        let reference = CGFloat(max(width, height))
        let scale = min(max(reference / Self.referenceEdge, 1), 1.5)
        let margin = 52 * scale

        // Bottom-left stack: wordmark with the channel line beneath it.
        drawGlowedImage(
            context,
            image: cachedText("grey//VISION", size: 26 * scale, alpha: 0.92, kern: 2 * scale, key: "brand-\(Int(scale * 10))"),
            x: margin,
            y: margin + 20 * scale,
            haloRadius: 24 * scale,
            haloAlpha: 0.22,
            coreRadius: 7 * scale,
            coreAlpha: 0.5
        )
        drawGlowedImage(
            context,
            image: cachedText("GV://CAM/01", size: 14 * scale, alpha: 0.55, kern: 1.2 * scale, key: "sig-\(Int(scale * 10))"),
            x: margin,
            y: margin - 4 * scale,
            haloRadius: 14 * scale,
            haloAlpha: 0.16,
            coreRadius: 5 * scale,
            coreAlpha: 0.35
        )

        // Bottom-right stack: duration with a live glowing record pip. The
        // number is how long this video IS — elapsed take time, which equals
        // the saved clip's length — formatted M:SS (H:MM:SS past an hour).
        let seconds = Int(timestamp)
        let durationImage = cachedDuration(seconds: seconds, size: 22 * scale)
        let durationWidth = CGFloat(durationImage.width)
        let rightEdge = CGFloat(width) - margin

        drawGlowingPip(
            context,
            centerX: rightEdge - durationWidth - 20 * scale,
            centerY: margin + 23 * scale,
            radius: 6 * scale
        )
        drawGlowedImage(
            context,
            image: durationImage,
            x: rightEdge - durationWidth,
            y: margin,
            haloRadius: 26 * scale,
            haloAlpha: 0.24,
            coreRadius: 8 * scale,
            coreAlpha: 0.55
        )
    }

    // MARK: - Drawing

    /// Two-pass glow: one wide faint halo behind one tight bright core, then
    /// the asset itself on top. Drawn in the native context orientation — no
    /// transform, so text lands upright and unmirrored.
    private func drawGlowedImage(
        _ context: CGContext,
        image: CGImage,
        x: CGFloat,
        y: CGFloat,
        haloRadius: CGFloat,
        haloAlpha: CGFloat,
        coreRadius: CGFloat,
        coreAlpha: CGFloat
    ) {
        let rect = CGRect(x: x, y: y, width: CGFloat(image.width), height: CGFloat(image.height))

        context.setShadow(offset: .zero, blur: haloRadius, color: UIColor.white.withAlphaComponent(haloAlpha).cgColor)
        context.draw(image, in: rect)

        context.setShadow(offset: .zero, blur: coreRadius, color: UIColor.white.withAlphaComponent(coreAlpha).cgColor)
        context.draw(image, in: rect)

        context.setShadow(offset: .zero, blur: 0, color: nil)
    }

    /// The record indicator: solid white dot carried by layered shadows so it
    /// reads as an emitter rather than a printed pixel.
    private func drawGlowingPip(_ context: CGContext, centerX: CGFloat, centerY: CGFloat, radius: CGFloat) {
        let rect = CGRect(x: centerX - radius, y: centerY - radius, width: radius * 2, height: radius * 2)

        context.setShadow(offset: .zero, blur: radius * 4.5, color: UIColor.white.withAlphaComponent(0.45).cgColor)
        context.fillEllipse(in: rect)
        context.setShadow(offset: .zero, blur: radius * 1.8, color: UIColor.white.withAlphaComponent(0.75).cgColor)
        context.fillEllipse(in: rect)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setFillColor(UIColor.white.cgColor)
        context.fillEllipse(in: rect)
    }

    // MARK: - Cached assets

    private func cachedDuration(seconds: Int, size: CGFloat) -> CGImage {
        lock.lock()
        defer { lock.unlock() }

        let key = "dur-\(seconds)-\(Int(size))" as NSString
        if let cached = durationCache.object(forKey: key) {
            return cached
        }

        let timeString: String
        if seconds >= 3600 {
            timeString = String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        } else {
            timeString = String(format: "%d:%02d", seconds / 60, seconds % 60)
        }

        let font = UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
        let image = Self.createTextImage(text: timeString, font: font, alpha: 0.9, kern: size * 0.08)
        durationCache.setObject(image, forKey: key)
        return image
    }

    private func cachedText(_ text: String, size: CGFloat, alpha: CGFloat, kern: CGFloat, key: String) -> CGImage {
        lock.lock()
        defer { lock.unlock() }

        let cacheKey = key as NSString
        if let cached = textCache.object(forKey: cacheKey) {
            return cached
        }

        let font = UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
        let image = Self.createTextImage(text: text, font: font, alpha: alpha, kern: kern)
        textCache.setObject(image, forKey: cacheKey)
        return image
    }

    private static func createTextImage(text: String, font: UIFont, alpha: CGFloat, kern: CGFloat) -> CGImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white.withAlphaComponent(alpha),
            .kern: kern
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let bounds = CGRect(origin: .zero, size: textSize)

        UIGraphicsBeginImageContextWithOptions(bounds.size, false, 1.0) // Render at 1x so it maps to pixel directly
        string.draw(at: .zero)
        let image = UIGraphicsGetImageFromCurrentImageContext()?.cgImage
        UIGraphicsEndImageContext()

        return image!
    }
}
