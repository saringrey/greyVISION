import Combine
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import simd
import UIKit

// MARK: - Esoteric designations

/// Procedural designation generator for tracked blobs. Deterministic for a
/// given (seed, index) pair so a blob keeps the same designation across frames
/// while the field itself is never reused.
enum EsotericLabelGenerator {
    private static let prefixes = [
        "VESPER", "THROAT", "ATRIUM", "SPECTER", "ORACLE", "HALCYON", "MONAD",
        "CHORUS", "AURIC", "NULL", "TELEM", "VEXIL", "OPHIDIAN", "CLOTHO",
        "CIPHER", "SABLE", "ARCANE", "LUCID", "EMPYREAN", "NOCTURNE"
    ]
    private static let stems = [
        "RING", "CORE", "VEIL", "TOOTH", "MIRROR", "GATE", "FONT", "SPINE",
        "LOOM", "WELL", "FOLD", "SIGNAL", "CIRCUIT", "HUM", "SHELL"
    ]
    private static let qualifiers = [
        "OF THE NEST", "BENEATH THE GRID", "AFTER CONTACT", "IN DELTA",
        "AT TERMINAL", "BEYOND RECALL", "UNDER GLASS", "WITHOUT NAME"
    ]
    private static let deltas = ["Δ", "Ω", "Σ", "Ψ", "Λ", "Θ"]

    static func label(for seed: UInt64, index: Int) -> String {
        let mixer = (seed &+ UInt64(index)) &* 0x9E37_79B9_7F4A_7C15
        let prefix = prefixes[Int((mixer >> 0) % UInt64(prefixes.count))]
        let stem = stems[Int((mixer >> 8) % UInt64(stems.count))]
        let qualifier = qualifiers[Int((mixer >> 16) % UInt64(qualifiers.count))]
        let delta = deltas[Int((mixer >> 24) % UInt64(deltas.count))]
        let numeral = UInt64((mixer >> 32) % 97) + 1
        return switch Int((mixer >> 40) % 3) {
        case 0: "\(prefix)-\(numeral)"
        case 1: "\(stem) \(delta) \(prefix)-\(numeral)"
        default: "\(prefix) \(qualifier) // \(numeral)"
        }
    }
}

// MARK: - Model

/// A connected color field detected on the live frame. `rect` is normalized to
/// the delivered (interface-oriented) image, so it maps to the preview with a
/// plain aspect-fill crop.
struct TrackedBlob: Identifiable, Equatable, Sendable {
    let id: UInt64
    var rect: CGRect
    var color: SIMD3<Float>
    var area: Float
    var label: String

    static let maxTracked = 12
}

struct BlobTrackingParameters: Equatable, Sendable {
    /// Analysis cell size as a fraction of the frame edge (0.02...0.12).
    var blockSize = 0.05
    /// Target hue in 0...1 (red is 0).
    var hue = 0.0
    /// Color distance tolerance 0...1. Lower is stricter.
    var tolerance = 0.30
    /// Minimum blob area as a fraction of the frame.
    var minArea = 0.004

    static let defaults = BlobTrackingParameters()

    var sanitized: BlobTrackingParameters {
        BlobTrackingParameters(
            blockSize: min(max(blockSize, 0.02), 0.12),
            hue: min(max(hue, 0), 1),
            tolerance: min(max(tolerance, 0.01), 1),
            minArea: min(max(minArea, 0.0005), 0.25)
        )
    }
}

struct BlobAnalysisResult: Sendable {
    let blobs: [TrackedBlob]
    let status: String
    let sourceSize: CGSize
}

// MARK: - Analyzer

/// CPU color-field analyzer. Consumes the latest delivered frame on its own
/// queue at a low cadence (~8 Hz) and never blocks the capture delegate: it
/// only retains the newest sample buffer until the next analysis tick.
final class BlobTracker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.saringrey.greyvision.blob", qos: .userInitiated)
    private let lock = NSLock()
    private var latestFrame: CapturedFrame?
    private var latestTimestamp = -Double.infinity
    private var parameters = BlobTrackingParameters.defaults
    private var isRunning = false
    private var resultHandler: (@Sendable (BlobAnalysisResult) -> Void)?
    private let seed: UInt64 = 0xB10B_5EED_2026

    func setParameters(_ parameters: BlobTrackingParameters) {
        lock.withLock {
            self.parameters = parameters.sanitized
        }
    }

    func submit(_ frame: CapturedFrame) {
        let timestamp = CMTimeGetSeconds(frame.presentationTime)
        lock.withLock {
            guard timestamp > latestTimestamp else { return }
            latestTimestamp = timestamp
            latestFrame = frame
        }
    }

    func start(resultHandler: @escaping @Sendable (BlobAnalysisResult) -> Void) {
        lock.withLock {
            guard !isRunning else { return }
            isRunning = true
            latestFrame = nil
            latestTimestamp = -Double.infinity
            self.resultHandler = resultHandler
        }
        queue.async { [weak self] in
            self?.loop()
        }
    }

    func stop() {
        lock.withLock {
            isRunning = false
            latestFrame = nil
            resultHandler = nil
        }
    }

    private func loop() {
        while true {
            let running = lock.withLock { isRunning }
            guard running else { return }
            let frame = lock.withLock { latestFrame }
            if let frame {
                let result = analyze(frame)
                let handler = lock.withLock { resultHandler }
                handler?(result)
            }
            Thread.sleep(forTimeInterval: 0.12)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func analyze(_ frame: CapturedFrame) -> BlobAnalysisResult {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer) else {
            return BlobAnalysisResult(blobs: [], status: "BLOB TRACKING // NO FRAME", sourceSize: .zero)
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0,
              CVPixelBufferGetPlaneCount(pixelBuffer) >= 2
        else {
            return BlobAnalysisResult(blobs: [], status: "BLOB TRACKING // BAD FORMAT", sourceSize: .zero)
        }
        let sourceSize = CGSize(width: width, height: height)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else {
            return BlobAnalysisResult(blobs: [], status: "BLOB TRACKING // NO PLANES", sourceSize: sourceSize)
        }
        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let parameters = lock.withLock { self.parameters }

        let columns = min(max(Int(Float(width) * Float(parameters.blockSize)), 6), 96)
        let rows = min(max(Int(Float(height) * Float(parameters.blockSize)), 6), 96)
        let cellWidth = Float(width) / Float(columns)
        let cellHeight = Float(height) / Float(rows)
        let targetHue = Float(parameters.hue)
        let tolerance = Float(parameters.tolerance)

        var active = [Bool](repeating: false, count: columns * rows)
        var cellColors = [SIMD3<Float>](repeating: .zero, count: columns * rows)
        let sampleFractions: [Float] = [0.25, 0.5, 0.75]

        for row in 0 ..< rows {
            for col in 0 ..< columns {
                var sum = SIMD3<Float>.zero
                var samples = 0
                for fractionY in sampleFractions {
                    for fractionX in sampleFractions {
                        let px = min(width - 1, Int(Float(col) * cellWidth + cellWidth * fractionX))
                        let py = min(height - 1, Int(Float(row) * cellHeight + cellHeight * fractionY))
                        let yValue = yBase.advanced(by: py * yBytesPerRow + px)
                            .assumingMemoryBound(to: UInt8.self).pointee
                        let uvIndex = (py / 2) * uvBytesPerRow + (px / 2) * 2
                        let cb = uvBase.advanced(by: uvIndex)
                            .assumingMemoryBound(to: UInt8.self).pointee
                        let cr = uvBase.advanced(by: uvIndex + 1)
                            .assumingMemoryBound(to: UInt8.self).pointee
                        let y = Float(yValue) / 255.0
                        let blueDifference = Float(cb) / 255.0 - 0.5
                        let redDifference = Float(cr) / 255.0 - 0.5
                        // BT.601. The delivered buffers are interface-rotated,
                        // so colors land exactly where the preview shows them.
                        sum += SIMD3<Float>(
                            min(max(y + 1.402 * redDifference, 0), 1),
                            min(max(y - 0.344136 * blueDifference - 0.714136 * redDifference, 0), 1),
                            min(max(y + 1.772 * blueDifference, 0), 1)
                        )
                        samples += 1
                    }
                }
                let color = sum / Float(max(samples, 1))
                let index = row * columns + col
                cellColors[index] = color
                let hsv = Self.rgbToHSV(color)
                let hueDelta = min(abs(hsv.x - targetHue), 1 - abs(hsv.x - targetHue))
                let distance = hueDelta * 0.72 + abs(hsv.y - 0.72) * 0.28
                active[index] = distance < tolerance
            }
        }

        // Connected components (4-neighborhood flood fill).
        var labels = [Int](repeating: -1, count: columns * rows)
        var nextLabel = 0
        var sizes: [Int] = []
        var colorSums: [SIMD3<Float>] = []
        var minColumns: [Int] = []
        var maxColumns: [Int] = []
        var minRows: [Int] = []
        var maxRows: [Int] = []

        for row in 0 ..< rows {
            for col in 0 ..< columns {
                let start = row * columns + col
                guard active[start], labels[start] == -1 else { continue }
                var stack = [start]
                labels[start] = nextLabel
                var count = 0
                var colorSum = SIMD3<Float>.zero
                var minColumn = col
                var maxColumn = col
                var minRow = row
                var maxRow = row
                while let current = stack.popLast() {
                    let currentColumn = current % columns
                    let currentRow = current / columns
                    count += 1
                    colorSum += cellColors[current]
                    minColumn = min(minColumn, currentColumn)
                    maxColumn = max(maxColumn, currentColumn)
                    minRow = min(minRow, currentRow)
                    maxRow = max(maxRow, currentRow)
                    let neighbors = [
                        (currentRow - 1, currentColumn),
                        (currentRow + 1, currentColumn),
                        (currentRow, currentColumn - 1),
                        (currentRow, currentColumn + 1)
                    ]
                    for (neighborRow, neighborColumn) in neighbors {
                        guard neighborRow >= 0, neighborRow < rows,
                              neighborColumn >= 0, neighborColumn < columns
                        else { continue }
                        let neighbor = neighborRow * columns + neighborColumn
                        if active[neighbor], labels[neighbor] == -1 {
                            labels[neighbor] = nextLabel
                            stack.append(neighbor)
                        }
                    }
                }
                sizes.append(count)
                colorSums.append(colorSum)
                minColumns.append(minColumn)
                maxColumns.append(maxColumn)
                minRows.append(minRow)
                maxRows.append(maxRow)
                nextLabel += 1
            }
        }

        let minimumCells = Float(columns * rows) * Float(parameters.minArea)
        var blobs: [TrackedBlob] = []
        for label in 0 ..< nextLabel {
            guard Float(sizes[label]) >= minimumCells else { continue }
            let rect = CGRect(
                x: CGFloat(minColumns[label]) / CGFloat(columns),
                y: CGFloat(minRows[label]) / CGFloat(rows),
                width: CGFloat(maxColumns[label] - minColumns[label] + 1) / CGFloat(columns),
                height: CGFloat(maxRows[label] - minRows[label] + 1) / CGFloat(rows)
            )
            let color = colorSums[label] / Float(max(sizes[label], 1))
            let id = Self.blobID(rect: rect)
            blobs.append(TrackedBlob(
                id: id,
                rect: rect,
                color: color,
                area: Float(sizes[label]) / Float(columns * rows),
                label: EsotericLabelGenerator.label(for: seed, index: Int(id % 1024))
            ))
        }
        blobs.sort { $0.area > $1.area }
        blobs = Array(blobs.prefix(TrackedBlob.maxTracked))
        let status = blobs.isEmpty
            ? "BLOB TRACKING // \(columns)×\(rows) CELLS // NO FIELD"
            : "BLOB TRACKING // \(blobs.count) FIELD\(blobs.count == 1 ? "" : "S") // \(columns)×\(rows) CELLS"
        return BlobAnalysisResult(blobs: blobs, status: status, sourceSize: sourceSize)
    }

    /// Position-quantized identity so a blob keeps its designation while it
    /// stays in the same cell region.
    private static func blobID(rect: CGRect) -> UInt64 {
        let cellX = UInt64(Int(rect.midX * 64) & 0xFF)
        let cellY = UInt64(Int(rect.midY * 64) & 0xFF)
        let width = UInt64(Int(rect.width * 64) & 0xFF)
        let height = UInt64(Int(rect.height * 64) & 0xFF)
        return cellX | (cellY << 8) | (width << 16) | (height << 24)
    }

    private static func rgbToHSV(_ color: SIMD3<Float>) -> SIMD3<Float> {
        let maximum = max(color.x, max(color.y, color.z))
        let minimum = min(color.x, min(color.y, color.z))
        let delta = maximum - minimum
        var hue: Float = 0
        if delta > 0.0001 {
            if maximum == color.x {
                hue = ((color.y - color.z) / delta).truncatingRemainder(dividingBy: 6)
            } else if maximum == color.y {
                hue = (color.z - color.x) / delta + 2
            } else {
                hue = (color.x - color.y) / delta + 4
            }
            hue /= 6
            if hue < 0 {
                hue += 1
            }
        }
        let saturation = maximum > 0.0001 ? delta / maximum : 0
        return SIMD3<Float>(hue, saturation, maximum)
    }
}

// MARK: - Runtime

@MainActor
final class BlobTrackingRuntime: ObservableObject {
    @Published var parameters = BlobTrackingParameters.defaults
    @Published private(set) var isEnabled = false
    @Published private(set) var blobs: [TrackedBlob] = []
    @Published private(set) var status = "BLOB TRACKING // OFFLINE"
    @Published private(set) var sourceSize = CGSize.zero

    private let tracker = BlobTracker()
    private var frameHandlerAttached = false
    private var lastBlobCount = 0
    private var lastBlobHapticTime: TimeInterval = 0

    func setParameters(_ parameters: BlobTrackingParameters) {
        self.parameters = parameters
        tracker.setParameters(parameters)
    }

    func start(using camera: CameraRuntime) {
        guard !isEnabled else { return }
        isEnabled = true
        status = "BLOB TRACKING // ANALYZING"
        tracker.setParameters(parameters)
        tracker.start { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, isEnabled else { return }
                blobs = result.blobs
                status = result.status
                if result.sourceSize.width > 0, result.sourceSize.height > 0 {
                    sourceSize = result.sourceSize
                }
                pulseFieldHaptic(count: result.blobs.count)
            }
        }
        camera.setFrameHandler { [weak tracker] frame in
            tracker?.submit(frame)
        }
        frameHandlerAttached = true
        GVLog.analysis.notice("Blob field tracking started")
    }

    func stop(using camera: CameraRuntime) {
        guard isEnabled else { return }
        isEnabled = false
        tracker.stop()
        if frameHandlerAttached {
            camera.setFrameHandler(nil)
            frameHandlerAttached = false
        }
        blobs = []
        status = "BLOB TRACKING // OFFLINE"
        lastBlobCount = 0
        GVLog.analysis.notice("Blob field tracking stopped")
    }

    /// A single selection tick when the tracked field count changes. The
    /// analyser runs at ~8 Hz, so the count is gated to at most one tick per
    /// second to keep the haptic from stuttering on a jittery field.
    private func pulseFieldHaptic(count: Int) {
        let now = CACurrentMediaTime()
        guard count != lastBlobCount, now - lastBlobHapticTime > 1 else {
            lastBlobCount = count
            return
        }
        lastBlobCount = count
        lastBlobHapticTime = now
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
