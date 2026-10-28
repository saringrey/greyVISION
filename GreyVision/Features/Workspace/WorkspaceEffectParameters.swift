// swiftlint:disable file_length
import Foundation

enum WorkspaceAdjustableEffect: String, CaseIterable, Identifiable, Codable, Sendable {
    case rgbSplit
    case datamosh
    case liquidMosh
    case heavyMosh
    case predictionDrift
    case sort
    case radialSort
    case pointCloudSmear
    case feedbackTunnel
    case frameHoldSmear
    case pixelShift
    case slitScan
    case dataBend
    case audioScanBend
    case audioBandSlice
    case audioKick
    // DAMAGE. Signal/sensor failure modes. All five read the shared
    // history ring, so what they preserve or replay is genuinely older
    // imagery rather than a synthesised artefact drawn over the frame.
    case frameTear
    case sensorSmear
    // SARIN.DEV. Effects that treat motion, time and history as material
    // rather than as a source of decoration. All seven read the shared flow
    // field, the frame ring, or both.
    case timeFracture
    case antiCamera
    // World-anchored. These accumulate in a frame locked to the room rather
    // than to the screen, so turning the phone leaves the trail where it was
    // painted instead of dragging it along.
    case feedback
    case trails
    case echo
    case pixelate
    case posterize
    case dither
    case edge
    case vhs
    case grain
    case thermal
    case threshold
    case invert
    case monochrome
    case crt
    case water
    case hologram
    case anamorphicFlare
    case tiltShift
    case fisheye
    case lightLeak
    case super8
    case polarWarp
    case hexTile
    case shatter
    case kaleido6
    case quadMirror
    case spiralWarp
    case fold
    case flowField
    case contourLines
    case falseColor
    case pixelMelt
    case burnThrough
    case bitRot
    case audioRepair
    case audioTunnel
    case audioDisplace
    // Three complete style kernels that had no Swift case at all. Modes 7, 8
    // and 15 were implemented in the shader and unreachable from the app, and
    // the gap they left in the mode numbering is what made the registry's
    // contiguity assertion impossible to satisfy.
    case kaleidoscope
    // RENDER. Reconstruction filters rather than damage: each one rebuilds the
    // frame out of a different primitive.
    case kuwahara
    case asciiMosaic
    // SCOPE. Measurement instruments, not filters. Three read the live FFT and
    // three read the frame itself; all six draw a reading over the image the
    // way a broadcast monitor does.
    case spectrumBars
    case radialSpectrum
    /// Finger-painted motion corruption. Reads the touch uniform directly.
    /// Per-pixel history age driven by brightness.
    /// Full Eulerian fluid solve. Runs its own multi-pass stage.
    case fluid
    // SHADERS. Colorful, interactive, audio-reactive GPU generative shaders.
    case cyberGrid
    case quantumRaymarch
    case liquidChroma
    case holoAurora
    // NEW INTERACTIVE SHADERS - generative, audio-reactive, touch-responsive
    case waveformTunnel
    case hologramMatrix
    case eventHorizon
    // FULL COLOR. Fast, tactile component-inspired generative shaders.
    case pixelConfetti
    case nebulaDrift
    case singularityWeave
    case fractalBurst
    case cmykPress

    var id: String {
        rawValue
    }
}

extension WorkspaceAdjustableEffect {
    static let metalRenderOrder: [WorkspaceAdjustableEffect] = [
        .rgbSplit,
        .pixelate,
        .posterize,
        .dither,
        .edge,
        .threshold,
        .monochrome,
        .thermal,
        .invert,
        .vhs,
        .grain,
        .crt,
        .dataBend,
        .audioScanBend,
        .audioBandSlice,
        .water,
        .hologram,
        .anamorphicFlare,
        .tiltShift,
        .fisheye,
        .lightLeak,
        .super8,
        .polarWarp,
        .hexTile,
        .shatter,
        .kaleido6,
        .quadMirror,
        .spiralWarp,
        .fold,
        .flowField,
        .contourLines,
        .falseColor,
        .pixelMelt,
        .burnThrough,
        .bitRot,
        .audioRepair,
        .audioTunnel,
        .audioDisplace,
        .kaleidoscope,
        .kuwahara,
        .asciiMosaic,
        // The scopes render last on purpose: an instrument measures what the
        // chain produced, so anything placed after one would be measuring a
        // frame the reading no longer describes.
        .spectrumBars,
        .radialSpectrum,
        .cyberGrid,
        .quantumRaymarch,
        .liquidChroma,
        .holoAurora,
        .waveformTunnel,
        .hologramMatrix,
        .eventHorizon,
        .pixelConfetti,
        .nebulaDrift,
        .singularityWeave,
        .fractalBurst,
        .cmykPress,
    ]

    static let temporalRenderOrder: [WorkspaceAdjustableEffect] = [
        .datamosh,
        .liquidMosh,
        .heavyMosh,
        .predictionDrift,
        .sort,
        .radialSort,
        .pointCloudSmear,
        .feedbackTunnel,
        .frameHoldSmear,
        .pixelShift,
        .slitScan,
        .audioKick,
        .frameTear,
        .sensorSmear,
        .timeFracture,
        .antiCamera,
        .feedback,
        .trails,
        .echo,
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
        metalRenderOrder + temporalRenderOrder + [.fluid]

    /// The historical "mosh rail": real moshes, the predictive moshes, the
    /// sorts and the frame-history effects in one list. Retained because
    /// tests assert that a temporal mode owns its rail entry, not because any
    /// shelf draws it. The browseable shelves below are the accurate split.
    static let legacyMoshRailEffects: [WorkspaceAdjustableEffect] = [
        .datamosh,
        .liquidMosh,
        .heavyMosh,
        .predictionDrift,
        .sort,
        .radialSort,
        .pointCloudSmear,
        .feedbackTunnel,
        .frameHoldSmear,
        .pixelShift
    ]


















    /// Anything that reads the live spectrum must be able to turn the
    /// microphone on, otherwise the effect renders against a silent uniform.
    var requiresAudioAnalysis: Bool {
        // The spectrum scopes and shader family read the live FFT, and need
        // the microphone armed to react dynamically. EXPERIMENTAL is included
        // because the interactive generative block reacts to the spectrum as
        // well as to touch.
        WorkspaceAdjustableEffect.audioFamily.contains(self)
            || WorkspaceAdjustableEffect.generativeFamily.contains(self)
            || [.spectrumBars, .radialSpectrum].contains(self)
    }

    /// Spectrum instruments are composited as movable overlays rather than as
    /// a full-frame grade. Their placement is kept with the slot, so two
    /// spectrum instances can live in different parts of the composition.
    var isSpectrumOverlay: Bool {
        self == .spectrumBars || self == .radialSpectrum
    }

    // MARK: - Consolidated categories (13 effect families)





    // MARK: - Families

    /// The picture as data that has gone wrong: real codec moshes, pixel
    /// sorts and digital damage.
    static let glitchFamily: [WorkspaceAdjustableEffect] = [
        .datamosh,
        .liquidMosh,
        .heavyMosh,
        .predictionDrift,
        .sort,
        .radialSort,
        .pointCloudSmear,
        .pixelShift,
        .dataBend,
        .frameTear,
        .rgbSplit,
        .pixelMelt,
        .burnThrough,
        .bitRot,
    ]

    /// Frame history: feedback, trails, echoes and time slicing.
    static let timeFamily: [WorkspaceAdjustableEffect] = [
        .feedback,
        .trails,
        .echo,
        .slitScan,
        .feedbackTunnel,
        .frameHoldSmear,
        .timeFracture,
        .antiCamera,
    ]

    /// Tape, film, tube and sensor: the artefacts of real hardware.
    static let analogFamily: [WorkspaceAdjustableEffect] = [
        .vhs,
        .crt,
        .super8,
        .grain,
        .hologram,
        .sensorSmear,
    ]

    /// Grades and print processes: the frame redrawn in another medium.
    static let lookFamily: [WorkspaceAdjustableEffect] = [
        .thermal,
        .falseColor,
        .threshold,
        .edge,
        .contourLines,
        .posterize,
        .dither,
        .pixelate,
        .asciiMosaic,
        .cmykPress,
        .kuwahara,
        .monochrome,
        .invert,
    ]

    /// Light through glass. These model optics, so they answer real
    /// highlights and do little on a flat, dim scene.
    static let lensFamily: [WorkspaceAdjustableEffect] = [
        .lightLeak,
        .anamorphicFlare,
        .tiltShift,
        .fisheye,
    ]

    /// Space bent: kaleidoscopes, mirrors, polar maps and fluid surfaces.
    static let warpFamily: [WorkspaceAdjustableEffect] = [
        .kaleidoscope,
        .kaleido6,
        .quadMirror,
        .polarWarp,
        .spiralWarp,
        .shatter,
        .hexTile,
        .fold,
        .flowField,
        .water,
        .fluid,
    ]

    /// Self-generating shader worlds drawn over the frame. They read the
    /// live spectrum, so selecting one arms the microphone.
    static let generativeFamily: [WorkspaceAdjustableEffect] = [
        .cyberGrid,
        .quantumRaymarch,
        .liquidChroma,
        .holoAurora,
        .eventHorizon,
        .nebulaDrift,
        .singularityWeave,
        .fractalBurst,
        .hologramMatrix,
        .pixelConfetti,
    ]

    /// Driven by the live FFT bands. Selecting any of these arms the
    /// audio analyser if it is not already running.
    static let audioFamily: [WorkspaceAdjustableEffect] = [
        .audioTunnel,
        .audioScanBend,
        .audioBandSlice,
        .audioKick,
        .audioRepair,
        .audioDisplace,
        .waveformTunnel,
        .spectrumBars,
        .radialSpectrum,
    ]

    static let curatedCategoryEffectGroups: [[WorkspaceAdjustableEffect]] = [
        glitchFamily,
        timeFamily,
        analogFamily,
        lookFamily,
        lensFamily,
        warpFamily,
        generativeFamily,
        audioFamily,
    ]

    /// The family this effect is filed under, with its title.
    var curatedFamily: (title: String, effects: [WorkspaceAdjustableEffect])? {
        let families: [(title: String, effects: [WorkspaceAdjustableEffect])] = [
            (title: "GLITCH", effects: WorkspaceAdjustableEffect.glitchFamily),
            (title: "TIME", effects: WorkspaceAdjustableEffect.timeFamily),
            (title: "ANALOG", effects: WorkspaceAdjustableEffect.analogFamily),
            (title: "LOOK", effects: WorkspaceAdjustableEffect.lookFamily),
            (title: "LENS", effects: WorkspaceAdjustableEffect.lensFamily),
            (title: "WARP", effects: WorkspaceAdjustableEffect.warpFamily),
            (title: "GENERATIVE", effects: WorkspaceAdjustableEffect.generativeFamily),
            (title: "AUDIO", effects: WorkspaceAdjustableEffect.audioFamily),
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
        case .radialSort: "RADIAL SORT"
        case .pointCloudSmear: "LUMA POINT SMEAR"
        case .feedbackTunnel: "FEEDBACK TUNNEL"
        case .frameHoldSmear: "FRAME-HOLD SMEAR"
        case .pixelShift: "PIXEL SHIFT"
        case .slitScan: "SLIT SCAN"
        case .dataBend: "DATA BEND"
        case .audioScanBend: "AUDIO SCAN BEND"
        case .audioBandSlice: "AUDIO BAND SLICE"
        case .audioKick: "AUDIO KICK"
        case .frameTear: "FRAME TEAR"
        case .sensorSmear: "SENSOR SMEAR"
        case .timeFracture: "TIME FRACTURE"
        case .antiCamera: "ANTI-CAMERA"
        case .water: "WATER"
        case .hologram: "HOLOGRAM"
        case .asciiMosaic: "ASCII"
        case .spectrumBars: "SPECTRUM"
        case .radialSpectrum: "RADIAL SPECTRUM"
        case .predictionDrift: "PREDICTION DRIFT"
        case .cyberGrid: "CYBER GRID"
        case .quantumRaymarch: "RAYMARCH SDF"
        case .liquidChroma: "LIQUID CHROMA"
        case .holoAurora: "HOLO AURORA"
        case .waveformTunnel: "WAVEFORM TUNNEL"
        case .hologramMatrix: "HOLO MATRIX"
        case .eventHorizon: "EVENT HORIZON"
        case .pixelConfetti: "PIXEL CONFETTI"
        case .nebulaDrift: "NEBULA DRIFT"
        case .singularityWeave: "SINGULARITY WEAVE"
        case .fractalBurst: "FRACTAL BURST"
        case .cmykPress: "CMYK PRESS"
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
        case .datamosh: "RECURSIVE FRAME MELT · HOLD TO LOCK SOURCE"
        case .liquidMosh: "COARSE MACROBLOCK MOSH"
        case .heavyMosh: "RECURSIVE CODEC CASCADE"
        case .predictionDrift: "DIFFERENTIAL MOTION MEMORY"
        case .sort: "LUMA LINE SORT"
        case .radialSort: "CENTER OUT SORT"
        case .pointCloudSmear: "SPARSE CLOUD DRAG"
        case .feedbackTunnel: "RECURSIVE TUNNEL"
        case .frameHoldSmear: "HOLD FRAME DRAG"
        case .pixelShift: "BANDED FRAME OFFSET"
        case .slitScan: "ROLLING TIME SLICES"
        case .dataBend: "QUANTIZED MEMORY ADDRESS"
        case .audioScanBend: "BASS-BENT SCANLINES"
        case .audioBandSlice: "BAND-KEYED SLICES"
        case .audioKick: "BASS FRAME STUTTER"
        case .frameTear: "BANDS ON SPLIT CLOCKS"
        case .sensorSmear: "HIGHLIGHT CHARGE BLEED"
        case .timeFracture: "CELLS ON OWN TIMELINES"
        case .antiCamera: "ONLY CHANGE IS DRAWN"
        case .feedback: "FRAME RECURSION"
        case .trails: "LUMA DECAY"
        case .echo: "OFFSET HISTORY"
        case .pixelate: "BLOCK QUANTIZE"
        case .posterize: "COLOR LEVELS"
        case .dither: "ORDERED BAYER"
        case .edge: "SOBEL CONTOUR"
        case .vhs: "ANALOG DAMAGE"
        case .grain: "CHROMA NOISE"
        case .thermal: "HEAT PALETTE"
        case .threshold: "LUMA CUT"
        case .invert: "CHANNEL NEGATIVE"
        case .monochrome: "TINTED LUMA"
        case .crt: "CURVE + GRILLE"
        case .water: "TOUCH-RIPPLED SURFACE"
        case .hologram: "INTERFERENCE PROJECTION"
        case .anamorphicFlare: "ANAMORPHIC FLARE"
        case .tiltShift: "TILT SHIFT"
        case .fisheye: "FISHEYE"
        case .lightLeak: "LIGHT LEAK"
        case .super8: "SUPER 8"
        case .polarWarp: "POLAR WARP"
        case .hexTile: "HEX TILE"
        case .shatter: "SHATTER"
        case .kaleido6: "KALEIDOSCOPE 6"
        case .quadMirror: "QUAD MIRROR"
        case .spiralWarp: "SPIRAL WARP"
        case .fold: "FOLD"
        case .flowField: "FLOW FIELD"
        case .contourLines: "CONTOUR LINES"
        case .falseColor: "FALSE COLOUR"
        case .pixelMelt: "PIXEL MELT"
        case .burnThrough: "BURN THROUGH"
        case .bitRot: "BIT ROT"
        case .audioRepair: "AUDIO DAMAGE / REPAIR"
        case .audioTunnel: "AUDIO TUNNEL"
        case .audioDisplace: "AUDIO DISPLACE"
        case .fluid: "FLUID"
        case .kaleidoscope: "RADIAL SEGMENT FOLD"
        case .kuwahara: "PAINTERLY EDGE-PRESERVE"
        case .asciiMosaic: "GLYPH DENSITY GRID"
        case .spectrumBars: "16-BAND FFT BARS"
        case .radialSpectrum: "FFT WRAPPED TO A RING"
        case .cyberGrid: "QUANTUM LASER MATRIX"
        case .quantumRaymarch: "3D SDF HYPERCUBE CORRIDOR"
        case .liquidChroma: "NEON FLUID DISPERSION"
        case .holoAurora: "PRISMATIC WAVE INTERFERENCE"
        case .waveformTunnel: "AUDIO WAVEFORM CORRIDOR"
        case .hologramMatrix: "HOLOGRAPHIC FALLING CODE"
        case .eventHorizon: "RECURSIVE WARP COLLAPSE"
        case .pixelConfetti: "BEAT-SYNCED COLOUR PARTICLES"
        case .nebulaDrift: "LIQUID NEBULA CLOUDS"
        case .singularityWeave: "WORMHOLE INTERFERENCE PATTERN"
        case .fractalBurst: "CATASTROPHIC FRACTAL EXPLOSION"
        case .cmykPress: "FOUR ROTATED SUBTRACTIVE INK SCREENS"
        }
    }

    var styleMode: UInt32? {
        switch self {
        case .pixelate: 1
        case .posterize: 2
        case .dither: 3
        case .edge: 4
        case .vhs: 6
        case .grain: 10
        case .thermal: 11
        case .threshold: 13
        case .invert: 14
        case .monochrome: 18
        case .crt: 22
        case .dataBend: 23
        case .audioScanBend: 27
        case .audioBandSlice: 30
        case .water: 31
        case .hologram: 36
        case .anamorphicFlare: 38
        case .tiltShift: 40
        case .fisheye: 41
        case .lightLeak: 43
        case .super8: 49
        case .polarWarp: 57
        case .hexTile: 59
        case .shatter: 60
        case .kaleido6: 61
        case .quadMirror: 62
        case .spiralWarp: 63
        case .fold: 66
        case .flowField: 67
        case .contourLines: 71
        case .falseColor: 74
        case .pixelMelt: 77
        case .burnThrough: 79
        case .bitRot: 81
        case .audioRepair: 85
        case .audioTunnel: 86
        case .audioDisplace: 89
        case .kaleidoscope: 7
        case .kuwahara: 92
        case .asciiMosaic: 93
        case .spectrumBars: 98
        case .radialSpectrum: 99
        case .cyberGrid: 104
        case .quantumRaymarch: 106
        case .liquidChroma: 107
        case .holoAurora: 108
        case .waveformTunnel: 113
        case .hologramMatrix: 116
        case .eventHorizon: 119
        case .pixelConfetti: 125
        case .nebulaDrift: 130
        case .singularityWeave: 134
        case .fractalBurst: 135
        case .cmykPress: 140
        case .fluid: nil
        case .rgbSplit, .datamosh, .liquidMosh, .heavyMosh, .predictionDrift, .sort,
             .radialSort, .pointCloudSmear, .feedbackTunnel,
             .frameHoldSmear, .pixelShift, .slitScan, .audioKick,
             .frameTear, .sensorSmear, .timeFracture, .antiCamera,
             .feedback, .trails, .echo:
            nil
        }
    }

    var temporalMode: UInt32? {
        switch self {
        case .feedback: 0
        case .trails: 1
        case .echo: 2
        // Three separate kernels. They shared mode 4 and differed only by
        // their default slider values, which made two thirds of the DATAMOSH
        // rail a relabelling of one effect - and broke the registry's
        // one-effect-one-mode invariant.
        case .datamosh: 4
        case .liquidMosh: 39
        case .heavyMosh: 40
        case .predictionDrift: 43
        case .sort: 5
        case .radialSort: 8
        case .pointCloudSmear: 10
        case .feedbackTunnel: 14
        case .frameHoldSmear: 18
        case .pixelShift: 20
        case .slitScan: 21
        case .audioKick: 24
        case .frameTear: 25
        case .sensorSmear: 29
        case .timeFracture: 32
        case .antiCamera: 33
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
        case .datamosh: ["MEMORY", "MOTION", "DIRECTION"]
        case .liquidMosh: ["SCALE", "DROP", "BITS"]
        case .heavyMosh: ["RECYCLE", "GOP", "BITS"]
        case .predictionDrift: ["DRIFT", "DECAY", "TEAR"]
        case .sort: ["SPAN", "BIAS", "MIX"]
        case .radialSort: ["RADIUS", "SPIN", "MIX"]
        case .pointCloudSmear: ["DENSITY", "DRIFT", "SMEAR"]
        case .feedbackTunnel: ["PULL", "SPIN", "DECAY"]
        case .frameHoldSmear: ["HOLD", "ANGLE", "SMEAR"]
        case .pixelShift: ["OFFSET", "BANDS", "MIX"]
        case .slitScan: ["ROLL", "WIDTH", "MIX"]
        case .dataBend: ["SHIFT", "ROWS", "MIX"]
        case .audioScanBend: ["BEND", "LINES", "MIX"]
        case .audioBandSlice: ["SHIFT", "SLICES", "MIX"]
        case .audioKick: ["HOLD", "GATE", "MIX"]
        case .frameTear: ["TEAR", "BANDS", "DRIFT"]
        case .sensorSmear: ["THRESH", "LENGTH", "BLOOM"]
        case .timeFracture: ["CELLS", "SPREAD", "DRIFT"]
        case .antiCamera: ["GATE", "PERSIST", "INVERT"]
        case .feedback: ["MIX", "ZOOM", "DRIFT"]
        case .trails: ["DECAY", "COLOR", "SMEAR"]
        case .echo: ["DISTANCE", "ANGLE", "MIX"]
        case .pixelate: ["BLOCK", "MIX", "ASPECT"]
        case .posterize: ["LEVELS", "MIX", "CONTRAST"]
        case .dither: ["SCALE", "STRENGTH", "LEVELS"]
        case .edge: ["WIDTH", "THRESHOLD", "MIX"]
        case .vhs: ["DAMAGE", "SCAN", "NOISE"]
        case .grain: ["AMOUNT", "SIZE", "CHROMA"]
        case .thermal: ["SHIFT", "CONTRAST", "MIX"]
        case .threshold: ["LEVEL", "SOFTNESS", "MIX"]
        case .invert: ["AMOUNT", "CHANNEL", "MIX"]
        case .monochrome: ["TINT", "CONTRAST", "MIX"]
        case .crt: ["CURVE", "SCAN", "GRILLE"]
        case .water: ["RIPPLE", "FREQUENCY", "SPEED"]
        case .hologram: ["FREQUENCY", "LINES", "DRIFT"]
        case .anamorphicFlare: ["LENGTH", "GATE", "GAIN"]
        case .tiltShift: ["BLUR", "BAND", "FALLOFF"]
        case .fisheye: ["CURVE", "CROP", "MIX"]
        case .lightLeak: ["WIDTH", "DRIFT", "GAIN"]
        case .super8: ["WEAVE", "GRAIN", "MIX"]
        case .polarWarp: ["CURVE", "REPEAT", "SPIN"]
        case .hexTile: ["SCALE", "BORDER", "MIX"]
        case .shatter: ["DRIFT", "CELLS", "MIX"]
        case .kaleido6: ["MIX", "ZOOM", "SPIN"]
        case .quadMirror: ["FLIP", "ZOOM", "MIX"]
        case .spiralWarp: ["TWIST", "MIX", "SPIN"]
        case .fold: ["FOLD", "ZOOM", "SPIN"]
        case .flowField: ["PUSH", "SCALE", "MIX"]
        case .contourLines: ["WIDTH", "LEVELS", "MIX"]
        case .falseColor: ["CONTRAST", "OFFSET", "MIX"]
        case .pixelMelt: ["SAG", "COLUMNS", "MIX"]
        case .burnThrough: ["SCALE", "RATE", "MIX"]
        case .bitRot: ["ROT", "BLOCKS", "MIX"]
        case .audioRepair: ["DAMAGE", "BLOCKS", "MIX"]
        case .audioTunnel: ["PULL", "SPIN", "MIX"]
        case .audioDisplace: ["SHIFT", "SLICES", "MIX"]
        case .fluid: ["DRAG", "PERSIST", "SWIRL"]
        case .kaleidoscope: ["SEGMENTS", "SPIN", "ZOOM"]
        case .kuwahara: ["RADIUS", "CONTRAST", "MIX"]
        case .asciiMosaic: ["CELL", "GAMMA", "COLOUR"]
        case .spectrumBars: ["SIZE", "BARS", "HUE"]
        case .radialSpectrum: ["SIZE", "INNER", "HUE"]
        case .cyberGrid: ["GRID", "COLOR", "MIX"]
        case .quantumRaymarch: ["MORPH", "GLOW", "MIX"]
        case .liquidChroma: ["DISPERSE", "SAT", "MIX"]
        case .holoAurora: ["PHASE", "GAIN", "MIX"]
        case .waveformTunnel: ["DEPTH", "RESONANCE", "MIX"]
        case .hologramMatrix: ["RAIN", "SCANLINE", "MIX"]
        case .eventHorizon: ["DEPTH", "SPIN", "MIX"]
        case .pixelConfetti: ["DENSITY", "ENERGY", "MIX"]
        case .nebulaDrift: ["DRIFT", "SWIRL", "MIX"]
        case .singularityWeave: ["PULL", "CHROMA", "MIX"]
        case .fractalBurst: ["EXPAND", "SPIN", "MIX"]
        case .cmykPress: ["SCREEN", "REGISTER", "INK"]
        default: []
        }
    }

    var defaultCameraParameters: CameraEffectParameters {
        let values: SIMD3<Double> = switch self {
        // Mosh starts from a recent seed. Strength comes from recursively
        // carrying and warping the decoded frame, not from showing a visibly
        // delayed camera feed.
        case .datamosh: SIMD3(0.998, 0.65, 0.5)
        case .liquidMosh: SIMD3(0.85, 0.72, 0.18)
        case .heavyMosh: SIMD3(0.95, 0.18, 0.90)
        case .predictionDrift: SIMD3(0.72, 0.82, 0.38)
        case .sort: SIMD3(0.58, 0.48, 0.82)
        case .radialSort: SIMD3(0.62, 0.58, 0.78)
        case .pointCloudSmear: SIMD3(0.48, 0.62, 0.72)
        case .feedbackTunnel: SIMD3(0.72, 0.52, 0.74)
        case .frameHoldSmear: SIMD3(0.82, 0.46, 0.76)
        case .pixelShift: SIMD3(0.62, 0.46, 0.86)
        case .slitScan: SIMD3(0.58, 0.42, 0.82)
        case .dataBend: SIMD3(0.54, 0.46, 0.84)
        case .audioScanBend: SIMD3(0.58, 0.52, 0.88)
        case .audioBandSlice: SIMD3(0.60, 0.50, 0.86)
        case .audioKick: SIMD3(0.58, 0.46, 0.82)
        case .frameTear: SIMD3(0.52, 0.44, 0.38)
        case .sensorSmear: SIMD3(0.62, 0.52, 0.46)
        case .timeFracture: SIMD3(0.46, 0.52, 0.38)
        case .antiCamera: SIMD3(0.40, 0.62, 0.0)
        case .feedback: SIMD3(0.72, 0.55, 0.52)
        case .trails: SIMD3(0.82, 0.24, 0.20)
        case .echo: SIMD3(0.25, 0.12, 0.72)
        case .pixelate: SIMD3(0.20, 1.00, 0.50)
        case .posterize: SIMD3(0.18, 1.00, 0.52)
        case .dither: SIMD3(0.24, 0.78, 0.25)
        case .edge: SIMD3(0.24, 0.16, 1.00)
        case .vhs: SIMD3(0.38, 0.44, 0.30)
        case .grain: SIMD3(0.20, 0.18, 0.25)
        case .thermal: SIMD3(0.50, 0.58, 1.00)
        case .threshold: SIMD3(0.50, 0.08, 1.00)
        case .invert: SIMD3(1.00, 0.50, 1.00)
        case .monochrome: SIMD3(0.72, 0.54, 1.00)
        case .crt: SIMD3(0.30, 0.62, 0.55)
        case .water: SIMD3(0.26, 0.40, 0.52)
        case .hologram: SIMD3(0.40, 0.38, 0.52)
        case .anamorphicFlare: SIMD3(0.54, 0.62, 0.70)
        case .tiltShift: SIMD3(0.58, 0.50, 0.42)
        case .fisheye: SIMD3(0.52, 0.40, 0.88)
        case .lightLeak: SIMD3(0.56, 0.38, 0.68)
        case .super8: SIMD3(0.46, 0.42, 0.80)
        case .polarWarp: SIMD3(0.52, 0.30, 0.50)
        case .hexTile: SIMD3(0.42, 0.46, 0.86)
        case .shatter: SIMD3(0.44, 0.48, 0.84)
        case .kaleido6: SIMD3(0.82, 0.52, 0.54)
        case .quadMirror: SIMD3(0.70, 0.50, 0.86)
        case .spiralWarp: SIMD3(0.44, 0.82, 0.52)
        case .fold: SIMD3(0.48, 0.46, 0.50)
        case .flowField: SIMD3(0.50, 0.46, 0.84)
        case .contourLines: SIMD3(0.40, 0.46, 0.80)
        case .falseColor: SIMD3(0.52, 0.50, 0.88)
        case .pixelMelt: SIMD3(0.50, 0.54, 0.84)
        case .burnThrough: SIMD3(0.48, 0.36, 0.86)
        case .bitRot: SIMD3(0.46, 0.52, 0.86)
        case .audioRepair: SIMD3(0.64, 0.52, 0.88)
        case .audioTunnel: SIMD3(0.56, 0.48, 0.86)
        case .audioDisplace: SIMD3(0.58, 0.52, 0.86)
        case .fluid: SIMD3(0.55, 0.62, 0.50)
        case .kaleidoscope: SIMD3(0.34, 0.50, 0.52)
        case .kuwahara: SIMD3(0.46, 0.42, 0.86)
        case .asciiMosaic: SIMD3(0.34, 0.52, 0.28)
        // Scopes default to a strong mix: a measurement drawn at 40% is not a
        // reading, it is a ghost.
        case .spectrumBars: SIMD3(0.58, 0.45, 0.92)
        case .radialSpectrum: SIMD3(0.55, 0.35, 0.90)
        case .cyberGrid: SIMD3(0.50, 0.40, 0.90)
        case .quantumRaymarch: SIMD3(0.35, 0.75, 0.92)
        case .liquidChroma: SIMD3(0.55, 0.65, 0.85)
        case .holoAurora: SIMD3(0.45, 0.60, 0.88)
        case .waveformTunnel: SIMD3(0.45, 0.55, 0.90)
        case .hologramMatrix: SIMD3(0.60, 0.50, 0.88)
        case .eventHorizon: SIMD3(0.56, 0.54, 0.92)
        case .pixelConfetti: SIMD3(0.50, 0.62, 0.86)
        case .nebulaDrift: SIMD3(0.52, 0.70, 0.92)
        case .singularityWeave: SIMD3(0.50, 0.58, 0.88)
        case .fractalBurst: SIMD3(0.42, 0.66, 0.90)
        case .cmykPress: SIMD3(0.48, 0.24, 0.78)
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
        case .cmykPress: 1.5
        case .quantumRaymarch:
            2.6
        case .liquidChroma, .cyberGrid, .holoAurora,
             .waveformTunnel, .hologramMatrix, .eventHorizon, .pixelConfetti,
             .nebulaDrift,
             .singularityWeave, .fractalBurst:
            1.6
        case .hologram, .water, .crt, .dataBend:
            1.4
        // Sixty-four taps per pixel over the whole frame. It is the most
        // expensive style kernel in the set and the budget must know that
        // before it starts dropping cheaper effects to pay for it.
        case .kuwahara:
            3.2
        // The scopes gate to their own panel, so the tap count is paid over a
        // fraction of the frame rather than all of it.
        case .liquidMosh:
            2.4
        case .datamosh, .sort, .radialSort,
             .pointCloudSmear, .feedbackTunnel,
             .frameHoldSmear,
             .pixelShift, .slitScan, .audioKick,
             .heavyMosh, .feedback, .trails, .echo,
             .frameTear, .sensorSmear, .timeFracture, .antiCamera:
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
        case .datamosh, .liquidMosh, .heavyMosh, .predictionDrift,
             .sort, .radialSort,
             .pointCloudSmear, .feedbackTunnel,
             .frameHoldSmear,
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
    var datamoshBlockSize = 16
    var datamoshVelocityDecay = 0.18
    var datamoshResidual = 0.0015

    init(
        isEnabled: Bool = false,
        primary: Double = 0.5,
        secondary: Double = 0.5,
        tertiary: Double = 0.5,
        blend: Double = 1.0,
        overlayX: Double = 0.5,
        overlayY: Double = 0.5,
        datamoshBlockSize: Int = 16,
        datamoshVelocityDecay: Double = 0.18,
        datamoshResidual: Double = 0.0015
    ) {
        self.isEnabled = isEnabled
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.blend = blend
        self.overlayX = overlayX
        self.overlayY = overlayY
        self.datamoshBlockSize = datamoshBlockSize
        self.datamoshVelocityDecay = datamoshVelocityDecay
        self.datamoshResidual = datamoshResidual
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, primary, secondary, tertiary, blend, overlayX, overlayY
        case datamoshBlockSize, datamoshVelocityDecay, datamoshResidual
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
        datamoshBlockSize = try values.decodeIfPresent(Int.self, forKey: .datamoshBlockSize) ?? 16
        datamoshVelocityDecay = try values.decodeIfPresent(Double.self, forKey: .datamoshVelocityDecay) ?? 0.18
        datamoshResidual = try values.decodeIfPresent(Double.self, forKey: .datamoshResidual) ?? 0.0015
    }

    var sanitized: CameraEffectParameters {
        CameraEffectParameters(
            isEnabled: isEnabled,
            primary: min(max(primary, 0), 1),
            secondary: min(max(secondary, 0), 1),
            tertiary: min(max(tertiary, 0), 1),
            blend: min(max(blend, 0), 1),
            overlayX: min(max(overlayX, 0.05), 0.95),
            overlayY: min(max(overlayY, 0.05), 0.95),
            datamoshBlockSize: [8, 16, 32].contains(datamoshBlockSize) ? datamoshBlockSize : 16,
            datamoshVelocityDecay: datamoshVelocityDecay.isFinite ? min(max(datamoshVelocityDecay, 0), 1) : 0.18,
            datamoshResidual: datamoshResidual.isFinite ? min(max(datamoshResidual, 0), 1) : 0.0015
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
