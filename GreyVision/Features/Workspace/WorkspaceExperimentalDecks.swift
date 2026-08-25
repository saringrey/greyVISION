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
            GVTerminalText(
                text: "AR.OBJECTS // \(String(format: "%02d", objectCount)) PLACED",
                size: GVMetrics.textSmall,
                weight: .black,
                tracking: 1.1,
                alignment: .leading,
                intensity: isRecording ? 1.3 : 1.1
            )

            Spacer(minLength: 6)

            GVDeckChip(
                label: isRecording ? "STOP REC" : "REC",
                symbol: nil,
                active: isRecording,
                tint: GVTheme.record,
                id: "ar.record"
            ) {
                onRecordToggle()
            }
            GVDeckChip(label: "CLEAR", id: "ar.clear") {
                onClear()
                toasts.show("AR // GEOMETRY CLEARED")
            }
            GVDeckChip(label: "RETURN CAM", symbol: "camera.aperture", id: "ar.exit") {
                onExit()
                onClose()
            }
            GVDeckChip(label: "", symbol: "xmark", id: "ar.close") {
                onClose()
            }
        }
    }

    private var sliderRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                GVRailSlider(
                    label: "SIZE",
                    value: $parameters.size,
                    defaultValue: ARObjectParameters.defaults.size,
                    range: 0.35...1.8,
                    format: { String(format: "%.2f\u{00D7}", $0) }
                )
                .accessibilityIdentifier("workspace.param.ar.size")

                GVRailSlider(
                    label: "SPIN",
                    value: $parameters.spin,
                    defaultValue: ARObjectParameters.defaults.spin,
                    range: 0...2,
                    format: { String(format: "%.2f", $0) }
                )
                .accessibilityIdentifier("workspace.param.ar.spin")

                GVRailSlider(
                    label: "GLOW",
                    value: $parameters.glow,
                    defaultValue: ARObjectParameters.defaults.glow,
                    range: 0.1...1.6,
                    format: { String(format: "%.2f", $0) }
                )
                .accessibilityIdentifier("workspace.param.ar.glow")
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 1)
            .padding(.bottom, 3)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .gvHorizontalEdgeFade()
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
            GVTerminalText(
                text: isEnabled ? status : "BLOB TRACK // FIELD ANALYZER",
                size: GVMetrics.textSmall,
                weight: .black,
                tracking: 1.05,
                baseColor: isEnabled ? GVTheme.acid : GVTheme.bone,
                alignment: .leading,
                intensity: isEnabled ? 1.15 : 0.9
            )
            .lineLimit(1)
            .minimumScaleFactor(0.62)

            Spacer(minLength: 6)

            GVDeckChip(
                label: isEnabled ? "STOP" : "START",
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                GVRailSlider(
                    label: "BLOCK",
                    value: $parameters.blockSize,
                    defaultValue: BlobTrackingParameters.defaults.blockSize,
                    range: 0.02...0.12,
                    format: { "\(Int($0 * 100))% CELL" }
                )
                .accessibilityIdentifier("workspace.param.blobs.block")

                GVRailSlider(
                    label: "HUE",
                    value: $parameters.hue,
                    defaultValue: BlobTrackingParameters.defaults.hue,
                    range: 0...1,
                    format: { "\(Int($0 * 360))\u{00B0}" }
                )
                .accessibilityIdentifier("workspace.param.blobs.hue")

                GVRailSlider(
                    label: "TOLERANCE",
                    value: $parameters.tolerance,
                    defaultValue: BlobTrackingParameters.defaults.tolerance,
                    range: 0.01...1,
                    format: { "\(Int($0 * 100))%" }
                )
                .accessibilityIdentifier("workspace.param.blobs.tolerance")

                GVRailSlider(
                    label: "MIN AREA",
                    value: $parameters.minArea,
                    defaultValue: BlobTrackingParameters.defaults.minArea,
                    range: 0.0005...0.25,
                    format: { String(format: "%.2f%%", $0 * 100) }
                )
                .accessibilityIdentifier("workspace.param.blobs.minarea")
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 1)
            .padding(.bottom, 3)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .gvHorizontalEdgeFade()
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
                .gvMono(GVMetrics.textMicro, .black)
                .tracking(0.7)
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
