import CoreGraphics
import Foundation
import simd

// MARK: - Modes

/// What the tracker treats as a subject.
///
/// The first seven segment a coarse analysis grid on the CPU; the rest ask
/// Vision. Both produce the same `GVTrackingDetection`, so association,
/// smoothing and drawing never need to know which kind of detector ran.
enum GVTrackingMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Classic blob tracking: anything that stands out from its surroundings,
    /// light or dark, with no colour or class to key on.
    case blob
    case color
    case bright
    case shadow
    case vivid
    case motion
    case skin
    case face
    case hand
    case body
    case salient
    case animal
    case text
    /// Rectangles: screens, papers, frames, signs. Corners come back as a quad.
    case shape

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blob: "Blobs"
        case .color: "Color"
        case .bright: "Bright"
        case .shadow: "Shadow"
        case .vivid: "Vivid"
        case .motion: "Motion"
        case .skin: "Skin"
        case .face: "Faces"
        case .hand: "Hands"
        case .body: "Bodies"
        case .salient: "Salient"
        case .animal: "Animals"
        case .text: "Text"
        case .shape: "Shapes"
        }
    }

    var symbol: String {
        switch self {
        case .blob: "circle.hexagongrid"
        case .color: "eyedropper"
        case .bright: "sun.max"
        case .shadow: "moon"
        case .vivid: "paintpalette"
        case .motion: "wind"
        case .skin: "hand.raised.fingers.spread"
        case .face: "face.dashed"
        case .hand: "hand.point.up.left"
        case .body: "figure.stand"
        case .salient: "scope"
        case .animal: "pawprint"
        case .text: "textformat"
        case .shape: "rectangle.dashed"
        }
    }

    /// Vision-backed modes have no colour or level to key, so the deck hides
    /// those controls instead of offering knobs that do nothing.
    var usesVision: Bool {
        switch self {
        case .face, .hand, .body, .salient, .animal, .text, .shape: true
        default: false
        }
    }

    var usesHue: Bool { self == .color }
    var usesThreshold: Bool { [.blob, .bright, .shadow, .vivid, .motion].contains(self) }
    var usesTolerance: Bool { self == .color || self == .skin }

    /// Kind word drawn in labels and the HUD.
    var noun: String {
        switch self {
        case .face: "FACE"
        case .hand: "HAND"
        case .body: "BODY"
        case .salient: "OBJECT"
        case .motion: "MOVER"
        case .blob: "BLOB"
        case .animal: "ANIMAL"
        case .text: "TEXT"
        case .shape: "QUAD"
        default: "FIELD"
        }
    }
}

// MARK: - Drawing options

enum GVTrackingStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case brackets, box, crosshair, ring, target, dot
    /// A targeting lock: corner-ticked box with hairlines across the frame
    /// through the subject's centre.
    case lockOn
    var id: String { rawValue }
    var label: String {
        switch self {
        case .lockOn: "Lock"
        case .brackets: "Brackets"
        case .box: "Box"
        case .crosshair: "Cross"
        case .ring: "Ring"
        case .target: "Target"
        case .dot: "Dot"
        }
    }
}

enum GVTrackingLabel: String, CaseIterable, Codable, Sendable, Identifiable {
    case designation, identifier, coordinates, telemetry, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .designation: "Name"
        case .identifier: "ID"
        case .coordinates: "XY"
        case .telemetry: "Data"
        case .none: "Off"
        }
    }
}

enum GVTrackingLinks: String, CaseIterable, Codable, Sendable, Identifiable {
    case none, chain, nearest, web
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "Off"
        case .chain: "Chain"
        case .nearest: "Nearest"
        case .web: "Web"
        }
    }
}

enum GVTrackingPalette: String, CaseIterable, Codable, Sendable, Identifiable {
    case field, mono, spectrum
    var id: String { rawValue }
    var label: String {
        switch self {
        case .field: "Field"
        case .mono: "Mono"
        case .spectrum: "Spectrum"
        }
    }
}

// MARK: - Parameters

/// Every control the tracking suite exposes. Codable so the operator's setup
/// survives relaunch; each field decodes independently, so a parameter added
/// later never invalidates a stored setup.
struct BlobTrackingParameters: Codable, Equatable, Sendable {
    var mode = GVTrackingMode.blob

    // Detect
    /// Target hue, 0...1 (red is 0). Color mode only.
    var hue = 0.0
    /// Colour distance accepted as a match, 0...1. Color and skin modes.
    var tolerance = 0.30
    /// Level a cell must clear, 0...1. Bright, shadow, vivid and motion.
    var threshold = 0.62
    /// Smallest subject kept, as a fraction of the frame.
    var minArea = 0.004
    /// Largest subject kept, as a fraction of the frame. Rejects a key that
    /// has swallowed the whole background.
    var maxArea = 0.6
    /// Analysis grid density, 0...1 → 24...160 cells on the long edge.
    var resolution = 0.5
    /// Dilation passes that bridge small gaps between cells, 0...3.
    var merge = 1.0
    /// Vision confidence floor, 0...1. Vision modes only.
    var confidence = 0.4

    // Track
    /// Most subjects followed at once, 1...16.
    var maxTracks = 8.0
    /// Position smoothing, 0 (raw) ... 0.95 (heavy).
    var smoothing = 0.55
    /// Seconds a lost subject is coasted on its last velocity before it drops.
    var persistence = 0.4
    /// How far ahead the drawn position leads the measured one, 0...1.
    var prediction = 0.5
    /// Largest jump, as a fraction of the frame, still treated as the same subject.
    var matchRadius = 0.18
    /// Analysis passes per second, 5...60. Vision modes are capped at 30.
    var rate = 15.0
    /// Consecutive detections before a new subject is shown, 1...6.
    var confirm = 2.0

    // Draw
    var style = GVTrackingStyle.brackets
    var labels = GVTrackingLabel.designation
    var links = GVTrackingLinks.none
    var palette = GVTrackingPalette.field
    /// Trail length, 0...1 → 0...48 samples.
    var trails = 0.35
    /// Stroke weight in points, 0.5...3.
    var lineWidth = 1.0
    /// Glow around marks, 0...1.
    var glow = 0.35
    var showVectors = false
    var showCentroids = true
    var showMask = false

    static let defaults = BlobTrackingParameters()

    init() {}

    var sanitized: BlobTrackingParameters {
        var value = self
        func clamp(_ x: Double, _ range: ClosedRange<Double>) -> Double {
            x.isFinite ? min(max(x, range.lowerBound), range.upperBound) : range.lowerBound
        }
        value.hue = clamp(hue, 0 ... 1)
        value.tolerance = clamp(tolerance, 0.01 ... 1)
        value.threshold = clamp(threshold, 0 ... 1)
        value.minArea = clamp(minArea, 0.0005 ... 0.25)
        value.maxArea = clamp(max(maxArea, value.minArea), 0.01 ... 1)
        value.resolution = clamp(resolution, 0 ... 1)
        value.merge = clamp(merge.rounded(), 0 ... 3)
        value.confidence = clamp(confidence, 0 ... 1)
        value.maxTracks = clamp(maxTracks.rounded(), 1 ... 16)
        value.smoothing = clamp(smoothing, 0 ... 0.95)
        value.persistence = clamp(persistence, 0 ... 2)
        value.prediction = clamp(prediction, 0 ... 1)
        value.matchRadius = clamp(matchRadius, 0.02 ... 0.5)
        value.rate = clamp(rate.rounded(), 5 ... (mode.usesVision ? 30 : 60))
        value.confirm = clamp(confirm.rounded(), 1 ... 6)
        value.trails = clamp(trails, 0 ... 1)
        value.lineWidth = clamp(lineWidth, 0.5 ... 3)
        value.glow = clamp(glow, 0 ... 1)
        return value
    }

    /// Grid cells on the frame's long edge.
    var gridLongEdge: Int { Int((24 + sanitized.resolution * 136).rounded()) }
    /// Trail samples kept per subject.
    var trailCapacity: Int { Int((sanitized.trails * 48).rounded()) }

    private enum CodingKeys: String, CodingKey {
        case mode, hue, tolerance, threshold, minArea, maxArea, resolution, merge, confidence
        case maxTracks, smoothing, persistence, prediction, matchRadius, rate, confirm
        case style, labels, links, palette, trails, lineWidth, glow
        case showVectors, showCentroids, showMask
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BlobTrackingParameters.defaults
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        mode = value(.mode, d.mode)
        hue = value(.hue, d.hue)
        tolerance = value(.tolerance, d.tolerance)
        threshold = value(.threshold, d.threshold)
        minArea = value(.minArea, d.minArea)
        maxArea = value(.maxArea, d.maxArea)
        resolution = value(.resolution, d.resolution)
        merge = value(.merge, d.merge)
        confidence = value(.confidence, d.confidence)
        maxTracks = value(.maxTracks, d.maxTracks)
        smoothing = value(.smoothing, d.smoothing)
        persistence = value(.persistence, d.persistence)
        prediction = value(.prediction, d.prediction)
        matchRadius = value(.matchRadius, d.matchRadius)
        rate = value(.rate, d.rate)
        confirm = value(.confirm, d.confirm)
        style = value(.style, d.style)
        labels = value(.labels, d.labels)
        links = value(.links, d.links)
        palette = value(.palette, d.palette)
        trails = value(.trails, d.trails)
        lineWidth = value(.lineWidth, d.lineWidth)
        glow = value(.glow, d.glow)
        showVectors = value(.showVectors, d.showVectors)
        showCentroids = value(.showCentroids, d.showCentroids)
        showMask = value(.showMask, d.showMask)
    }
}

// MARK: - Detections and tracks

/// One subject found in one analysis frame. Rects and points are normalised
/// to the analysed frame with a top-left origin, matching the preview.
struct GVTrackingDetection: Sendable, Equatable {
    var rect: CGRect
    var color: SIMD3<Float>
    var area: Float
    var confidence: Float
    /// Pose joints or landmarks, when the detector supplies them.
    var joints: [CGPoint] = []
    /// Index pairs into `joints` drawn as a skeleton.
    var bones: [[Int]] = []
    /// What the detector says this is ("CAT", "DOG"), when it classifies.
    var kind: String?
}

/// A followed subject: a detection with identity, smoothing and history.
struct TrackedBlob: Identifiable, Equatable, Sendable {
    let id: UInt64
    /// Smoothed position at `timestamp`.
    var rect: CGRect
    /// Normalised units per second, from the alpha-beta filter.
    var velocity: CGVector
    var color: SIMD3<Float>
    var area: Float
    var confidence: Float
    var label: String
    /// Seconds since the subject was first confirmed.
    var age: Double
    /// True while the subject is lost and being carried on its velocity.
    var isCoasting: Bool
    /// Recent centres, oldest first.
    var trail: [CGPoint]
    var joints: [CGPoint]
    var bones: [[Int]]

    static let maxTracked = 16
}

/// What one analysis pass hands to the interface.
struct BlobAnalysisResult: Sendable {
    let blobs: [TrackedBlob]
    let status: String
    let sourceSize: CGSize
    /// Uptime the analysed frame was rendered, for prediction between passes.
    let timestamp: Double
    /// Active cells of the field grid, row-major, when a field mode ran.
    let mask: GVTrackingMask?
    /// Analysis passes completed per second, measured.
    let passRate: Double
    /// Where the analysed frame sits in the full working frame.
    let region: CGRect
}

struct GVTrackingMask: Sendable, Equatable {
    let columns: Int
    let rows: Int
    let cells: [UInt8]
}
