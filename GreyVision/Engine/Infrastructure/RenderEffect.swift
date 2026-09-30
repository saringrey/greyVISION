import Foundation
import Metal

enum RenderEffectKind: String, Codable, Sendable {
    case stateless
    case temporal
    case analysis
    case composite
}

enum EffectResetReason: String, Codable, Sendable {
    case explicit
    case sourceChanged
    case orientationChanged
    case formatChanged
    case disabled
    case memoryWarning
    case renderRestarted
}

struct EffectRenderFormat: Equatable, Sendable {
    var dimensions: RenderDimensions
    var pixelFormat: MTLPixelFormat
    var internalScale: Float

    var scaledDimensions: RenderDimensions {
        let safeScale = min(max(internalScale.isFinite ? internalScale : 1, 0.25), 1)
        return RenderDimensions(
            width: max(Int((Float(dimensions.width) * safeScale).rounded()), 1),
            height: max(Int((Float(dimensions.height) * safeScale).rounded()), 1)
        )
    }
}

struct RenderPreparationContext: @unchecked Sendable {
    let device: MTLDevice
    let library: MTLLibrary
    let texturePool: TexturePool
    let temporalBuffers: TemporalBufferBank
    let format: EffectRenderFormat
}

struct EffectRenderRequest: @unchecked Sendable {
    let frame: FrameContext
    let input: MTLTexture
    let output: MTLTexture
    let mix: Float
    let mask: EffectMaskInput
    let parameters: EffectParameterState
}

enum RenderEffectError: Error, Equatable, LocalizedError {
    case unavailable(String)
    case invalidFormat(String)
    case resourceAllocationFailed(String)
    case encoderUnavailable(String)
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message), let .invalidFormat(message),
             let .resourceAllocationFailed(message), let .encoderUnavailable(message),
             let .processingFailed(message): message
        }
    }
}

/// GPU-native effect contract. Effects receive all external frame state through
/// `EffectRenderRequest`; they do not reach into camera, view, or gesture owners.
protocol RenderEffect: AnyObject {
    var identifier: String { get }
    var displayName: String { get }
    var kind: RenderEffectKind { get }
    var isEnabled: Bool { get set }
    var mix: Float { get set }
    var internalScale: Float { get }
    var parameterDefinitions: [ParameterDefinition] { get }
    var parameterState: EffectParameterState { get set }
    var mask: EffectMaskInput { get set }

    func prepare(_ context: RenderPreparationContext) throws
    func resize(to format: EffectRenderFormat, context: RenderPreparationContext) throws
    func process(_ request: EffectRenderRequest) throws
    func reset(reason: EffectResetReason)
    func releaseResources()
}

extension RenderEffect {
    var internalScale: Float { 1 }
    var mask: EffectMaskInput {
        get { .none }
        set {}
    }

    func shouldBypass() -> Bool {
        !isEnabled || !mix.isFinite || mix <= 0
    }

    func resize(to _: EffectRenderFormat, context _: RenderPreparationContext) throws {}
    func reset(reason _: EffectResetReason) {}
    func releaseResources() {}
}

struct SerializableEffectSlot: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var effectIdentifier: String
    var isEnabled: Bool
    var mix: Float
    var parameters: [String: ParameterState]
    var routingIdentifier: String?
    var maskMix: Float
    var maskIsInverted: Bool

    init(
        id: UUID = UUID(),
        effectIdentifier: String,
        isEnabled: Bool,
        mix: Float,
        parameters: [String: ParameterState],
        routingIdentifier: String? = nil,
        maskMix: Float = 1,
        maskIsInverted: Bool = false
    ) {
        self.id = id
        self.effectIdentifier = effectIdentifier
        self.isEnabled = isEnabled
        self.mix = mix
        self.parameters = parameters
        self.routingIdentifier = routingIdentifier
        self.maskMix = maskMix
        self.maskIsInverted = maskIsInverted
    }
}

struct SerializableRenderGraphState: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var orderedSlots: [SerializableEffectSlot]
}

struct RenderGraphModel: Equatable, Sendable {
    private(set) var orderedEffectIdentifiers: [String] = []

    mutating func replace(with identifiers: [String]) {
        orderedEffectIdentifiers = identifiers
    }

    mutating func move(from source: Int, to destination: Int) {
        guard orderedEffectIdentifiers.indices.contains(source),
              destination >= 0, destination <= orderedEffectIdentifiers.count
        else { return }
        let value = orderedEffectIdentifiers.remove(at: source)
        orderedEffectIdentifiers.insert(value, at: min(destination, orderedEffectIdentifiers.count))
    }
}
