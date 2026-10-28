import CoreGraphics
@testable import GreyVision
import XCTest

final class TrackingSuiteTests: XCTestCase {
    // MARK: Parameters

    func testParametersDecodeMissingFieldsToDefaultsAndClamp() throws {
        let partial = Data(#"{"mode":"motion","maxTracks":99,"smoothing":-4}"#.utf8)
        let decoded = try JSONDecoder().decode(BlobTrackingParameters.self, from: partial)
        XCTAssertEqual(decoded.mode, .motion)
        XCTAssertEqual(decoded.style, BlobTrackingParameters.defaults.style)
        XCTAssertEqual(decoded.sanitized.maxTracks, 16)
        XCTAssertEqual(decoded.sanitized.smoothing, 0)
        let roundTrip = try JSONDecoder().decode(BlobTrackingParameters.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(roundTrip, decoded)
    }

    func testEveryPresetIsSaneAndUniquelyNamed() {
        XCTAssertEqual(Set(GVTrackingPreset.all.map(\.id)).count, GVTrackingPreset.all.count)
        for preset in GVTrackingPreset.all {
            XCTAssertEqual(preset.parameters, preset.parameters.sanitized, preset.id)
            XCTAssertEqual(GVTrackingPreset.matching(preset.parameters)?.id, preset.id)
        }
    }

    // MARK: Field detection

    func testColorModeFindsAKeyedSquareAndIgnoresGrey() {
        let frame = Self.frame(width: 120, height: 200, square: CGRect(x: 30, y: 60, width: 40, height: 40),
                               fill: (220, 30, 30), background: (128, 128, 128))
        var parameters = BlobTrackingParameters.defaults
        parameters.mode = .color
        parameters.hue = 0
        let output = GVFieldDetector().detect(frame, parameters: parameters)
        XCTAssertEqual(output.detections.count, 1)
        let rect = try? XCTUnwrap(output.detections.first?.rect)
        XCTAssertEqual(rect?.midX ?? 0, 50.0 / 120, accuracy: 0.05)
        XCTAssertEqual(rect?.midY ?? 0, 80.0 / 200, accuracy: 0.05)
    }

    func testBrightModeSelectsTheBrightestSliceOfAFlatScene() {
        let frame = Self.frame(width: 120, height: 200, square: CGRect(x: 70, y: 20, width: 30, height: 30),
                               fill: (250, 250, 250), background: (90, 90, 90))
        var parameters = BlobTrackingParameters.defaults
        parameters.mode = .bright
        let output = GVFieldDetector().detect(frame, parameters: parameters)
        XCTAssertFalse(output.detections.isEmpty)
        XCTAssertEqual(output.detections[0].rect.midX, 85.0 / 120, accuracy: 0.06)
    }

    func testMotionModeNeedsAPreviousFrame() {
        let detector = GVFieldDetector()
        var parameters = BlobTrackingParameters.defaults
        parameters.mode = .motion
        let still = Self.frame(width: 80, height: 80, square: CGRect(x: 10, y: 10, width: 20, height: 20),
                               fill: (240, 240, 240), background: (20, 20, 20))
        let moved = Self.frame(width: 80, height: 80, square: CGRect(x: 50, y: 50, width: 20, height: 20),
                               fill: (240, 240, 240), background: (20, 20, 20))
        XCTAssertTrue(detector.detect(still, parameters: parameters).detections.isEmpty)
        XCTAssertFalse(detector.detect(moved, parameters: parameters).detections.isEmpty)
    }

    // MARK: Association

    func testIdentitySurvivesMotionAndCoastsThenDrops() {
        let associator = GVTrackAssociator()
        var parameters = BlobTrackingParameters.defaults
        parameters.confirm = 2
        parameters.persistence = 0.3
        var id: UInt64?
        for step in 0 ..< 6 {
            let x = 0.2 + Double(step) * 0.03
            let blobs = associator.update([Self.detection(x: x, y: 0.5)], at: Double(step) / 15, parameters: parameters)
            if step == 0 { XCTAssertTrue(blobs.isEmpty, "unconfirmed subjects stay hidden") }
            if step >= 1 {
                XCTAssertEqual(blobs.count, 1)
                if id == nil { id = blobs[0].id }
                XCTAssertEqual(blobs[0].id, id, "one subject keeps one identity")
            }
        }
        let coasting = associator.update([], at: 6.0 / 15, parameters: parameters)
        XCTAssertEqual(coasting.first?.isCoasting, true)
        XCTAssertGreaterThan(coasting.first?.velocity.dx ?? 0, 0, "coasts in the direction it was moving")
        XCTAssertTrue(associator.update([], at: 6.0 / 15 + 0.5, parameters: parameters).isEmpty)
    }

    func testTwoSubjectsKeepSeparateIdentities() {
        let associator = GVTrackAssociator()
        var parameters = BlobTrackingParameters.defaults
        parameters.confirm = 1
        let first = associator.update([Self.detection(x: 0.2, y: 0.2), Self.detection(x: 0.8, y: 0.8)], at: 0, parameters: parameters)
        let second = associator.update([Self.detection(x: 0.82, y: 0.79), Self.detection(x: 0.21, y: 0.22)], at: 0.066, parameters: parameters)
        XCTAssertEqual(Set(first.map(\.id)), Set(second.map(\.id)))
        let left = second.first { $0.rect.midX < 0.5 }
        XCTAssertEqual(left?.id, first.first { $0.rect.midX < 0.5 }?.id)
    }

    // MARK: Feed

    func testVisibleRegionMatchesAnAspectFillCrop() {
        let landscapeOnPortrait = GVTrackingFeed.visibleRegion(sourceWidth: 3840, sourceHeight: 2160, viewAspect: 393.0 / 852)
        XCTAssertEqual(landscapeOnPortrait.height, 1)
        XCTAssertEqual(landscapeOnPortrait.width, (393.0 / 852) / (3840.0 / 2160), accuracy: 0.0001)
        XCTAssertEqual(landscapeOnPortrait.midX, 0.5, accuracy: 0.0001)
        let size = GVTrackingFeed.size(sourceWidth: 3840, sourceHeight: 2160, region: landscapeOnPortrait)
        XCTAssertEqual(size.height, GVTrackingFeed.longEdge)
        XCTAssertEqual(Double(size.width) / Double(size.height), 393.0 / 852, accuracy: 0.02)
    }

    // MARK: Fixtures

    private static func frame(width: Int, height: Int, square: CGRect,
                              fill: (UInt8, UInt8, UInt8), background: (UInt8, UInt8, UInt8)) -> GVTrackingFrame
    {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let inside = square.contains(CGPoint(x: x, y: y))
                let color = inside ? fill : background
                let index = (y * width + x) * 4
                pixels[index] = color.0
                pixels[index + 1] = color.1
                pixels[index + 2] = color.2
            }
        }
        return GVTrackingFrame(width: width, height: height, pixels: pixels, timestamp: 0)
    }

    private static func detection(x: Double, y: Double) -> GVTrackingDetection {
        GVTrackingDetection(rect: CGRect(x: x - 0.05, y: y - 0.05, width: 0.1, height: 0.1),
                            color: SIMD3(1, 0, 0), area: 0.01, confidence: 1)
    }
}
