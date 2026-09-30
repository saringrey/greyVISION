import CoreMedia
import Foundation
import Metal
import simd

struct RenderDimensions: Codable, Equatable, Hashable, Sendable {
    var width: Int
    var height: Int

    var isValid: Bool { width > 0 && height > 0 }
    var pixelCount: Int { isValid ? width * height : 0 }
}

struct RenderResolutionSet: Codable, Equatable, Sendable {
    var capture: RenderDimensions
    var preview: RenderDimensions
    var effects: RenderDimensions
    var output: RenderDimensions
}

enum RenderColorTransfer: String, Codable, Equatable, Sendable {
    case linear
    case sRGB
    case rec709
    case hlg
    case pq
    case log
    case unknown
}

enum RenderColorPrimaries: String, Codable, Equatable, Sendable {
    case rec709
    case displayP3
    case rec2020
    case unknown
}

struct RenderColorPipeline: Codable, Equatable, Sendable {
    var inputTransfer: RenderColorTransfer
    var workingTransfer: RenderColorTransfer
    var previewTransfer: RenderColorTransfer
    var outputTransfer: RenderColorTransfer
    var primaries: RenderColorPrimaries
    var isHDR: Bool

    static let cameraSDR = RenderColorPipeline(
        inputTransfer: .rec709,
        workingTransfer: .linear,
        previewTransfer: .sRGB,
        outputTransfer: .rec709,
        primaries: .rec709,
        isHDR: false
    )
}

struct RenderOrientationState: Codable, Equatable, Sendable {
    var source: CapturedFrameOrientation
    var render: CapturedFrameOrientation
    var display: CapturedFrameOrientation
    var record: CapturedFrameOrientation
    var isMirrored: Bool

    func sourceToRender(_ coordinate: SIMD2<Float>) -> SIMD2<Float> {
        var uv = Self.rotate(coordinate, from: source, to: render)
        if isMirrored { uv.x = 1 - uv.x }
        return uv
    }

    private static func quarterTurns(_ orientation: CapturedFrameOrientation) -> Int {
        switch orientation {
        case .landscapeRight: 0
        case .portrait: 1
        case .landscapeLeft: 2
        case .portraitUpsideDown: 3
        }
    }

    private static func rotate(
        _ uv: SIMD2<Float>,
        from source: CapturedFrameOrientation,
        to destination: CapturedFrameOrientation
    ) -> SIMD2<Float> {
        let turns = (quarterTurns(destination) - quarterTurns(source) + 4) % 4
        return switch turns {
        case 1: SIMD2<Float>(1 - uv.y, uv.x)
        case 2: SIMD2<Float>(1 - uv.x, 1 - uv.y)
        case 3: SIMD2<Float>(uv.y, 1 - uv.x)
        default: uv
        }
    }
}

struct CameraFrameMetadata: Equatable, Sendable {
    var presentationTime: CMTime
    var exposureDurationSeconds: Double?
    var iso: Float?
    var lensPosition: Float?
    var whiteBalanceTemperature: Float?
    var sourceIdentifier: String?
}

struct RenderInteractionState: Equatable, Sendable {
    var position = SIMD2<Float>(repeating: 0.5)
    var velocity = SIMD2<Float>.zero
    var drag = SIMD2<Float>.zero
    var impactPosition: SIMD2<Float>?
    var impactAge: TimeInterval?
    var isActive = false

    static let idle = RenderInteractionState()
}

struct RenderModulationState: Equatable, Sendable {
    var values: [String: Float] = [:]

    subscript(identifier: String) -> Float {
        values[identifier] ?? 0
    }

    static let empty = RenderModulationState()
}

struct EffectMaskInput: @unchecked Sendable {
    var texture: MTLTexture?
    var mix: Float
    var isInverted: Bool

    init(texture: MTLTexture? = nil, mix: Float = 1, isInverted: Bool = false) {
        self.texture = texture
        self.mix = min(max(mix.isFinite ? mix : 0, 0), 1)
        self.isInverted = isInverted
    }

    static let none = EffectMaskInput()
}

/// Explicit per-frame input to plug-in render effects. GPU objects are owned by
/// the render thread and must not escape the command buffer completion boundary.
struct FrameContext: @unchecked Sendable {
    let frameIndex: UInt64
    let timestamp: TimeInterval
    let deltaTime: TimeInterval
    let sourceTexture: MTLTexture
    let previousSourceTexture: MTLTexture?
    let resolutions: RenderResolutionSet
    let orientation: RenderOrientationState
    let colorPipeline: RenderColorPipeline
    let cameraMetadata: CameraFrameMetadata
    let temporalBuffers: TemporalBufferBank
    let motionField: MotionFieldSnapshot
    let interaction: RenderInteractionState
    let modulation: RenderModulationState
    let commandBuffer: MTLCommandBuffer

    var safeDeltaTime: TimeInterval {
        min(max(deltaTime.isFinite ? deltaTime : 1 / 60, 1 / 240), 0.25)
    }
}
