import Foundation
import Metal

enum RenderFailurePolicy: Sendable {
    case bypass
    case bypassAndDisable
    case stop
}

struct RenderGraphResult: @unchecked Sendable {
    let texture: MTLTexture
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
        // Whether anything runs is a question about the list, not a question
        // that needs a copy of it answered. The filter this replaced allocated
        // an array every frame to hold a subset of a list that rarely changed.
        let hasActiveEffect = effects.contains { !$0.shouldBypass() }
        guard hasActiveEffect else {
            return RenderGraphResult(texture: input, failedEffectIdentifiers: [])
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
                    failedEffectIdentifiers: ["render.graph"]
                )
            }
            guard let pooledB = texturePool.checkout(key, label: "greyVISION graph pong") else {
                texturePool.recycle(pooledA)
                return RenderGraphResult(
                    texture: input,
                    failedEffectIdentifiers: ["render.graph"]
                )
            }
            textureA = pooledA
            textureB = pooledB
        }

        var current = input
        var destination = textureA
        var failures: [String] = []

        for effect in effects {
            do {
                try effect.process(EffectRenderRequest(
                    frame: frame,
                    input: current,
                    output: destination,
                    mix: min(max(effect.mix, 0), 1),
                    mask: effect.mask,
                    parameters: effect.parameterState
                ))
                current = destination
                destination = ObjectIdentifier(destination) == ObjectIdentifier(textureA)
                    ? textureB
                    : textureA
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                failures.append(effect.identifier)
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
            failedEffectIdentifiers: failures
        )
    }

    private static func matches(_ texture: MTLTexture, input: MTLTexture) -> Bool {
        texture.width == input.width &&
            texture.height == input.height &&
            texture.pixelFormat == input.pixelFormat
    }
}
