import CoreVideo
@testable import GreyVision
import simd
import SwiftUI
import XCTest

final class DepthEffectContractTests: XCTestCase {
    @MainActor
    func testDepthKnobDeckRendersUsingPhysicalParameterBindings() throws {
        for mode in [DepthEffectMode.pointCloud, .surfaceRelight, .worldGrid, .subjectDecay] {
            var parameters = DepthEffectParameters.defaults(for: mode)
            let deck = DepthEffectParameterDeck(
                effect: mode,
                parameters: Binding(get: { parameters }, set: { parameters = $0 }),
                onClose: {}, onExitDepth: {}
            )
            .environmentObject(GVToastBox())
            .frame(width: 390)
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: deck)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertGreaterThan(image.size.height, 80)
            let attachment = XCTAttachment(image: image)
            attachment.name = "LiDAR knobs - \(mode.label)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testStableIDsAndPhysicalDefaults() {
        XCTAssertEqual(DepthEffectMode.nightVision.rawValue, 16)
        XCTAssertEqual(DepthEffectMode.surfaceRelight.rawValue, 17)
        XCTAssertEqual(DepthEffectMode.worldGrid.rawValue, 18)
        // Consolidation retires wire numbers without ever reusing them, so a
        // recording saved before it resolves to the same look it always did.
        let retired: Set<UInt32> = [2, 4, 5, 8, 9, 10, 11, 12, 13, 14, 19]
        XCTAssertTrue(retired.isDisjoint(with: Set(DepthEffectMode.allCases.map(\.rawValue))))
        XCTAssertEqual(DepthEffectMode.allCases.count, 9)
        // Every fullscreen mode packs four real units into the SIMD4 the shader
        // reads; a fifth would be dropped before it ever reached the GPU.
        for mode in DepthEffectMode.allCases where mode != .pointCloud {
            XCTAssertEqual(DepthEffectCatalog.effectControls(for: mode).count, 4, mode.label)
        }
        for (mode, expected) in [(DepthEffectMode.surfaceRelight, SIMD3<Float>(-35, 45, 0.3)),
                                 (.worldGrid, SIMD3<Float>(0.25, 1, 0.75)),
                                 (.depthSlice, SIMD3<Float>(1.3, 0.6, 0.5)),
                                 (.depthMap, SIMD3<Float>(1, 0.01, 0.5))] {
            let packed = DepthEffectParameters.defaults(for: mode).packedControls(for: mode)
            XCTAssertEqual(packed.x, expected.x, accuracy: 0.0001)
            XCTAssertEqual(packed.y, expected.y, accuracy: 0.0001)
            XCTAssertEqual(packed.z, expected.z, accuracy: 0.0001)
        }
        // Paging: `controls` is the pages flattened, so page one is INTENSITY plus
        // the first three effect knobs, and page two opens with the acquisition
        // gates ahead of any effect knob that did not fit on page one.
        for mode in DepthEffectMode.allCases {
            let pages = DepthEffectCatalog.controlPages(for: mode)
            let ids = pages.flatMap { $0.map(\.id) }
            let defining = DepthEffectCatalog.effectControls(for: mode).map(\.id)
            XCTAssertEqual(ids.first, "INTENSITY", mode.label)
            XCTAssertEqual(Array(ids.dropFirst().prefix(3)), Array(defining.prefix(3)), mode.label)
            XCTAssertEqual(pages[1].prefix(3).map { $0.id }, ["NEAR", "FAR", "CONFIDENCE"], mode.label)
            XCTAssertEqual(Set(ids).count, ids.count, mode.label)
            XCTAssertEqual(pages.map { $0.count }.reduce(0, +), ids.count, mode.label)
            for id in defining {
                XCTAssertTrue(ids.contains(id), "\(mode.label) hides \(id)")
            }
        }
    }

    func testViewToSensorOrientationAndAspectFill() {
        let image = SIMD2<Float>(1920, 1440)
        let cases: [(CapturedFrameOrientation, SIMD2<Float>, SIMD2<Float>)] = [
            (.portrait, SIMD2(300, 400), SIMD2(0.25, 0.75)),
            (.portraitUpsideDown, SIMD2(300, 400), SIMD2(0.75, 0.25)),
            (.landscapeLeft, SIMD2(400, 300), SIMD2(0.25, 0.25)),
            (.landscapeRight, SIMD2(400, 300), SIMD2(0.75, 0.75))
        ]
        for (orientation, viewport, expected) in cases {
            let actual = DepthGeometry.sensorUV(viewUV: SIMD2(0.25, 0.25), viewport: viewport, image: image, orientation: orientation)
            XCTAssertEqual(actual?.x ?? -1, expected.x, accuracy: 0.0001)
            XCTAssertEqual(actual?.y ?? -1, expected.y, accuracy: 0.0001)
        }
        // A tall portrait crops horizontal sensor extent after rotation.
        let cropped = DepthGeometry.sensorUV(viewUV: .zero, viewport: SIMD2(300, 600), image: image, orientation: .portrait)
        XCTAssertEqual(cropped?.x ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(cropped?.y ?? -1, 5.0 / 6.0, accuracy: 0.0001)
        XCTAssertNil(DepthGeometry.sensorUV(viewUV: SIMD2(.nan, 0), viewport: SIMD2(300, 600), image: image, orientation: .portrait))
    }

    func testWorldUnprojectionUsesARKitAxesAndPose() {
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4(10, 20, 30, 1)
        let point = DepthGeometry.worldPoint(pixel: SIMD2(60, 70), depthMeters: 2, intrinsics: SIMD4(100, 100, 50, 50), worldFromCamera: pose)
        XCTAssertEqual(point?.x ?? 0, 10.2, accuracy: 0.0001)
        XCTAssertEqual(point?.y ?? 0, 19.6, accuracy: 0.0001)
        XCTAssertEqual(point?.z ?? 0, 28, accuracy: 0.0001)
    }

    func testFiniteSanitizationAndVariantResolution() {
        var value = DepthEffectParameters.defaults
        value.confidenceThreshold = .nan
        value.sampleStride = .infinity
        value.intensity = -.infinity
        value.bandWidth = .nan
        let safe = value.sanitized
        XCTAssertEqual(Int(safe.sampleStride), 1)
        XCTAssertEqual(Int(safe.confidenceThreshold), 0)
        XCTAssertTrue(safe.intensity.isFinite)
        XCTAssertTrue(safe.bandWidth.isFinite)
        // Consolidation left every retired wire number unreachable rather than
        // aliased, so an old recording falls back to the feed instead of
        // resolving to a look that now means something else.
        XCTAssertNil(DepthEffectMode(rawValue: 19))
    }

    @MainActor
    func testRuntimeKeepsParametersPerMode() {
        let runtime = DepthRuntime(capability: DepthCapability(isSupported: false, supportsSmoothedDepth: false, reason: "test"))
        runtime.setEffect(.worldGrid)
        runtime.parameters.intensity = 0.31
        runtime.setEffect(.depthSlice)
        XCTAssertEqual(runtime.parameters.packedControls(for: .depthSlice).x, 1.3, accuracy: 0.0001)
        runtime.setEffect(.worldGrid)
        XCTAssertEqual(runtime.parameters.intensity, 0.31)
    }
}
