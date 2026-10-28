import SwiftUI

/// The tracking suite's controls, on the shared compact deck plate.
///
/// Three pages — Detect, Track, Draw — under a mode strip. Controls a mode
/// cannot use are left out rather than shown inert: a hue knob on a face
/// tracker would be a control that does nothing.
struct GVTrackingDeck: View {
    @ObservedObject var runtime: BlobTrackingRuntime
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = Page.detect

    enum Page: String, CaseIterable, Identifiable {
        case detect = "Detect", track = "Track", draw = "Draw"
        var id: String { rawValue }
    }

    private var parameters: BlobTrackingParameters { runtime.parameters }

    var body: some View {
        VStack(spacing: 6) {
            header
            modeStrip
            Group {
                switch page {
                case .detect: detectPage
                case .track: trackPage
                case .draw: drawPage
                }
            }
            .transition(.opacity)
        }
        .animation(GVMotion.resolved(GVMotion.normal, reduceMotion: reduceMotion), value: page)
        .animation(GVMotion.resolved(GVMotion.normal, reduceMotion: reduceMotion), value: parameters.mode)
        .gvCompactDeckPlate()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.parameters.blobs")
    }

    // MARK: Header

    /// One row: lock light and live count, the page tabs, then actions. The
    /// full status line lives in the overlay HUD, so the deck spends its
    /// height on controls.
    private var header: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(runtime.isEnabled ? (runtime.blobs.isEmpty ? GVTheme.ash : Color.mint) : GVTheme.ash.opacity(0.5))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(runtime.isEnabled ? "\(runtime.blobs.count)" : "–")
                .font(GVTheme.mono(12, .semibold))
                .foregroundStyle(GVTheme.bone)
                .monospacedDigit()
                .contentTransition(.numericText())
                .frame(minWidth: 14, alignment: .leading)
                .accessibilityLabel(runtime.isEnabled ? runtime.status : "Tracking off")
                .accessibilityIdentifier("workspace.tracking.status")
            pageTabs
            Spacer(minLength: 4)
            GVDeckChip(label: "", symbol: "arrow.counterclockwise", accessibilityLabel: "Reset tracking setup", id: "blob.reset") {
                var reset = BlobTrackingParameters.defaults
                reset.mode = parameters.mode
                runtime.setParameters(reset)
            }
            GVDeckChip(label: "", symbol: runtime.isEnabled ? "stop.fill" : "play.fill",
                       accessibilityLabel: runtime.isEnabled ? "Stop tracking" : "Start tracking",
                       active: runtime.isEnabled, tint: .white, id: "blob.toggle")
            {
                runtime.isEnabled ? runtime.stop() : runtime.start()
            }
            GVDeckChip(label: "", symbol: "xmark", id: "blob.close") { onClose() }
        }
    }

    private var modeStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(GVTrackingMode.allCases) { mode in
                    GVDeckChip(label: mode.label, symbol: mode.symbol, active: parameters.mode == mode,
                               tint: .white, id: "blob.mode.\(mode.rawValue)")
                    {
                        update { $0.mode = mode }
                        GVInteractionHaptics.select()
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .accessibilityIdentifier("workspace.tracking.modes")
    }

    private var pageTabs: some View {
        HStack(spacing: 3) {
            ForEach(Page.allCases) { item in
                GVDeckChip(label: item.rawValue, active: page == item, tint: .white, id: "blob.page.\(item.rawValue.lowercased())") {
                    page = item
                }
            }
        }
    }

    // MARK: Pages

    private var detectPage: some View {
        grid {
            if parameters.mode.usesHue {
                slider("Hue", \.hue, 0 ... 1) { "\(Int($0 * 360))\u{00B0}" }
                    .overlay(alignment: .top) { hueSwatch }
            }
            if parameters.mode.usesTolerance {
                slider("Tolerance", \.tolerance, 0.01 ... 1, percent)
            }
            if parameters.mode.usesThreshold {
                slider(parameters.mode == .motion ? "Sensitivity" : "Threshold", \.threshold, 0 ... 1, percent)
            }
            if parameters.mode.usesVision {
                slider("Confidence", \.confidence, 0 ... 1, percent)
            }
            slider("Min Size", \.minArea, 0.0005 ... 0.25) { String(format: "%.1f%%", $0 * 100) }
            slider("Max Size", \.maxArea, 0.01 ... 1) { "\(Int($0 * 100))%" }
            if !parameters.mode.usesVision {
                slider("Resolution", \.resolution, 0 ... 1) { _ in "\(parameters.gridLongEdge) cells" }
                slider("Merge", \.merge, 0 ... 3) { "\(Int($0.rounded()))" }
            }
        }
    }

    private var trackPage: some View {
        grid {
            slider("Subjects", \.maxTracks, 1 ... 16) { "\(Int($0.rounded()))" }
            slider("Smoothing", \.smoothing, 0 ... 0.95, percent)
            slider("Persistence", \.persistence, 0 ... 2) { String(format: "%.1fs", $0) }
            slider("Prediction", \.prediction, 0 ... 1, percent)
            slider("Match Radius", \.matchRadius, 0.02 ... 0.5, percent)
            slider("Rate", \.rate, 5 ... (parameters.mode.usesVision ? 30 : 60)) { "\(Int($0.rounded())) Hz" }
            slider("Confirm", \.confirm, 1 ... 6) { "\(Int($0.rounded())) hits" }
        }
    }

    private var drawPage: some View {
        VStack(spacing: 6) {
            choiceRow("Style", GVTrackingStyle.allCases, selected: parameters.style, label: \.label) { value in
                update { $0.style = value }
            }
            choiceRow("Label", GVTrackingLabel.allCases, selected: parameters.labels, label: \.label) { value in
                update { $0.labels = value }
            }
            choiceRow("Links", GVTrackingLinks.allCases, selected: parameters.links, label: \.label) { value in
                update { $0.links = value }
            }
            choiceRow("Color", GVTrackingPalette.allCases, selected: parameters.palette, label: \.label) { value in
                update { $0.palette = value }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    toggle("Vectors", "arrow.up.right", \.showVectors)
                    toggle("Centroids", "plus", \.showCentroids)
                    if !parameters.mode.usesVision {
                        toggle("Mask", "square.grid.3x3", \.showMask)
                    }
                }
            }
            grid {
                slider("Trails", \.trails, 0 ... 1) { _ in "\(parameters.trailCapacity)" }
                slider("Line", \.lineWidth, 0.5 ... 3) { String(format: "%.1fpt", $0) }
                slider("Glow", \.glow, 0 ... 1, percent)
            }
        }
    }

    // MARK: Building blocks

    private func grid(@ViewBuilder _ content: () -> some View) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            content()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private func slider(_ label: String, _ keyPath: WritableKeyPath<BlobTrackingParameters, Double>,
                        _ range: ClosedRange<Double>, _ format: @escaping (Double) -> String) -> some View
    {
        GVRailSlider(
            label: label,
            value: Binding(get: { runtime.parameters[keyPath: keyPath] }, set: { value in update { $0[keyPath: keyPath] = value } }),
            defaultValue: BlobTrackingParameters.defaults[keyPath: keyPath],
            range: range,
            format: format
        )
        .accessibilityIdentifier("workspace.param.blobs.\(label.lowercased().replacingOccurrences(of: " ", with: ""))")
    }

    private func toggle(_ label: String, _ symbol: String, _ keyPath: WritableKeyPath<BlobTrackingParameters, Bool>) -> some View {
        GVDeckChip(label: label, symbol: symbol, active: parameters[keyPath: keyPath], tint: .white,
                   id: "blob.toggle.\(label.lowercased())")
        {
            update { $0[keyPath: keyPath].toggle() }
        }
    }

    private func choiceRow<Value: Hashable & Identifiable>(
        _ title: String, _ values: [Value], selected: Value, label: KeyPath<Value, String>,
        choose: @escaping (Value) -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(GVTheme.ash)
                .frame(width: 38, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(values) { value in
                        GVDeckChip(label: value[keyPath: label], active: value == selected, tint: .white,
                                   id: "blob.\(title.lowercased()).\(value[keyPath: label].lowercased())")
                        {
                            choose(value)
                        }
                    }
                }
            }
        }
    }

    private var hueSwatch: some View {
        Capsule()
            .fill(Color(hue: parameters.hue, saturation: 0.85, brightness: 1))
            .frame(width: 18, height: 3)
            .offset(y: -3)
            .accessibilityHidden(true)
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func update(_ change: (inout BlobTrackingParameters) -> Void) {
        var next = runtime.parameters
        change(&next)
        runtime.setParameters(next)
    }
}
