@testable import GreyVision
import Metal
import XCTest

/// Opt-in audit probes over every effect kernel; see `GVEffectKernelProbe`.
///
/// `GV_EFFECT_BENCH=1` ranks kernels by GPU cost. `GV_EFFECT_SIGNATURES=<dir>`
/// with `GV_AUDIT_STILL=<image>` writes each effect over a photograph. From
/// xcodebuild, prefix both with `TEST_RUNNER_`.
final class EffectCostBenchmarkTests: XCTestCase {
    func testEveryCatalogKernelExecutesWithoutGPUFailure() throws {
        let results = try probe().rankByCost(width: 64, height: 64, iterations: 1)
        let expected = WorkspaceAdjustableEffect.allCases.filter { $0.styleMode != nil || $0.temporalMode != nil }
        XCTAssertEqual(Set(results.map(\.0)), Set(expected))
        XCTAssertTrue(results.allSatisfy { $0.1.isFinite && $0.1 >= 0 })
    }

    func testRankEveryEffectKernelByGPUCost() throws {
        guard ProcessInfo.processInfo.environment["GV_EFFECT_BENCH"] == "1" else {
            throw XCTSkip("Set GV_EFFECT_BENCH=1 to run the effect cost benchmark")
        }
        let ranked = try probe().rankByCost()
        for (effect, milliseconds) in ranked {
            print(String(format: "GVBENCH %@ %.4f", effect.rawValue, milliseconds))
        }
        XCTAssertFalse(ranked.isEmpty)
    }

    func testWriteEveryEffectSignatureOverAPhotograph() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["GV_EFFECT_SIGNATURES"], let still = environment["GV_AUDIT_STILL"] else {
            throw XCTSkip("Set GV_EFFECT_SIGNATURES and GV_AUDIT_STILL to write effect signatures")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let signatures = try probe().writeSignatures(still: URL(fileURLWithPath: still), to: directory)
        for (effect, change) in signatures {
            print(String(format: "GVSIG %@ %.4f", effect.rawValue, change))
        }
        XCTAssertFalse(signatures.isEmpty)
    }

    private func probe() throws -> GVEffectKernelProbe {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        return try GVEffectKernelProbe(
            device: device,
            library: device.makeDefaultLibrary(bundle: Bundle(for: AppModel.self))
        )
    }
}
