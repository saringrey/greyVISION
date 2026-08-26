import Metal
import simd

/// Uniform block for the fluid kernels. Layout must match `GVFluidUniforms`
/// in `CameraShaders.metal`.
struct CameraFluidUniforms {
    var texel: SIMD2<Float>
    var touch: SIMD2<Float>
    var touchVelocity: SIMD2<Float>
    var touchActive: Float
    var deltaTime: Float
    var dissipation: Float
    var viscosity: Float
    var forceRadius: Float
    var forceStrength: Float
    var vorticity: Float
    var cameraInject: Float
}

/// Operator-facing fluid parameters, mapped from the effect's three controls.
struct CameraFluidParameters {
    /// 0...1 — how strongly the flow drags the camera image.
    var drag: Double = 0.5
    /// 0...1 — dye persistence.
    var persistence: Double = 0.6
    /// 0...1 — curl energy fed back into the field.
    var swirl: Double = 0.5
}

/// A realtime Eulerian fluid solver on the GPU.
///
/// Runs a standard stable-fluids schedule per frame:
///
///   advect velocity → splat force → vorticity → divergence
///   → Jacobi pressure (N iterations) → project → advect dye → splat dye
///
/// The dye is seeded from the camera image, so the fluid is literally made of
/// the scene rather than of an arbitrary palette.
///
/// The simulation grid is deliberately much smaller than the camera frame.
/// Fluid detail is dominated by the pressure solve, not by resolution, and a
/// quarter-res grid keeps the whole schedule inside a couple of milliseconds
/// while the composite samples it bilinearly at full res.
final class CameraFluidSolver {
    /// Longest edge of the simulation grid. 256 is the smallest size at which
    /// vortices still read as vortices rather than as blobs.
    private static let gridLimit = 256
    /// Jacobi iterations per frame. Below ~20 the field stays visibly
    /// divergent and the fluid looks like smearing; above ~40 the cost stops
    /// buying visible quality.
    private static let pressureIterations = 24

    private let device: MTLDevice
    private let advect: MTLComputePipelineState
    private let splat: MTLComputePipelineState
    private let divergence: MTLComputePipelineState
    private let pressure: MTLComputePipelineState
    private let project: MTLComputePipelineState
    private let vorticity: MTLComputePipelineState
    private let composite: MTLComputePipelineState

    private var velocityA: MTLTexture?
    private var velocityB: MTLTexture?
    private var dyeA: MTLTexture?
    private var dyeB: MTLTexture?
    private var divergenceTexture: MTLTexture?
    private var pressureA: MTLTexture?
    private var pressureB: MTLTexture?
    private var gridSize = MTLSize(width: 0, height: 0, depth: 1)

    private var lastTouch = SIMD2<Float>(0.5, 0.5)
    private var hasLastTouch = false

    init?(device: MTLDevice, library: MTLLibrary) {
        guard let advectFunction = library.makeFunction(name: "gvFluidAdvect"),
              let splatFunction = library.makeFunction(name: "gvFluidSplat"),
              let divergenceFunction = library.makeFunction(name: "gvFluidDivergence"),
              let pressureFunction = library.makeFunction(name: "gvFluidPressure"),
              let projectFunction = library.makeFunction(name: "gvFluidProject"),
              let vorticityFunction = library.makeFunction(name: "gvFluidVorticity"),
              let compositeFunction = library.makeFunction(name: "gvFluidComposite"),
              let advect = try? device.makeComputePipelineState(function: advectFunction),
              let splat = try? device.makeComputePipelineState(function: splatFunction),
              let divergence = try? device.makeComputePipelineState(function: divergenceFunction),
              let pressure = try? device.makeComputePipelineState(function: pressureFunction),
              let project = try? device.makeComputePipelineState(function: projectFunction),
              let vorticity = try? device.makeComputePipelineState(function: vorticityFunction),
              let composite = try? device.makeComputePipelineState(function: compositeFunction)
        else {
            GVLog.rendering.error("fluid solver pipelines unavailable")
            return nil
        }
        self.device = device
        self.advect = advect
        self.splat = splat
        self.divergence = divergence
        self.pressure = pressure
        self.project = project
        self.vorticity = vorticity
        self.composite = composite
    }

    /// Drops every simulation texture. Called when the effect is disabled so an
    /// unused fluid never holds ~6 MB of private storage.
    func reset() {
        velocityA = nil
        velocityB = nil
        dyeA = nil
        dyeB = nil
        divergenceTexture = nil
        pressureA = nil
        pressureB = nil
        gridSize = MTLSize(width: 0, height: 0, depth: 1)
        hasLastTouch = false
    }

    // MARK: - Simulation

    /// Advances the simulation one step and composites it over `source`.
    ///
    /// - Returns: `false` when the grid could not be allocated, so the caller
    ///   can fall through to the unmodified frame rather than showing black.
    @discardableResult
    func encode(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        destination: MTLTexture,
        touch: SIMD4<Float>,
        parameters: CameraFluidParameters,
        blend: Float,
        deltaTime: Float
    ) -> Bool {
        guard ensureTextures(for: source) else { return false }
        guard let velocityA, let velocityB, let dyeA, let dyeB,
              let divergenceTexture, let pressureA, let pressureB
        else { return false }

        var uniforms = makeUniforms(
            touch: touch,
            parameters: parameters,
            deltaTime: deltaTime
        )

        // 1. Move the velocity field through itself.
        encodePass(
            commandBuffer, advect, label: "Fluid Advect Velocity",
            textures: [velocityA, velocityA, velocityB], uniforms: &uniforms
        )

        // 2. Push the field where the finger is.
        var isVelocity: UInt32 = 1
        encodeSplat(
            commandBuffer, source: velocityB, camera: source, destination: velocityA,
            uniforms: &uniforms, isVelocity: &isVelocity
        )

        // 3. Restore the curl that advection just smoothed away.
        encodePass(
            commandBuffer, vorticity, label: "Fluid Vorticity",
            textures: [velocityA, velocityB], uniforms: &uniforms
        )

        // 4-6. Make the field divergence free.
        encodePass(
            commandBuffer, divergence, label: "Fluid Divergence",
            textures: [velocityB, divergenceTexture], uniforms: &uniforms
        )
        clear(commandBuffer, texture: pressureA)
        var readPressure = pressureA
        var writePressure = pressureB
        for _ in 0 ..< Self.pressureIterations {
            encodePass(
                commandBuffer, pressure, label: "Fluid Pressure",
                textures: [readPressure, divergenceTexture, writePressure], uniforms: &uniforms
            )
            swap(&readPressure, &writePressure)
        }
        encodePass(
            commandBuffer, project, label: "Fluid Project",
            textures: [readPressure, velocityB, velocityA], uniforms: &uniforms
        )

        // 7. Carry the dye along the now-solenoidal field, then add more.
        encodePass(
            commandBuffer, advect, label: "Fluid Advect Dye",
            textures: [velocityA, dyeA, dyeB], uniforms: &uniforms
        )
        isVelocity = 0
        encodeSplat(
            commandBuffer, source: dyeB, camera: source, destination: dyeA,
            uniforms: &uniforms, isVelocity: &isVelocity
        )

        encodeComposite(
            commandBuffer,
            source: source,
            destination: destination,
            dye: dyeA,
            velocity: velocityA,
            parameters: parameters,
            blend: blend
        )
        return true
    }

    // MARK: - Passes

    private func encodePass(
        _ commandBuffer: MTLCommandBuffer,
        _ pipeline: MTLComputePipelineState,
        label: String,
        textures: [MTLTexture],
        uniforms: inout CameraFluidUniforms
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = label
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() {
            encoder.setTexture(texture, index: index)
        }
        encoder.setBytes(&uniforms, length: MemoryLayout<CameraFluidUniforms>.stride, index: 0)
        dispatch(encoder, pipeline: pipeline, size: gridSize)
        encoder.endEncoding()
    }

    private func encodeSplat(
        _ commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        camera: MTLTexture,
        destination: MTLTexture,
        uniforms: inout CameraFluidUniforms,
        isVelocity: inout UInt32
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = isVelocity == 1 ? "Fluid Splat Force" : "Fluid Splat Dye"
        encoder.setComputePipelineState(splat)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(camera, index: 1)
        encoder.setTexture(destination, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<CameraFluidUniforms>.stride, index: 0)
        encoder.setBytes(&isVelocity, length: MemoryLayout<UInt32>.stride, index: 1)
        dispatch(encoder, pipeline: splat, size: gridSize)
        encoder.endEncoding()
    }

    private func encodeComposite(
        _ commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        destination: MTLTexture,
        dye: MTLTexture,
        velocity: MTLTexture,
        parameters: CameraFluidParameters,
        blend: Float
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "Fluid Composite"
        encoder.setComputePipelineState(composite)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(dye, index: 1)
        encoder.setTexture(velocity, index: 2)
        encoder.setTexture(destination, index: 3)

        // The composite reads the shared effect uniform block, so only the
        // fields it actually uses are populated.
        var uniforms = CameraStyleEffectUniforms(
            mode: SIMD4<UInt32>(0, 0, 0, 0),
            parameters: SIMD4<Float>(Float(parameters.drag), Float(parameters.persistence), 0, 0),
            viewport: SIMD4<Float>(
                Float(destination.width),
                Float(destination.height),
                1 / Float(max(destination.width, 1)),
                1 / Float(max(destination.height, 1))
            ),
            extra: SIMD4<Float>(blend, 0, 0, 0),
            audio: .zero,
            touch: .zero,
            touchImpact: .zero,
            audioDynamics: .zero,
            blob0: .zero,
            blob1: .zero,
            blob2: .zero,
            blob3: .zero,
            spectrum0: .zero,
            spectrum1: .zero,
            spectrum2: .zero,
            spectrum3: .zero,
            // The solver is a stage, not an accumulator; nothing here
            // is anchored to the world.
            worldReprojection: matrix_identity_float3x3
        )
        encoder.setBytes(&uniforms, length: MemoryLayout<CameraStyleEffectUniforms>.stride, index: 0)
        dispatch(
            encoder,
            pipeline: composite,
            size: MTLSize(width: destination.width, height: destination.height, depth: 1)
        )
        encoder.endEncoding()
    }

    /// Zeroes a texture between frames. Pressure must start from zero or the
    /// Jacobi solve inherits the previous frame's residual and drifts.
    private func clear(_ commandBuffer: MTLCommandBuffer, texture: MTLTexture) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()
    }

    private func dispatch(
        _ encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        size: MTLSize
    ) {
        let width = pipeline.threadExecutionWidth
        let height = max(pipeline.maxTotalThreadsPerThreadgroup / width, 1)
        let threadgroup = MTLSize(width: width, height: height, depth: 1)
        let groups = MTLSize(
            width: (size.width + width - 1) / width,
            height: (size.height + height - 1) / height,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadgroup)
    }

    // MARK: - Resources

    private func makeUniforms(
        touch: SIMD4<Float>,
        parameters: CameraFluidParameters,
        deltaTime: Float
    ) -> CameraFluidUniforms {
        let active = touch.w > 0.5
        let point = SIMD2(touch.x, touch.y)

        // Velocity from frame-to-frame finger movement rather than the
        // reported speed: it stays correct regardless of how the gesture
        // recogniser reports velocity, and it is zero on the first contact so
        // a tap does not fling the field.
        var velocity = SIMD2<Float>.zero
        if active, hasLastTouch {
            velocity = (point - lastTouch) / max(deltaTime, 1.0 / 120.0)
            // Clamp so a fast flick cannot blow the simulation up.
            let speed = simd_length(velocity)
            if speed > 6 { velocity *= 6 / speed }
        }
        if active {
            lastTouch = point
            hasLastTouch = true
        } else {
            hasLastTouch = false
        }

        return CameraFluidUniforms(
            texel: SIMD2(1 / Float(gridSize.width), 1 / Float(gridSize.height)),
            touch: point,
            touchVelocity: velocity,
            touchActive: active ? 1 : 0,
            deltaTime: deltaTime,
            // Dye fades slowly; velocity fades faster or the field never settles.
            dissipation: Float(0.985 + parameters.persistence * 0.0145),
            viscosity: 0.994,
            forceRadius: 0.00025,
            forceStrength: 0.85,
            vorticity: Float(parameters.swirl * 26.0),
            cameraInject: 0.55
        )
    }

    private func ensureTextures(for source: MTLTexture) -> Bool {
        let aspect = Double(source.height) / Double(max(source.width, 1))
        let width = min(Self.gridLimit, source.width)
        let height = max(Int(Double(width) * aspect), 1)
        if gridSize.width == width, gridSize.height == height, velocityA != nil {
            return true
        }

        // Velocity and pressure are two- and one-channel fields; rgba16Float
        // for all of them keeps one descriptor and costs little at this size.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]

        guard let velocityA = device.makeTexture(descriptor: descriptor),
              let velocityB = device.makeTexture(descriptor: descriptor),
              let dyeA = device.makeTexture(descriptor: descriptor),
              let dyeB = device.makeTexture(descriptor: descriptor),
              let divergenceTexture = device.makeTexture(descriptor: descriptor),
              let pressureA = device.makeTexture(descriptor: descriptor),
              let pressureB = device.makeTexture(descriptor: descriptor)
        else {
            GVLog.rendering.error("fluid grid allocation failed at \(width)x\(height)")
            return false
        }

        velocityA.label = "greyVISION Fluid Velocity A"
        velocityB.label = "greyVISION Fluid Velocity B"
        dyeA.label = "greyVISION Fluid Dye A"
        dyeB.label = "greyVISION Fluid Dye B"
        divergenceTexture.label = "greyVISION Fluid Divergence"
        pressureA.label = "greyVISION Fluid Pressure A"
        pressureB.label = "greyVISION Fluid Pressure B"

        self.velocityA = velocityA
        self.velocityB = velocityB
        self.dyeA = dyeA
        self.dyeB = dyeB
        self.divergenceTexture = divergenceTexture
        self.pressureA = pressureA
        self.pressureB = pressureB
        gridSize = MTLSize(width: width, height: height, depth: 1)

        // A fresh grid must start empty or the first frame advects garbage.
        if let queue = device.makeCommandQueue(), let buffer = queue.makeCommandBuffer() {
            for texture in [velocityA, velocityB, dyeA, dyeB, divergenceTexture, pressureA, pressureB] {
                clear(buffer, texture: texture)
            }
            buffer.commit()
            buffer.waitUntilCompleted()
        }
        return true
    }
}
