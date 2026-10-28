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
    /// Retired in the October 2026 effect audit and consolidation, each for
    /// looking like a stronger sibling or for barely changing the frame.
    static let retiredReplacements: [String: WorkspaceAdjustableEffect] = [
        // Same construction, the survivor is the more striking of the two.
        "audioKaleido": .kaleidoscope,
        "astralPlasma": .nebulaDrift,
        "singularityLens": .eventHorizon,
        "twirl": .spiralWarp,
        "fractalZoom": .fractalBurst,
        "barrelWarp": .fisheye,
        "chromaticAberration": .rgbSplit,
        "audioChromaPulse": .audioTunnel,
        "blueNoiseDither": .dither,
        "halftone": .cmykPress,
        "worleyCracks": .shatter,
        "voronoi": .hexTile,
        "curlWarp": .flowField,
        "wave": .flowField,
        "spectralNova": .waveformTunnel,
        "particleLife": .singularityWeave,
        "voxelStorm": .pixelConfetti,
        "audioGrain": .grain,
        "corrode": .burnThrough,
        "depthFeedback": .feedback,
        "rollingTime": .dataBend,
        "opticalFlowLiquid": .liquidMosh,
        // Near-invisible at their defaults, with a sibling that does the job.
        "bokeh": .tiltShift,
        "tapeWarp": .vhs,
        "interlace": .crt,
        "printThrough": .super8,
        "dctBlocks": .audioRepair,
        "audioPosterize": .posterize,
        "topography": .contourLines,
        "depthSort": .sort,
        "objectSort": .sort,
        "lumaExtrusion": .pointCloudSmear,
        // October 2026 consolidation: only high-impact, high-fidelity looks
        // remain. Each name below resolves to the survivor nearest in look;
        // the frame scopes, which have no look equivalent, resolve to the
        // spectrum overlay, the nearest instrument still shipping.
        "temporalPixelSort": .sort,
        "freezeBrush": .frameHoldSmear,
        "sortBrush": .sort,
        "pixelGravity": .frameHoldSmear,
        "motionBloom": .trails,
        "prismStreak": .lightLeak,
        "vectorWarp": .flowField,
        "audioSpectral": .audioTunnel,
        "audioWaveform": .spectrumBars,
        "audioBloom": .audioKick,
        "bufferUnderrun": .frameTear,
        "packetLoss": .frameTear,
        "chromaFailure": .rgbSplit,
        "causalSmear": .timeFracture,
        "realityCavitation": .antiCamera,
        "memoryBurnIn": .echo,
        "spectralDepth": .echo,
        "vectorNecromancy": .trails,
        "worldFeedback": .feedback,
        "timeGraffiti": .trails,
        "freeze": .echo,
        "ripple": .water,
        "signalTear": .frameTear,
        "vignette": .super8,
        "emboss": .edge,
        "solarize": .posterize,
        "hueShift": .falseColor,
        "sharpen": .edge,
        "touchWarp": .water,
        "hatch": .dither,
        "phosphor": .crt,
        "lensDirt": .lightLeak,
        "starFilter": .anamorphicFlare,
        "softFocus": .tiltShift,
        "halation": .lightLeak,
        "vhsTracking": .vhs,
        "chromaBleed": .vhs,
        "dropout": .vhs,
        "colorBarTear": .frameTear,
        "degauss": .crt,
        "shearStack": .dataBend,
        "lensArray": .hexTile,
        "plasma": .flowField,
        "gradientMap": .falseColor,
        "edgeGlow": .contourLines,
        "reactionBands": .contourLines,
        "ashDrift": .burnThrough,
        "audioMacroblock": .audioRepair,
        "audioFracture": .audioRepair,
        "audioStretch": .audioScanBend,
        "spectralTint": .audioTunnel,
        "mirror": .quadMirror,
        "lensWarp": .fisheye,
        "frostedGlass": .hexTile,
        "domainWarp": .flowField,
        "lissajous": .radialSpectrum,
        "vectorscope": .spectrumBars,
        "waveformMonitor": .spectrumBars,
        "rgbParade": .spectrumBars,
        "moshBrush": .datamosh,
        "timeMap": .slitScan,
        "neuralFlow": .cyberGrid,
        "spectralFlower": .waveformTunnel,
        "glitchWeave": .hologramMatrix,
        "causticReactor": .liquidChroma,
        "prismPortal": .eventHorizon,
        "neonOrbit": .singularityWeave,
        "chromeRipple": .singularityWeave,
        "laserGarden": .cyberGrid,
        "hyperBloom": .holoAurora,
        "solarFlare": .holoAurora,
        "candyMesh": .cyberGrid,
        "auroraGlass": .liquidChroma,
        "cosmicKnot": .singularityWeave,
        "quantumBloom": .singularityWeave,
        "plasmaRipple": .singularityWeave,
        "chromascrape": .hologramMatrix,
        "vortexPulse": .singularityWeave,
        "ionStorm": .nebulaDrift,
        "opalWave": .liquidChroma,
        "spectralDiffraction": .anamorphicFlare,
        "reactionGarden": .fluid,
        "vectorCodebook": .datamosh,
        "motionTransplant": .datamosh,
        "bitplaneLatch": .bitRot,
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
