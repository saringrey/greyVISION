import Foundation

/// A named starting point for the tracking suite: a detection mode plus the
/// tracking and drawing setup that suits it. Every preset is a complete
/// `BlobTrackingParameters`; the deck then tunes it like any other setup.
struct GVTrackingPreset: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let detail: String
    let parameters: BlobTrackingParameters

    var symbol: String { parameters.mode.symbol }

    static let all: [GVTrackingPreset] = [
        // Plain blob tracking first: white boxes, numbered, nothing else.
        make("blobTrack", "Blob Track", "Classic blob tracking: numbered boxes on whatever stands out") {
            $0.mode = .blob
            $0.threshold = 0.6
            $0.style = .box
            $0.labels = .identifier
            $0.palette = .mono
            $0.trails = 0
            $0.glow = 0
            $0.showCentroids = true
            $0.merge = 1
            $0.maxTracks = 12
        },
        make("lockOn", "Lock On", "Targeting locks with hairlines across the frame") {
            $0.mode = .blob
            $0.threshold = 0.66
            $0.style = .lockOn
            $0.labels = .telemetry
            $0.palette = .mono
            $0.maxTracks = 3
            $0.smoothing = 0.7
            $0.glow = 0.25
        },
        make("colorLock", "Color Lock", "Locks onto one hue and names what it finds") {
            $0.mode = .color
            $0.hue = 0.0
            $0.tolerance = 0.32
            $0.style = .brackets
            $0.labels = .designation
        },
        make("highlightHunter", "Highlight Hunter", "Follows the brightest light with long trails") {
            $0.mode = .bright
            $0.threshold = 0.72
            $0.style = .crosshair
            $0.labels = .coordinates
            $0.trails = 0.8
            $0.glow = 0.7
        },
        make("shadowSeeker", "Shadow Seeker", "Boxes the darkest masses in the frame") {
            $0.mode = .shadow
            $0.threshold = 0.6
            $0.style = .box
            $0.labels = .telemetry
            $0.merge = 2
        },
        make("neonWeb", "Neon Web", "Vivid colour fields strung together in a web") {
            $0.mode = .vivid
            $0.threshold = 0.55
            $0.style = .ring
            $0.links = .web
            $0.palette = .spectrum
            $0.labels = .none
            $0.maxTracks = 12
            $0.glow = 0.8
        },
        make("motionSwarm", "Motion Swarm", "Every moving thing, with velocity vectors") {
            $0.mode = .motion
            $0.threshold = 0.55
            $0.style = .dot
            $0.labels = .none
            $0.showVectors = true
            $0.trails = 0.6
            $0.maxTracks = 16
            $0.minArea = 0.002
            $0.persistence = 0.25
            $0.smoothing = 0.4
        },
        make("heatMask", "Heat Mask", "Shows the raw motion field as a dithered mask") {
            $0.mode = .motion
            $0.threshold = 0.5
            $0.showMask = true
            $0.style = .box
            $0.labels = .identifier
            $0.palette = .mono
            $0.resolution = 0.7
        },
        make("skinTone", "Skin Tone", "Follows skin without a face detector") {
            $0.mode = .skin
            $0.tolerance = 0.35
            $0.style = .target
            $0.labels = .identifier
            $0.merge = 2
        },
        make("faceLock", "Face Lock", "Target reticles with face landmarks") {
            $0.mode = .face
            $0.style = .target
            $0.labels = .telemetry
            $0.smoothing = 0.65
            $0.persistence = 0.8
            $0.confirm = 1
        },
        make("handTrace", "Hand Trace", "Full hand skeletons with fingertip trails") {
            $0.mode = .hand
            $0.style = .dot
            $0.labels = .identifier
            $0.trails = 0.7
            $0.maxTracks = 2
            $0.confirm = 1
            $0.smoothing = 0.45
            $0.rate = 24
        },
        make("bodyRig", "Body Rig", "Pose skeletons for everyone in frame") {
            $0.mode = .body
            $0.style = .brackets
            $0.labels = .designation
            $0.confirm = 1
            $0.rate = 20
        },
        make("saliencyScout", "Saliency Scout", "Brackets whatever the eye would land on") {
            $0.mode = .salient
            $0.style = .brackets
            $0.labels = .telemetry
            $0.confidence = 0.2
            $0.smoothing = 0.7
            $0.rate = 10
        },
        make("petCam", "Pet Cam", "Finds cats and dogs and names them") {
            $0.mode = .animal
            $0.style = .brackets
            $0.labels = .designation
            $0.confidence = 0.3
            $0.smoothing = 0.65
            $0.persistence = 0.8
            $0.confirm = 1
            $0.rate = 12
        },
        make("textHunter", "Text Hunter", "Boxes every word in view") {
            $0.mode = .text
            $0.style = .box
            $0.labels = .none
            $0.palette = .mono
            $0.maxTracks = 16
            $0.smoothing = 0.5
            $0.confirm = 1
            $0.rate = 12
        },
        make("frameFinder", "Frame Finder", "Outlines screens, pages and frames, corner to corner") {
            $0.mode = .shape
            $0.style = .dot
            $0.labels = .telemetry
            $0.confidence = 0.5
            $0.maxTracks = 4
            $0.smoothing = 0.6
            $0.confirm = 1
            $0.rate = 15
        },
        make("constellation", "Constellation", "Bright points chained into a star map") {
            $0.mode = .bright
            $0.threshold = 0.66
            $0.style = .dot
            $0.links = .chain
            $0.labels = .designation
            $0.palette = .mono
            $0.maxTracks = 12
            $0.minArea = 0.001
            $0.glow = 0.9
        }
    ]

    private static func make(_ id: String, _ name: String, _ detail: String,
                             _ configure: (inout BlobTrackingParameters) -> Void) -> GVTrackingPreset
    {
        var parameters = BlobTrackingParameters.defaults
        configure(&parameters)
        return GVTrackingPreset(id: id, name: name, detail: detail, parameters: parameters.sanitized)
    }

    /// The preset the current setup started from, if it still matches on mode.
    static func matching(_ parameters: BlobTrackingParameters) -> GVTrackingPreset? {
        all.first { $0.parameters == parameters }
    }
}
