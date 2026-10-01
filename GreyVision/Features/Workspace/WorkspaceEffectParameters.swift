// swiftlint:disable file_length
import Foundation

enum WorkspaceAdjustableEffect: String, CaseIterable, Identifiable, Codable, Sendable {
    case rgbSplit
    case datamosh
    case liquidMosh
    case heavyMosh
    case predictionDrift
    case sort
    case depthSort
    case objectSort
    case radialSort
    case temporalPixelSort
    case pointCloudSmear
    case depthFeedback
    case freezeBrush
    case sortBrush
    case feedbackTunnel
    case lumaExtrusion
    case opticalFlowLiquid
    case rollingTime
    case frameHoldSmear
    case pixelGravity
    case pixelShift
    case slitScan
    case motionBloom
    case dataBend
    case prismStreak
    case vectorWarp
    case audioSpectral
    case audioScanBend
    case audioChromaPulse
    case audioWaveform
    case audioBandSlice
    case audioBloom
    case audioKick
    // DAMAGE. Signal/sensor failure modes. All five read the shared
    // history ring, so what they preserve or replay is genuinely older
    // imagery rather than a synthesised artefact drawn over the frame.
    case frameTear
    case bufferUnderrun
    case packetLoss
    case chromaFailure
    case sensorSmear
    // SARIN.DEV. Effects that treat motion, time and history as material
    // rather than as a source of decoration. All seven read the shared flow
    // field, the frame ring, or both.
    case causalSmear
    case realityCavitation
    case timeFracture
    case antiCamera
    case memoryBurnIn
    case spectralDepth
    case vectorNecromancy
    // World-anchored. These accumulate in a frame locked to the room rather
    // than to the screen, so turning the phone leaves the trail where it was
    // painted instead of dragging it along.
    case worldFeedback
    case timeGraffiti
    case feedback
    case trails
    case echo
    case freeze
    case ripple
    case pixelate
    case posterize
    case dither
    case edge
    case signalTear
    case vhs
    case vignette
    case grain
    case thermal
    case halftone
    case threshold
    case invert
    case solarize
    case hueShift
    case monochrome
    case sharpen
    case emboss
    case wave
    case crt
    case water
    case touchWarp
    case hatch
    case phosphor
    case voronoi
    case hologram
    case chromaticAberration
    case anamorphicFlare
    case bokeh
    case tiltShift
    case fisheye
    case lensDirt
    case lightLeak
    case starFilter
    case barrelWarp
    case softFocus
    case halation
    case vhsTracking
    case super8
    case chromaBleed
    case tapeWarp
    case dropout
    case colorBarTear
    case interlace
    case degauss
    case printThrough
    case polarWarp
    case twirl
    case hexTile
    case shatter
    case kaleido6
    case quadMirror
    case spiralWarp
    case shearStack
    case lensArray
    case fold
    case flowField
    case curlWarp
    case worleyCracks
    case plasma
    case contourLines
    case topography
    case gradientMap
    case falseColor
    case edgeGlow
    case reactionBands
    case pixelMelt
    case corrode
    case burnThrough
    case ashDrift
    case bitRot
    case audioMacroblock
    case audioFracture
    case audioStretch
    case audioRepair
    case audioTunnel
    case audioKaleido
    case audioGrain
    case audioDisplace
    case audioPosterize
    case spectralTint
    // Three complete style kernels that had no Swift case at all. Modes 7, 8
    // and 15 were implemented in the shader and unreachable from the app, and
    // the gap they left in the mode numbering is what made the registry's
    // contiguity assertion impossible to satisfy.
    case kaleidoscope
    case mirror
    case lensWarp
    // RENDER. Reconstruction filters rather than damage: each one rebuilds the
    // frame out of a different primitive.
    case kuwahara
    case asciiMosaic
    case frostedGlass
    case dctBlocks
    case domainWarp
    case blueNoiseDither
    // SCOPE. Measurement instruments, not filters. Three read the live FFT and
    // three read the frame itself; all six draw a reading over the image the
    // way a broadcast monitor does.
    case spectrumBars
    case radialSpectrum
    case lissajous
    case vectorscope
    case waveformMonitor
    case rgbParade
    /// Finger-painted motion corruption. Reads the touch uniform directly.
    case moshBrush
    /// Per-pixel history age driven by brightness.
    case timeMap
    /// Full Eulerian fluid solve. Runs its own multi-pass stage.
    case fluid
    // SHADERS. Colorful, interactive, audio-reactive GPU generative shaders.
    case cyberGrid
    case astralPlasma
    case quantumRaymarch
    case liquidChroma
    case holoAurora
    // NEW INTERACTIVE SHADERS - generative, audio-reactive, touch-responsive
    case neuralFlow
    case voxelStorm
    case fractalZoom
    case particleLife
    case waveformTunnel
    case spectralFlower
    case glitchWeave
    case hologramMatrix
    case singularityLens
    case causticReactor
    case eventHorizon
    // FULL COLOR. Fast, tactile component-inspired generative shaders.
    case prismPortal
    case neonOrbit
    case chromeRipple
    case laserGarden
    case hyperBloom
    case pixelConfetti
    case solarFlare
    case candyMesh
    case auroraGlass
    case cosmicKnot
    case nebulaDrift
    case quantumBloom
    case plasmaRipple
    case chromascrape
    case singularityWeave
    case fractalBurst
    case vortexPulse
    case spectralNova
    case ionStorm
    case opalWave
    case cmykPress
    case spectralDiffraction
    case reactionGarden
    case vectorCodebook
    case motionTransplant
    case bitplaneLatch

    var id: String {
        rawValue
    }
}

extension WorkspaceAdjustableEffect {
    static let metalRenderOrder: [WorkspaceAdjustableEffect] = [
        .rgbSplit,
        .ripple,
        .wave,
        .pixelate,
        .posterize,
        .dither,
        .halftone,
        .edge,
        .sharpen,
        .emboss,
        .threshold,
        .solarize,
        .hueShift,
        .monochrome,
        .thermal,
        .invert,
        .signalTear,
        .vhs,
        .grain,
        .vignette,
        .crt,
        .dataBend,
        .prismStreak,
        .vectorWarp,
        .audioSpectral,
        .audioScanBend,
        .audioChromaPulse,
        .audioWaveform,
        .audioBandSlice,
        .water,
        .touchWarp,
        .hatch,
        .phosphor,
        .voronoi,
        .hologram,
        .chromaticAberration,
        .anamorphicFlare,
        .bokeh,
        .tiltShift,
        .fisheye,
        .lensDirt,
        .lightLeak,
        .starFilter,
        .barrelWarp,
        .softFocus,
        .halation,
        .vhsTracking,
        .super8,
        .chromaBleed,
        .tapeWarp,
        .dropout,
        .colorBarTear,
        .interlace,
        .degauss,
        .printThrough,
        .polarWarp,
        .twirl,
        .hexTile,
        .shatter,
        .kaleido6,
        .quadMirror,
        .spiralWarp,
        .shearStack,
        .lensArray,
        .fold,
        .flowField,
        .curlWarp,
        .worleyCracks,
        .plasma,
        .contourLines,
        .topography,
        .gradientMap,
        .falseColor,
        .edgeGlow,
        .reactionBands,
        .pixelMelt,
        .corrode,
        .burnThrough,
        .ashDrift,
        .bitRot,
        .audioMacroblock,
        .audioFracture,
        .audioStretch,
        .audioRepair,
        .audioTunnel,
        .audioKaleido,
        .audioGrain,
        .audioDisplace,
        .audioPosterize,
        .spectralTint,
        .kaleidoscope,
        .mirror,
        .lensWarp,
        .kuwahara,
        .asciiMosaic,
        .frostedGlass,
        .dctBlocks,
        .domainWarp,
        .blueNoiseDither,
        // The scopes render last on purpose: an instrument measures what the
        // chain produced, so anything placed after one would be measuring a
        // frame the reading no longer describes.
        .spectrumBars,
        .radialSpectrum,
        .lissajous,
        .vectorscope,
        .waveformMonitor,
        .rgbParade,
        .cyberGrid,
        .astralPlasma,
        .quantumRaymarch,
        .liquidChroma,
        .holoAurora,
        .neuralFlow,
        .voxelStorm,
        .fractalZoom,
        .particleLife,
        .waveformTunnel,
        .spectralFlower,
        .glitchWeave,
        .hologramMatrix,
        .singularityLens,
        .causticReactor,
        .eventHorizon,
        .prismPortal,
        .neonOrbit,
        .chromeRipple,
        .laserGarden,
        .hyperBloom,
        .pixelConfetti,
        .solarFlare,
        .candyMesh,
        .auroraGlass,
        .cosmicKnot,
        .nebulaDrift,
        .quantumBloom,
        .plasmaRipple,
        .chromascrape,
        .singularityWeave,
        .fractalBurst,
        .vortexPulse,
        .spectralNova,
        .ionStorm,
        .opalWave,
        .cmykPress,
        .spectralDiffraction
    ]

    static let temporalRenderOrder: [WorkspaceAdjustableEffect] = [
        .datamosh,
        .liquidMosh,
        .heavyMosh,
        .predictionDrift,
        .vectorCodebook,
        .motionTransplant,
        .bitplaneLatch,
        .moshBrush,
        .timeMap,
        .sort,
        .depthSort,
        .objectSort,
        .radialSort,
        .temporalPixelSort,
        .pointCloudSmear,
        .depthFeedback,
        .freezeBrush,
        .sortBrush,
        .feedbackTunnel,
        .lumaExtrusion,
        .opticalFlowLiquid,
        .rollingTime,
        .frameHoldSmear,
        .pixelGravity,
        .pixelShift,
        .slitScan,
        .motionBloom,
        .audioBloom,
        .audioKick,
        .frameTear,
        .bufferUnderrun,
        .packetLoss,
        .chromaFailure,
        .sensorSmear,
        .causalSmear,
        .realityCavitation,
        .timeFracture,
        .antiCamera,
        .memoryBurnIn,
        .spectralDepth,
        .vectorNecromancy,
        .worldFeedback,
        .timeGraffiti,
        .feedback,
        .trails,
        .echo,
        .freeze
    ]

    /// Where a newly enabled effect lands in the stack by default.
    ///
    /// The style pass and the temporal pass each filter the stack down to
    /// their own nodes, so concatenating the two orders gives every effect
    /// exactly one rank while leaving the within-pass order of both passes
    /// exactly as it was. The two lists are disjoint —
    /// `testEveryRenderableEffectHasExactlyOnePlacementRank` enforces that,
    /// because an effect present in both would rank by its style position and
    /// quietly render out of temporal order.
    static let defaultPlacementOrder: [WorkspaceAdjustableEffect] =
        metalRenderOrder + temporalRenderOrder + [.fluid, .reactionGarden]

    static let datamoshCategoryEffects: [WorkspaceAdjustableEffect] = [
        .datamosh,
        .liquidMosh,
        .heavyMosh,
        .predictionDrift,
        .vectorCodebook,
        .motionTransplant,
        .bitplaneLatch,
        .moshBrush,
        .sort,
        .depthSort,
        .objectSort,
        .radialSort,
        .temporalPixelSort,
        .pointCloudSmear,
        .depthFeedback,
        .freezeBrush,
        .sortBrush,
        .feedbackTunnel,
        .lumaExtrusion,
        .opticalFlowLiquid,
        .rollingTime,
        .frameHoldSmear,
        .pixelGravity,
        .pixelShift
    ]

    static let blockCategoryEffects: [WorkspaceAdjustableEffect] = [
        .pixelate,
        .posterize,
        .dither,
        .halftone,
        .cmykPress,
        .threshold,
        .edge,
        .emboss,
        .sharpen,
        .hatch,
        // Same family as dither and halftone: every one of these rebuilds the
        // frame out of a repeated primitive.
        .asciiMosaic,
        .blueNoiseDither,
        .kuwahara
    ]

    static let feedbackCategoryEffects: [WorkspaceAdjustableEffect] = [
        .feedback,
        .trails,
        .echo,
        .freeze,
        .motionBloom,
        .slitScan
    ]

    static let flowCategoryEffects: [WorkspaceAdjustableEffect] = [
        .ripple,
        .wave,
        .water,
        .touchWarp,
        .vectorWarp
    ]

    /// Straight color grades. Split out of glitch so a "color" lookup lands
    /// here directly; the family is small enough to show effects with no
    /// subgroups.
    static let colorCategoryEffects: [WorkspaceAdjustableEffect] = [
        .thermal,
        .solarize,
        .hueShift,
        .invert,
        .monochrome
    ]

    static let glitchCategoryEffects: [WorkspaceAdjustableEffect] = [
        .rgbSplit,
        .signalTear,
        .vhs,
        .grain,
        .crt
    ]

    /// Effects driven by the live FFT bands. Selecting any of these arms the
    /// audio analyser if it is not already running.
    static let audioCategoryEffects: [WorkspaceAdjustableEffect] = [
        .audioSpectral,
        .audioScanBend,
        .audioChromaPulse,
        .audioWaveform,
        .audioBandSlice,
        .audioBloom,
        .audioKick,
        .audioMacroblock,
        .audioFracture,
        .audioStretch,
        .audioRepair,
        .audioTunnel,
        .audioKaleido,
        .audioGrain,
        .audioDisplace,
        .audioPosterize,
        .spectralTint
    ]

    /// Measurement instruments. Three read the live spectrum, three read the
    /// frame. They are grouped apart from the audio filters because what they
    /// do is different in kind: a filter changes the image, a scope reports on
    /// it, and mixing the two makes the rail unreadable.
    static let scopeCategoryEffects: [WorkspaceAdjustableEffect] = [
        .waveformMonitor,
        .rgbParade,
        .vectorscope,
        .spectrumBars,
        .radialSpectrum,
        .lissajous
    ]

    static let opticsCategoryEffects: [WorkspaceAdjustableEffect] = [
        .chromaticAberration,
        .spectralDiffraction,
        .anamorphicFlare,
        .bokeh,
        .tiltShift,
        .fisheye,
        .lensDirt,
        .lightLeak,
        .starFilter,
        .barrelWarp,
        .softFocus,
        .vignette,
        .prismStreak,
        .hologram,
        .frostedGlass,
        .lensWarp
    ]

    static let analogCategoryEffects: [WorkspaceAdjustableEffect] = [
        .halation,
        .vhsTracking,
        .super8,
        .chromaBleed,
        .tapeWarp,
        .dropout,
        .colorBarTear,
        .interlace,
        .degauss,
        .printThrough,
        .phosphor
    ]

    static let geometryCategoryEffects: [WorkspaceAdjustableEffect] = [
        .polarWarp,
        .twirl,
        .hexTile,
        .shatter,
        .kaleido6,
        .quadMirror,
        .spiralWarp,
        .shearStack,
        .lensArray,
        .fold,
        .kaleidoscope,
        .mirror
    ]

    static let fieldCategoryEffects: [WorkspaceAdjustableEffect] = [
        .flowField,
        .curlWarp,
        .worleyCracks,
        .plasma,
        .contourLines,
        .topography,
        .gradientMap,
        .falseColor,
        .edgeGlow,
        .reactionBands,
        .voronoi,
        .domainWarp
    ]

    /// Signal, sensor and buffer failure. Distinct from GLITCH, which is
    /// decorative: these model a specific thing going wrong in the imaging
    /// chain and all of them read real frame history.
    /// SARIN.DEV. The experiments that treat time and motion as material.
    /// Every one of these needs the shared flow field or the frame ring, which
    /// is why they could not exist before those were built.
    static let sarinCategoryEffects: [WorkspaceAdjustableEffect] = [
        .causalSmear,
        .realityCavitation,
        .timeFracture,
        .antiCamera,
        .memoryBurnIn,
        .spectralDepth,
        .vectorNecromancy,
        .worldFeedback,
        .timeGraffiti,
        .timeMap
    ]

    static let damageCategoryEffects: [WorkspaceAdjustableEffect] = [
        .frameTear,
        .bufferUnderrun,
        .packetLoss,
        .chromaFailure,
        .sensorSmear,
        // Compression failure rather than transport failure, but the same
        // chain and the same family of artefact.
        .dctBlocks
    ]

    static let shaderCategoryEffects: [WorkspaceAdjustableEffect] = [
        .cyberGrid,
        .astralPlasma,
        .quantumRaymarch,
        .liquidChroma,
        .holoAurora,
        .neuralFlow,
        .voxelStorm,
        .fractalZoom,
        .particleLife,
        .waveformTunnel,
        .spectralFlower,
        .glitchWeave,
        .hologramMatrix,
        .singularityLens,
        .causticReactor,
        .eventHorizon,
        .prismPortal,
        .neonOrbit,
        .chromeRipple,
        .laserGarden,
        .hyperBloom,
        .pixelConfetti,
        .solarFlare,
        .candyMesh,
        .auroraGlass,
        .cosmicKnot,
        .nebulaDrift,
        .quantumBloom,
        .plasmaRipple,
        .chromascrape,
        .singularityWeave,
        .fractalBurst,
        .vortexPulse,
        .spectralNova,
        .ionStorm,
        .opalWave
    ]

    /// Effects that accumulate in a world-locked frame. The renderer only
    /// starts the attitude sensor while one of these is armed.
    var requiresWorldAnchor: Bool {
        self == .worldFeedback || self == .timeGraffiti
    }

    /// Anything that reads the live spectrum must be able to turn the
    /// microphone on, otherwise the effect renders against a silent uniform.
    var requiresAudioAnalysis: Bool {
        // The spectrum scopes and shader family read the live FFT, and need
        // the microphone armed to react dynamically.
        WorkspaceAdjustableEffect.audioCategoryEffects.contains(self)
            || WorkspaceAdjustableEffect.shaderCategoryEffects.contains(self)
            || [.spectrumBars, .radialSpectrum, .lissajous].contains(self)
    }

    /// Spectrum instruments are composited as movable overlays rather than as
    /// a full-frame grade. Their placement is kept with the slot, so two
    /// spectrum instances can live in different parts of the composition.
    var isSpectrumOverlay: Bool {
        self == .spectrumBars || self == .radialSpectrum
    }

    // MARK: - Consolidated categories (10 effect families)

    /// All frame-history work: mosh/sort/smear plus the sarin
    /// motion-as-material experiments, which read the same flow field and
    /// frame ring.
    static let timeCategoryEffects: [WorkspaceAdjustableEffect] = datamoshCategoryEffects + sarinCategoryEffects

    /// Merged motion: temporal feedback + vector flow + the fluid solve.
    static let motionCategoryEffects: [WorkspaceAdjustableEffect] = feedbackCategoryEffects + flowCategoryEffects + [.fluid]
    /// Pixel-integrity group: primitive rebuilds + transport failure + decay.
    static let decayCategoryEffects: [WorkspaceAdjustableEffect] = blockCategoryEffects + damageCategoryEffects + [
        .pixelMelt,
        .corrode,
        .burnThrough,
        .ashDrift,
        .bitRot
    ]
    /// Decorative glitch + analog tape + the reassigned data bend. Color
    /// grades moved to COLOR; optics moved to OPTICS.
    static let signalCategoryEffects: [WorkspaceAdjustableEffect] = glitchCategoryEffects + analogCategoryEffects + [.dataBend]
    /// Merged form: spatial geometry + field warps + the reassigned garden.
    static let formCategoryEffects: [WorkspaceAdjustableEffect] = geometryCategoryEffects + fieldCategoryEffects + [.reactionGarden]

    static let curatedCategoryEffectGroups: [[WorkspaceAdjustableEffect]] = [
        colorCategoryEffects,
        timeCategoryEffects,
        motionCategoryEffects,
        decayCategoryEffects,
        signalCategoryEffects,
        opticsCategoryEffects,
        formCategoryEffects,
        shaderCategoryEffects,
        audioCategoryEffects,
        scopeCategoryEffects,
    ]

    /// The curated family this effect fans out with, plus a rail title for the
    /// radial ring. Nil only for effects that belong to no family rail.
    var curatedFamily: (title: String, effects: [WorkspaceAdjustableEffect])? {
        let families: [(title: String, effects: [WorkspaceAdjustableEffect])] = [
            (title: "COLOR", effects: WorkspaceAdjustableEffect.colorCategoryEffects),
            (title: "TIME", effects: WorkspaceAdjustableEffect.timeCategoryEffects),
            (title: "MOTION", effects: WorkspaceAdjustableEffect.motionCategoryEffects),
            (title: "DECAY", effects: WorkspaceAdjustableEffect.decayCategoryEffects),
            (title: "SIGNAL", effects: WorkspaceAdjustableEffect.signalCategoryEffects),
            (title: "OPTICS", effects: WorkspaceAdjustableEffect.opticsCategoryEffects),
            (title: "FORM", effects: WorkspaceAdjustableEffect.formCategoryEffects),
            (title: "SHADERS", effects: WorkspaceAdjustableEffect.shaderCategoryEffects),
            (title: "AUDIO", effects: WorkspaceAdjustableEffect.audioCategoryEffects),
            (title: "SCOPE", effects: WorkspaceAdjustableEffect.scopeCategoryEffects),
        ]
        return families.first { $0.effects.contains(self) }
    }

    static var repeatedCuratedCategoryEffects: Set<WorkspaceAdjustableEffect> {
        var seen = Set<WorkspaceAdjustableEffect>()
        var repeated = Set<WorkspaceAdjustableEffect>()
        for effects in curatedCategoryEffectGroups {
            for effect in effects {
                let result = seen.insert(effect)
                if !result.inserted {
                    repeated.insert(effect)
                }
            }
        }
        return repeated
    }

    /// Built once, on first use.
    ///
    /// `label` and `detail` are 192-arm switches. The effect rail asks both
    /// for every card on every body pass, and the dock re-renders on each
    /// parameter write — so browsing SHADERS was running two hundred and
    /// fifty-six switch dispatches, each returning an interned literal, just
    /// to build text the catalog has never changed at runtime. The switch
    /// below stays the single source of truth; this only stops it being
    /// re-run.
    private static let labelTable: [WorkspaceAdjustableEffect: String] = {
        var table: [WorkspaceAdjustableEffect: String] = [:]
        table.reserveCapacity(allCases.count)
        for effect in allCases {
            table[effect] = effect.computedLabel
        }
        return table
    }()

    var label: String { Self.labelTable[self] ?? Self.unknownText }

    private var computedLabel: String {
        switch self {
        case .rgbSplit: "RGB SPLIT"
        case .signalTear: "SIGNAL TEAR"
        case .hueShift: "HUE SHIFT"
        case .depthSort: "LUMA SORT"
        case .objectSort: "EDGE SORT"
        case .radialSort: "RADIAL SORT"
        case .temporalPixelSort: "TEMPORAL PIXEL SORT"
        case .pointCloudSmear: "LUMA POINT SMEAR"
        case .depthFeedback: "LUMA FEEDBACK"
        case .freezeBrush: "FREEZE BRUSH"
        case .sortBrush: "SORT BRUSH"
        case .feedbackTunnel: "FEEDBACK TUNNEL"
        case .lumaExtrusion: "LUMA EXTRUSION"
        case .opticalFlowLiquid: "OPTICAL-FLOW LIQUID"
        case .rollingTime: "ROLLING TIME"
        case .frameHoldSmear: "FRAME-HOLD SMEAR"
        case .pixelGravity: "PIXEL GRAVITY"
        case .pixelShift: "PIXEL SHIFT"
        case .slitScan: "SLIT SCAN"
        case .motionBloom: "MOTION BLOOM"
        case .dataBend: "DATA BEND"
        case .prismStreak: "PRISM STREAK"
        case .vectorWarp: "VECTOR WARP"
        case .audioSpectral: "AUDIO SPECTRAL"
        case .audioScanBend: "AUDIO SCAN BEND"
        case .audioChromaPulse: "AUDIO CHROMA"
        case .audioWaveform: "AUDIO WAVEFORM"
        case .audioBandSlice: "AUDIO BAND SLICE"
        case .audioBloom: "AUDIO BLOOM"
        case .audioKick: "AUDIO KICK"
        case .frameTear: "FRAME TEAR"
        case .bufferUnderrun: "BUFFER UNDERRUN"
        case .packetLoss: "PACKET LOSS"
        case .chromaFailure: "CHROMA FAILURE"
        case .sensorSmear: "SENSOR SMEAR"
        case .causalSmear: "CAUSAL SMEAR"
        case .realityCavitation: "CAVITATION"
        case .timeFracture: "TIME FRACTURE"
        case .antiCamera: "ANTI-CAMERA"
        case .memoryBurnIn: "MEMORY BURN-IN"
        case .spectralDepth: "SPECTRAL DEPTH"
        case .vectorNecromancy: "NECROMANCY"
        case .worldFeedback: "WORLD FEEDBACK"
        case .timeGraffiti: "TIME GRAFFITI"
        case .water: "WATER"
        case .touchWarp: "TOUCH WARP"
        case .hatch: "HATCH"
        case .phosphor: "PHOSPHOR"
        case .voronoi: "VORONOI"
        case .hologram: "HOLOGRAM"
        case .asciiMosaic: "ASCII"
        case .blueNoiseDither: "BLUE NOISE"
        case .frostedGlass: "FROSTED GLASS"
        case .dctBlocks: "DCT RINGING"
        case .domainWarp: "DOMAIN WARP"
        case .lensWarp: "LENS WARP"
        case .spectrumBars: "SPECTRUM"
        case .radialSpectrum: "RADIAL SPECTRUM"
        case .lissajous: "LISSAJOUS"
        case .vectorscope: "VECTORSCOPE"
        case .waveformMonitor: "WAVEFORM"
        case .rgbParade: "RGB PARADE"
        case .moshBrush: "MOSH BRUSH"
        case .timeMap: "TIME MAP"
        case .predictionDrift: "PREDICTION DRIFT"
        case .cyberGrid: "CYBER GRID"
        case .astralPlasma: "ASTRAL PLASMA"
        case .quantumRaymarch: "RAYMARCH SDF"
        case .liquidChroma: "LIQUID CHROMA"
        case .holoAurora: "HOLO AURORA"
        case .neuralFlow: "NEURAL FLOW"
        case .voxelStorm: "VOXEL STORM"
        case .fractalZoom: "FRACTAL ZOOM"
        case .particleLife: "PARTICLE LIFE"
        case .waveformTunnel: "WAVEFORM TUNNEL"
        case .spectralFlower: "SPECTRAL FLOWER"
        case .glitchWeave: "GLITCH WEAVE"
        case .hologramMatrix: "HOLO MATRIX"
        case .singularityLens: "SINGULARITY LENS"
        case .causticReactor: "CAUSTIC REACTOR"
        case .eventHorizon: "EVENT HORIZON"
        case .prismPortal: "PRISM PORTAL"
        case .neonOrbit: "NEON ORBIT"
        case .chromeRipple: "CHROME RIPPLE"
        case .laserGarden: "LASER GARDEN"
        case .hyperBloom: "HYPER BLOOM"
        case .pixelConfetti: "PIXEL CONFETTI"
        case .solarFlare: "SOLAR FLARE"
        case .candyMesh: "CANDY MESH"
        case .auroraGlass: "AURORA GLASS"
        case .cosmicKnot: "COSMIC KNOT"
        case .nebulaDrift: "NEBULA DRIFT"
        case .quantumBloom: "QUANTUM BLOOM"
        case .plasmaRipple: "PLASMA RIPPLE"
        case .chromascrape: "CHROMASCRAPE"
        case .singularityWeave: "SINGULARITY WEAVE"
        case .fractalBurst: "FRACTAL BURST"
        case .vortexPulse: "VORTEX PULSE"
        case .spectralNova: "SPECTRAL NOVA"
        case .ionStorm: "ION STORM"
        case .opalWave: "OPAL WAVE"
        case .bokeh: "LUMA DIFFUSION"
        case .cmykPress: "CMYK PRESS"
        case .spectralDiffraction: "SPECTRAL DIFFRACTION"
        case .reactionGarden: "REACTION GARDEN"
        case .vectorCodebook: "VECTOR CODEBOOK"
        case .motionTransplant: "MOTION TRANSPLANT"
        case .bitplaneLatch: "BITPLANE LATCH"
        default: rawValue.uppercased()
        }
    }

    private static let detailTable: [WorkspaceAdjustableEffect: String] = {
        var table: [WorkspaceAdjustableEffect: String] = [:]
        table.reserveCapacity(allCases.count)
        for effect in allCases {
            table[effect] = effect.computedDetail
        }
        return table
    }()

    var detail: String { Self.detailTable[self] ?? Self.unknownText }

    private var computedDetail: String {
        switch self {
        case .rgbSplit: "CHANNEL OFFSET"
        case .datamosh: "H.264 REFERENCE DRAG"
        case .liquidMosh: "COARSE MACROBLOCK MOSH"
        case .heavyMosh: "RECURSIVE CODEC CASCADE"
        case .predictionDrift: "DIFFERENTIAL MOTION MEMORY"
        case .sort: "LUMA LINE SORT"
        case .depthSort: "DEPTH-RANK SMEAR"
        case .objectSort: "EDGE-BOUND SORT"
        case .radialSort: "CENTER OUT SORT"
        case .temporalPixelSort: "HISTORY PIXEL SORT"
        case .pointCloudSmear: "SPARSE CLOUD DRAG"
        case .depthFeedback: "LUMA DEPTH LOOP"
        case .freezeBrush: "HELD REGION PAINT"
        case .sortBrush: "BRUSHED SORT FIELD"
        case .feedbackTunnel: "RECURSIVE TUNNEL"
        case .lumaExtrusion: "BRIGHTNESS PULL"
        case .opticalFlowLiquid: "MOTION LIQUID"
        case .rollingTime: "BAND TIME OFFSET"
        case .frameHoldSmear: "HOLD FRAME DRAG"
        case .pixelGravity: "LUMA FALL FIELD"
        case .pixelShift: "BANDED FRAME OFFSET"
        case .slitScan: "ROLLING TIME SLICES"
        case .motionBloom: "MOTION ENERGY HALO"
        case .dataBend: "QUANTIZED MEMORY ADDRESS"
        case .prismStreak: "LUMA SPECTRAL DRAG"
        case .vectorWarp: "CURL FIELD DISPLACE"
        case .audioSpectral: "FFT BAND REFRACTION"
        case .audioScanBend: "BASS-BENT SCANLINES"
        case .audioChromaPulse: "TRANSIENT RGB SPLIT"
        case .audioWaveform: "LIVE LEVEL TRACE"
        case .audioBandSlice: "BAND-KEYED SLICES"
        case .audioBloom: "ENERGY HALO"
        case .audioKick: "BASS FRAME STUTTER"
        case .frameTear: "BANDS ON SPLIT CLOCKS"
        case .bufferUnderrun: "BLOCKS MISS REFRESH"
        case .packetLoss: "REGIONS DROP AND STALE"
        case .chromaFailure: "COLOUR LAGS LUMA"
        case .sensorSmear: "HIGHLIGHT CHARGE BLEED"
        case .causalSmear: "CORRUPTS AHEAD OF MOTION"
        case .realityCavitation: "MOTION PUNCHES VOIDS"
        case .timeFracture: "CELLS ON OWN TIMELINES"
        case .antiCamera: "ONLY CHANGE IS DRAWN"
        case .memoryBurnIn: "STILL REGIONS ENGRAVE"
        case .spectralDepth: "RGB SPLIT BY TIME"
        case .vectorNecromancy: "RESURRECTS OLD MOTION"
        case .worldFeedback: "TRAILS STICK TO THE ROOM"
        case .timeGraffiti: "PAINT TIME ONTO SPACE"
        case .feedback: "FRAME RECURSION"
        case .trails: "LUMA DECAY"
        case .echo: "OFFSET HISTORY"
        case .freeze: "HELD FRAME"
        case .ripple: "RADIAL WARP"
        case .pixelate: "BLOCK QUANTIZE"
        case .posterize: "COLOR LEVELS"
        case .dither: "ORDERED BAYER"
        case .edge: "SOBEL CONTOUR"
        case .signalTear: "BAND DISPLACE"
        case .vhs: "ANALOG DAMAGE"
        case .vignette: "EDGE FALL-OFF"
        case .grain: "CHROMA NOISE"
        case .thermal: "HEAT PALETTE"
        case .halftone: "DOT SCREEN"
        case .threshold: "LUMA CUT"
        case .invert: "CHANNEL NEGATIVE"
        case .solarize: "TONE REVERSAL"
        case .hueShift: "HSV ROTATION"
        case .monochrome: "TINTED LUMA"
        case .sharpen: "LAPLACIAN DETAIL"
        case .emboss: "RELIEF CONTOUR"
        case .wave: "AXIS WARP"
        case .crt: "CURVE + GRILLE"
        case .water: "TOUCH-RIPPLED SURFACE"
        case .touchWarp: "FINGER GRAVITY LENS"
        case .hatch: "ENGRAVED CROSSHATCH"
        case .phosphor: "HOT BLOOM ACCUMULATION"
        case .voronoi: "CELL FRACTURE FIELD"
        case .hologram: "INTERFERENCE PROJECTION"
        case .chromaticAberration: "CHROMATIC ABERRATION"
        case .anamorphicFlare: "ANAMORPHIC FLARE"
        case .bokeh: "BOKEH DEFOCUS"
        case .tiltShift: "TILT SHIFT"
        case .fisheye: "FISHEYE"
        case .lensDirt: "LENS DIRT"
        case .lightLeak: "LIGHT LEAK"
        case .starFilter: "STAR FILTER"
        case .barrelWarp: "BARREL / PINCUSHION"
        case .softFocus: "SOFT FOCUS"
        case .halation: "HALATION"
        case .vhsTracking: "VHS TRACKING"
        case .super8: "SUPER 8"
        case .chromaBleed: "CHROMA BLEED"
        case .tapeWarp: "TAPE WARP"
        case .dropout: "TAPE DROPOUT"
        case .colorBarTear: "COLOUR BAR TEAR"
        case .interlace: "INTERLACE"
        case .degauss: "DEGAUSS"
        case .printThrough: "PRINT THROUGH"
        case .polarWarp: "POLAR WARP"
        case .twirl: "TWIRL"
        case .hexTile: "HEX TILE"
        case .shatter: "SHATTER"
        case .kaleido6: "KALEIDOSCOPE 6"
        case .quadMirror: "QUAD MIRROR"
        case .spiralWarp: "SPIRAL WARP"
        case .shearStack: "SHEAR STACK"
        case .lensArray: "LENS ARRAY"
        case .fold: "FOLD"
        case .flowField: "FLOW FIELD"
        case .curlWarp: "CURL WARP"
        case .worleyCracks: "WORLEY CRACKS"
        case .plasma: "PLASMA FIELD"
        case .contourLines: "CONTOUR LINES"
        case .topography: "LUMA TOPOGRAPHY"
        case .gradientMap: "GRADIENT MAP"
        case .falseColor: "FALSE COLOUR"
        case .edgeGlow: "EDGE GLOW"
        case .reactionBands: "REACTION BANDS"
        case .pixelMelt: "PIXEL MELT"
        case .corrode: "CORRODE"
        case .burnThrough: "BURN THROUGH"
        case .ashDrift: "ASH DRIFT"
        case .bitRot: "BIT ROT"
        case .audioMacroblock: "AUDIO MACROBLOCK"
        case .audioFracture: "AUDIO FRACTURE"
        case .audioStretch: "AUDIO STRETCH"
        case .audioRepair: "AUDIO DAMAGE / REPAIR"
        case .audioTunnel: "AUDIO TUNNEL"
        case .audioKaleido: "AUDIO KALEIDOSCOPE"
        case .audioGrain: "AUDIO GRAIN"
        case .audioDisplace: "AUDIO DISPLACE"
        case .audioPosterize: "AUDIO POSTERIZE"
        case .spectralTint: "SPECTRAL TINT"
        case .fluid: "FLUID"
        case .kaleidoscope: "RADIAL SEGMENT FOLD"
        case .mirror: "AXIS REFLECTION"
        case .lensWarp: "RADIAL LENS PROFILE"
        case .kuwahara: "PAINTERLY EDGE-PRESERVE"
        case .asciiMosaic: "GLYPH DENSITY GRID"
        case .frostedGlass: "CELL REFRACTION"
        case .dctBlocks: "CODEC BLOCK RINGING"
        case .domainWarp: "FBM WARPED BY FBM"
        case .blueNoiseDither: "SCATTERED QUANTISE"
        case .spectrumBars: "16-BAND FFT BARS"
        case .radialSpectrum: "FFT WRAPPED TO A RING"
        case .lissajous: "AUDIO SCOPE TRACE"
        case .vectorscope: "CHROMA ON A COLOUR WHEEL"
        case .waveformMonitor: "LUMA PER COLUMN"
        case .rgbParade: "R / G / B WAVEFORMS"
        case .moshBrush: "FINGER-PAINTED MOTION"
        case .timeMap: "BRIGHTNESS PICKS THE MOMENT"
        case .cyberGrid: "QUANTUM LASER MATRIX"
        case .astralPlasma: "WARPED COSMIC NEBULA"
        case .quantumRaymarch: "3D SDF HYPERCUBE CORRIDOR"
        case .liquidChroma: "NEON FLUID DISPERSION"
        case .holoAurora: "PRISMATIC WAVE INTERFERENCE"
        case .neuralFlow: "AI NEURAL VISUALIZATION"
        case .voxelStorm: "3D VOXEL PARTICLE FIELD"
        case .fractalZoom: "INFINITE FRACTAL DEEP ZOOM"
        case .particleLife: "EMERGENT PARTICLE ECOSYSTEM"
        case .waveformTunnel: "AUDIO WAVEFORM CORRIDOR"
        case .spectralFlower: "REACTIVE SPECTRAL BLOOM"
        case .glitchWeave: "INTERACTIVE GLITCH TAPESTRY"
        case .hologramMatrix: "HOLOGRAPHIC FALLING CODE"
        case .singularityLens: "GRAVITATIONAL CHROMA LENS"
        case .causticReactor: "AUDIO-CHARGED LIQUID LIGHT"
        case .eventHorizon: "RECURSIVE WARP COLLAPSE"
        case .prismPortal: "TOUCH-ANCHORED SPECTRUM GATE"
        case .neonOrbit: "AUDIO-CHARGED ORBITAL RINGS"
        case .chromeRipple: "IRIDESCENT LIQUID LENS"
        case .laserGarden: "GESTURE-BENT LIGHT LATTICE"
        case .hyperBloom: "VIVID HIGHLIGHT HALO"
        case .pixelConfetti: "BEAT-SYNCED COLOUR PARTICLES"
        case .solarFlare: "SPECTRAL RADIAL STREAKS"
        case .candyMesh: "ANIMATED MESH GRADIENT"
        case .auroraGlass: "REFRACTIVE PRISM CURTAIN"
        case .cosmicKnot: "INTERACTIVE NEON TORUS KNOT"
        case .nebulaDrift: "LIQUID NEBULA CLOUDS"
        case .quantumBloom: "QUANTUM ENTANGLEMENT BLOOM"
        case .plasmaRipple: "ELECTRIC PLASMA RIPPLES"
        case .chromascrape: "CHROMATIC ABERRATION SCRAPE"
        case .singularityWeave: "WORMHOLE INTERFERENCE PATTERN"
        case .fractalBurst: "CATASTROPHIC FRACTAL EXPLOSION"
        case .vortexPulse: "GAMMA RAY VORTEX PULSE"
        case .spectralNova: "WHITE DWARF SPECTRAL NOVA"
        case .ionStorm: "AUDIO-CHARGED FLOW REFRACTION"
        case .opalWave: "IRIDESCENT CAUSTIC REFRACTION"
        case .cmykPress: "FOUR ROTATED SUBTRACTIVE INK SCREENS"
        case .spectralDiffraction: "HIGHLIGHT DIFFRACTION ORDERS"
        case .reactionGarden: "CAMERA-SEEDED GRAY-SCOTT CHEMISTRY"
        case .vectorCodebook: "QUANTIZED MEASURED MOTION MEMORY"
        case .motionTransplant: "DONOR REGION FLOW TRANSPORT"
        case .bitplaneLatch: "MOTION-GATED BIT PLANE MEMORY"
        }
    }

    var styleMode: UInt32? {
        switch self {
        case .ripple: 0
        case .pixelate: 1
        case .posterize: 2
        case .dither: 3
        case .edge: 4
        case .signalTear: 5
        case .vhs: 6
        case .vignette: 9
        case .grain: 10
        case .thermal: 11
        case .halftone: 12
        case .threshold: 13
        case .invert: 14
        case .solarize: 16
        case .hueShift: 17
        case .monochrome: 18
        case .sharpen: 19
        case .emboss: 20
        case .wave: 21
        case .crt: 22
        case .dataBend: 23
        case .prismStreak: 24
        case .vectorWarp: 25
        case .audioSpectral: 26
        case .audioScanBend: 27
        case .audioChromaPulse: 28
        case .audioWaveform: 29
        case .audioBandSlice: 30
        case .water: 31
        case .touchWarp: 32
        case .hatch: 33
        case .phosphor: 34
        case .voronoi: 35
        case .hologram: 36
        case .chromaticAberration: 37
        case .anamorphicFlare: 38
        case .bokeh: 39
        case .tiltShift: 40
        case .fisheye: 41
        case .lensDirt: 42
        case .lightLeak: 43
        case .starFilter: 44
        case .barrelWarp: 45
        case .softFocus: 46
        case .halation: 47
        case .vhsTracking: 48
        case .super8: 49
        case .chromaBleed: 50
        case .tapeWarp: 51
        case .dropout: 52
        case .colorBarTear: 53
        case .interlace: 54
        case .degauss: 55
        case .printThrough: 56
        case .polarWarp: 57
        case .twirl: 58
        case .hexTile: 59
        case .shatter: 60
        case .kaleido6: 61
        case .quadMirror: 62
        case .spiralWarp: 63
        case .shearStack: 64
        case .lensArray: 65
        case .fold: 66
        case .flowField: 67
        case .curlWarp: 68
        case .worleyCracks: 69
        case .plasma: 70
        case .contourLines: 71
        case .topography: 72
        case .gradientMap: 73
        case .falseColor: 74
        case .edgeGlow: 75
        case .reactionBands: 76
        case .pixelMelt: 77
        case .corrode: 78
        case .burnThrough: 79
        case .ashDrift: 80
        case .bitRot: 81
        case .audioMacroblock: 82
        case .audioFracture: 83
        case .audioStretch: 84
        case .audioRepair: 85
        case .audioTunnel: 86
        case .audioKaleido: 87
        case .audioGrain: 88
        case .audioDisplace: 89
        case .audioPosterize: 90
        case .spectralTint: 91
        case .kaleidoscope: 7
        case .mirror: 8
        case .lensWarp: 15
        case .kuwahara: 92
        case .asciiMosaic: 93
        case .frostedGlass: 94
        case .dctBlocks: 95
        case .domainWarp: 96
        case .blueNoiseDither: 97
        case .spectrumBars: 98
        case .radialSpectrum: 99
        case .lissajous: 100
        case .vectorscope: 101
        case .waveformMonitor: 102
        case .rgbParade: 103
        case .cyberGrid: 104
        case .astralPlasma: 105
        case .quantumRaymarch: 106
        case .liquidChroma: 107
        case .holoAurora: 108
        case .neuralFlow: 109
        case .voxelStorm: 110
        case .fractalZoom: 111
        case .particleLife: 112
        case .waveformTunnel: 113
        case .spectralFlower: 114
        case .glitchWeave: 115
        case .hologramMatrix: 116
        case .singularityLens: 117
        case .causticReactor: 118
        case .eventHorizon: 119
        case .prismPortal: 120
        case .neonOrbit: 121
        case .chromeRipple: 122
        case .laserGarden: 123
        case .hyperBloom: 124
        case .pixelConfetti: 125
        case .solarFlare: 126
        case .candyMesh: 127
        case .auroraGlass: 128
        case .cosmicKnot: 129
        case .nebulaDrift: 130
        case .quantumBloom: 131
        case .plasmaRipple: 132
        case .chromascrape: 133
        case .singularityWeave: 134
        case .fractalBurst: 135
        case .vortexPulse: 136
        case .spectralNova: 137
        case .ionStorm: 138
        case .opalWave: 139
        case .cmykPress: 140
        case .spectralDiffraction: 141
        case .fluid, .reactionGarden, .vectorCodebook, .motionTransplant, .bitplaneLatch: nil
        case .rgbSplit, .datamosh, .liquidMosh, .heavyMosh, .predictionDrift, .sort, .depthSort, .objectSort,
             .radialSort, .temporalPixelSort, .pointCloudSmear, .depthFeedback, .freezeBrush,
             .sortBrush, .feedbackTunnel, .lumaExtrusion, .opticalFlowLiquid, .rollingTime,
             .frameHoldSmear, .pixelGravity, .pixelShift, .slitScan, .motionBloom,
             .audioBloom, .audioKick,
             .frameTear, .bufferUnderrun, .packetLoss, .chromaFailure, .sensorSmear,
             .causalSmear, .realityCavitation, .timeFracture, .antiCamera,
             .memoryBurnIn, .spectralDepth, .vectorNecromancy,
             .worldFeedback, .timeGraffiti, .moshBrush, .timeMap,
             .feedback, .trails, .echo, .freeze:
            nil
        }
    }

    var temporalMode: UInt32? {
        switch self {
        case .feedback: 0
        case .trails: 1
        case .echo: 2
        case .freeze: 3
        // Three separate kernels. They shared mode 4 and differed only by
        // their default slider values, which made two thirds of the DATAMOSH
        // rail a relabelling of one effect - and broke the registry's
        // one-effect-one-mode invariant.
        case .datamosh: 4
        case .liquidMosh: 39
        case .heavyMosh: 40
        case .predictionDrift: 43
        case .vectorCodebook: 44
        case .motionTransplant: 45
        case .bitplaneLatch: 46
        case .moshBrush: 41
        case .timeMap: 42
        case .sort: 5
        case .depthSort: 6
        case .objectSort: 7
        case .radialSort: 8
        case .temporalPixelSort: 9
        case .pointCloudSmear: 10
        case .depthFeedback: 11
        case .freezeBrush: 12
        case .sortBrush: 13
        case .feedbackTunnel: 14
        case .lumaExtrusion: 15
        case .opticalFlowLiquid: 16
        case .rollingTime: 17
        case .frameHoldSmear: 18
        case .pixelGravity: 19
        case .pixelShift: 20
        case .slitScan: 21
        case .motionBloom: 22
        case .audioBloom: 23
        case .audioKick: 24
        case .frameTear: 25
        case .bufferUnderrun: 26
        case .packetLoss: 27
        case .chromaFailure: 28
        case .sensorSmear: 29
        case .causalSmear: 30
        case .realityCavitation: 31
        case .timeFracture: 32
        case .antiCamera: 33
        case .memoryBurnIn: 34
        case .spectralDepth: 35
        case .vectorNecromancy: 36
        case .worldFeedback: 37
        case .timeGraffiti: 38
        default: nil
        }
    }

    /// Fallback for an effect the tables somehow missed. Should be
    /// unreachable — the tables are built from `allCases` — but a card with no
    /// text is worse than a card with a placeholder.
    private static let unknownText = "UNNAMED"

    private static let parameterLabelTable: [WorkspaceAdjustableEffect: [String]] = {
        var table: [WorkspaceAdjustableEffect: [String]] = [:]
        table.reserveCapacity(allCases.count)
        for effect in allCases {
            table[effect] = effect.computedParameterLabels
        }
        return table
    }()

    var parameterLabels: [String] { Self.parameterLabelTable[self] ?? [] }

    private var computedParameterLabels: [String] {
        switch self {
        case .datamosh: ["GOP", "DROP", "BITS"]
        case .liquidMosh: ["SCALE", "DROP", "BITS"]
        case .heavyMosh: ["RECYCLE", "GOP", "BITS"]
        case .predictionDrift: ["DRIFT", "DECAY", "TEAR"]
        case .moshBrush: ["PUSH", "REACH", "BLOCK"]
        case .timeMap: ["DEPTH", "BIAS", "CONTRAST"]
        case .sort: ["SPAN", "BIAS", "MIX"]
        case .depthSort: ["DEPTH", "GATE", "SMEAR"]
        case .objectSort: ["EDGE", "GATE", "MIX"]
        case .radialSort: ["RADIUS", "SPIN", "MIX"]
        case .temporalPixelSort: ["HISTORY", "THRESH", "MIX"]
        case .pointCloudSmear: ["DENSITY", "DRIFT", "SMEAR"]
        case .depthFeedback: ["DEPTH", "ZOOM", "DECAY"]
        case .freezeBrush: ["SIZE", "DRIFT", "HOLD"]
        case .sortBrush: ["SIZE", "SPAN", "MIX"]
        case .feedbackTunnel: ["PULL", "SPIN", "DECAY"]
        case .lumaExtrusion: ["HEIGHT", "GATE", "MIX"]
        case .opticalFlowLiquid: ["FLOW", "VISC", "MIX"]
        case .rollingTime: ["ROLL", "BANDS", "MIX"]
        case .frameHoldSmear: ["HOLD", "ANGLE", "SMEAR"]
        case .pixelGravity: ["GRAVITY", "WEIGHT", "MIX"]
        case .pixelShift: ["OFFSET", "BANDS", "MIX"]
        case .slitScan: ["ROLL", "WIDTH", "MIX"]
        case .motionBloom: ["GAIN", "RADIUS", "MIX"]
        case .dataBend: ["SHIFT", "ROWS", "MIX"]
        case .prismStreak: ["LENGTH", "GATE", "MIX"]
        case .vectorWarp: ["FIELD", "SCALE", "SPEED"]
        case .audioSpectral: ["REFRACT", "BANDS", "MIX"]
        case .audioScanBend: ["BEND", "LINES", "MIX"]
        case .audioChromaPulse: ["SPLIT", "ATTACK", "MIX"]
        case .audioWaveform: ["HEIGHT", "TRACE", "MIX"]
        case .audioBandSlice: ["SHIFT", "SLICES", "MIX"]
        case .audioBloom: ["GAIN", "RADIUS", "MIX"]
        case .audioKick: ["HOLD", "GATE", "MIX"]
        case .frameTear: ["TEAR", "BANDS", "DRIFT"]
        case .bufferUnderrun: ["AMOUNT", "BLOCK", "HOLD"]
        case .packetLoss: ["LOSS", "BURST", "SMEAR"]
        case .chromaFailure: ["DELAY", "DRIFT", "SMEAR"]
        case .sensorSmear: ["THRESH", "LENGTH", "BLOOM"]
        case .causalSmear: ["HORIZON", "GAIN", "SPREAD"]
        case .realityCavitation: ["THRESH", "SIZE", "RESIDUE"]
        case .timeFracture: ["CELLS", "SPREAD", "DRIFT"]
        case .antiCamera: ["GATE", "PERSIST", "INVERT"]
        case .memoryBurnIn: ["BURN", "HOLD", "ERASE"]
        case .spectralDepth: ["SPLIT", "DEPTH", "MIX"]
        case .vectorNecromancy: ["AGE", "GAIN", "CYCLE"]
        case .worldFeedback: ["GAIN", "DECAY", "BLUR"]
        case .timeGraffiti: ["SIZE", "HOLD", "FADE"]
        case .feedback: ["MIX", "ZOOM", "DRIFT"]
        case .trails: ["DECAY", "COLOR", "SMEAR"]
        case .echo: ["DISTANCE", "ANGLE", "MIX"]
        case .freeze: ["MIX", "TINT", "GRAIN"]
        case .ripple: ["AMOUNT", "FREQUENCY", "SPEED"]
        case .pixelate: ["BLOCK", "MIX", "ASPECT"]
        case .posterize: ["LEVELS", "MIX", "CONTRAST"]
        case .dither: ["SCALE", "STRENGTH", "LEVELS"]
        case .edge: ["WIDTH", "THRESHOLD", "MIX"]
        case .signalTear: ["OFFSET", "BANDS", "SPEED"]
        case .vhs: ["DAMAGE", "SCAN", "NOISE"]
        case .vignette: ["AMOUNT", "SOFTNESS", "ROUND"]
        case .grain: ["AMOUNT", "SIZE", "CHROMA"]
        case .thermal: ["SHIFT", "CONTRAST", "MIX"]
        case .halftone: ["DOT SIZE", "ANGLE", "MIX"]
        case .threshold: ["LEVEL", "SOFTNESS", "MIX"]
        case .invert: ["AMOUNT", "CHANNEL", "MIX"]
        case .solarize: ["LEVEL", "SHIFT", "MIX"]
        case .hueShift: ["HUE", "SATURATION", "MIX"]
        case .monochrome: ["TINT", "CONTRAST", "MIX"]
        case .sharpen: ["AMOUNT", "RADIUS", "MIX"]
        case .emboss: ["DEPTH", "ANGLE", "MIX"]
        case .wave: ["AMOUNT", "FREQUENCY", "SPEED"]
        case .crt: ["CURVE", "SCAN", "GRILLE"]
        case .water: ["RIPPLE", "FREQUENCY", "SPEED"]
        case .touchWarp: ["PULL", "RADIUS", "MIX"]
        case .hatch: ["SCALE", "GATE", "INK"]
        case .phosphor: ["GAIN", "THRESH", "MIX"]
        case .voronoi: ["CELLS", "EDGE", "DRIFT"]
        case .hologram: ["FREQUENCY", "LINES", "DRIFT"]
        case .chromaticAberration: ["SPREAD", "FALLOFF", "MIX"]
        case .anamorphicFlare: ["LENGTH", "GATE", "GAIN"]
        case .bokeh: ["RADIUS", "FOCUS", "MIX"]
        case .tiltShift: ["BLUR", "BAND", "FALLOFF"]
        case .fisheye: ["CURVE", "CROP", "MIX"]
        case .lensDirt: ["AMOUNT", "SCALE", "MIX"]
        case .lightLeak: ["WIDTH", "DRIFT", "GAIN"]
        case .starFilter: ["REACH", "GATE", "GAIN"]
        case .barrelWarp: ["CURVE", "SCALE", "MIX"]
        case .softFocus: ["RADIUS", "GATE", "GAIN"]
        case .halation: ["RADIUS", "GATE", "GAIN"]
        case .vhsTracking: ["ERROR", "DRIFT", "MIX"]
        case .super8: ["WEAVE", "GRAIN", "MIX"]
        case .chromaBleed: ["REACH", "BOOST", "MIX"]
        case .tapeWarp: ["BEND", "RATE", "MIX"]
        case .dropout: ["DENSITY", "ROWS", "MIX"]
        case .colorBarTear: ["DENSITY", "ROWS", "MIX"]
        case .interlace: ["OFFSET", "CONTRAST", "MIX"]
        case .degauss: ["AMOUNT", "RATE", "MIX"]
        case .printThrough: ["OFFSET", "SKEW", "MIX"]
        case .polarWarp: ["CURVE", "REPEAT", "SPIN"]
        case .twirl: ["ANGLE", "REACH", "DRIFT"]
        case .hexTile: ["SCALE", "BORDER", "MIX"]
        case .shatter: ["DRIFT", "CELLS", "MIX"]
        case .kaleido6: ["MIX", "ZOOM", "SPIN"]
        case .quadMirror: ["FLIP", "ZOOM", "MIX"]
        case .spiralWarp: ["TWIST", "MIX", "SPIN"]
        case .shearStack: ["SHEAR", "BANDS", "MIX"]
        case .lensArray: ["CURVE", "PITCH", "MIX"]
        case .fold: ["FOLD", "ZOOM", "SPIN"]
        case .flowField: ["PUSH", "SCALE", "MIX"]
        case .curlWarp: ["PUSH", "SCALE", "MIX"]
        case .worleyCracks: ["WIDTH", "CELLS", "MIX"]
        case .plasma: ["AMOUNT", "SCALE", "MIX"]
        case .contourLines: ["WIDTH", "LEVELS", "MIX"]
        case .topography: ["RELIEF", "SMOOTH", "MIX"]
        case .gradientMap: ["AMOUNT", "CURVE", "MIX"]
        case .falseColor: ["CONTRAST", "OFFSET", "MIX"]
        case .edgeGlow: ["GAIN", "WIDTH", "MIX"]
        case .reactionBands: ["SHARP", "SCALE", "MIX"]
        case .pixelMelt: ["SAG", "COLUMNS", "MIX"]
        case .corrode: ["PITTING", "CELLS", "MIX"]
        case .burnThrough: ["SCALE", "RATE", "MIX"]
        case .ashDrift: ["MOTES", "WIND", "MIX"]
        case .bitRot: ["ROT", "BLOCKS", "MIX"]
        case .audioMacroblock: ["FORCE", "BLOCKS", "MIX"]
        case .audioFracture: ["SPLIT", "TRIGGER", "MIX"]
        case .audioStretch: ["REACH", "DIRECTION", "MIX"]
        case .audioRepair: ["DAMAGE", "BLOCKS", "MIX"]
        case .audioTunnel: ["PULL", "SPIN", "MIX"]
        case .audioKaleido: ["PUMP", "SEGMENTS", "MIX"]
        case .audioGrain: ["NOISE", "BLEACH", "MIX"]
        case .audioDisplace: ["SHIFT", "SLICES", "MIX"]
        case .audioPosterize: ["COLLAPSE", "LEVELS", "MIX"]
        case .spectralTint: ["GAIN", "SATURATION", "MIX"]
        case .fluid: ["DRAG", "PERSIST", "SWIRL"]
        case .kaleidoscope: ["SEGMENTS", "SPIN", "ZOOM"]
        case .mirror: ["ANGLE", "OFFSET", "MIX"]
        case .lensWarp: ["CURVE", "RADIUS", "SCALE"]
        case .kuwahara: ["RADIUS", "CONTRAST", "MIX"]
        case .asciiMosaic: ["CELL", "GAMMA", "COLOUR"]
        case .frostedGlass: ["ROUGH", "SCALE", "MIX"]
        case .dctBlocks: ["QUALITY", "BLOCK", "MIX"]
        case .domainWarp: ["AMOUNT", "SCALE", "MIX"]
        case .blueNoiseDither: ["LEVELS", "PIXEL", "MIX"]
        case .spectrumBars: ["SIZE", "BARS", "HUE"]
        case .radialSpectrum: ["SIZE", "INNER", "HUE"]
        case .lissajous: ["GAIN", "RATIO", "MIX"]
        case .vectorscope: ["GAIN", "SIZE", "MIX"]
        case .waveformMonitor: ["GAIN", "HEIGHT", "MIX"]
        case .rgbParade: ["GAIN", "HEIGHT", "MIX"]
        case .cyberGrid: ["GRID", "COLOR", "MIX"]
        case .astralPlasma: ["WARP", "GLOW", "MIX"]
        case .quantumRaymarch: ["MORPH", "GLOW", "MIX"]
        case .liquidChroma: ["DISPERSE", "SAT", "MIX"]
        case .holoAurora: ["PHASE", "GAIN", "MIX"]
        case .neuralFlow: ["DEPTH", "ACTIVITY", "MIX"]
        case .voxelStorm: ["DENSITY", "CHAOS", "MIX"]
        case .fractalZoom: ["ZOOM", "ITERATIONS", "MIX"]
        case .particleLife: ["POPULATION", "ENERGY", "MIX"]
        case .waveformTunnel: ["DEPTH", "RESONANCE", "MIX"]
        case .spectralFlower: ["PETALS", "HARMONICS", "MIX"]
        case .glitchWeave: ["COMPLEXITY", "DISTORT", "MIX"]
        case .hologramMatrix: ["RAIN", "SCANLINE", "MIX"]
        case .singularityLens: ["PULL", "CHROMA", "MIX"]
        case .causticReactor: ["ENERGY", "REFRACT", "MIX"]
        case .eventHorizon: ["DEPTH", "SPIN", "MIX"]
        case .prismPortal: ["RADIUS", "FACETS", "MIX"]
        case .neonOrbit: ["ORBIT", "SPEED", "MIX"]
        case .chromeRipple: ["REFRACT", "CHROME", "MIX"]
        case .laserGarden: ["DENSITY", "BEND", "MIX"]
        case .hyperBloom: ["BLOOM", "GATE", "MIX"]
        case .pixelConfetti: ["DENSITY", "ENERGY", "MIX"]
        case .solarFlare: ["REACH", "RAYS", "MIX"]
        case .candyMesh: ["FLOW", "SATURATION", "MIX"]
        case .auroraGlass: ["WARP", "SHEEN", "MIX"]
        case .cosmicKnot: ["KNOT", "TWIST", "MIX"]
        case .nebulaDrift: ["DRIFT", "SWIRL", "MIX"]
        case .quantumBloom: ["GROW", "GAIN", "MIX"]
        case .plasmaRipple: ["SCALE", "INTENSITY", "MIX"]
        case .chromascrape: ["REACH", "BOOST", "MIX"]
        case .singularityWeave: ["PULL", "CHROMA", "MIX"]
        case .fractalBurst: ["EXPAND", "SPIN", "MIX"]
        case .vortexPulse: ["SPEED", "ANGLE", "MIX"]
        case .spectralNova: ["GAIN", "RESOLUTION", "MIX"]
        case .ionStorm: ["FIELD", "CHARGE", "MIX"]
        case .opalWave: ["CAUSTIC", "FLOW", "MIX"]
        case .cmykPress: ["SCREEN", "REGISTER", "INK"]
        case .spectralDiffraction: ["PITCH", "ORDERS", "GATE"]
        case .reactionGarden: ["FEED", "SCALE", "RELIEF"]
        case .vectorCodebook: ["DIRECTIONS", "STEP", "RETAIN"]
        case .motionTransplant: ["REGION", "TRAVEL", "MEMORY"]
        case .bitplaneLatch: ["PLANES", "REFRESH", "FLOW"]
        default: []
        }
    }

    var defaultCameraParameters: CameraEffectParameters {
        let values: SIMD3<Double> = switch self {
        // Mosh starts from a recent seed. Strength comes from recursively
        // carrying and warping the decoded frame, not from showing a visibly
        // delayed camera feed.
        case .datamosh: SIMD3(0.68, 0.12, 0.48)
        case .liquidMosh: SIMD3(0.85, 0.72, 0.18)
        case .heavyMosh: SIMD3(0.95, 0.18, 0.90)
        case .predictionDrift: SIMD3(0.72, 0.82, 0.38)
        case .sort: SIMD3(0.58, 0.48, 0.82)
        case .depthSort: SIMD3(0.66, 0.38, 0.74)
        case .objectSort: SIMD3(0.54, 0.42, 0.82)
        case .radialSort: SIMD3(0.62, 0.58, 0.78)
        case .temporalPixelSort: SIMD3(0.76, 0.28, 0.82)
        case .pointCloudSmear: SIMD3(0.48, 0.62, 0.72)
        case .depthFeedback: SIMD3(0.64, 0.54, 0.70)
        case .freezeBrush: SIMD3(0.42, 0.36, 0.88)
        case .sortBrush: SIMD3(0.48, 0.60, 0.82)
        case .feedbackTunnel: SIMD3(0.72, 0.52, 0.74)
        case .lumaExtrusion: SIMD3(0.66, 0.42, 0.78)
        case .opticalFlowLiquid: SIMD3(0.58, 0.58, 0.84)
        case .rollingTime: SIMD3(0.58, 0.62, 0.78)
        case .frameHoldSmear: SIMD3(0.82, 0.46, 0.76)
        case .pixelGravity: SIMD3(0.58, 0.60, 0.82)
        case .pixelShift: SIMD3(0.62, 0.46, 0.86)
        case .slitScan: SIMD3(0.58, 0.42, 0.82)
        case .motionBloom: SIMD3(0.66, 0.38, 0.82)
        case .dataBend: SIMD3(0.54, 0.46, 0.84)
        case .prismStreak: SIMD3(0.62, 0.44, 0.82)
        case .vectorWarp: SIMD3(0.48, 0.52, 0.56)
        case .audioSpectral: SIMD3(0.64, 0.58, 0.90)
        case .audioScanBend: SIMD3(0.58, 0.52, 0.88)
        case .audioChromaPulse: SIMD3(0.52, 0.62, 0.92)
        case .audioWaveform: SIMD3(0.56, 0.48, 0.78)
        case .audioBandSlice: SIMD3(0.60, 0.50, 0.86)
        case .audioBloom: SIMD3(0.62, 0.44, 0.84)
        case .audioKick: SIMD3(0.58, 0.46, 0.82)
        case .frameTear: SIMD3(0.52, 0.44, 0.38)
        case .bufferUnderrun: SIMD3(0.46, 0.40, 0.55)
        case .packetLoss: SIMD3(0.42, 0.36, 0.50)
        case .chromaFailure: SIMD3(0.55, 0.38, 0.44)
        case .sensorSmear: SIMD3(0.62, 0.52, 0.46)
        case .causalSmear: SIMD3(0.58, 0.50, 0.42)
        case .realityCavitation: SIMD3(0.44, 0.46, 0.55)
        case .timeFracture: SIMD3(0.46, 0.52, 0.38)
        case .antiCamera: SIMD3(0.40, 0.62, 0.0)
        case .memoryBurnIn: SIMD3(0.52, 0.58, 0.35)
        case .spectralDepth: SIMD3(0.55, 0.48, 0.72)
        case .vectorNecromancy: SIMD3(0.50, 0.56, 0.40)
        case .worldFeedback: SIMD3(0.72, 0.30, 0.22)
        case .timeGraffiti: SIMD3(0.42, 0.68, 0.25)
        case .feedback: SIMD3(0.72, 0.55, 0.52)
        case .trails: SIMD3(0.82, 0.24, 0.20)
        case .echo: SIMD3(0.25, 0.12, 0.72)
        case .freeze: SIMD3(1.00, 0.50, 0.00)
        case .ripple: SIMD3(0.28, 0.34, 0.64)
        case .pixelate: SIMD3(0.20, 1.00, 0.50)
        case .posterize: SIMD3(0.18, 1.00, 0.52)
        case .dither: SIMD3(0.24, 0.78, 0.25)
        case .edge: SIMD3(0.24, 0.16, 1.00)
        case .signalTear: SIMD3(0.28, 0.42, 0.62)
        case .vhs: SIMD3(0.38, 0.44, 0.30)
        case .vignette: SIMD3(0.42, 0.46, 0.50)
        case .grain: SIMD3(0.20, 0.18, 0.25)
        case .thermal: SIMD3(0.50, 0.58, 1.00)
        case .halftone: SIMD3(0.20, 0.12, 0.88)
        case .threshold: SIMD3(0.50, 0.08, 1.00)
        case .invert: SIMD3(1.00, 0.50, 1.00)
        case .solarize: SIMD3(0.54, 0.50, 1.00)
        case .hueShift: SIMD3(0.68, 0.62, 1.00)
        case .monochrome: SIMD3(0.72, 0.54, 1.00)
        case .sharpen: SIMD3(0.34, 0.20, 0.78)
        case .emboss: SIMD3(0.35, 0.14, 0.82)
        case .wave: SIMD3(0.22, 0.28, 0.68)
        case .crt: SIMD3(0.22, 0.34, 0.30)
        case .water: SIMD3(0.26, 0.40, 0.52)
        case .touchWarp: SIMD3(0.62, 0.34, 0.86)
        case .hatch: SIMD3(0.34, 0.30, 0.78)
        case .phosphor: SIMD3(0.42, 0.36, 0.88)
        case .voronoi: SIMD3(0.36, 0.34, 0.60)
        case .hologram: SIMD3(0.40, 0.38, 0.52)
        case .chromaticAberration: SIMD3(0.46, 0.58, 0.85)
        case .anamorphicFlare: SIMD3(0.54, 0.62, 0.70)
        case .bokeh: SIMD3(0.44, 0.52, 0.82)
        case .tiltShift: SIMD3(0.58, 0.50, 0.42)
        case .fisheye: SIMD3(0.52, 0.40, 0.88)
        case .lensDirt: SIMD3(0.48, 0.54, 0.72)
        case .lightLeak: SIMD3(0.56, 0.38, 0.68)
        case .starFilter: SIMD3(0.50, 0.66, 0.64)
        case .barrelWarp: SIMD3(0.68, 0.52, 0.86)
        case .softFocus: SIMD3(0.52, 0.44, 0.62)
        case .halation: SIMD3(0.54, 0.50, 0.66)
        case .vhsTracking: SIMD3(0.52, 0.34, 0.84)
        case .super8: SIMD3(0.46, 0.42, 0.80)
        case .chromaBleed: SIMD3(0.56, 0.48, 0.82)
        case .tapeWarp: SIMD3(0.44, 0.46, 0.84)
        case .dropout: SIMD3(0.38, 0.52, 0.86)
        case .colorBarTear: SIMD3(0.34, 0.48, 0.88)
        case .interlace: SIMD3(0.42, 0.50, 0.78)
        case .degauss: SIMD3(0.52, 0.42, 0.84)
        case .printThrough: SIMD3(0.40, 0.52, 0.72)
        case .polarWarp: SIMD3(0.52, 0.30, 0.50)
        case .twirl: SIMD3(0.62, 0.46, 0.50)
        case .hexTile: SIMD3(0.42, 0.46, 0.86)
        case .shatter: SIMD3(0.44, 0.48, 0.84)
        case .kaleido6: SIMD3(0.82, 0.52, 0.54)
        case .quadMirror: SIMD3(0.70, 0.50, 0.86)
        case .spiralWarp: SIMD3(0.44, 0.82, 0.52)
        case .shearStack: SIMD3(0.46, 0.52, 0.84)
        case .lensArray: SIMD3(0.56, 0.44, 0.84)
        case .fold: SIMD3(0.48, 0.46, 0.50)
        case .flowField: SIMD3(0.50, 0.46, 0.84)
        case .curlWarp: SIMD3(0.48, 0.44, 0.84)
        case .worleyCracks: SIMD3(0.44, 0.50, 0.78)
        case .plasma: SIMD3(0.58, 0.44, 0.72)
        case .contourLines: SIMD3(0.40, 0.46, 0.80)
        case .topography: SIMD3(0.54, 0.40, 0.82)
        case .gradientMap: SIMD3(0.78, 0.50, 0.84)
        case .falseColor: SIMD3(0.52, 0.50, 0.88)
        case .edgeGlow: SIMD3(0.54, 0.38, 0.82)
        case .reactionBands: SIMD3(0.48, 0.44, 0.76)
        case .pixelMelt: SIMD3(0.50, 0.54, 0.84)
        case .corrode: SIMD3(0.46, 0.52, 0.80)
        case .burnThrough: SIMD3(0.48, 0.36, 0.86)
        case .ashDrift: SIMD3(0.52, 0.44, 0.78)
        case .bitRot: SIMD3(0.46, 0.52, 0.86)
        case .audioMacroblock: SIMD3(0.62, 0.50, 0.88)
        case .audioFracture: SIMD3(0.58, 0.46, 0.88)
        case .audioStretch: SIMD3(0.60, 0.40, 0.86)
        case .audioRepair: SIMD3(0.64, 0.52, 0.88)
        case .audioTunnel: SIMD3(0.56, 0.48, 0.86)
        case .audioKaleido: SIMD3(0.52, 0.50, 0.86)
        case .audioGrain: SIMD3(0.54, 0.40, 0.84)
        case .audioDisplace: SIMD3(0.58, 0.52, 0.86)
        case .audioPosterize: SIMD3(0.60, 0.46, 0.86)
        case .spectralTint: SIMD3(0.56, 0.50, 0.88)
        case .moshBrush: SIMD3(0.55, 0.34, 0.42)
        case .timeMap: SIMD3(0.45, 0.50, 0.55)
        case .fluid: SIMD3(0.55, 0.62, 0.50)
        case .kaleidoscope: SIMD3(0.34, 0.50, 0.52)
        case .mirror: SIMD3(0.50, 0.50, 0.92)
        case .lensWarp: SIMD3(0.66, 0.54, 0.50)
        case .kuwahara: SIMD3(0.46, 0.42, 0.86)
        case .asciiMosaic: SIMD3(0.34, 0.52, 0.28)
        case .frostedGlass: SIMD3(0.42, 0.48, 0.80)
        case .dctBlocks: SIMD3(0.58, 0.34, 0.88)
        case .domainWarp: SIMD3(0.40, 0.46, 0.82)
        case .blueNoiseDither: SIMD3(0.52, 0.20, 0.86)
        // Scopes default to a strong mix: a measurement drawn at 40% is not a
        // reading, it is a ghost.
        case .spectrumBars: SIMD3(0.58, 0.45, 0.92)
        case .radialSpectrum: SIMD3(0.55, 0.35, 0.90)
        case .lissajous: SIMD3(0.52, 0.30, 0.88)
        case .vectorscope: SIMD3(0.46, 0.50, 0.95)
        case .waveformMonitor: SIMD3(0.50, 0.42, 0.95)
        case .rgbParade: SIMD3(0.50, 0.42, 0.95)
        case .cyberGrid: SIMD3(0.50, 0.40, 0.90)
        case .astralPlasma: SIMD3(0.60, 0.70, 0.88)
        case .quantumRaymarch: SIMD3(0.35, 0.75, 0.92)
        case .liquidChroma: SIMD3(0.55, 0.65, 0.85)
        case .holoAurora: SIMD3(0.45, 0.60, 0.88)
        case .neuralFlow: SIMD3(0.45, 0.55, 0.88)
        case .voxelStorm: SIMD3(0.55, 0.60, 0.85)
        case .fractalZoom: SIMD3(0.35, 0.45, 0.90)
        case .particleLife: SIMD3(0.50, 0.65, 0.88)
        case .waveformTunnel: SIMD3(0.45, 0.55, 0.90)
        case .spectralFlower: SIMD3(0.55, 0.60, 0.88)
        case .glitchWeave: SIMD3(0.50, 0.55, 0.86)
        case .hologramMatrix: SIMD3(0.60, 0.50, 0.88)
        case .singularityLens: SIMD3(0.58, 0.62, 0.90)
        case .causticReactor: SIMD3(0.64, 0.56, 0.88)
        case .eventHorizon: SIMD3(0.56, 0.54, 0.92)
        case .prismPortal: SIMD3(0.48, 0.60, 0.90)
        case .neonOrbit: SIMD3(0.52, 0.58, 0.88)
        case .chromeRipple: SIMD3(0.46, 0.64, 0.86)
        case .laserGarden: SIMD3(0.48, 0.55, 0.84)
        case .hyperBloom: SIMD3(0.58, 0.52, 0.88)
        case .pixelConfetti: SIMD3(0.50, 0.62, 0.86)
        case .solarFlare: SIMD3(0.56, 0.56, 0.88)
        case .candyMesh: SIMD3(0.48, 0.78, 0.90)
        case .auroraGlass: SIMD3(0.50, 0.64, 0.88)
        case .cosmicKnot: SIMD3(0.54, 0.58, 0.90)
        case .nebulaDrift: SIMD3(0.52, 0.70, 0.92)
        case .quantumBloom: SIMD3(0.58, 0.62, 0.88)
        case .plasmaRipple: SIMD3(0.64, 0.56, 0.90)
        case .chromascrape: SIMD3(0.48, 0.62, 0.86)
        case .singularityWeave: SIMD3(0.50, 0.58, 0.88)
        case .fractalBurst: SIMD3(0.42, 0.66, 0.90)
        case .vortexPulse: SIMD3(0.56, 0.54, 0.88)
        case .spectralNova: SIMD3(0.52, 0.60, 0.92)
        case .ionStorm: SIMD3(0.58, 0.64, 0.90)
        case .opalWave: SIMD3(0.54, 0.58, 0.88)
        case .cmykPress: SIMD3(0.48, 0.24, 0.78)
        case .spectralDiffraction: SIMD3(0.48, 0.50, 0.62)
        case .reactionGarden: SIMD3(0.46, 0.60, 0.58)
        case .vectorCodebook: SIMD3(0.35, 0.58, 0.82)
        case .motionTransplant: SIMD3(0.45, 0.62, 0.84)
        case .bitplaneLatch: SIMD3(0.65, 0.32, 0.60)
        default: .zero
        }
        return CameraEffectParameters(primary: values.x, secondary: values.y, tertiary: values.z)
    }

    /// Relative per-frame GPU cost used by the adaptive quality budget to pick
    /// what to drop first when sustained GPU time exceeds the frame target.
    /// Base full-res pass = 1.0; history-sampling and multi-sample kernels cost
    /// more than the single-sample ones.
    var estimatedCost: Double {
        switch self {
        case .reactionGarden: 1.8
        case .spectralDiffraction: 2.0
        case .cmykPress, .vectorCodebook, .motionTransplant, .bitplaneLatch: 1.5
        case .quantumRaymarch:
            2.6
        case .astralPlasma, .liquidChroma, .cyberGrid, .holoAurora,
             .neuralFlow, .voxelStorm, .fractalZoom, .particleLife,
             .waveformTunnel, .spectralFlower, .glitchWeave, .hologramMatrix,
             .singularityLens, .causticReactor, .eventHorizon, .prismPortal,
             .neonOrbit, .chromeRipple, .laserGarden, .hyperBloom, .pixelConfetti,
             .solarFlare, .candyMesh, .auroraGlass, .cosmicKnot,
             .nebulaDrift, .quantumBloom, .plasmaRipple, .chromascrape,
             .singularityWeave, .fractalBurst, .vortexPulse, .spectralNova,
             .ionStorm, .opalWave:
            1.6
        case .phosphor, .voronoi, .hologram, .hatch, .water, .touchWarp, .crt, .dataBend,
             .frostedGlass, .dctBlocks, .domainWarp:
            1.4
        // Sixty-four taps per pixel over the whole frame. It is the most
        // expensive style kernel in the set and the budget must know that
        // before it starts dropping cheaper effects to pay for it.
        case .kuwahara:
            3.2
        // The scopes gate to their own panel, so the tap count is paid over a
        // fraction of the frame rather than all of it.
        case .vectorscope, .waveformMonitor, .rgbParade:
            1.8
        case .liquidMosh:
            2.4
        case .datamosh, .sort, .depthSort, .objectSort, .radialSort, .temporalPixelSort,
             .pointCloudSmear, .depthFeedback, .freezeBrush, .sortBrush, .feedbackTunnel,
             .lumaExtrusion, .opticalFlowLiquid, .rollingTime, .frameHoldSmear, .pixelGravity,
             .pixelShift, .slitScan, .motionBloom, .audioBloom, .audioKick, .prismStreak,
             .heavyMosh, .moshBrush, .timeMap,
             .vectorWarp, .feedback, .trails, .echo,
             .frameTear, .bufferUnderrun, .packetLoss, .chromaFailure, .sensorSmear,
             .causalSmear, .realityCavitation, .timeFracture, .antiCamera,
             .memoryBurnIn, .spectralDepth, .vectorNecromancy,
             .worldFeedback, .timeGraffiti:
            1.5
        default:
            1.0
        }
    }

    var freezesHistoryOnHold: Bool {
        switch self {
        // The three compression instruments belong here for the same reason the
        // shader moshes do, and their absence was half of the hold bug: with no
        // entry in this set a held frame never reached the codec as a hold, so
        // it kept being handed the same clean still. The codec then found no
        // motion to predict, diverged from no reference, and converged.
        case .datamosh, .liquidMosh, .heavyMosh,
             .moshBrush, .predictionDrift,
             .vectorCodebook, .motionTransplant, .bitplaneLatch, .reactionGarden,
             .sort, .depthSort, .objectSort, .radialSort, .temporalPixelSort,
             .pointCloudSmear, .depthFeedback, .freezeBrush, .sortBrush, .feedbackTunnel,
             .lumaExtrusion, .opticalFlowLiquid, .rollingTime, .frameHoldSmear, .pixelGravity,
             .pixelShift:
            true
        default:
            false
        }
    }
}

struct CameraEffectParameters: Codable, Equatable, Sendable {
    var isEnabled = false
    var primary = 0.5
    var secondary = 0.5
    var tertiary = 0.5
    var blend = 1.0
    /// Normalised centre for the movable spectrum overlays.
    var overlayX = 0.5
    var overlayY = 0.5

    init(
        isEnabled: Bool = false,
        primary: Double = 0.5,
        secondary: Double = 0.5,
        tertiary: Double = 0.5,
        blend: Double = 1.0,
        overlayX: Double = 0.5,
        overlayY: Double = 0.5
    ) {
        self.isEnabled = isEnabled
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.blend = blend
        self.overlayX = overlayX
        self.overlayY = overlayY
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, primary, secondary, tertiary, blend, overlayX, overlayY
    }

    /// Old recipes predate freeform overlays. Missing layout fields decode to
    /// a centred instrument rather than making the entire recipe unreadable.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        primary = try values.decodeIfPresent(Double.self, forKey: .primary) ?? 0.5
        secondary = try values.decodeIfPresent(Double.self, forKey: .secondary) ?? 0.5
        tertiary = try values.decodeIfPresent(Double.self, forKey: .tertiary) ?? 0.5
        blend = try values.decodeIfPresent(Double.self, forKey: .blend) ?? 1
        overlayX = try values.decodeIfPresent(Double.self, forKey: .overlayX) ?? 0.5
        overlayY = try values.decodeIfPresent(Double.self, forKey: .overlayY) ?? 0.5
    }

    var sanitized: CameraEffectParameters {
        CameraEffectParameters(
            isEnabled: isEnabled,
            primary: min(max(primary, 0), 1),
            secondary: min(max(secondary, 0), 1),
            tertiary: min(max(tertiary, 0), 1),
            blend: min(max(blend, 0), 1),
            overlayX: min(max(overlayX, 0.05), 0.95),
            overlayY: min(max(overlayY, 0.05), 0.95)
        )
    }
}

struct CameraEffectStackParameters: Codable, Equatable, Sendable {
    /// One placed effect. Identity is per-slot, not per-effect, which is what
    /// makes two DATAMOSH entries with different parameters possible.
    struct Slot: Identifiable, Equatable, Codable, Sendable {
        let id: UUID
        var effect: WorkspaceAdjustableEffect
        var parameters: CameraEffectParameters

        init(id: UUID = UUID(), effect: WorkspaceAdjustableEffect, parameters: CameraEffectParameters) {
            self.id = id
            self.effect = effect
            self.parameters = parameters
        }
    }

    /// Render order is the operator's, not the pipeline's.
    ///
    /// This was a dictionary keyed by effect, which made order a fixed
    /// constant and a second instance of an effect unrepresentable. Slots are
    /// ordered and carry their own identity, so reorder and duplicate become
    /// data operations rather than pipeline changes.
    private var slots: [Slot] = []

    /// Bumped on every mutation.
    ///
    /// Two things need to know that a value changed without paying to compare
    /// it: the preview projection, which was doing a synthesized `Equatable`
    /// walk of every slot and every parameter on each edit, and the undo
    /// history, which only cares whether the gesture moved at all. A counter
    /// answers both in constant time and cannot go stale the way a cached
    /// fingerprint can.
    private(set) var revision: UInt64 = 0

    /// Advances the revision. Every mutating operation routes through one of
    /// the two mutating entry points below, so no path can change the stack
    /// without moving the counter.
    mutating func markChanged() {
        revision &+= 1
    }

    /// A whole-stack write from a slider, a preset, or an apply. The subslots
    /// hand this the value they already built.
    mutating func setSlots(_ newSlots: [Slot]) {
        slots = newSlots
        markChanged()
    }

    /// The stack with its counter carried along, for anything that stores a
    /// snapshot of the composition.
    var revisionedIdentity: UInt64 { revision }

    /// Value equality deliberately ignores `revision`.
    ///
    /// The counter answers "did anything change", which is not the same
    /// question as "are these two compositions the same image". Synthesized
    /// equality would conflate them and make an undo that lands back on an
    /// identical composition look like a real edit.
    static func == (lhs: CameraEffectStackParameters, rhs: CameraEffectStackParameters) -> Bool {
        lhs.slots == rhs.slots
    }

    /// Reads and writes the first slot for an effect, creating one if absent.
    ///
    /// Kept so every existing call site — nine subscript uses across the
    /// decks and the renderer — continues to work untouched. Code that only
    /// ever wanted "the parameters for this effect" still gets exactly that.
    subscript(effect: WorkspaceAdjustableEffect) -> CameraEffectParameters {
        get {
            slots.first { $0.effect == effect }?.parameters ?? effect.defaultCameraParameters
        }
        set {
            let sanitized = newValue.sanitized
            if let index = slots.firstIndex(where: { $0.effect == effect }) {
                slots[index].parameters = sanitized
                markChanged()
            } else {
                insertInPipelineOrder(Slot(effect: effect, parameters: sanitized))
            }
        }
    }

    /// Every slot, in the order they will be applied.
    var orderedSlots: [Slot] { slots }

    /// Reads and writes one specific slot.
    ///
    /// The effect-keyed subscript above always resolves to the *first* slot
    /// carrying that effect, which is correct for "the parameters for this
    /// effect" and wrong the moment a slot is duplicated: both copies would
    /// edit as one and `duplicate` would produce two identical nodes with no
    /// way to separate them. Addressing by slot identity is what makes the
    /// same effect twice, with different settings, actually reachable.
    subscript(slot id: Slot.ID) -> CameraEffectParameters? {
        get { slots.first { $0.id == id }?.parameters }
        set {
            guard let newValue, let index = slots.firstIndex(where: { $0.id == id }) else { return }
            slots[index].parameters = newValue.sanitized
            markChanged()
        }
    }

    func slot(_ id: Slot.ID) -> Slot? {
        slots.first { $0.id == id }
    }

    /// One-based render position of a slot, for display.
    func renderPosition(of id: Slot.ID) -> Int? {
        slots.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    /// The first slot carrying an effect, if it is placed at all.
    func firstSlotID(for effect: WorkspaceAdjustableEffect) -> Slot.ID? {
        slots.first { $0.effect == effect }?.id
    }

    mutating func reset(slot id: Slot.ID) {
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return }
        var parameters = slots[index].effect.defaultCameraParameters
        parameters.isEnabled = slots[index].parameters.isEnabled
        slots[index].parameters = parameters
        markChanged()
    }

    var activeEffects: [(WorkspaceAdjustableEffect, CameraEffectParameters)] {
        slots.compactMap { slot in
            guard slot.effect.styleMode != nil else { return nil }
            let parameters = slot.parameters.sanitized
            return parameters.isEnabled ? (slot.effect, parameters) : nil
        }
    }

    var activeTemporalEffects: [(WorkspaceAdjustableEffect, CameraEffectParameters)] {
        slots.compactMap { slot in
            guard slot.effect.temporalMode != nil else { return nil }
            let parameters = slot.parameters.sanitized
            return parameters.isEnabled ? (slot.effect, parameters) : nil
        }
    }

    mutating func setEnabled(_ enabled: Bool, for effect: WorkspaceAdjustableEffect) {
        var parameters = self[effect]
        parameters.isEnabled = enabled
        self[effect] = parameters
    }

    /// Bumps the revision for callers that mutate through a subscript they
    /// already own. The subscripts mark themselves, so this exists only for
    /// the paths that reach past them.
    mutating func noteChanged() {
        markChanged()
    }

    mutating func reset(_ effect: WorkspaceAdjustableEffect, enabled: Bool = true) {
        var parameters = effect.defaultCameraParameters
        parameters.isEnabled = enabled
        self[effect] = parameters
    }

    mutating func enableOnly(_ effect: WorkspaceAdjustableEffect) {
        disableAll()
        setEnabled(true, for: effect)
    }

    mutating func disableAll() {
        guard !slots.isEmpty else { return }
        slots.removeAll(keepingCapacity: true)
        markChanged()
    }

    // MARK: - Stack operations

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        slots.move(fromOffsets: source, toOffset: destination)
        markChanged()
    }

    /// Copies a slot, parameters and all, directly after the original.
    @discardableResult
    mutating func duplicate(_ id: Slot.ID) -> Slot.ID? {
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return nil }
        let copy = Slot(effect: slots[index].effect, parameters: slots[index].parameters)
        slots.insert(copy, at: index + 1)
        markChanged()
        return copy.id
    }

    @discardableResult
    mutating func replace(slot id: Slot.ID, with effect: WorkspaceAdjustableEffect, parameters: CameraEffectParameters) -> Bool {
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return false }
        slots[index].effect = effect
        slots[index].parameters = parameters.sanitized
        markChanged()
        return true
    }

    mutating func remove(_ id: Slot.ID) {
        let before = slots.count
        slots.removeAll { $0.id == id }
        if slots.count != before { markChanged() }
    }

    mutating func setEnabled(_ enabled: Bool, slot id: Slot.ID) {
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return }
        slots[index].parameters.isEnabled = enabled
        markChanged()
    }

    /// New slots land where the pipeline would have put them.
    ///
    /// Order is the operator's to change, but the *default* stays exactly what
    /// it was before slots existed — otherwise enabling two effects in a
    /// different sequence would silently render differently than it used to.
    ///
    /// Ranking against `defaultPlacementOrder` rather than `metalRenderOrder`
    /// is load-bearing: the temporal nodes are absent from `metalRenderOrder`,
    /// so ranking against it alone gave all 39 of them the same fallback rank
    /// and left their order to whichever the operator happened to tap first.
    private mutating func insertInPipelineOrder(_ slot: Slot) {
        let order = WorkspaceAdjustableEffect.defaultPlacementOrder
        let rank = order.firstIndex(of: slot.effect) ?? order.count
        let index = slots.firstIndex { existing in
            (order.firstIndex(of: existing.effect) ?? order.count) > rank
        }
        slots.insert(slot, at: index ?? slots.endIndex)
        markChanged()
    }
}

struct GridEffectParameters: Equatable, Sendable {
    var isEnabled = false
    var density = 3.0
    var opacity = 0.22
    var rotation = 0.0

    static let activeDefaults = GridEffectParameters(isEnabled: true)
}

struct ScanlineEffectParameters: Equatable, Sendable {
    var isEnabled = false
    var frequency = 25.0
    var intensity = 0.095
    var speed = 0.42
    var direction = GVScanlineDirection.horizontal

    static let activeDefaults = ScanlineEffectParameters(isEnabled: true)
}

struct BracketEffectParameters: Equatable, Sendable {
    var isEnabled = false
    var inset = 18.0
    var length = 24.0
    var opacity = 0.24

    static let activeDefaults = BracketEffectParameters(isEnabled: true)
}

struct RGBSplitEffectParameters: Codable, Equatable, Sendable {
    var isEnabled = false
    var amount = 0.018
    var angleDegrees = 0.0
    var mix = 1.0

    static let activeDefaults = RGBSplitEffectParameters(isEnabled: true)

    var sanitized: RGBSplitEffectParameters {
        RGBSplitEffectParameters(
            isEnabled: isEnabled,
            amount: min(max(amount, 0), 0.08),
            angleDegrees: angleDegrees.truncatingRemainder(dividingBy: 360),
            mix: min(max(mix, 0), 1)
        )
    }
}

// swiftlint:enable file_length

// MARK: - Radial menu subcategories

//
// The radial ring used to fan out every effect in a family at once (SHADERS
// alone was 35 same-size slots). Instead the ring now shows small
// subcategory entries first; hovering one auto-expands into that group's
// variants. Pure grouping metadata — no effect is reclassified anywhere.

/// One subcategory entry shown on the radial category ring.
struct GVRadialSubcategory {
    let title: String
    let hue: GVTheme.RadialHue
    let glyph: GVEffectGlyphKind
    let effects: [WorkspaceAdjustableEffect]
}

extension WorkspaceAdjustableEffect {
    /// The radial subcategories for a curated family. Effects missing from
    /// every group here still appear via a fallback "ALL" subcategory.
    static func curatedRadialSubcategories(for familyTitle: String) -> [GVRadialSubcategory]? {
        switch familyTitle {
        case "TIME":
            return [
                GVRadialSubcategory(title: "MOSH", hue: .magenta, glyph: .datamosh, effects: [.datamosh, .liquidMosh, .heavyMosh, .predictionDrift, .moshBrush, .vectorCodebook, .motionTransplant, .bitplaneLatch]),
                GVRadialSubcategory(title: "SORT", hue: .cyan, glyph: .pixelSort, effects: [.sort, .depthSort, .objectSort, .radialSort, .temporalPixelSort, .sortBrush]),
                GVRadialSubcategory(title: "SMEAR", hue: .amber, glyph: .echo, effects: [.pointCloudSmear, .depthFeedback, .lumaExtrusion, .opticalFlowLiquid, .pixelGravity, .pixelShift]),
                GVRadialSubcategory(title: "TIME", hue: .rose, glyph: .frame, effects: [.rollingTime, .frameHoldSmear, .freezeBrush, .feedbackTunnel]),
                GVRadialSubcategory(title: "SARIN", hue: .moss, glyph: .echo, effects: sarinCategoryEffects),
            ]
        case "MOTION":
            return [
                GVRadialSubcategory(title: "FEEDBACK", hue: .teal, glyph: .feedback, effects: feedbackCategoryEffects),
                GVRadialSubcategory(title: "FLOW", hue: .sky, glyph: .flow, effects: flowCategoryEffects),
                GVRadialSubcategory(title: "FLUID", hue: .cyan, glyph: .flow, effects: [.fluid]),
            ]
        case "DECAY":
            return [
                GVRadialSubcategory(title: "REBUILD", hue: .lime, glyph: .block, effects: blockCategoryEffects),
                GVRadialSubcategory(title: "DAMAGE", hue: .rose, glyph: .glitch, effects: damageCategoryEffects),
                GVRadialSubcategory(title: "DECAY", hue: .ember, glyph: .frame, effects: [.pixelMelt, .corrode, .burnThrough, .ashDrift, .bitRot]),
            ]
        case "SIGNAL":
            return [
                GVRadialSubcategory(title: "GLITCH", hue: .magenta, glyph: .glitch, effects: glitchCategoryEffects + [.dataBend]),
                GVRadialSubcategory(title: "ANALOG", hue: .sand, glyph: .frame, effects: analogCategoryEffects),
            ]
        case "OPTICS":
            return [
                GVRadialSubcategory(title: "LENS", hue: .azure, glyph: .frame, effects: [.fisheye, .barrelWarp, .lensWarp, .tiltShift, .bokeh, .softFocus, .vignette]),
                GVRadialSubcategory(title: "LIGHT", hue: .amber, glyph: .glitch, effects: [.anamorphicFlare, .lightLeak, .starFilter, .prismStreak, .spectralDiffraction, .chromaticAberration]),
                GVRadialSubcategory(title: "GLASS", hue: .sky, glyph: .flow, effects: [.lensDirt, .frostedGlass, .hologram]),
            ]
        case "FORM":
            return [
                GVRadialSubcategory(title: "GEOMETRY", hue: .plum, glyph: .frame, effects: geometryCategoryEffects),
                GVRadialSubcategory(title: "FIELD", hue: .teal, glyph: .flow, effects: fieldCategoryEffects + [.reactionGarden]),
            ]
        case "SHADERS":
            // Six groups of exactly six, because the ring holds six wedges and
            // anything larger spills into MORE pages. The previous four groups
            // of eight to ten meant reaching `causticReactor` cost a hold, a
            // push into SHADERS, then a walk through four MORE pages before
            // the effect itself. Six-by-six fits the ring exactly, so every
            // shader is two gestures from the preview.
            return [
                GVRadialSubcategory(title: "PLASMA", hue: .plum, glyph: .flow, effects: [.astralPlasma, .plasmaRipple, .liquidChroma, .auroraGlass, .nebulaDrift, .opalWave]),
                GVRadialSubcategory(title: "QUANTUM", hue: .magenta, glyph: .echo, effects: [.quantumRaymarch, .quantumBloom, .fractalZoom, .fractalBurst, .singularityLens, .singularityWeave]),
                GVRadialSubcategory(title: "VOLUME", hue: .cyan, glyph: .block, effects: [.cyberGrid, .voxelStorm, .cosmicKnot, .chromeRipple, .neuralFlow, .chromascrape]),
                GVRadialSubcategory(title: "PARTICLE", hue: .lime, glyph: .trails, effects: [.particleLife, .pixelConfetti, .ionStorm, .vortexPulse, .waveformTunnel, .spectralFlower]),
                GVRadialSubcategory(title: "NEON", hue: .amber, glyph: .glitch, effects: [.neonOrbit, .laserGarden, .prismPortal, .solarFlare, .spectralNova, .hyperBloom]),
                GVRadialSubcategory(title: "GATEWAY", hue: .rose, glyph: .feedback, effects: [.holoAurora, .hologramMatrix, .causticReactor, .eventHorizon, .glitchWeave, .candyMesh]),
            ]
        case "AUDIO":
            return [
                GVRadialSubcategory(title: "VISUALIZE", hue: .teal, glyph: .audio, effects: [.audioSpectral, .audioWaveform, .audioBandSlice, .audioBloom, .audioKick]),
                GVRadialSubcategory(title: "WARP", hue: .sky, glyph: .flow, effects: [.audioScanBend, .audioTunnel, .audioKaleido, .audioDisplace, .audioStretch]),
                GVRadialSubcategory(title: "TEXTURE", hue: .amber, glyph: .block, effects: [.audioMacroblock, .audioFracture, .audioGrain, .audioPosterize, .audioRepair]),
                GVRadialSubcategory(title: "TINT", hue: .magenta, glyph: .glitch, effects: [.audioChromaPulse, .spectralTint]),
            ]
        default:
            return nil
        }
    }
}
