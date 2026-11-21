import SwiftUI

/// LiDAR effect parameters on the shared compact rail — one header row and
/// one horizontal knob row, matching FX.PARAM so switching between camera
/// effects and depth effects never feels like a different instrument.
struct DepthEffectParameterDeck: View {
    let effect: DepthEffectMode
    @Binding var parameters: DepthEffectParameters
    @EnvironmentObject private var toasts: GVToastBox
    let onClose: () -> Void
    let onExitDepth: () -> Void
    @State private var parameterPage = 0

    private struct Spec: Identifiable {
        let id: String
        let label: String
        let value: Binding<Double>
        let defaultValue: Double
        let range: ClosedRange<Double>
        let format: (Double) -> String
    }

    var body: some View {
        VStack(spacing: 6) {
            headerRow
            knobRow
            GVParameterPager(page: $parameterPage, pageCount: pageCount)
        }
        .gvCompactDeckPlate(tag: "LIDAR")
        .onChange(of: effect) { _, _ in parameterPage = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.parameters.depth.\(effect.rawValue)")
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 5) {
            Text(effect.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(GVTheme.bone)
                .lineLimit(1)

            Spacer(minLength: 6)
            GVDeckChip(label: "Reset", id: "depth.reset") {
                parameters = .defaults(for: effect)
                toasts.show("\(effect.label) reset")
            }
            GVDeckChip(label: "Exit", symbol: "camera.aperture", id: "depth.exit") {
                onExitDepth()
                onClose()
            }
            GVDeckChip(label: "", symbol: "xmark", id: "depth.close") {
                onClose()
            }
        }
    }

    // MARK: - Knobs

    private var knobRow: some View {
        HStack(alignment: .top, spacing: 2) {
            ForEach(visibleSpecs) { spec in
                GVParamRow(
                    label: spec.label,
                    value: spec.value,
                    defaultValue: spec.defaultValue,
                    range: spec.range,
                    format: spec.format
                )
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("workspace.param.depth.\(spec.id.lowercased())")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    private var pageCount: Int { DepthEffectCatalog.controlPages(for: effect).count }

    private var visibleSpecs: [Spec] {
        let pages = DepthEffectCatalog.controlPages(for: effect)
        let index = min(max(parameterPage, 0), pages.count - 1)
        return specs(for: pages[index])
    }

    // Descriptor metadata drives both the deck and Metal packing.
    private func specs(for descriptors: [DepthParameterDescriptor]) -> [Spec] {
        descriptors.map { descriptor in
            Spec(id: descriptor.id, label: descriptor.id,
                 value: Binding(get: { descriptor.value(in: parameters) },
                                set: { descriptor.set($0, in: &parameters) }),
                 defaultValue: descriptor.defaultValue, range: descriptor.range,
                 format: descriptor.formatted)
        }
    }
}
