@testable import GreyVision
import Metal
import simd
import XCTest

final class FlagshipRenderTests: XCTestCase {
    func testReactionClockIsBoundedAndHoldDoesNotAccumulateDebt() {
        var clock = CameraReactionClock()
        XCTAssertEqual(clock.steps(at: 0, held: false), 0)
        XCTAssertEqual(clock.steps(at: 1.0 / 60, held: false), 2)
        XCTAssertEqual(clock.steps(at: 10, held: false), 4)
        XCTAssertEqual(clock.steps(at: 20, held: true), 0)
        XCTAssertEqual(clock.steps(at: 20 + 1.0 / 60, held: false), 2)
        XCTAssertEqual(CameraReactionDiffusion.gridSize(width: 3840, height: 2160), SIMD2(256, 144))
    }

    func testQualityRequiresSustainedPressureAndRecoversSlowly() {
        var quality = CameraEffectQuality()
        for index in 1 ... 29 {
            quality.update(stats: CameraRenderStats(frameNumber: UInt64(index), gpuMilliseconds: 20), fps: 60, thermalPressure: false)
        }
        XCTAssertFalse(quality.reducedDetail)
        quality.update(stats: CameraRenderStats(frameNumber: 30, gpuMilliseconds: 20), fps: 60, thermalPressure: false)
        XCTAssertTrue(quality.reducedDetail)
        for index in 31 ... 329 {
            quality.update(stats: CameraRenderStats(frameNumber: UInt64(index), gpuMilliseconds: 5), fps: 60, thermalPressure: false)
        }
        XCTAssertTrue(quality.reducedDetail)
        quality.update(stats: CameraRenderStats(frameNumber: 330, gpuMilliseconds: 5), fps: 60, thermalPressure: false)
        XCTAssertFalse(quality.reducedDetail)
    }

    func testNewEffectsDeclareOnlyTheirRequiredResources() {
        XCTAssertTrue(WorkspaceAdjustableEffect.cmykPress.cameraResourceRequirements.isEmpty)
        XCTAssertTrue(WorkspaceAdjustableEffect.spectralDiffraction.cameraResourceRequirements.isEmpty)
        XCTAssertEqual(WorkspaceAdjustableEffect.reactionGarden.cameraResourceRequirements, [.simulation])
        for effect in [WorkspaceAdjustableEffect.vectorCodebook, .motionTransplant, .bitplaneLatch] {
            XCTAssertTrue(effect.cameraResourceRequirements.contains([.opticalFlow, .slotHistory, .moshState]))
            XCTAssertFalse(effect.cameraResourceRequirements.contains(.timestampedHistory))
            XCTAssertTrue(effect.freezesHistoryOnHold)
        }
        XCTAssertTrue(WorkspaceAdjustableEffect.predictionDrift.freezesHistoryOnHold)
    }

    @MainActor
    func testPreviewProjectionIgnoresSelectionButTracksPixelsAndBypass() {
        let editor = EffectEditingSession()
        let projection = EffectRenderProjection(editor: editor)
        var deliveries = 0
        let token = projection.$composition.sink { _ in deliveries += 1 }
        editor.focus(.grain)
        editor.dismissSelection()
        XCTAssertEqual(deliveries, 1)
        editor.effectStack.reset(.grain)
        XCTAssertEqual(deliveries, 2)
        editor.focus(.grain)
        XCTAssertEqual(deliveries, 2)
        editor.setGlobalBypassed(true)
        XCTAssertEqual(deliveries, 3)
        XCTAssertFalse(projection.composition.stack[.grain].isEnabled)
        withExtendedLifetime(token) {}
    }

    func testPrintAndDiffractionRenderDistinctFinitePixelsAndZeroBlendIdentity() throws {
        let gpu = try GPUFixture()
        let source = try gpu.pattern()
        let reference = gpu.read(source)
        var outputs: [[Float]] = []
        for effect in [WorkspaceAdjustableEffect.cmykPress, .spectralDiffraction] {
            var mode = try XCTUnwrap(effect.styleMode)
            let constants = MTLFunctionConstantValues()
            constants.setConstantValue(&mode, type: .uint, index: 0)
            let function = try gpu.library.makeFunction(name: "gvCameraStyleEffect", constantValues: constants)
            let pipeline = try gpu.device.makeComputePipelineState(function: function)
            let output = try gpu.texture()
            for blend: Float in [0, 1] {
                var uniforms = Self.cameraUniforms(mode: mode, blend: blend)
                try gpu.compute(pipeline) { encoder in
                    encoder.setTexture(source, index: 0)
                    encoder.setTexture(output, index: 1)
                    encoder.setBytes(&uniforms, length: MemoryLayout<CameraStyleEffectUniforms>.stride, index: 0)
                }
                let pixels = gpu.read(output)
                XCTAssertTrue(pixels.allSatisfy(\.isFinite), effect.label)
                if blend == 0 { XCTAssertLessThan(Self.difference(pixels, reference), 0.0001) }
                else {
                    XCTAssertGreaterThan(Self.difference(pixels, reference), 0.001, effect.label)
                    outputs.append(pixels)
                }
            }
        }
        XCTAssertGreaterThan(Self.difference(outputs[0], outputs[1]), 0.01)
    }

    func testDatamoshVariantsRenderFiniteDistinctPixelsAndZeroBlendIdentity() throws {
        let gpu = try GPUFixture()
        let source = try gpu.pattern()
        let history = try gpu.pattern(shift: 11)
        let flow = try gpu.texture(fill: SIMD4(0.012, -0.009, 0, 0))
        let pipeline = try gpu.device.makeComputePipelineState(function: XCTUnwrap(gpu.library.makeFunction(name: "gvCameraTemporalEffect")))
        let ringDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        ringDescriptor.textureType = .type2DArray
        ringDescriptor.arrayLength = 1
        let ring = try XCTUnwrap(gpu.device.makeTexture(descriptor: ringDescriptor))
        var ringInfo = TemporalRingUniforms(slotCount: 0, head: 0, validCount: 0, isPrimed: 0, currentTime: 0, historySpan: 0, padding: .zero)
        var timestamp: Float = -1e9
        var results: [[Float]] = []
        for effect in [WorkspaceAdjustableEffect.datamosh, .liquidMosh, .heavyMosh, .predictionDrift,
                       .vectorCodebook, .motionTransplant, .bitplaneLatch]
        {
            let output = try gpu.texture()
            let state = try gpu.texture(width: 8, height: 8, fill: .zero)
            let nextState = try gpu.texture(width: 8, height: 8, fill: .zero)
            for blend: Float in [0, 1] {
                var uniforms = try Self.cameraUniforms(mode: XCTUnwrap(effect.temporalMode), blend: blend)
                try gpu.compute(pipeline) { encoder in
                    encoder.setTexture(source, index: 0)
                    encoder.setTexture(history, index: 1)
                    encoder.setTexture(output, index: 2)
                    for index in 3 ... 6 {
                        encoder.setTexture(history, index: index)
                    }
                    encoder.setTexture(flow, index: 7)
                    encoder.setTexture(ring, index: 8)
                    encoder.setTexture(state, index: 9)
                    encoder.setTexture(nextState, index: 10)
                    encoder.setBytes(&uniforms, length: MemoryLayout<CameraStyleEffectUniforms>.stride, index: 0)
                    encoder.setBytes(&timestamp, length: MemoryLayout<Float>.stride, index: 1)
                    encoder.setBytes(&ringInfo, length: MemoryLayout<TemporalRingUniforms>.stride, index: 2)
                }
                let pixels = gpu.read(output)
                XCTAssertTrue(pixels.allSatisfy(\.isFinite), effect.label)
                if blend == 0 { XCTAssertLessThan(Self.difference(pixels, gpu.read(source)), 0.0001) }
                else {
                    XCTAssertGreaterThan(Self.difference(pixels, gpu.read(source)), 0.001, effect.label)
                    results.append(pixels)
                }
            }
        }
        for index in 1 ..< results.count {
            XCTAssertGreaterThan(Self.difference(results[index - 1], results[index]), 0.001)
        }
    }

    func testReactionGardenEvolvesHoldsAndKeepsDuplicateSimulationsIndependent() throws {
        let gpu = try GPUFixture()
        let source = try gpu.pattern()
        let output = try gpu.texture()
        let otherOutput = try gpu.texture()
        let first = try XCTUnwrap(CameraReactionDiffusion(device: gpu.device, library: gpu.library))
        let second = try XCTUnwrap(CameraReactionDiffusion(device: gpu.device, library: gpu.library))
        var parameters = WorkspaceAdjustableEffect.reactionGarden.defaultCameraParameters
        parameters.blend = 0
        try gpu.command { command in
            XCTAssertTrue(first.encode(commandBuffer: command, source: source, destination: output, parameters: parameters, touch: .zero, time: 0, held: false))
        }
        XCTAssertLessThan(Self.difference(gpu.read(output), gpu.read(source)), 0.0001)
        parameters.blend = 1
        for frame in 1 ... 40 {
            try gpu.command { command in
                XCTAssertTrue(first.encode(commandBuffer: command, source: source, destination: output, parameters: parameters, touch: SIMD4(0.3, 0.5, 0, 1), time: Double(frame) / 60, held: false))
            }
        }
        let evolved = gpu.read(output)
        let steps = first.completedStepCount
        try gpu.command { command in
            XCTAssertTrue(first.encode(commandBuffer: command, source: source, destination: output, parameters: parameters, touch: .zero, time: 10, held: true))
            XCTAssertTrue(second.encode(commandBuffer: command, source: source, destination: otherOutput, parameters: parameters, touch: .zero, time: 0, held: false))
        }
        XCTAssertEqual(first.completedStepCount, steps)
        XCTAssertEqual(second.completedStepCount, 0)
        XCTAssertLessThan(Self.difference(evolved, gpu.read(output)), 0.0001)
        XCTAssertGreaterThan(Self.difference(evolved, gpu.read(otherOutput)), 0.0001)
        XCTAssertTrue(evolved.allSatisfy(\.isFinite))
        first.reset()
        XCTAssertEqual(first.completedStepCount, 0)
    }

    func testDepthFlagshipsRenderFiniteDistinctPixelsAndPreserveInvalidDepth() throws {
        let gpu = try GPUFixture()
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = gpu.library.makeFunction(name: "gvDepthFullscreenVertex")
        descriptor.fragmentFunction = gpu.library.makeFunction(name: "gvDepthCompositeFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        let pipeline = try gpu.device.makeRenderPipelineState(descriptor: descriptor)
        let luma = try gpu.pattern()
        let chroma = try gpu.texture(fill: SIMD4(0.5, 0.5, 0, 1))
        let output = try gpu.texture()
        let mapDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 64, height: 64, mipmapped: false)
        mapDescriptor.storageMode = .shared
        mapDescriptor.usage = .shaderRead
        let depth = try XCTUnwrap(gpu.device.makeTexture(descriptor: mapDescriptor))
        mapDescriptor.pixelFormat = .r8Uint
        let confidence = try XCTUnwrap(gpu.device.makeTexture(descriptor: mapDescriptor))
        let confidenceValues = Array(repeating: UInt8(2), count: 4096)
        confidenceValues.withUnsafeBytes { confidence.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64) }
        func render(_ mode: DepthEffectMode, intensity: Float, valid: Bool, threshold: UInt32 = 0) throws -> [Float] {
            let depthValues = Array(repeating: valid ? Float(2) : .nan, count: 4096)
            depthValues.withUnsafeBytes { depth.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 256) }
            var uniforms = DepthMetalUniforms(intrinsics: SIMD4(64, 64, 32, 32), viewport: SIMD4(64, 64, 64, 64),
                                              tuning: SIMD4(0.18, 5, intensity, 3), pose: .zero,
                                              controls: DepthEffectParameters.defaults(for: mode).packedControls(for: mode), interaction: SIMD4(0, 0, 1, 0),
                                              source: SIMD4(64, 64, 1, threshold), options: SIMD4(UInt32(mode.rawValue), 2, 1, 0),
                                              worldFromCamera: matrix_identity_float4x4, scanOriginAge: SIMD4(0, 0, -2, 1))
            try gpu.command { command in
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = output
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
                encoder.setRenderPipelineState(pipeline)
                for (index, texture) in [luma, chroma, depth, confidence, luma, luma].enumerated() {
                    encoder.setFragmentTexture(texture, index: index)
                }
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DepthMetalUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
            return gpu.read(output)
        }
        let original = try render(.surfaceRelight, intensity: 0, valid: true)
        var results: [[Float]] = []
        for mode in [DepthEffectMode.surfaceRelight, .worldGrid, .sonarPulse] {
            let result = try render(mode, intensity: 1, valid: true)
            XCTAssertTrue(result.allSatisfy(\.isFinite), mode.label)
            XCTAssertGreaterThan(Self.difference(result, original), 0.001, mode.label)
            XCTAssertLessThan(try Self.difference(render(mode, intensity: 0, valid: true), original), 0.0001)
            XCTAssertLessThan(try Self.difference(render(mode, intensity: 1, valid: false), original), 0.0001)
            XCTAssertLessThan(try Self.difference(render(mode, intensity: 1, valid: true, threshold: 3), original), 0.0001)
            results.append(result)
        }
        XCTAssertGreaterThan(Self.difference(results[0], results[1]), 0.001)
        XCTAssertGreaterThan(Self.difference(results[1], results[2]), 0.001)
    }

    private static func difference(_ first: [Float], _ second: [Float]) -> Float {
        zip(first, second).reduce(0) { $0 + abs($1.0 - $1.1) } / Float(max(first.count, 1))
    }

    private static func cameraUniforms(mode: UInt32, blend: Float) -> CameraStyleEffectUniforms {
        CameraStyleEffectUniforms(mode: SIMD4(mode, 0, 1092, 0), parameters: SIMD4(0.5, 0.5, 0.75, 1),
                                  viewport: SIMD4(64, 64, 1.0 / 64, 1.0 / 64), extra: SIMD4(blend, 0, 1, 0),
                                  audio: .zero, touch: .zero, touchImpact: .zero, touchDrag: .zero, audioDynamics: .zero,
                                  blob0: .zero, blob1: .zero, blob2: .zero, blob3: .zero,
                                  spectrum0: .zero, spectrum1: .zero, spectrum2: .zero, spectrum3: .zero,
                                  worldReprojection: matrix_identity_float3x3)
    }
}

private struct GPUFixture {
    let device: MTLDevice
    let library: MTLLibrary
    let queue: MTLCommandQueue

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable on this destination") }
        self.device = device
        library = try device.makeDefaultLibrary(bundle: Bundle(for: AppModel.self))
        queue = try XCTUnwrap(device.makeCommandQueue())
    }

    func texture(width: Int = 64, height: Int = 64, fill: SIMD4<Float> = .zero) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let values = Array(repeating: [Float16(fill.x), Float16(fill.y), Float16(fill.z), Float16(fill.w)], count: width * height).flatMap(\.self)
        values.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        return texture
    }

    func pattern(shift: Int = 0) throws -> MTLTexture {
        let texture = try texture()
        let values: [Float16] = (0 ..< 4096).flatMap { index in
            let x = (index % 64 + shift) % 64
            let y = index / 64
            return [Float16(Float(x) / 63), Float16(Float(y) / 63), Float16((x / 8 + y / 8) % 2 == 0 ? 1 : 0.1), 1]
        }
        values.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 512) }
        return texture
    }

    func read(_ texture: MTLTexture) -> [Float] {
        var values = Array(repeating: Float16.zero, count: texture.width * texture.height * 4)
        values.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 8, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0) }
        return values.map(Float.init)
    }

    func command(_ encode: (MTLCommandBuffer) throws -> Void) throws {
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        try encode(command)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "GPU command failed")
    }

    func compute(_ pipeline: MTLComputePipelineState, bind: (MTLComputeCommandEncoder) -> Void) throws {
        try command { command in
            let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            bind(encoder)
            encoder.dispatchThreads(MTLSize(width: 64, height: 64, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            encoder.endEncoding()
        }
    }
}
