import Foundation
import Metal
import simd

/// Must match the `GVParticleUniforms` struct in `ParticleShaders.metal`
/// (16 bytes: float2 + float + float).
struct GVParticleUniforms {
    /// Output texture size in pixels.
    var viewportSize: SIMD2<Float>
    /// Slot mix, applied on top of the per-particle glow.
    var globalAlpha: Float
    /// Point-size multiplier. 1 on device pixels; the wiring may raise it
    /// when the effect renders at a reduced internal scale.
    var pointScale: Float
}

/// One particle emitter as a first-class render-graph node.
///
/// The effect owns a ``GVParticleEngine`` (CPU simulation, render-thread
/// confined) and a small GPU pipeline (point sprites, additive blend) that
/// composites the particles over the processed frame. Because it renders in
/// the processed-frame path, `GVVideoRecorder` captures the particles with
/// no extra work.
///
/// Fail-closed posture, following `CameraReactionDiffusion`: every
/// Metal lookup is guarded, `prepare` throws instead of trapping, and a
/// missing pipeline degrades to zero particles — never to a crash or a
/// half-rendered frame.
///
/// Concurrency: render-thread confined. `signalMailbox` is the only
/// cross-thread surface and it is lock-guarded. `qualityScale` is set from
/// the render thread alongside `process`.
final class GVParticleOverlayEffect: RenderEffect, @unchecked Sendable {
    let emitter: GVParticleEmitterKind
    let identifier: String
    let displayName: String
    let kind: RenderEffectKind = .composite

    var isEnabled = true
    var mix: Float = 1
    var parameterDefinitions: [ParameterDefinition] { GVParticleParameters.definitions }
    var parameterState = EffectParameterState()

    /// Live signal feed, published once per frame by the render loop.
    /// See ``GVParticleSignals/from(audio:motion:depth:depthPresent:)`` for
    /// the exact publish snippet.
    let signalMailbox = GVParticleSignalMailbox()

    /// Governor input: 1 = full detail, 0.5 = reduced. Halves the particle
    /// population at 0.5. Set from the render thread.
    var qualityScale: Float = 1 {
        didSet { engine?.noteQualityScale(qualityScale) }
    }

    /// Telemetry hook: alive particle count this frame.
    var activeParticleCount: Int { engine?.activeCount ?? 0 }
    /// Rolling average simulation cost in milliseconds. Feed this into the
    /// frame governor's adaptive budget next to
    /// `WorkspaceAdjustableEffect.estimatedCost`.
    var estimatedCostMilliseconds: Double { engine?.estimatedCostMilliseconds ?? 0 }

    private var pipeline: MTLRenderPipelineState?
    private var vertexBuffer: MTLBuffer?
    private var engine: GVParticleEngine?

    init(emitter: GVParticleEmitterKind) {
        self.emitter = emitter
        identifier = "greyvision.particle.\(emitter.rawValue)"
        displayName = emitter.displayName
    }

    /// Bridges the workspace slot model (`CameraEffectParameters`, driven by
    /// the deck's three sliders plus blend) onto the five particle
    /// parameters. Deck mapping: primary -> density, secondary -> size,
    /// tertiary -> speed. Turbulence and glow keep their definition defaults
    /// here; they are already modulatable through `parameterState` for
    /// automation or a future deck row.
    func sync(from parameters: CameraEffectParameters) {
        isEnabled = parameters.isEnabled
        mix = Float(min(max(parameters.blend, 0), 1))
        var state = EffectParameterState()
        let mapping: [(String, Double)] = [
            (GVParticleParameterID.density, parameters.primary),
            (GVParticleParameterID.size, parameters.secondary),
            (GVParticleParameterID.speed, parameters.tertiary),
        ]
        for (id, value) in mapping {
            if let definition = GVParticleParameters.definition(id: id) {
                state.setBaseValue(Float(value), definition: definition)
            }
        }
        parameterState = state
    }

    // MARK: RenderEffect

    func prepare(_ context: RenderPreparationContext) throws {
        guard let vertexFunction = context.library.makeFunction(name: "gvParticleVertex") else {
            throw RenderEffectError.unavailable("ParticleShaders.metal is missing gvParticleVertex")
        }
        guard let fragmentFunction = context.library.makeFunction(name: "gvParticleFragment") else {
            throw RenderEffectError.unavailable("ParticleShaders.metal is missing gvParticleFragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        guard let attachment = descriptor.colorAttachments[0] else {
            throw RenderEffectError.resourceAllocationFailed("particle pipeline has no color attachment 0")
        }
        // Particles are light: additive blending onto the processed frame.
        attachment.pixelFormat = context.format.pixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .one
        do {
            pipeline = try context.device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw RenderEffectError.resourceAllocationFailed("particle pipeline: \(error.localizedDescription)")
        }

        let engine = GVParticleEngine(emitter: emitter, device: context.device)
        engine.noteQualityScale(qualityScale)
        self.engine = engine

        let capacity = GVParticleEngine.capacity(for: context.device)
        let length = capacity * MemoryLayout<GVParticleVertexData>.stride
        guard let buffer = context.device.makeBuffer(length: length, options: .storageModeShared) else {
            throw RenderEffectError.resourceAllocationFailed("particle vertex buffer (\(length) bytes)")
        }
        buffer.label = "GVParticleOverlayEffect(\(emitter.rawValue)) vertices"
        vertexBuffer = buffer
    }

    func resize(to _: EffectRenderFormat, context _: RenderPreparationContext) throws {
        // The vertex buffer is sized by particle capacity, not resolution;
        // the per-frame viewport comes from the output texture. Nothing to do.
    }

    func process(_ request: EffectRenderRequest) throws {
        guard let pipeline, let engine, let vertexBuffer else {
            // Not prepared (or resources released): fail closed to a
            // pass-through instead of trapping or dropping the frame.
            try blitIfNeeded(input: request.input, output: request.output, commandBuffer: request.frame.commandBuffer)
            return
        }
        let mixValue = min(max(mix.isFinite ? mix : 0, 0), 1)
        guard isEnabled, mixValue > 0 else {
            try blitIfNeeded(input: request.input, output: request.output, commandBuffer: request.frame.commandBuffer)
            return
        }

        let output = request.output
        let viewportSize = SIMD2<Float>(Float(output.width), Float(output.height))
        guard viewportSize.x > 0, viewportSize.y > 0 else {
            try blitIfNeeded(input: request.input, output: request.output, commandBuffer: request.frame.commandBuffer)
            return
        }

        // Resolve parameters: prefer state the graph handed us when it
        // carries our ids, otherwise the bridged `parameterState`.
        let incoming = request.parameters
        let hasOurs = GVParticleParameters.definitions.contains { incoming[$0.id] != nil }
        let config = GVParticleConfiguration.resolve(state: hasOurs ? incoming : parameterState, mix: mixValue)

        // Enrich the published signals with the frame's motion field, so
        // dust stirs and glitch bursts even if the wiring only publishes audio.
        var signals = signalMailbox.latest
        let aggregate = request.frame.motionField.aggregateVector
        let motionMagnitude = Float(min(max(hypot(aggregate.x, aggregate.y) * 3, 0), 1))
        signals.motion = max(signals.motion, motionMagnitude)

        engine.update(
            signals: signals,
            config: config,
            deltaTime: request.frame.safeDeltaTime,
            viewportSize: viewportSize
        )

        // The graph gives us a distinct output texture; make sure it holds
        // the input image before we composite additively on top of it.
        try blitIfNeeded(input: request.input, output: request.output, commandBuffer: request.frame.commandBuffer)

        let count = engine.writeVertices(into: vertexBuffer.contents(), capacity: engine.maxParticles)
        guard count > 0 else { return }

        var uniforms = GVParticleUniforms(
            viewportSize: viewportSize,
            globalAlpha: mixValue,
            pointScale: 1
        )
        let pass = MTLRenderPassDescriptor()
        guard let colorAttachment = pass.colorAttachments[0] else {
            throw RenderEffectError.resourceAllocationFailed("particle render pass has no color attachment 0")
        }
        colorAttachment.texture = output
        colorAttachment.loadAction = .load
        colorAttachment.storeAction = .store
        guard let encoder = request.frame.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw RenderEffectError.encoderUnavailable("particle render encoder")
        }
        encoder.label = "GVParticleOverlayEffect(\(emitter.rawValue))"
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<GVParticleUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
        encoder.endEncoding()
    }

    func reset(reason _: EffectResetReason) {
        engine?.reset()
    }

    func releaseResources() {
        pipeline = nil
        vertexBuffer = nil
        engine = nil
    }

    // MARK: Private

    /// Copies input -> output when the graph hands us distinct textures.
    /// Skipped for in-place graphs. Also the fail-closed path: a bypassed
    /// or unprepared node must still forward the frame.
    private func blitIfNeeded(input: MTLTexture, output: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        guard input !== output else { return }
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw RenderEffectError.encoderUnavailable("particle blit encoder")
        }
        encoder.label = "GVParticleOverlayEffect(\(emitter.rawValue)) blit"
        encoder.copy(
            from: input,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: input.width, height: input.height, depth: 1),
            to: output,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        encoder.endEncoding()
    }
}
