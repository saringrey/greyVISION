import SwiftUI

// MARK: - AR objects parameter deck

/// AR object placement controls on the shared compact rail — same charcoal
/// material, header chips and one-row sliders as FX.PARAM.
struct ARObjectsParameterDeck: View {
    @Binding var parameters: ARObjectParameters
    let objectCount: Int
    let isRecording: Bool
    @EnvironmentObject private var toasts: GVToastBox
    let onRecordToggle: () -> Void
    let onClear: () -> Void
    let onExit: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            headerRow
            sliderRow
                .gvScrollProgressLine()
        }
        .gvCompactDeckPlate()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.parameters.ar")
    }

    private var headerRow: some View {
        HStack(spacing: 5) {
            Text("\(objectCount) objects placed")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(GVTheme.bone)

            Spacer(minLength: 6)

            GVDeckChip(
                label: isRecording ? "Stop" : "Record",
                symbol: nil,
                active: isRecording,
                tint: GVTheme.record,
                id: "ar.record"
            ) {
                onRecordToggle()
            }
            GVDeckChip(label: "Clear", id: "ar.clear") {
                onClear()
                toasts.show("AR geometry cleared")
            }
            GVDeckChip(label: "Camera", symbol: "camera.aperture", id: "ar.exit") {
                onExit()
                onClose()
            }
            GVDeckChip(label: "", symbol: "xmark", id: "ar.close") {
                onClose()
            }
        }
    }

    private var sliderRow: some View {
        HStack(spacing: 8) {
            GVRailSlider(
                label: "Size",
                value: $parameters.size,
                defaultValue: ARObjectParameters.defaults.size,
                range: 0.35 ... 1.8,
                format: { String(format: "%.2f\u{00D7}", $0) }
            )
            .accessibilityIdentifier("workspace.param.ar.size")

            GVRailSlider(
                label: "Spin",
                value: $parameters.spin,
                defaultValue: ARObjectParameters.defaults.spin,
                range: 0 ... 2,
                format: { String(format: "%.2f", $0) }
            )
            .accessibilityIdentifier("workspace.param.ar.spin")

            GVRailSlider(
                label: "Glow",
                value: $parameters.glow,
                defaultValue: ARObjectParameters.defaults.glow,
                range: 0.1 ... 1.6,
                format: { String(format: "%.2f", $0) }
            )
            .accessibilityIdentifier("workspace.param.ar.glow")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }
}

// MARK: - Blob tracking parameter deck

/// Blob field analyzer controls on the shared compact rail.
struct BlobTrackingParameterDeck: View {
    @Binding var parameters: BlobTrackingParameters
    let isEnabled: Bool
    let status: String
    @EnvironmentObject private var toasts: GVToastBox
    let onParametersChanged: (BlobTrackingParameters) -> Void
    let onToggle: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            headerRow
            sliderRow
                .gvScrollProgressLine()
        }
        .gvCompactDeckPlate()
        .onChange(of: parameters) { _, newValue in
            onParametersChanged(newValue)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.parameters.blobs")
    }

    private var headerRow: some View {
        HStack(spacing: 5) {
            Text(isEnabled ? status : "Blob Tracking")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isEnabled ? GVTheme.bone : GVTheme.bone.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 6)

            GVDeckChip(
                label: isEnabled ? "Stop" : "Start",
                active: isEnabled,
                tint: .white,
                id: "blob.toggle"
            ) {
                onToggle()
            }
            GVDeckChip(label: "", symbol: "xmark", id: "blob.close") {
                onClose()
            }
        }
    }

    private var sliderRow: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
            spacing: 8
        ) {
            GVRailSlider(
                label: "Cell Size",
                value: $parameters.blockSize,
                defaultValue: BlobTrackingParameters.defaults.blockSize,
                range: 0.02 ... 0.12,
                format: { "\(Int($0 * 100))%" }
            )
            .accessibilityIdentifier("workspace.param.blobs.block")

            GVRailSlider(
                label: "Hue",
                value: $parameters.hue,
                defaultValue: BlobTrackingParameters.defaults.hue,
                range: 0 ... 1,
                format: { "\(Int($0 * 360))\u{00B0}" }
            )
            .accessibilityIdentifier("workspace.param.blobs.hue")

            GVRailSlider(
                label: "Tolerance",
                value: $parameters.tolerance,
                defaultValue: BlobTrackingParameters.defaults.tolerance,
                range: 0.01 ... 1,
                format: { "\(Int($0 * 100))%" }
            )
            .accessibilityIdentifier("workspace.param.blobs.tolerance")

            GVRailSlider(
                label: "Min Area",
                value: $parameters.minArea,
                defaultValue: BlobTrackingParameters.defaults.minArea,
                range: 0.0005 ... 0.25,
                format: { String(format: "%.2f%%", $0 * 100) }
            )
            .accessibilityIdentifier("workspace.param.blobs.minarea")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }
}

// MARK: - Blob field overlay

/// Draws tracked fields as thin brackets with their procedural designations,
/// mapped from the delivered (interface-rotated) image to the preview with the
/// same aspect-fill crop the camera preview applies.
struct BlobTrackingOverlay: View {
    let blobs: [TrackedBlob]
    let sourceSize: CGSize

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(blobs) { blob in
                    fieldView(blob, viewport: geometry.size)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func fieldView(_ blob: TrackedBlob, viewport: CGSize) -> some View {
        let rect = viewportRect(for: blob.rect, viewport: viewport)
        let tint = Color(
            red: Double(blob.color.x),
            green: Double(blob.color.y),
            blue: Double(blob.color.z)
        )
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(tint.opacity(0.85), lineWidth: 1)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(tint.opacity(0.05))
            Rectangle()
                .fill(tint.opacity(0.35))
                .frame(width: 10, height: 1)
                .padding(3)
            Text(blob.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                .offset(x: 0, y: -13)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }

    private func viewportRect(for rect: CGRect, viewport: CGSize) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0, viewport.width > 0, viewport.height > 0 else {
            return .zero
        }
        let scale = max(viewport.width / sourceSize.width, viewport.height / sourceSize.height)
        let displayed = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let offset = CGPoint(
            x: (viewport.width - displayed.width) * 0.5,
            y: (viewport.height - displayed.height) * 0.5
        )
        return CGRect(
            x: offset.x + rect.minX * displayed.width,
            y: offset.y + rect.minY * displayed.height,
            width: rect.width * displayed.width,
            height: rect.height * displayed.height
        )
    }
}
