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
    func testPreviewProjectionIgnoresSelectionButTracksPixelsAndBypass() async {
        let editor = EffectEditingSession()
        let projection = EffectRenderProjection(editor: editor)
        var deliveries = 0
        let token = projection.$composition.sink { _ in deliveries += 1 }

        // Selection is not an edit, so it must produce no delivery at all.
        // (The first count of 1 is the current value arriving on subscribe.)
        editor.focus(.grain)
        editor.dismissSelection()
        await Self.settleRepublish()
        XCTAssertEqual(deliveries, 1, "focus and dismiss change no pixels")

        editor.effectStack.reset(.grain)
        await Self.settleRepublish()
        XCTAssertEqual(deliveries, 2, "arming a slot has to reach the preview")

        editor.focus(.grain)
        await Self.settleRepublish()
        XCTAssertEqual(deliveries, 2, "focus is not an edit")

        editor.setGlobalBypassed(true)
        await Self.settleRepublish()
        XCTAssertEqual(deliveries, 3)
        XCTAssertFalse(
            projection.composition.stack[.grain].isEnabled,
            "bypass has to show the preview a clean stack"
        )
        withExtendedLifetime(token) {}
    }

    /// Lets the session's deferred publish run.
    ///
    /// Deriving the rendered composition has to happen a runloop turn after
    /// the write, because an observer on a stored property runs inside that
    /// property's write access and reading it back there is a simultaneous
    /// access. So the count cannot be read back synchronously after an edit.
    @MainActor
    private static func settleRepublish() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(10))
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
        // Stands in for the decoder's reconstruction. The three compression
        // modes read only this and the live frame — no flow, no shader history —
        // so the fixture is what they are actually shown.
        let decoded = try gpu.decodePattern()
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
                var uniforms = try Self.cameraUniforms(mode: XCTUnwrap(effect.temporalMode), blend: blend,
                                                       decodeReady: 1)
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
                    encoder.setTexture(decoded, index: 11)
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

        // A person mask with a hard edge, which is what Vision actually emits. A
        // smooth ramp cannot produce a silhouette, so a mask like that would make
        // SUBJECT DECAY look broken when in fact it had nothing to act on.
        let mask = try gpu.texture()
        let maskValues: [Float16] = (0 ..< 4096).flatMap { index in
            let inside = (20 ... 44).contains(index % 64) && (12 ... 52).contains(index / 64) ? Float16(1) : Float16(0)
            return [inside, 0, 0, 1]
        }
        maskValues.withUnsafeBytes { mask.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 512) }
        // A previous frame that differs from the current one, so optical flow is
        // non-zero and the feedback path is genuinely exercised.
        let history = try gpu.pattern(shift: 9)

        // A sloped surface with a step in it. A single flat range has no gradient
        // and no silhouette, which is precisely the input every one of these
        // effects is built to avoid: contours have nothing to band, parallax has
        // no parallax, and the seam rejection never fires.
        func fillDepth(valid: Bool) {
            let values: [Float] = (0 ..< 4096).map { index -> Float in
                guard valid else { return Float.nan }
                let x: Float = Float(index % 64) / 63
                let y: Float = Float(index / 64) / 63
                let step: Float = x > 0.5 ? -0.9 : 0
                let range: Float = 1.1
                return range + x * 1.8 + y * 0.6 + step
            }
            values.withUnsafeBytes { depth.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 256) }
        }
        fillDepth(valid: true)
        func render(_ mode: DepthEffectMode, intensity: Float, valid: Bool, threshold: UInt32 = 0) throws -> [Float] {
            fillDepth(valid: valid)
            var uniforms = DepthMetalUniforms(intrinsics: SIMD4(64, 64, 32, 32), viewport: SIMD4(64, 64, 64, 64),
                                              tuning: SIMD4(0.18, 5, intensity, 3), pose: .zero,
                                              controls: DepthEffectParameters.defaults(for: mode).packedControls(for: mode), interaction: SIMD4(0.5, 0.5, 1, 0),
                                              source: SIMD4(64, 64, 1, threshold), options: SIMD4(UInt32(mode.rawValue), 2, 1, 1),
                                              worldFromCamera: matrix_identity_float4x4,
                                              // One live echo a metre up the +Z axis, so the space
                                              // scan has a wavefront that can actually reach the
                                              // geometry being lit.
                                              pulses: (SIMD4(0, 0, -1, 1), SIMD4(0, 0, 0, -1), SIMD4(0, 0, 0, -1), SIMD4(0, 0, 0, -1)))
            try gpu.command { command in
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = output
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
                encoder.setRenderPipelineState(pipeline)
                for (index, texture) in [luma, chroma, depth, confidence, mask, history].enumerated() {
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
        // The fullscreen modes are what this shader owns; the cloud is drawn by
        // its own pipeline, so it is exercised in the point-raster test instead.
        for mode in DepthEffectMode.allCases where mode != .pointCloud {
            let result = try render(mode, intensity: 1, valid: true)
            XCTAssertTrue(result.allSatisfy(\.isFinite), mode.label)
            XCTAssertGreaterThan(Self.difference(result, original), 0.001, mode.label)
            XCTAssertLessThan(try Self.difference(render(mode, intensity: 0, valid: true), original), 0.0001)
            XCTAssertLessThan(try Self.difference(render(mode, intensity: 1, valid: false), original), 0.0001)
            XCTAssertLessThan(try Self.difference(render(mode, intensity: 1, valid: true, threshold: 3), original), 0.0001)
            results.append(result)
        }
        // No two survivors may share a look: consolidation is only honest if the
        // modes that remain are separable in pixels, not just in name.
        for (index, first) in results.enumerated() {
            for second in results.dropFirst(index + 1) {
                XCTAssertGreaterThan(Self.difference(first, second), 0.001)
            }
        }
    }

    private static func difference(_ first: [Float], _ second: [Float]) -> Float {
        zip(first, second).reduce(0) { $0 + abs($1.0 - $1.1) } / Float(max(first.count, 1))
    }

    /// The round trip itself with no shader in the way: frames go in and a
    /// reconstruction the decoder produced comes back. This is what separates
    /// real datamoshing from a shader imitating it — if VideoToolbox is not
    /// genuinely running, nothing here can pass.
    func testDatamoshEngineRoundTripsFramesThroughTheCodec() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable on this destination") }
        let engine = try XCTUnwrap(GVDatamoshEngine(device: device))
        var configuration = GVDatamoshEngine.Configuration()
        configuration.encodeLongEdge = 64
        configuration.keyframeIntervalFrames = 1
        configuration.bitrateBitsPerSecond = 120_000
        configuration.referenceDropEvery = 3
        let size = CGSize(width: 64, height: 64)
        let deadline = Date().addingTimeInterval(20)
        var submitted = 0
        while engine.latestDecodedFrame == nil, Date() < deadline {
            guard let staging = engine.beginFrame(configuration: configuration, sourceSize: size) else {
                usleep(2_000)
                continue
            }
            // Paint the encoder's input. Every frame slides, which is what makes
            // a codec emit inter-predicted units at all rather than coding each
            // frame independently — and inter prediction is the only reason a
            // datamosh can exist.
            let shift = submitted % 32
            let bytes: [UInt8] = (0 ..< 64 * 64).flatMap { index in
                let x = (index % 64 + shift) % 64
                let y = index / 64
                return [UInt8(x * 4), UInt8(y * 4), UInt8((x & 8) == 0 ? 200 : 40), 255]
            }
            bytes.withUnsafeBytes {
                staging.texture.replace(region: MTLRegionMake2D(0, 0, 64, 64),
                                        mipmapLevel: 0,
                                        withBytes: $0.baseAddress!,
                                        bytesPerRow: 64 * 4)
            }
            engine.endFrame(staging, configuration: configuration)
            submitted += 1
            usleep(4_000)
        }
        XCTAssertGreaterThanOrEqual(submitted, 3, "the codec never advanced past the first frames")
        let decoded = try XCTUnwrap(engine.latestDecodedFrame, "VideoToolbox never produced a reconstruction")
        XCTAssertEqual(decoded.texture.width, 64)
        XCTAssertEqual(decoded.texture.height, 64)
        XCTAssertEqual(decoded.texture.pixelFormat, .bgra8Unorm)
        XCTAssertGreaterThan(decoded.generation, 0)
    }

    /// The sliders are the operator's only controls over a real codec, so what
    /// they map onto has to be pinned down without a camera in the way. The
    /// regression this guards is the quiet kind: an effect that adds at its
    /// default position and shows nothing but a slightly soft picture, because
    /// the DROP slider's bottom half rounded down to "withhold nothing" and a
    /// datamosh with an intact reference chain is just video.
    func testDatamoshSliderMappingKeepsTheReferenceChainBrokenAtItsDefaults() {
        func configuration(_ variant: GVDatamoshEngine.Variant,
                           primary: Double = 0.5,
                           secondary: Double = 0.12,
                           tertiary: Double = 0.5,
                           ceiling: Int = 0) -> GVDatamoshEngine.Configuration {
            GVDatamoshEngine.configuration(variant: variant,
                                           primary: primary,
                                           secondary: secondary,
                                           tertiary: tertiary,
                                           maximumEncodeEdge: ceiling)
        }
        // At the default travel, both drop-capable instruments are withholding.
        XCTAssertGreaterThan(configuration(.datamosh).referenceDropEvery, 1)
        XCTAssertGreaterThan(configuration(.liquidMosh).referenceDropEvery, 1)
        // At rest the control is off, which is what makes it a comparison and
        // not merely an accident of rounding.
        XCTAssertEqual(configuration(.datamosh, secondary: 0).referenceDropEvery, 0)
        XCTAssertEqual(configuration(.liquidMosh, secondary: 0).referenceDropEvery, 0)
        // More travel withholds more often: the value must rise with the slider,
        // or the control is decorative.
        let light = configuration(.datamosh, secondary: 0.10).referenceDropEvery
        let heavy = configuration(.datamosh, secondary: 1.0).referenceDropEvery
        XCTAssertGreaterThan(heavy, light)
        XCTAssertLessThanOrEqual(heavy, 8)
        // SCALE runs coarse with travel, and the governor's ceiling is a ceiling
        // and not a floor: an encode already small enough to oversized its
        // macroblocks is never resized back up.
        let coarse = configuration(.liquidMosh, primary: 0.9, ceiling: 512).encodeLongEdge
        let fine = configuration(.liquidMosh, primary: 0.1, ceiling: 512).encodeLongEdge
        XCTAssertLessThan(coarse, fine)
        XCTAssertEqual(configuration(.datamosh, ceiling: 512).encodeLongEdge, 512)
        XCTAssertEqual(configuration(.datamosh, ceiling: 0).encodeLongEdge, 960)
        // The cascade asks for HEVC; the other two stay on the instrument the
        // technique was invented on.
        XCTAssertEqual(configuration(.heavyMosh).codec, .hevc)
        XCTAssertEqual(configuration(.datamosh).codec, .h264)
        // RECYCLE is a fraction of the encoder's own output, clamped: an
        // over-one blend would sample outside the reconstruction.
        XCTAssertEqual(configuration(.heavyMosh, primary: 1.7).recycle, 1, accuracy: 0.001)
        XCTAssertEqual(configuration(.heavyMosh, primary: -0.3).recycle, 0, accuracy: 0.001)
    }

    /// The quality governor has to reach the codec, or "step down a rung"
    /// quietly means "shrink everything except the second hardware engine": the
    /// one cost a warm device most wants shed would be the one left running at
    /// full size, because encode size is decided on the codec's side of the
    /// pipeline and not on the render chain's.
    func testQualityGovernorCutsTheCodecBudgetWithEverythingElse() {
        XCTAssertGreaterThan(GVRenderQuality.high.codecEdge, GVRenderQuality.balanced.codecEdge)
        XCTAssertGreaterThan(GVRenderQuality.balanced.codecEdge, GVRenderQuality.efficient.codecEdge)
        XCTAssertLessThanOrEqual(GVRenderQuality.high.codecEdge, 960)
        // The ceiling is a ceiling: an effect that exists to encode coarse —
        // forty-eight pixels on a side, so a fixed macroblock covers the frame —
        // is never resized by it, however much room the rung leaves.
        let coarse = GVDatamoshEngine.configuration(variant: .liquidMosh,
                                                    primary: 0.9,
                                                    secondary: 0.5,
                                                    tertiary: 0.5,
                                                    maximumEncodeEdge: GVRenderQuality.efficient.codecEdge)
        XCTAssertLessThan(coarse.encodeLongEdge, GVRenderQuality.efficient.codecEdge)
    }

    /// Counts what the codec really did rather than what the shader intended:
    /// units withheld from the decoder while the encoder kept predicting from
    /// them is the mechanism, and above zero it is the only externally visible
    /// proof that the round trip is a mosh and not a low-bitrate video call.
    func testDatamoshEngineReportsWhatTheCodecActuallyDid() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable on this destination") }
        let engine = try XCTUnwrap(GVDatamoshEngine(device: device))
        var configuration = GVDatamoshEngine.Configuration()
        configuration.encodeLongEdge = 64
        configuration.keyframeIntervalFrames = 300
        configuration.bitrateBitsPerSecond = 90_000
        configuration.referenceDropEvery = 2
        driveDatamosh(engine,
                      configuration: configuration,
                      frames: 40,
                      size: CGSize(width: 64, height: 64))
        let deadline = Date().addingTimeInterval(20)
        var statistics = engine.statistics
        while (statistics.unitsWithheld == 0 || statistics.framesDecoded == 0), Date() < deadline {
            usleep(20_000)
            statistics = engine.statistics
        }
        XCTAssertGreaterThan(statistics.framesSubmitted, 30, "the pump never fed the encoder")
        XCTAssertGreaterThan(statistics.syncSamples, 0, "a stream with no sync sample cannot be decoded at all")
        XCTAssertGreaterThan(statistics.unitsDelivered, 0)
        XCTAssertGreaterThan(statistics.unitsWithheld, 0, "no reference was ever withheld: this is lossy video, not a mosh")
        XCTAssertGreaterThan(statistics.framesDecoded, 0, "VideoToolbox never reconstructed anything")
        XCTAssertNotNil(statistics.codec, "the engine never settled on a codec family")
    }

    /// Two regressions in one, both of them crashes this engine has had: tearing
    /// the sessions down while frames are still queued, and changing the codec
    /// family underneath a decoder that was built from the previous family's
    /// parameter sets. Neither shows up in a return value, so the assertion is
    /// simply that the round trip is still running afterwards.
    func testDatamoshEngineSurvivesTeardownAndCodecChangeMidStream() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable on this destination") }
        let engine = try XCTUnwrap(GVDatamoshEngine(device: device))
        var h264 = GVDatamoshEngine.Configuration()
        h264.encodeLongEdge = 64
        h264.keyframeIntervalFrames = 120
        h264.bitrateBitsPerSecond = 90_000
        h264.referenceDropEvery = 3
        h264.codec = .h264
        driveDatamosh(engine, configuration: h264, frames: 20, size: CGSize(width: 64, height: 64))
        let beforeSwitch = engine.statistics.framesDecoded
        // Same decode size, different family: the next unit arrives with a format
        // description the live decoder has no parameter sets for.
        var hevc = h264
        hevc.codec = .hevc
        driveDatamosh(engine, configuration: hevc, frames: 30, size: CGSize(width: 64, height: 64))
        let deadline = Date().addingTimeInterval(20)
        while engine.statistics.framesDecoded <= beforeSwitch, Date() < deadline {
            usleep(20_000)
        }
        XCTAssertGreaterThan(engine.statistics.framesDecoded, beforeSwitch,
                             "the stream never recovered after the codec family changed")
        // Hardware is handed back while nothing is looking at it, and the picture
        // with it: a stale reconstruction must not outlive the sessions that made
        // it. Frames keep arriving regardless — this is the path a mode takes when
        // the operator leaves it and comes back.
        engine.setCodecActive(false)
        XCTAssertNil(engine.latestDecodedFrame, "a reconstruction survived the sessions that produced it")
        driveDatamosh(engine, configuration: h264, frames: 12, size: CGSize(width: 64, height: 64))
        engine.setCodecActive(true)
        driveDatamosh(engine, configuration: h264, frames: 20, size: CGSize(width: 64, height: 64))
        XCTAssertGreaterThan(engine.statistics.framesSubmitted, 60)
    }

    /// Which Slots get real hardware is a decision, so it is tested as a decision.
    /// The bug this prevents is the silent one: a second codec Slot sharing the
    /// first Slot's session, which means one reference chain and a renderer-wide
    /// stall timer that made an idle Slot force the running Slot to resync every
    /// frame.
    func testCodecBudgetFundsTwoSlotsAndRefusesTheThird() {
        var budget = GVDatamoshEngine.Budget(limit: 2)
        XCTAssertTrue(budget.fund(requested: 1))
        XCTAssertTrue(budget.fund(requested: 1), "two single-session Slots fit")
        XCTAssertFalse(budget.fund(requested: 1), "a third Slot must fall back, not oversubscribe")

        // A cascade spends two units, so one cascade alone fills the budget.
        var cascaded = GVDatamoshEngine.Budget(limit: 2)
        XCTAssertTrue(cascaded.fund(requested: 2))
        XCTAssertFalse(cascaded.fund(requested: 1))
    }

    func testCodecBudgetIsTheRendererWideLimit() {
        XCTAssertEqual(GVDatamoshEngine.Budget.defaultLimit, 2,
                       "stated in one place so the renderer and the tests cannot drift")
    }

    /// Sessions are only metered while they are live: a Slot that leaves the
    /// stack has to give the hardware back, or the budget would report every
    /// Slot that ever ran and refuse Slots that could still be funded.
    func testCodecBudgetReturnsSessionsWhenASlotReleasesThem() {
        var budget = GVDatamoshEngine.Budget(limit: 2)
        XCTAssertTrue(budget.fund(requested: 1))
        XCTAssertTrue(budget.fund(requested: 1))
        XCTAssertEqual(budget.liveSessions, 2)
        budget.release(1)
        XCTAssertEqual(budget.liveSessions, 1, "a cascade gives back two, a single round trip one")
        budget.release(2)
        XCTAssertEqual(budget.liveSessions, 0, "releasing more than was spent must not go negative")
        XCTAssertTrue(budget.fund(requested: 2), "the freed hardware is available to the next Slot")
    }

    /// A hold must not stall the mosh. With the camera frame frozen, the only
    /// thing that keeps a codec corrupting is feeding it its own reconstruction,
    /// so `held` has to force the self-feed on every instrument — including the
    /// two that have no RECYCLE control at all.
    func testHeldConfigurationFeedsTheCodecItsOwnReconstruction() {
        let live = GVDatamoshEngine.configuration(variant: .datamosh,
                                                  primary: 0.5, secondary: 0.5, tertiary: 0.5,
                                                  held: false)
        let held = GVDatamoshEngine.configuration(variant: .datamosh,
                                                  primary: 0.5, secondary: 0.5, tertiary: 0.5,
                                                  held: true)
        XCTAssertEqual(live.recycle, 0, "DATAMOSH has no recycle control while the camera runs")
        XCTAssertEqual(held.recycle, 1, "a held DATAMOSH must encode its own previous output")
        // The reference must keep being withheld, or there is no divergence and
        // therefore no drag: a held frame with an intact chain is a clean still.
        XCTAssertGreaterThan(held.referenceDropEvery, 1)
    }

    /// The hold is not a per-instrument option. DATAMOSH and LIQUID MOSH have no
    /// RECYCLE control at all — their encoder input is always the camera — and
    /// HEAVY MOSH's blend is a slider the operator can leave at its bottom, where
    /// it is again all camera. A held mapping that only obeyed the sliders would
    /// therefore keep re-encoding a picture with nothing moving in it: no motion
    /// to predict, no reference to diverge from, and a slightly soft still where
    /// the operator is waiting for the melt. Held, every instrument eats itself.
    func testHeldForcesTheSelfFeedOnEveryInstrumentRegardlessOfSliders() {
        for variant in [GVDatamoshEngine.Variant.datamosh, .liquidMosh, .heavyMosh] {
            for control in [0.0, 0.5, 1.0] {
                let held = GVDatamoshEngine.configuration(variant: variant,
                                                          primary: control, secondary: control,
                                                          tertiary: control,
                                                          held: true)
                XCTAssertEqual(held.recycle, 1, "\(variant) left the encoder reading a frozen camera")
                XCTAssertGreaterThan(held.referenceDropEvery, 1,
                                     "\(variant) at rest kept every reference while held, so the chain converged")
            }
        }
        // Live behaviour is untouched by all of this: `held` defaults to false,
        // and while the camera runs the sliders still own the codec.
        let liveDatamosh = GVDatamoshEngine.configuration(variant: .datamosh, primary: 0.5, secondary: 0.5, tertiary: 0.5)
        XCTAssertEqual(liveDatamosh.recycle, 0)
        let liveCascadeAtRest = GVDatamoshEngine.configuration(variant: .heavyMosh, primary: 0, secondary: 0.5, tertiary: 0.5)
        XCTAssertEqual(liveCascadeAtRest.recycle, 0, accuracy: 0.0001)
        let liveLiquidWithNoDrop = GVDatamoshEngine.configuration(variant: .liquidMosh, primary: 0.5, secondary: 0, tertiary: 0.5)
        XCTAssertEqual(liveLiquidWithNoDrop.referenceDropEvery, 0)
    }

    // MARK: - Codec techniques not yet on a rail

    /// The claim CHROMA MOSH makes is specific: colour from the decoder, detail from
    /// the camera. Nothing but the intent can be asserted without a shader arm, so
    /// this pins the two things the arm will depend on — that only chroma is asked
    /// for, and that it is asked of the codec whose 4:2:0 macroblock grid produces the
    /// bleeding in the first place.
    func testChromaMoshMappingAsksTheCodecForChromaOnly() {
        let configuration = GVDatamoshEngine.configuration(variant: .chromaMosh,
                                                           primary: 0.5, secondary: 0.5, tertiary: 0.5)
        XCTAssertTrue(configuration.chromaOnly, "the whole technique is that only chroma comes from the codec")
        XCTAssertGreaterThan(configuration.referenceDropEvery, 1, "colour has to be dragged, not merely blurred")
        XCTAssertEqual(configuration.codec, .h264, "4:2:0 macroblock chroma is the H.264 artefact")
        // SCALE runs coarse with travel, and coarse is what drags colour across
        // bigger blocks. The governor's ceiling is deliberately not applied: a
        // request for 96px of encode has to stay 96px on a hot device, because the
        // look *is* the encode size.
        let coarse = GVDatamoshEngine.configuration(variant: .chromaMosh,
                                                    primary: 0.9, secondary: 0.5, tertiary: 0.5,
                                                    maximumEncodeEdge: 512)
        XCTAssertLessThan(coarse.encodeLongEdge, configuration.encodeLongEdge)
        let smallest = GVDatamoshEngine.configuration(variant: .chromaMosh,
                                                      primary: 1, secondary: 0.5, tertiary: 0.5,
                                                      maximumEncodeEdge: 512)
        XCTAssertEqual(smallest.encodeLongEdge, 96, "the ceiling must not resize an encode already coarse on purpose")
        // BITS is the starvation, and starvation is the smear.
        let starved = GVDatamoshEngine.configuration(variant: .chromaMosh,
                                                     primary: 0.5, secondary: 0.5, tertiary: 0)
        XCTAssertLessThan(starved.bitrateBitsPerSecond, 20_000)
    }

    /// Two chained round trips, not one engine told to recycle harder: stage two must
    /// encode what stage one's decoder reconstructed, so every frame crosses the
    /// quantiser twice. Asking for two is only meaningful if the budget can be told,
    /// which is what `stages` is for.
    func testGenerationMoshAsksForTwoStagesAndTwoProcessors() {
        let configuration = GVDatamoshEngine.configuration(variant: .generationMosh,
                                                           primary: 0.5, secondary: 0.5, tertiary: 0.5)
        XCTAssertEqual(configuration.stages, 2, "a frame must cross two quantisers")
        XCTAssertEqual(configuration.recycle, 1, "stage one has to be self-feeding for stage two to work on")
        XCTAssertLessThan(configuration.bitrateBitsPerSecond, 400_000,
                          "a second encode of an already-clean frame is just H.264")
    }

    /// Prediction against a moment rather than a frame: the encoder is pointed at an
    /// older picture, so its own motion compensation carries the past onto the
    /// present. Zero has to mean zero, or the control's resting position is a hidden
    /// second effect.
    func testTimeLoopMappingAsksForAnAgedReference() {
        func age(_ primary: Double) -> Int {
            GVDatamoshEngine.configuration(variant: .timeLoopMosh,
                                           primary: primary, secondary: 0.5, tertiary: 0.5).referenceAgeFrames
        }
        XCTAssertEqual(age(0), 0, "no travel means the previous frame, which is ordinary prediction")
        XCTAssertEqual(age(0.5), 30, "half travel reaches half the ring")
        XCTAssertEqual(age(1), 60)
        XCTAssertGreaterThan(age(1), age(0.5), "the control has to move something")
    }

    /// A transient-forced sync sample is a real encoder action, so the interesting
    /// failure is arming it constantly: at rest this must be an ordinary long-GOP
    /// mosh, and when armed the interval between forced repairs has to be long enough
    /// for drift to accumulate in the first place.
    func testBeatMappingForcesSyncSamplesOnlyWhenArmed() {
        let armed = GVDatamoshEngine.configuration(variant: .beatGOP,
                                                   primary: 0.7, secondary: 0.5, tertiary: 0.5)
        XCTAssertTrue(armed.syncOnTransient)
        XCTAssertGreaterThan(armed.keyframeIntervalFrames, 60,
                             "the fallback interval must let drift build between beats")
        XCTAssertGreaterThan(armed.referenceDropEvery, 1, "a chain that is never withheld is not corrupting")

        let off = GVDatamoshEngine.configuration(variant: .beatGOP,
                                                 primary: 0, secondary: 0.5, tertiary: 0.5)
        XCTAssertFalse(off.syncOnTransient, "at rest this is just DATAMOSH, and should look like it")
        XCTAssertEqual(off.stages, 1)
        XCTAssertFalse(off.chromaOnly)
    }

    /// The three shipped instruments must not change behaviour because four more
    /// arrived: every new intent has a neutral default, and the old arms never set
    /// one. If this fails, a slider mapping someone already relies on has moved.
    func testNewCodecIntentsDoNotDisturbTheShippedInstruments() {
        for variant in [GVDatamoshEngine.Variant.datamosh, .liquidMosh, .heavyMosh] {
            let configuration = GVDatamoshEngine.configuration(variant: variant,
                                                               primary: 0.5, secondary: 0.5, tertiary: 0.5)
            XCTAssertEqual(configuration.stages, 1, "\(variant)")
            XCTAssertFalse(configuration.chromaOnly, "\(variant)")
            XCTAssertEqual(configuration.referenceAgeFrames, 0, "\(variant)")
            XCTAssertFalse(configuration.syncOnTransient, "\(variant)")
        }
    }

    /// The self-feed a hold depends on is not a second source texture: it is the
    /// staging kernel's own `mix(live, reconstruction, recycle)`, which the hold
    /// drives to one. Pinned because everything at full recycle rests on it — if
    /// any camera survived into the encoder input, a held frame would keep being
    /// re-encoded from a frozen clean still, the codec would find nothing moving,
    /// and the mosh would converge instead of compounding.
    ///
    /// The comparison is deliberately transfer-function agnostic: the same
    /// reconstruction staged against two different live frames has to come back
    /// identical, which says "no camera in the output" without having to know how
    /// the kernel encodes it on the way out.
    func testStagingKernelAtFullRecycleContainsNoCameraAtAll() throws {
        let gpu = try GPUFixture()
        let pipeline = try XCTUnwrap(gpu.device.makeComputePipelineState(
            function: XCTUnwrap(gpu.library.makeFunction(name: "gvCameraDatamoshStage"))
        ))
        let reconstruction = try gpu.decodePattern()
        func stage(live: MTLTexture, recycle: Float, decodeReady: UInt32) throws -> [Float] {
            let output = try gpu.texture()
            var uniforms = DatamoshStageTestUniforms(recycle: recycle, decodeReady: decodeReady)
            try gpu.compute(pipeline) { encoder in
                encoder.setTexture(live, index: 0)
                encoder.setTexture(reconstruction, index: 1)
                encoder.setTexture(output, index: 2)
                encoder.setBytes(&uniforms, length: MemoryLayout<DatamoshStageTestUniforms>.stride, index: 0)
            }
            return gpu.read(output)
        }
        let heldFirst = try stage(live: gpu.pattern(), recycle: 1, decodeReady: 1)
        let heldSecond = try stage(live: gpu.pattern(shift: 29), recycle: 1, decodeReady: 1)
        XCTAssertLessThan(Self.difference(heldFirst, heldSecond), 0.0001,
                          "at full recycle the encoder input still contains camera")
        // Not a vacuous pass: the same kernel at recycle zero is all camera, so
        // the two runs above differ only in the mapping the hold drives.
        let live = try stage(live: gpu.pattern(), recycle: 0, decodeReady: 1)
        XCTAssertGreaterThan(Self.difference(live, heldFirst), 0.001)
        // And with no reconstruction yet, recycle must not reach for one. This is
        // the gate that keeps a first frame from encoding an empty buffer.
        let gated = try stage(live: gpu.pattern(), recycle: 1, decodeReady: 0)
        XCTAssertLessThan(Self.difference(gated, live), 0.0001)
    }

    /// Half of the hold bug sits upstream of the codec: the three instruments are
    /// absent from `freezesHistoryOnHold`, so `freezeForEffect` never becomes true
    /// for them and nothing in the renderer treats a held codec Slot as held at
    /// all. The contextual hold gesture arms on this same predicate, so a codec
    /// mode missing here would be a headline feature that never switches on.
    func testCodecMoshEffectsFreezeTheirHistoryOnHold() {
        for effect in [WorkspaceAdjustableEffect.datamosh, .liquidMosh, .heavyMosh] {
            XCTAssertTrue(effect.freezesHistoryOnHold, "\(effect.rawValue) must freeze history while held")
        }
    }

    /// Paints and submits moving content into the engine's own encoder input,
    /// sliding the pattern every frame. Sliding is not decoration: an encoder
    /// with nothing moving between frames codes every frame independently, and
    /// inter prediction is the only reason a datamosh can exist at all.
    private func driveDatamosh(_ engine: GVDatamoshEngine,
                               configuration: GVDatamoshEngine.Configuration,
                               frames: Int,
                               size: CGSize) {
        let width = Int(size.width)
        let height = Int(size.height)
        let deadline = Date().addingTimeInterval(30)
        var submitted = 0
        while submitted < frames, Date() < deadline {
            guard let staging = engine.beginFrame(configuration: configuration, sourceSize: size) else {
                usleep(2_000)
                continue
            }
            let shift = submitted % 32
            let bytes: [UInt8] = (0 ..< width * height).flatMap { index in
                let x = (index % width + shift) % width
                let y = index / width
                return [UInt8(x * 255 / max(width - 1, 1)),
                        UInt8(y * 255 / max(height - 1, 1)),
                        UInt8((x & 8) == 0 ? 220 : 30),
                        255]
            }
            bytes.withUnsafeBytes {
                staging.texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                                        mipmapLevel: 0,
                                        withBytes: $0.baseAddress!,
                                        bytesPerRow: width * 4)
            }
            engine.endFrame(staging, configuration: configuration)
            submitted += 1
            usleep(6_000)
        }
    }

    private static func cameraUniforms(mode: UInt32, blend: Float, decodeReady: UInt32 = 0) -> CameraStyleEffectUniforms {
        CameraStyleEffectUniforms(mode: SIMD4(mode, 0, 1092, decodeReady), parameters: SIMD4(0.5, 0.5, 0.75, 1),
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

    /// A stand-in for a decoder's reconstruction: 8-bit BGRA, which is the
    /// format VideoToolbox actually writes, and an offset pattern so it differs
    /// from the live frame the way a broken reference chain makes a decode
    /// differ. Sampling it applies the same transfer function the real one does.
    func decodePattern(shift: Int = 23) throws -> MTLTexture {
        let width = 64
        let height = 64
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let bytes: [UInt8] = (0 ..< width * height).flatMap { index in
            let x = (index % width + shift) % width
            let y = index / width
            let blue = UInt8(x * 4)
            let green = UInt8(y * 4)
            let red: UInt8 = ((x / 8 + y / 8) % 2 == 0) ? 235 : 30
            return [blue, green, red, 255]
        }
        bytes.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
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

/// Mirrors `GVDatamoshStageUniforms` in CameraShaders.metal. The renderer's copy
/// of this layout is private to its own file, so a test that drives the staging
/// kernel directly — which is the only way to test the self-feed without a
/// camera — has to declare the bytes again. The Metal struct is two fields and
/// their order is the contract.
private struct DatamoshStageTestUniforms {
    var recycle: Float
    var decodeReady: UInt32
}
