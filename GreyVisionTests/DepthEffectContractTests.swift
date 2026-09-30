import CoreVideo
@testable import GreyVision
import simd
import SwiftUI
import XCTest

final class DepthEffectContractTests: XCTestCase {
    @MainActor
    func testDepthKnobDeckRendersUsingPhysicalParameterBindings() throws {
        for mode in [DepthEffectMode.pointCloud, .surfaceRelight, .sonarPulse] {
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
        XCTAssertEqual(DepthEffectMode.sonarPulse.rawValue, 19)
        for (mode, expected) in [(DepthEffectMode.surfaceRelight, SIMD3<Float>(-35, 45, 0.35)), (.worldGrid, SIMD3<Float>(0.25, 1, 1)), (.sonarPulse, SIMD3<Float>(0.75, 0.08, 0.45))] {
            let packed = DepthEffectParameters.defaults(for: mode).packedControls(for: mode)
            XCTAssertEqual(packed.x, expected.x, accuracy: 0.0001)
            XCTAssertEqual(packed.y, expected.y, accuracy: 0.0001)
            XCTAssertEqual(packed.z, expected.z, accuracy: 0.0001)
            XCTAssertEqual(DepthEffectCatalog.controls(for: mode).prefix(4).map(\.id).first, "INTENSITY")
            XCTAssertEqual(Array(DepthEffectCatalog.controls(for: mode).dropFirst(4)).map(\.id), ["NEAR", "FAR", "CONFIDENCE"])
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
        XCTAssertEqual(DepthEffectCatalog.canonicalMode(for: .depthBands), .contours)
        XCTAssertEqual(DepthEffectCatalog.variants(for: .depthGlow), [.depthEdges, .depthGlow])
    }

    @MainActor
    func testRuntimeKeepsParametersPerMode() {
        let runtime = DepthRuntime(capability: DepthCapability(isSupported: false, supportsSmoothedDepth: false, reason: "test"))
        runtime.setEffect(.worldGrid)
        runtime.parameters.intensity = 0.31
        runtime.setEffect(.sonarPulse)
        XCTAssertEqual(runtime.parameters.packedControls(for: .sonarPulse).x, 0.75, accuracy: 0.0001)
        runtime.setEffect(.worldGrid)
        XCTAssertEqual(runtime.parameters.intensity, 0.31)
    }
}
