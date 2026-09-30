@testable import GreyVision
import Metal
import XCTest

final class RenderCoreInfrastructureTests: XCTestCase {
    func testParameterMappingsClampAndUseRealUnits() {
        let logarithmic = ParameterDefinition(
            id: "frequency",
            displayName: "Frequency",
            defaultValue: 20,
            minimum: 20,
            maximum: 20_000,
            mapping: .logarithmic,
            unit: .hertz
        )
        XCTAssertEqual(logarithmic.value(normalized: 0), 20, accuracy: 0.001)
        XCTAssertEqual(logarithmic.value(normalized: 1), 20_000, accuracy: 0.1)
        XCTAssertGreaterThan(logarithmic.value(normalized: 0.5), 500)

        let stepped = ParameterDefinition(
            id: "frames",
            displayName: "Frames",
            defaultValue: 4,
            minimum: 1,
            maximum: 16,
            mapping: .stepped(step: 1),
            unit: .frames
        )
        XCTAssertEqual(stepped.value(normalized: 0.51).rounded(), stepped.value(normalized: 0.51))
        XCTAssertEqual(stepped.value(normalized: -.infinity), 1)
    }

    func testParameterStateDoesNotMutateBaseWhenModulated() {
        let definition = ParameterDefinition(
            id: "mix",
            displayName: "Mix",
            defaultValue: 0.5,
            minimum: 0,
            maximum: 1
        )
        let state = ParameterState(baseValue: 0.4, modulation: 0.3, automation: 0.2)
        XCTAssertEqual(state.baseValue, 0.4)
        XCTAssertEqual(state.effectiveValue(for: definition), 0.9, accuracy: 0.0001)
    }

    func testRenderGraphModelPreservesOrder() {
        var model = RenderGraphModel()
        model.replace(with: ["datamosh", "feedback", "bulge", "color"])
        model.move(from: 3, to: 1)
        XCTAssertEqual(model.orderedEffectIdentifiers, ["datamosh", "color", "feedback", "bulge"])
    }

    func testSerializableGraphRoundTripsWithoutGPUState() throws {
        let state = SerializableRenderGraphState(orderedSlots: [
            SerializableEffectSlot(
                effectIdentifier: "feedback",
                isEnabled: true,
                mix: 0.75,
                parameters: ["decay": ParameterState(baseValue: 0.9)]
            )
        ])
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(SerializableRenderGraphState.self, from: data), state)
    }

    func testTexturePoolReusesRecycledTexture() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pool = TexturePool(device: device, budgetBytes: 1024 * 1024)
        let key = TexturePoolKey(width: 64, height: 64)
        let first = try XCTUnwrap(pool.checkout(key))
        pool.recycle(first)
        let second = try XCTUnwrap(pool.checkout(key))
        XCTAssertEqual(ObjectIdentifier(first), ObjectIdentifier(second))
        XCTAssertEqual(pool.diagnostics.reuseCount, 1)
        pool.recycle(second)
    }

    func testPingPongSwapsExactlyOnce() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pair = try XCTUnwrap(PingPongTextures(
            device: device,
            key: TexturePoolKey(width: 16, height: 16),
            label: "test"
        ))
        let firstRead = ObjectIdentifier(pair.read)
        let firstWrite = ObjectIdentifier(pair.write)
        pair.swap()
        XCTAssertEqual(ObjectIdentifier(pair.read), firstWrite)
        XCTAssertEqual(ObjectIdentifier(pair.write), firstRead)
    }

    func testCircularHistoryIndexesAndBoundsCapacity() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let history = try CircularFrameHistory(
            device: device,
            configuration: CircularFrameHistoryConfiguration(
                dimensions: RenderDimensions(width: 16, height: 16),
                requestedCapacity: 8,
                memoryBudgetBytes: 16 * 16 * 8 * 3
            )
        )
        XCTAssertEqual(history.capacity, 3)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: 16,
            height: 16,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        let source = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        for timestamp in 1 ... 4 {
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            try history.encodeAppend(
                source: source,
                timestamp: TimeInterval(timestamp),
                commandBuffer: buffer
            )
        }

        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.frame(framesAgo: 0)?.timestamp, 4)
        XCTAssertEqual(history.frame(framesAgo: 1)?.timestamp, 3)
        XCTAssertEqual(history.frame(framesAgo: 2)?.timestamp, 2)
        XCTAssertNil(history.frame(framesAgo: 3))
    }

    func testEffectFailureBypassesAndContinues() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: 16,
            height: 16,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        let input = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let bank = TemporalBufferBank(device: device, memoryBudgetBytes: 1024 * 1024)
        let pool = TexturePool(device: device, budgetBytes: 1024 * 1024)
        let recorder = EffectOrderRecorder()
        let first = TestRenderEffect(identifier: "first", recorder: recorder)
        let failing = TestRenderEffect(identifier: "failing", recorder: recorder, shouldFail: true)
        let last = TestRenderEffect(identifier: "last", recorder: recorder)
        let graph = RenderGraph(texturePool: pool)
        graph.replaceEffects([first, failing, last])

        let result = graph.process(
            input: input,
            frame: makeFrameContext(
                texture: input,
                commandBuffer: buffer,
                temporalBuffers: bank
            )
        )

        XCTAssertEqual(recorder.identifiers, ["first", "failing", "last"])
        XCTAssertEqual(result.failedEffectIdentifiers, ["failing"])
        XCTAssertFalse(failing.isEnabled)
    }

    func testRenderGraphAcceptsPersistentExternalScratchTextures() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: 16,
            height: 16,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        let input = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let scratchA = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let scratchB = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let bank = TemporalBufferBank(device: device, memoryBudgetBytes: 1024)
        let pool = TexturePool(device: device, budgetBytes: 1)
        let recorder = EffectOrderRecorder()
        let graph = RenderGraph(texturePool: pool)
        graph.replaceEffects([TestRenderEffect(identifier: "external", recorder: recorder)])

        let result = graph.process(
            input: input,
            frame: makeFrameContext(
                texture: input,
                commandBuffer: buffer,
                temporalBuffers: bank
            ),
            scratchTextures: (scratchA, scratchB)
        )

        XCTAssertEqual(recorder.identifiers, ["external"])
        XCTAssertEqual(ObjectIdentifier(result.texture), ObjectIdentifier(scratchA))
        XCTAssertEqual(pool.diagnostics.allocationCount, 0)
    }

    private func makeFrameContext(
        texture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        temporalBuffers: TemporalBufferBank
    ) -> FrameContext {
        let dimensions = RenderDimensions(width: texture.width, height: texture.height)
        return FrameContext(
            frameIndex: 1,
            timestamp: 1,
            deltaTime: 1 / 60,
            sourceTexture: texture,
            previousSourceTexture: nil,
            resolutions: RenderResolutionSet(
                capture: dimensions,
                preview: dimensions,
                effects: dimensions,
                output: dimensions
            ),
            orientation: RenderOrientationState(
                source: .landscapeRight,
                render: .landscapeRight,
                display: .landscapeRight,
                record: .landscapeRight,
                isMirrored: false
            ),
            colorPipeline: .cameraSDR,
            cameraMetadata: CameraFrameMetadata(
                presentationTime: .zero,
                exposureDurationSeconds: nil,
                iso: nil,
                lensPosition: nil,
                whiteBalanceTemperature: nil,
                sourceIdentifier: nil
            ),
            temporalBuffers: temporalBuffers,
            motionField: .empty,
            interaction: .idle,
            modulation: .empty,
            commandBuffer: commandBuffer
        )
    }
}

private final class EffectOrderRecorder {
    private(set) var identifiers: [String] = []
    func append(_ identifier: String) {
        identifiers.append(identifier)
    }
}

private final class TestRenderEffect: RenderEffect {
    let identifier: String
    let displayName: String
    let kind = RenderEffectKind.stateless
    var isEnabled = true
    var mix: Float = 1
    var parameterDefinitions: [ParameterDefinition] = []
    var parameterState = EffectParameterState()
    var mask = EffectMaskInput.none
    private let recorder: EffectOrderRecorder
    private let shouldFail: Bool

    init(identifier: String, recorder: EffectOrderRecorder, shouldFail: Bool = false) {
        self.identifier = identifier
        self.displayName = identifier
        self.recorder = recorder
        self.shouldFail = shouldFail
    }

    func prepare(_: RenderPreparationContext) throws {}

    func process(_: EffectRenderRequest) throws {
        recorder.append(identifier)
        if shouldFail { throw RenderEffectError.processingFailed(identifier) }
    }
}
