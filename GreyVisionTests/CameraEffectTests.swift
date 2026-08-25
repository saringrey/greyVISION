@testable import GreyVision
import Metal

// NOTE: several tests were removed here. They asserted against an API set
// (relighting, memoryEffect, subjectComposite, frameAverage,
// CameraSubjectIsolationParameters, GVModulationMatrix*) that exists in a
// different branch of this project, not in this source tree. They were
// failing to compile, not failing to pass. Restore them alongside the
// features, not before.
import XCTest

final class CameraEffectTests: XCTestCase {
    func testEffectRegistryHasUniqueImplementedModesAndLiveParameters() {
        let styleEffects = WorkspaceAdjustableEffect.allCases.filter { $0.styleMode != nil }
        let temporalEffects = WorkspaceAdjustableEffect.allCases.filter { $0.temporalMode != nil }
        let styleModes = styleEffects.compactMap(\.styleMode)
        let temporalModes = temporalEffects.compactMap(\.temporalMode)

        // Asserted as an invariant, not as a count. The mode value indexes a
        // switch inside the Metal kernel, so what matters is that the modes
        // are unique and contiguous from zero — a gap silently routes an
        // effect to whatever the shader's default arm draws. The previous
        // hardcoded 31/30 only recorded how many effects existed on the day
        // it was written and went red on every effect added since.
        XCTAssertFalse(styleEffects.isEmpty)
        XCTAssertFalse(temporalEffects.isEmpty)
        XCTAssertEqual(Set(styleModes).count, styleModes.count, "Two style effects share a shader mode")
        XCTAssertEqual(Set(temporalModes).count, temporalModes.count, "Two temporal effects share a shader mode")
        XCTAssertEqual(styleModes.sorted(), Array(0 ... UInt32(styleModes.count - 1)), "Style modes must be contiguous")
        XCTAssertEqual(
            temporalModes.sorted(),
            Array(0 ... UInt32(temporalModes.count - 1)),
            "Temporal modes must be contiguous"
        )

        for effect in styleEffects + temporalEffects {
            let parameters = effect.defaultCameraParameters
            XCTAssertEqual(effect.parameterLabels.count, 3, effect.label)
            XCTAssertTrue((0 ... 1).contains(parameters.primary), effect.label)
            XCTAssertTrue((0 ... 1).contains(parameters.secondary), effect.label)
            XCTAssertTrue((0 ... 1).contains(parameters.tertiary), effect.label)
            XCTAssertTrue((0 ... 1).contains(parameters.blend), effect.label)
            XCTAssertFalse(parameters.isEnabled)
        }
    }

    /// Guards the exposure lock's contract.
    ///
    /// Driving ISO or shutter requires custom exposure mode, so the device
    /// stops metering. Those two fields are the ones that must show they are
    /// manual and the ones that hand metering back; marking a third by mistake
    /// would offer "restore auto" on a control that never left it, and
    /// forgetting one would strand the camera the way it was stranded before
    /// `resumeAutoExposure` had a caller.
    func testOnlyISOAndShutterHoldExposure() {
        XCTAssertEqual(
            Set(GVTelemetryField.allCases.filter(\.holdsExposure)),
            [.iso, .shutter]
        )
        XCTAssertFalse(CameraRuntimeSnapshot.idle.exposureLocked, "A camera starts metering")
    }

    /// The effect chain ran at capture resolution — 3840x2160, because the
    /// format filter rejects anything smaller — to fill a 1320x2868 drawable.
    /// Every kernel was dispatching over roughly twice the pixels it needed to.
    func testChainRunsAtPreviewScaleUntilAFrameIsBeingKept() {
        let drawable = 1320.0 * 2868.0

        let preview = CameraChainResolution.resolve(
            sourceWidth: 3840,
            sourceHeight: 2160,
            drawablePixels: drawable,
            fullResolution: false
        )
        let previewPixels = Double(preview.width * preview.height)
        XCTAssertLessThan(previewPixels, 3840.0 * 2160.0 * 0.62, "4K preview should cost well under two thirds")
        XCTAssertGreaterThan(previewPixels, drawable, "and still cover the drawable with headroom for the crop")
        XCTAssertEqual(preview.width % 2, 0)
        XCTAssertEqual(preview.height % 2, 0)
        XCTAssertEqual(
            Double(preview.width) / Double(preview.height),
            3840.0 / 2160.0,
            accuracy: 0.01,
            "Aspect must survive, or the preview fill and tap-to-focus mapping both skew"
        )

        // Recording and stills take the frame the resolution was for.
        let full = CameraChainResolution.resolve(
            sourceWidth: 3840,
            sourceHeight: 2160,
            drawablePixels: drawable,
            fullResolution: true
        )
        XCTAssertEqual(full.width, 3840)
        XCTAssertEqual(full.height, 2160)

        // Never upscales: a source already smaller than the drawable is left
        // alone rather than being blown up to fill it.
        let small = CameraChainResolution.resolve(
            sourceWidth: 1280,
            sourceHeight: 720,
            drawablePixels: drawable,
            fullResolution: false
        )
        XCTAssertEqual(small.width, 1280)
        XCTAssertEqual(small.height, 720)
    }

    func testCameraEffectBlendClampsToRendererContract() {
        var parameters = WorkspaceAdjustableEffect.vhs.defaultCameraParameters
        parameters.blend = 4
        XCTAssertEqual(parameters.sanitized.blend, 1)

        parameters.blend = -2
        XCTAssertEqual(parameters.sanitized.blend, 0)
    }

    func testEffectStackComposesAndDisablesWithoutStaleState() {
        var stack = CameraEffectStackParameters()
        stack.setEnabled(true, for: .pixelate)
        stack.setEnabled(true, for: .edge)
        stack.setEnabled(true, for: .feedback)

        XCTAssertEqual(stack.activeEffects.map(\.0), [.pixelate, .edge])
        XCTAssertEqual(stack.activeTemporalEffects.map(\.0), [.feedback])

        stack.reset(.pixelate)
        XCTAssertTrue(stack[.pixelate].isEnabled)
        stack.disableAll()
        XCTAssertTrue(stack.activeEffects.isEmpty)
        XCTAssertTrue(stack.activeTemporalEffects.isEmpty)
    }

    func testEffectStackCanEnableSingleDefaultEffect() {
        var stack = CameraEffectStackParameters()
        stack.setEnabled(true, for: .pixelate)
        stack.setEnabled(true, for: .feedback)

        stack.enableOnly(.edge)

        XCTAssertEqual(stack.activeEffects.map(\.0), [.edge])
        XCTAssertTrue(stack.activeTemporalEffects.isEmpty)
    }

    private func requireMetalDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable in this test environment.")
        }
        return device
    }

    private func texture(device: MTLDevice, color: SIMD4<Float>) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var pixel = [
            Float16(color.x).bitPattern,
            Float16(color.y).bitPattern,
            Float16(color.z).bitPattern,
            Float16(color.w).bitPattern
        ]
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &pixel,
            bytesPerRow: 4 * MemoryLayout<UInt16>.stride
        )
        return texture
    }

    private func readColor(_ texture: MTLTexture) -> SIMD4<Float> {
        var pixel = [UInt16](repeating: 0, count: 4)
        texture.getBytes(
            &pixel,
            bytesPerRow: 4 * MemoryLayout<UInt16>.stride,
            from: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0
        )
        return SIMD4<Float>(
            Float(Float16(bitPattern: pixel[0])),
            Float(Float16(bitPattern: pixel[1])),
            Float(Float16(bitPattern: pixel[2])),
            Float(Float16(bitPattern: pixel[3]))
        )
    }

    private func encode(
        pipeline: MTLComputePipelineState,
        queue: MTLCommandQueue,
        textures: [MTLTexture],
        uniforms: inout CameraStyleEffectUniforms
    ) throws {
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() {
            encoder.setTexture(texture, index: index)
        }
        encoder.setBytes(
            &uniforms,
            length: MemoryLayout<CameraStyleEffectUniforms>.stride,
            index: 0
        )
        encoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)
    }
}

/// Guards the slot model against the two ways it could quietly change output:
/// by reordering effects that used to render in pipeline order, and by losing
/// per-instance parameters when an effect appears twice.
final class CameraEffectStackSlotTests: XCTestCase {
    func testDefaultOrderStillMatchesPipelineOrder() {
        var stack = CameraEffectStackParameters()
        // Enabled in deliberately reversed pipeline order.
        let pipeline = WorkspaceAdjustableEffect.metalRenderOrder.filter { $0.styleMode != nil }
        let chosen = Array(pipeline.prefix(4)).reversed()
        for effect in chosen {
            stack.setEnabled(true, for: effect)
        }

        let rendered = stack.activeEffects.map(\.0)
        let expected = pipeline.filter { chosen.contains($0) }
        XCTAssertEqual(rendered, expected, "New slots must land in pipeline order")
    }

    /// The mirror of the test above, for the pass it did not reach.
    ///
    /// The style test filters to `styleMode != nil`, so it only ever exercised
    /// effects that appear in `metalRenderOrder`. Every temporal node is
    /// absent from that list, which is how they all came to share one fallback
    /// rank and fall back to tap order without a single test going red.
    func testTemporalOrderStillMatchesPipelineOrder() {
        var stack = CameraEffectStackParameters()
        let pipeline = WorkspaceAdjustableEffect.temporalRenderOrder.filter { $0.temporalMode != nil }
        XCTAssertGreaterThanOrEqual(pipeline.count, 4, "Need four temporal effects to reorder")
        let chosen = Array(pipeline.prefix(4)).reversed()
        for effect in chosen {
            stack.setEnabled(true, for: effect)
        }

        let rendered = stack.activeTemporalEffects.map(\.0)
        let expected = pipeline.filter { chosen.contains($0) }
        XCTAssertEqual(rendered, expected, "New temporal slots must land in pipeline order")
    }

    /// Enabling a style effect must not disturb where temporal effects sit,
    /// and vice versa — the two passes read the same slot array.
    func testStyleAndTemporalKeepTheirOwnOrderWhenInterleaved() {
        var stack = CameraEffectStackParameters()
        let style = WorkspaceAdjustableEffect.metalRenderOrder.filter { $0.styleMode != nil }
        let temporal = WorkspaceAdjustableEffect.temporalRenderOrder.filter { $0.temporalMode != nil }
        XCTAssertGreaterThanOrEqual(style.count, 2)
        XCTAssertGreaterThanOrEqual(temporal.count, 2)

        // Deliberately alternating, and each pair reversed.
        stack.setEnabled(true, for: temporal[1])
        stack.setEnabled(true, for: style[1])
        stack.setEnabled(true, for: temporal[0])
        stack.setEnabled(true, for: style[0])

        XCTAssertEqual(stack.activeEffects.map(\.0), [style[0], style[1]])
        XCTAssertEqual(stack.activeTemporalEffects.map(\.0), [temporal[0], temporal[1]])
    }

    /// The structural guard.
    ///
    /// Every effect the renderer can execute needs exactly one place in
    /// `defaultPlacementOrder`. An effect missing from both lists ranks last
    /// and orders by tap; an effect in both ranks by its style position and
    /// renders out of temporal order. Adding a case to the enum without
    /// adding it to the matching list fails here rather than on device.
    func testEveryRenderableEffectHasExactlyOnePlacementRank() {
        let metal = WorkspaceAdjustableEffect.metalRenderOrder
        let temporal = WorkspaceAdjustableEffect.temporalRenderOrder

        XCTAssertEqual(Set(metal).count, metal.count, "metalRenderOrder repeats an effect")
        XCTAssertEqual(Set(temporal).count, temporal.count, "temporalRenderOrder repeats an effect")
        XCTAssertTrue(Set(metal).isDisjoint(with: Set(temporal)), "An effect cannot be in both orders")

        for effect in WorkspaceAdjustableEffect.allCases {
            if effect.styleMode != nil {
                XCTAssertTrue(metal.contains(effect), "\(effect.rawValue) has a styleMode but no metalRenderOrder entry")
            }
            if effect.temporalMode != nil {
                XCTAssertTrue(
                    temporal.contains(effect),
                    "\(effect.rawValue) has a temporalMode but no temporalRenderOrder entry"
                )
            }
        }

        let placement = WorkspaceAdjustableEffect.defaultPlacementOrder
        XCTAssertEqual(placement.count, metal.count + temporal.count)
        XCTAssertEqual(Set(placement).count, placement.count)
    }

    func testDuplicateCopiesParametersAndKeepsBothInstances() {
        var stack = CameraEffectStackParameters()
        guard let effect = WorkspaceAdjustableEffect.metalRenderOrder.first(where: { $0.styleMode != nil })
        else { return XCTFail("No style effect available") }

        stack.setEnabled(true, for: effect)
        guard let original = stack.orderedSlots.first else { return XCTFail("No slot created") }
        XCTAssertNotNil(stack.duplicate(original.id))

        let matching = stack.orderedSlots.filter { $0.effect == effect }
        XCTAssertEqual(matching.count, 2, "Duplicate must produce a second instance")
        XCTAssertNotEqual(matching[0].id, matching[1].id, "Instances need distinct identity")
        XCTAssertEqual(matching[0].parameters, matching[1].parameters, "Duplicate copies parameters")
    }

    func testMoveChangesRenderOrder() {
        var stack = CameraEffectStackParameters()
        let pipeline = WorkspaceAdjustableEffect.metalRenderOrder.filter { $0.styleMode != nil }
        guard pipeline.count >= 2 else { return XCTFail("Need two style effects") }
        stack.setEnabled(true, for: pipeline[0])
        stack.setEnabled(true, for: pipeline[1])

        stack.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(stack.activeEffects.map(\.0), [pipeline[1], pipeline[0]])
    }

    func testRemoveDropsOnlyThatInstance() {
        var stack = CameraEffectStackParameters()
        guard let effect = WorkspaceAdjustableEffect.metalRenderOrder.first(where: { $0.styleMode != nil })
        else { return XCTFail("No style effect available") }
        stack.setEnabled(true, for: effect)
        guard let original = stack.orderedSlots.first else { return XCTFail("No slot created") }
        stack.duplicate(original.id)

        stack.remove(original.id)
        XCTAssertEqual(stack.orderedSlots.filter { $0.effect == effect }.count, 1)
    }
}
