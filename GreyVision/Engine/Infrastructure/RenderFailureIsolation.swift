import Foundation
import Metal

enum RenderFailurePolicy: Sendable {
    case bypass
    case bypassAndDisable
    case stop
}

struct RenderPassMeasurement: Equatable, Sendable {
    var identifier: String
    var cpuEncodingMilliseconds: Double
    var wasBypassed: Bool
    var failure: String?
}

struct RenderGraphResult: @unchecked Sendable {
    let texture: MTLTexture
    let measurements: [RenderPassMeasurement]
    let failedEffectIdentifiers: [String]
}

/// Sequential graph executor. Effect order is authoritative. Failed effects
/// leave `current` unchanged, so processing continues from the last valid image.
final class RenderGraph: @unchecked Sendable {
    private let texturePool: TexturePool
    private(set) var effects: [any RenderEffect] = []
    var failurePolicy = RenderFailurePolicy.bypassAndDisable
    var onFailure: (@Sendable (_ effectIdentifier: String, _ message: String) -> Void)?

    init(texturePool: TexturePool) {
        self.texturePool = texturePool
    }

    func replaceEffects(_ effects: [any RenderEffect]) {
        self.effects = effects
    }

    var orderedEffectIdentifiers: [String] { effects.map(\.identifier) }

    func process(
        input: MTLTexture,
        frame: FrameContext,
        scratchTextures: (MTLTexture, MTLTexture)? = nil
    ) -> RenderGraphResult {
        let active = effects.filter { !$0.shouldBypass() }
        guard !active.isEmpty else {
            return RenderGraphResult(texture: input, measurements: [], failedEffectIdentifiers: [])
        }

        let ownsScratchTextures = scratchTextures == nil
        let textureA: MTLTexture
        let textureB: MTLTexture
        if let scratchTextures,
           Self.matches(scratchTextures.0, input: input),
           Self.matches(scratchTextures.1, input: input),
           ObjectIdentifier(scratchTextures.0) != ObjectIdentifier(scratchTextures.1)
        {
            textureA = scratchTextures.0
            textureB = scratchTextures.1
        } else if scratchTextures != nil {
            return RenderGraphResult(
                texture: input,
                measurements: [RenderPassMeasurement(
                    identifier: "render.graph",
                    cpuEncodingMilliseconds: 0,
                    wasBypassed: true,
                    failure: "Invalid external graph scratch textures"
                )],
                failedEffectIdentifiers: ["render.graph"]
            )
        } else {
            let key = TexturePoolKey(
                width: input.width,
                height: input.height,
                pixelFormat: input.pixelFormat
            )
            guard let pooledA = texturePool.checkout(key, label: "greyVISION graph ping") else {
                return RenderGraphResult(
                    texture: input,
                    measurements: [RenderPassMeasurement(
                        identifier: "render.graph",
                        cpuEncodingMilliseconds: 0,
                        wasBypassed: true,
                        failure: "Texture pool budget exhausted"
                    )],
                    failedEffectIdentifiers: ["render.graph"]
                )
            }
            guard let pooledB = texturePool.checkout(key, label: "greyVISION graph pong") else {
                texturePool.recycle(pooledA)
                return RenderGraphResult(
                    texture: input,
                    measurements: [RenderPassMeasurement(
                        identifier: "render.graph",
                        cpuEncodingMilliseconds: 0,
                        wasBypassed: true,
                        failure: "Texture pool budget exhausted"
                    )],
                    failedEffectIdentifiers: ["render.graph"]
                )
            }
            textureA = pooledA
            textureB = pooledB
        }

        var current = input
        var destination = textureA
        var measurements: [RenderPassMeasurement] = []
        var failures: [String] = []

        for effect in active {
            let start = ProcessInfo.processInfo.systemUptime
            do {
                try effect.process(EffectRenderRequest(
                    frame: frame,
                    input: current,
                    output: destination,
                    mix: min(max(effect.mix, 0), 1),
                    mask: effect.mask,
                    parameters: effect.parameterState
                ))
                measurements.append(RenderPassMeasurement(
                    identifier: effect.identifier,
                    cpuEncodingMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000,
                    wasBypassed: false,
                    failure: nil
                ))
                current = destination
                destination = ObjectIdentifier(destination) == ObjectIdentifier(textureA)
                    ? textureB
                    : textureA
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                failures.append(effect.identifier)
                measurements.append(RenderPassMeasurement(
                    identifier: effect.identifier,
                    cpuEncodingMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000,
                    wasBypassed: true,
                    failure: message
                ))
                onFailure?(effect.identifier, message)
                switch failurePolicy {
                case .bypass:
                    continue
                case .bypassAndDisable:
                    effect.isEnabled = false
                case .stop:
                    if ownsScratchTextures {
                        texturePool.recycle(textureA, after: frame.commandBuffer)
                        texturePool.recycle(textureB, after: frame.commandBuffer)
                    }
                    return RenderGraphResult(
                        texture: current,
                        measurements: measurements,
                        failedEffectIdentifiers: failures
                    )
                }
            }
        }

        if ownsScratchTextures {
            texturePool.recycle(textureA, after: frame.commandBuffer)
            texturePool.recycle(textureB, after: frame.commandBuffer)
        }
        return RenderGraphResult(
            texture: current,
            measurements: measurements,
            failedEffectIdentifiers: failures
        )
    }

    private static func matches(_ texture: MTLTexture, input: MTLTexture) -> Bool {
        texture.width == input.width &&
            texture.height == input.height &&
            texture.pixelFormat == input.pixelFormat
    }
}
