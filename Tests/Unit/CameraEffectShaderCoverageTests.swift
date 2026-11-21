@testable import GreyVision
import XCTest

/// Ties the Swift effect registry to the Metal kernel that actually renders it.
///
/// The registry tests next door assert that modes are unique and contiguous,
/// which is necessary and was not sufficient. Three failures got past them:
///
///   - style modes 7, 8 and 15 were fully implemented kernels with no Swift
///     case at all, so three effects existed and were unreachable;
///   - temporal modes 37 and 38 (WORLD FEEDBACK, TIME GRAFFITI) were listed in
///     the app with no shader arm, fell through to `default: break`, and
///     shipped as passthroughs — an effect that draws nothing;
///   - DATAMOSH, LIQUID MOSH and HEAVY MOSH all reported mode 4, so two thirds
///     of that rail were the same kernel under different names.
///
/// None of those are visible from Swift alone: the shader is the other half of
/// the contract. So this reads the kernel source and compares the arms it
/// actually implements against the modes the registry claims.
///
/// The source is located from `#filePath`, which points at the checkout on any
/// machine that built the bundle. Where it does not resolve — a bundle moved
/// away from its source — the test skips rather than fails, because a missing
/// file is not evidence of a missing effect.
final class CameraEffectShaderCoverageTests: XCTestCase {
    func testEveryStyleModeHasAShaderArmAndEveryArmHasAnEffect() throws {
        let arms = try shaderModes()[0]
        let declared = Set(WorkspaceAdjustableEffect.allCases.compactMap(\.styleMode))

        XCTAssertEqual(
            declared.subtracting(arms).sorted(),
            [],
            "style modes declared in Swift with no arm in gvCameraStyleEffect — these render as passthrough"
        )
        XCTAssertEqual(
            arms.subtracting(declared).sorted(),
            [],
            "style kernels with no WorkspaceAdjustableEffect case — implemented and unreachable"
        )
    }

    func testEveryTemporalModeHasAShaderArmAndEveryArmHasAnEffect() throws {
        let arms = try shaderModes()[1]
        let declared = Set(WorkspaceAdjustableEffect.allCases.compactMap(\.temporalMode))

        XCTAssertEqual(
            declared.subtracting(arms).sorted(),
            [],
            "temporal modes declared in Swift with no arm in gvCameraTemporalEffect — these render as passthrough"
        )
        XCTAssertEqual(
            arms.subtracting(declared).sorted(),
            [],
            "temporal kernels with no WorkspaceAdjustableEffect case — implemented and unreachable"
        )
    }

    /// One effect, one kernel. Sharing a mode makes two rail entries a
    /// relabelling of the same code, which is what LIQUID MOSH and HEAVY MOSH
    /// were: different default sliders, identical rendering.
    func testNoTwoEffectsShareAKernel() {
        for keyPath in [\WorkspaceAdjustableEffect.styleMode, \WorkspaceAdjustableEffect.temporalMode] {
            var owner: [UInt32: WorkspaceAdjustableEffect] = [:]
            for effect in WorkspaceAdjustableEffect.allCases {
                guard let mode = effect[keyPath: keyPath] else { continue }
                if let existing = owner[mode] {
                    XCTFail("\(effect.rawValue) and \(existing.rawValue) both render as mode \(mode)")
                }
                owner[mode] = effect
            }
        }
    }

    func testStyleKernelSupportsFunctionConstantSpecialization() throws {
        let source = try shaderSource()
        XCTAssertTrue(source.contains("gvStyleModeConstant [[function_constant(0)]]"))
        XCTAssertTrue(source.contains("kernel void gvCameraStyleEffectGeneric"))
        XCTAssertTrue(source.contains("position, gvStyleModeConstant"))
        XCTAssertTrue(source.contains("switch (styleMode)"))
    }

    func testFlowFieldsUseAnalyticNoiseGradients() throws {
        let source = try shaderSource()
        XCTAssertTrue(source.contains("GVNoiseGradient gvNoiseGradient"))
        XCTAssertFalse(
            source.contains("gvFbm(p + float2(epsilon"),
            "FBM gradients must not regress to four complete finite-difference evaluations per pixel"
        )
    }

    // MARK: - Shader parsing

    /// The `case N:` arms of each top-level mode switch in kernel source order:
    /// specialized style first, then uniform-selected temporal.
    ///
    /// Depth-tracked rather than regex-scanned over the whole file, so a
    /// `case` inside a nested switch or an initialiser list cannot be mistaken
    /// for a mode. Line comments are stripped first because several arms carry
    /// their description on the `case` line.
    private func shaderModes() throws -> [Set<UInt32>] {
        let source = try shaderSource()
        let stripped = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex ..< comment.lowerBound]
            }
            .joined(separator: "\n")

        let characters = Array(stripped)
        var switches: [Set<UInt32>] = []
        var index = characters.startIndex
        let markers = [
            Array("switch (styleMode) {"),
            Array("switch (uniforms.mode.x) {")
        ]

        while index < characters.count {
            guard let marker = markers.first(where: { matches(characters, at: index, $0) }) else {
                index += 1
                continue
            }
            index += marker.count
            var depth = 1
            var modes: Set<UInt32> = []
            while index < characters.count, depth > 0 {
                switch characters[index] {
                case "{": depth += 1
                case "}": depth -= 1
                default:
                    if depth == 1, let mode = caseLabel(characters, at: index) {
                        modes.insert(mode)
                    }
                }
                index += 1
            }
            switches.append(modes)
        }

        XCTAssertEqual(switches.count, 2, "expected exactly two mode switches: style and temporal")
        return switches
    }

    private func matches(_ characters: [Character], at index: Int, _ pattern: [Character]) -> Bool {
        guard index + pattern.count <= characters.count else { return false }
        for offset in 0 ..< pattern.count where characters[index + offset] != pattern[offset] {
            return false
        }
        return true
    }

    /// Reads `case <digits>:` starting exactly at `index`, or nil.
    private func caseLabel(_ characters: [Character], at index: Int) -> UInt32? {
        guard matches(characters, at: index, Array("case ")) else { return nil }
        var cursor = index + 5
        var digits = ""
        while cursor < characters.count, characters[cursor].isNumber {
            digits.append(characters[cursor])
            cursor += 1
        }
        guard !digits.isEmpty, cursor < characters.count, characters[cursor] == ":" else { return nil }
        return UInt32(digits)
    }

    private func shaderSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let shader = testFile
            .deletingLastPathComponent() // Tests/Unit
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("GreyVision/Resources/Shaders/CameraShaders.metal")
        guard FileManager.default.fileExists(atPath: shader.path) else {
            throw XCTSkip("Kernel source not reachable from \(shader.path); bundle built elsewhere")
        }
        return try String(contentsOf: shader, encoding: .utf8)
    }
}
