import SwiftUI

/// The browser's Tracking shelf: one tile per preset, each previewing its look
/// with the same drawing code the live overlay uses, over mock subjects.
struct GVTrackingPane: View {
    @ObservedObject var runtime: BlobTrackingRuntime
    let tileMinimum: CGFloat
    let spacing: CGFloat
    let onSelect: (GVTrackingPreset) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: spacing) {
                header
                LazyVGrid(columns: [GridItem(.adaptive(minimum: tileMinimum, maximum: 260), spacing: spacing)],
                          spacing: spacing)
                {
                    ForEach(Array(GVTrackingPreset.all.enumerated()), id: \.element.id) { index, preset in
                        Button { onSelect(preset) } label: {
                            GVTrackingPresetTile(preset: preset, active: isActive(preset))
                        }
                        .buttonStyle(GVEffectTileStyle())
                        .gvTileEntrance(index: index, reduceMotion: reduceMotion)
                        .gvTileScrollDepth(reduceMotion: reduceMotion)
                        .accessibilityLabel(preset.name)
                        .accessibilityHint(preset.detail)
                        .accessibilityValue(isActive(preset) ? "active" : "inactive")
                        .accessibilityIdentifier("workspace.tracking.preset.\(preset.id)")
                    }
                }
            }
            .padding(spacing)
        }
        .accessibilityIdentifier("workspace.tracking.presets")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tracking")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(GVTheme.bone)
                Text(runtime.isEnabled ? runtime.status : "Pick a look to start. Every control is in the deck after.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(GVTheme.bone.opacity(0.6))
                    .lineLimit(2)
            }
            Spacer()
            if runtime.isEnabled {
                GVDeckChip(label: "Stop", symbol: "stop.fill", active: true, tint: .white, id: "tracking.stop") {
                    runtime.stop()
                }
            }
        }
    }

    private func isActive(_ preset: GVTrackingPreset) -> Bool {
        runtime.isEnabled && GVTrackingPreset.matching(runtime.parameters)?.id == preset.id
    }
}

/// A preset preview: the preset's own overlay drawn over a few still mock
/// subjects on a dark field, using `GVTrackingCanvas` so the tile shows what
/// the live overlay will actually draw.
private struct GVTrackingPresetTile: View {
    let preset: GVTrackingPreset
    let active: Bool

    var body: some View {
        Color.clear
            .aspectRatio(0.82, contentMode: .fit)
            .overlay { preview }
            .overlay(alignment: .bottom) { caption }
            .overlay(alignment: .topLeading) {
                Image(systemName: preset.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GVTheme.bone)
                    .frame(width: 24, height: 24)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding(8)
                    .accessibilityHidden(true)
            }
            .background(
                LinearGradient(colors: [Color(white: 0.10), Color(white: 0.03)], startPoint: .top, endPoint: .bottom)
            )
            .clipShape(RoundedRectangle(cornerRadius: GVEffectTileFace.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: GVEffectTileFace.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(active ? 0.85 : 0.07), lineWidth: active ? 1.5 : 0.75)
            }
    }

    private var preview: some View {
        Canvas { context, size in
            let canvas = GVTrackingCanvas(parameters: preset.parameters, surface: size,
                                          displayed: CGRect(origin: .zero, size: size), elapsed: 0)
            canvas.build(blobs: Self.mockSubjects(for: preset.parameters), mask: Self.mockMask, hud: [])
                .play(in: &context)
        }
        .padding(.top, 34)
        .padding(.bottom, 40)
        .accessibilityHidden(true)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(preset.name)
                .font(.system(size: 13, weight: active ? .semibold : .medium))
                .foregroundStyle(GVTheme.bone)
            Text(preset.detail)
                .font(.system(size: 10))
                .foregroundStyle(GVTheme.bone.opacity(0.6))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.bottom, 10)
    }

    // MARK: Mock subjects

    private static func mockSubjects(for parameters: BlobTrackingParameters) -> [TrackedBlob] {
        let placements: [(CGRect, SIMD3<Float>)] = [
            (CGRect(x: 0.14, y: 0.16, width: 0.30, height: 0.26), SIMD3(1.0, 0.25, 0.3)),
            (CGRect(x: 0.56, y: 0.30, width: 0.24, height: 0.20), SIMD3(0.3, 0.9, 1.0)),
            (CGRect(x: 0.30, y: 0.58, width: 0.20, height: 0.18), SIMD3(1.0, 0.85, 0.3))
        ]
        let count = parameters.mode == .face || parameters.mode == .body ? 2 : (parameters.mode == .hand ? 1 : 3)
        return placements.prefix(count).enumerated().map { index, placement in
            let (rect, color) = placement
            let trail = (0 ..< parameters.trailCapacity / 3).map { step -> CGPoint in
                let t = CGFloat(step) / 16
                return CGPoint(x: rect.midX - 0.22 * (1 - t) + 0.02 * sin(t * 9), y: rect.midY + 0.12 * (1 - t))
            }
            let (joints, bones) = mockPose(for: parameters.mode, in: rect)
            return TrackedBlob(
                id: UInt64(index + 3),
                rect: rect,
                velocity: CGVector(dx: 0.18, dy: -0.08),
                color: color,
                area: Float(rect.width * rect.height),
                confidence: 0.92,
                label: EsotericLabelGenerator.label(for: 0xB10B_5EED_2026, index: index + 3),
                age: 1.2 + Double(index),
                isCoasting: false,
                trail: trail,
                joints: joints,
                bones: bones
            )
        }
    }

    private static func mockPose(for mode: GVTrackingMode, in rect: CGRect) -> ([CGPoint], [[Int]]) {
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        switch mode {
        case .body:
            // nose, eyes, ears, neck, shoulders, elbows, wrists, root, hips, knees, ankles
            let joints = [at(0.5, 0.08), at(0.46, 0.06), at(0.54, 0.06), at(0.42, 0.08), at(0.58, 0.08), at(0.5, 0.2),
                          at(0.3, 0.22), at(0.7, 0.22), at(0.22, 0.42), at(0.78, 0.42), at(0.18, 0.6), at(0.84, 0.58),
                          at(0.5, 0.55), at(0.38, 0.56), at(0.62, 0.56), at(0.36, 0.76), at(0.64, 0.76), at(0.34, 0.96), at(0.66, 0.96)]
            return (joints, GVVisionDetector.bodyBones)
        case .hand:
            var joints = [at(0.5, 0.95)]
            for finger in 0 ..< 5 {
                let x = 0.18 + CGFloat(finger) * 0.16
                let reach: CGFloat = finger == 0 ? 0.55 : 0.0
                for joint in 1 ... 4 {
                    joints.append(at(x + (finger == 0 ? -0.1 * CGFloat(joint) : 0), 0.7 - CGFloat(joint) * 0.15 + reach * 0.3))
                }
            }
            return (joints, GVVisionDetector.handBones)
        default:
            return ([], [])
        }
    }

    private static let mockMask: GVTrackingMask = {
        let columns = 18, rows = 22
        let cells = (0 ..< columns * rows).map { index -> UInt8 in
            let x = Double(index % columns) / Double(columns), y = Double(index / columns) / Double(rows)
            let blob = exp(-pow((x - 0.3) * 4, 2) - pow((y - 0.3) * 4, 2)) + exp(-pow((x - 0.68) * 5, 2) - pow((y - 0.45) * 5, 2))
            return blob > 0.45 ? 1 : 0
        }
        return GVTrackingMask(columns: columns, rows: rows, cells: cells)
    }()
}
