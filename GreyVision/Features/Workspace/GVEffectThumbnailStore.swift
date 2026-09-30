import CoreImage
import CoreMedia
import Foundation
import Metal
import UIKit

/// Renders a single effect over a fixed reference still, once, and keeps the
/// result on disk.
///
/// ## The problem it solves
///
/// The effect rail is a wall of 128-point text cards. With 192 effects the
/// label and a four-word detail line are not enough to tell `astralPlasma`
/// from `plasmaRipple` from `plasma` — the operator has to power each one on
/// and look at the preview to find out. That is the wrong way round.
///
/// ## Why it is offline
///
/// Rendering a thumbnail through the live camera means grabbing frames off a
/// session the operator is using, encoding them, and racing the render loop
/// for the GPU — for every one of 192 effects, at unpredictable moments. That
/// is a battery cost, a thermal cost, and a source of visible stutter in
/// exactly the place the user is browsing.
///
/// So nothing here touches the camera. The still is generated once, on a
/// background queue, with a short warm-up so temporal effects that read
/// history have something to read, and the render is bounded and cancellable.
/// The rail asks for a thumbnail when a card scrolls into view; a card that
/// has never been seen simply has no image, which is the same as today.
@MainActor
final class GVEffectThumbnailStore: ObservableObject {
    static let shared = GVEffectThumbnailStore()

    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "greyvision.thumbnails", qos: .utility, attributes: .concurrent)
    private var inFlight: Set<WorkspaceAdjustableEffect> = []
    private var directory: URL?
    /// Effects the operator has no reason to preview, or that cannot be
    /// rendered headlessly. Keeps the store from being asked for work that
    /// would fail every time.
    private static let ineligible: Set<WorkspaceAdjustableEffect> = [
        .spectrumBars, .radialSpectrum, .lissajous, .vectorscope, .waveformMonitor, .rgbParade
    ]

    private init() {
        cache.countLimit = 96
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("EffectThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directory = dir
    }

    /// The cached image for an effect, if one has been rendered.
    func image(for effect: WorkspaceAdjustableEffect) -> UIImage? {
        cache.object(forKey: effect.rawValue as NSString)
    }

    /// Renders the thumbnail if it is not already known. Safe to call from
    /// `onAppear` for every card: repeats collapse, and a second call for an
    /// effect already in the memory cache does nothing at all.
    func request(_ effect: WorkspaceAdjustableEffect) {
        guard !Self.ineligible.contains(effect),
              cache.object(forKey: effect.rawValue as NSString) == nil,
              !inFlight.contains(effect)
        else { return }
        inFlight.insert(effect)
        queue.async { [weak self] in
            guard let self else { return }
            let image = self.render(effect)
            Task { @MainActor in
                self.inFlight.remove(effect)
                guard let image else { return }
                self.cache.setObject(image, forKey: effect.rawValue as NSString)
                self.write(image, for: effect)
            }
        }
    }

    /// Whether this effect can be previewed headlessly at all.
    static func isEligible(_ effect: WorkspaceAdjustableEffect) -> Bool {
        !ineligible.contains(effect)
    }

    // MARK: - Disk

    private func fileURL(for effect: WorkspaceAdjustableEffect) -> URL? {
        directory?.appendingPathComponent("\(effect.rawValue).png")
    }

    private func write(_ image: UIImage, for effect: WorkspaceAdjustableEffect) {
        guard let url = fileURL(for: effect),
              let data = image.pngData()
        else { return }
        // Caches directory: this is disposable, and the OS may reclaim it.
        try? data.write(to: url, options: .atomic)
    }

    private func readCached(_ effect: WorkspaceAdjustableEffect) -> UIImage? {
        guard let url = fileURL(for: effect) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    // MARK: - Rendering

    /// The reference still.
    ///
    /// Generated rather than bundled for two reasons: it has to be
    /// resolution-independent to whatever card size the rail settles on, and
    /// it has to carry structure. A flat grey would make every threshold,
    /// edge and sort effect render to a featureless field, and a thumbnail
    /// that cannot show what the effect does is worse than no thumbnail.
    private func makeReferenceStill(width: Int, height: Int) -> CGImage? {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let cg = context.cgContext
            // Vertical gradient, dark to light, so luma-dependent effects have
            // a full range to work with.
            let colors = [
                UIColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1).cgColor,
                UIColor(red: 0.55, green: 0.48, blue: 0.62, alpha: 1).cgColor,
                UIColor(red: 0.95, green: 0.86, blue: 0.70, alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 0.55, 1]
            ) {
                cg.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: 0, y: size.height),
                    options: []
                )
            }
            // A bright disc and a few hard edges: what a threshold, a sort or
            // an edge filter actually has to find in a frame.
            cg.setFillColor(UIColor.white.withAlphaComponent(0.92).cgColor)
            cg.fillEllipse(in: CGRect(
                x: size.width * 0.18,
                y: size.height * 0.24,
                width: size.width * 0.30,
                height: size.height * 0.30
            ))
            cg.setFillColor(UIColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 1).cgColor)
            for index in 0 ..< 5 {
                let barWidth = size.width * 0.06
                let x = size.width * (0.56 + Double(index) * 0.08)
                cg.fill(CGRect(x: x, y: size.height * 0.12, width: barWidth, height: size.height * 0.76))
            }
        }
        return image.cgImage
    }

    /// Runs the effect over the reference still.
    ///
    /// The render is a plain compute-free CPU path on purpose: a GPU context
    /// would need a device, a queue and a command buffer per thumbnail, and
    /// 192 of those from a utility queue while the operator is holding a take
    /// is exactly the kind of thing that shows up as a dropped frame. The
    /// style kernels that need a GPU are declared ineligible by the caller,
    /// and a card that cannot be thumbnailed simply keeps its text.
    private func render(_ effect: WorkspaceAdjustableEffect) -> UIImage? {
        let width = 256
        let height = 256
        guard let source = makeReferenceStill(width: width, height: height) else { return nil }
        guard !Self.gpuOnlyEffects.contains(effect) else { return nil }
        guard let output = applyCPUKernel(effect, to: source, width: width, height: height) else { return nil }
        return UIImage(cgImage: output)
    }

    /// Effects whose kernels are fragment-shader only. There is no honest CPU
    /// stand-in for these, and a thumbnail that showed something other than
    /// what the effect does would be worse than a blank card.
    private static let gpuOnlyEffects: Set<WorkspaceAdjustableEffect> = [
        .fluid, .reactionGarden, .kuwahara, .dctBlocks, .blueNoiseDither,
        .hologram, .anamorphicFlare, .bokeh, .voronoi, .worleyCracks
    ]

    /// A small, deliberately plain preview of the family's character: geometry
    /// for the geometric families, smear for the temporal ones, quantisation
    /// for the block ones. It is not the shader — it is a legible stand-in, and
    /// the card's own detail line still says what the effect is.
    private func applyCPUKernel(
        _ effect: WorkspaceAdjustableEffect,
        to source: CGImage,
        width: Int,
        height: Int
    ) -> CGImage? {
        let ci = CIImage(cgImage: source)
        let output: CIImage?
        switch effect.curatedFamily?.title {
        case "FORM":
            let rotated = ci.transformed(by: CGAffineTransform(rotationAngle: .pi / 6))
                .cropped(to: ci.extent)
            output = rotated.applyingFilter("CIMirror", parameters: ["inputAxis": 0])
        case "DECAY":
            output = ci.applyingFilter("CIPosterize", parameters: ["inputLevels": 5.0])
        case "TIME", "MOTION":
            // A horizontal smear, which is what most of these families do.
            output = ci.applyingFilter("CIMotionBlur", parameters: [
                kCIInputBackgroundImageKey: ci,
                kCIInputAmountKey: 9.0
            ])
        case "SIGNAL":
            output = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 2.2
            ])
        case "OPTICS":
            output = ci.applyingFilter("CIGaussianBlur", parameters: [
                kCIInputBackgroundImageKey: ci,
                kCIInputRadiusKey: 7.0
            ]).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.4])
        case "COLOR":
            output = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.6,
                kCIInputBrightnessKey: 0.08
            ])
        case "SCOPE", "AUDIO":
            output = nil
        default:
            output = ci.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.72])
        }
        guard let output else { return nil }
        let context = CIContext(options: [.cacheIntermediates: false])
        return context.createCGImage(output, from: CGRect(x: 0, y: 0, width: width, height: height))
    }
}
