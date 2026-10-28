import Foundation

/// Effects removed from the catalogue, and what replaced each one.
///
/// Saved recipes, presets, takes' performance metadata, favourites, recents
/// and the Mac control surface all name effects by raw value. Removing a case
/// outright would make every one of those fail to decode — a whole recipe lost
/// because one slot named a retired effect. Instead each retired name resolves
/// to the surviving effect that does the same job better, so old work opens
/// with the closest look the app still has.
///
/// Entries are permanent. A name removed from this table makes every saved
/// file that still uses it unreadable again.
extension WorkspaceAdjustableEffect {
    /// Retired in the October 2026 effect audit, each for looking like a
    /// stronger sibling or for barely changing the frame at its defaults.
    static let retiredReplacements: [String: WorkspaceAdjustableEffect] = [
        // Same construction, the survivor is the more striking of the two.
        "audioKaleido": .kaleidoscope,
        "astralPlasma": .nebulaDrift,
        "singularityLens": .eventHorizon,
        "twirl": .spiralWarp,
        "fractalZoom": .fractalBurst,
        "barrelWarp": .fisheye,
        "chromaticAberration": .rgbSplit,
        "audioChromaPulse": .audioSpectral,
        "blueNoiseDither": .dither,
        "halftone": .cmykPress,
        "worleyCracks": .shatter,
        "voronoi": .hexTile,
        "curlWarp": .flowField,
        "wave": .vectorWarp,
        "spectralNova": .waveformTunnel,
        "particleLife": .neonOrbit,
        "voxelStorm": .pixelConfetti,
        "audioGrain": .grain,
        "corrode": .ashDrift,
        "depthFeedback": .feedback,
        "rollingTime": .shearStack,
        "opticalFlowLiquid": .liquidMosh,
        // Near-invisible at their defaults, with a sibling that does the job.
        "bokeh": .softFocus,
        "tapeWarp": .vhsTracking,
        "interlace": .crt,
        "printThrough": .super8,
        "dctBlocks": .audioMacroblock,
        "audioPosterize": .posterize,
        "topography": .contourLines,
        "depthSort": .sort,
        "objectSort": .sort,
        "lumaExtrusion": .pointCloudSmear,
    ]

    /// Current effect for a stored identifier: the effect itself, or the
    /// survivor of a retired one.
    static func resolving(_ identifier: String) -> WorkspaceAdjustableEffect? {
        Self(rawValue: identifier) ?? retiredReplacements[identifier]
    }

    init(from decoder: Decoder) throws {
        let identifier = try decoder.singleValueContainer().decode(String.self)
        guard let effect = Self.resolving(identifier) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown effect \(identifier)"
            ))
        }
        self = effect
    }
}
