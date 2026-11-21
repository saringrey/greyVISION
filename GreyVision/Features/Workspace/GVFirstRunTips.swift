import SwiftUI

/// The controls the first-run tips point at.
enum GVTipTarget: String, CaseIterable, Hashable {
    case camera
    case effects
    case capture

    var title: String {
        switch self {
        case .camera: "Camera"
        case .effects: "Effects"
        case .capture: "Capture"
        }
    }

    var detail: String {
        switch self {
        case .camera: "Lens, flip, torch, timer and the Mac link all live behind this one button."
        case .effects: "Pick a look. Open a family, then tap a live preview to put it on."
        case .capture: "Photo saves straight to Photos. Record starts a take; tap again to stop."
        }
    }
}

/// Where each tip target sits, published by the real controls so the tips
/// frame the button itself rather than a guessed position.
struct GVTipAnchorKey: PreferenceKey {
    static var defaultValue: [GVTipTarget: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [GVTipTarget: Anchor<CGRect>], nextValue: () -> [GVTipTarget: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Marks this view as the control a first-run tip points at.
    func gvTipAnchor(_ target: GVTipTarget) -> some View {
        anchorPreference(key: GVTipAnchorKey.self, value: .bounds) { [target: $0] }
    }
}

/// Three short tips, one per control, each framed with the splash's tracker
/// brackets on the real button. Tap anywhere for the next; Skip ends it.
/// Tips whose control is not on screen (mid-take, chrome hidden) are left out.
struct GVFirstRunTips: View {
    let anchors: [GVTipTarget: Anchor<CGRect>]
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0

    private var steps: [GVTipTarget] {
        GVTipTarget.allCases.filter { anchors[$0] != nil }
    }

    var body: some View {
        GeometryReader { proxy in
            let steps = steps
            if steps.isEmpty {
                Color.clear.onAppear(perform: onFinish)
            } else {
                let index = min(step, steps.count - 1)
                let target = steps[index]
                let rect = anchors[target].map { proxy[$0] } ?? .zero
                let framed = rect.insetBy(dx: -8, dy: -8)
                let below = rect.midY < proxy.size.height / 2

                ZStack(alignment: .topLeading) {
                    // Dim everything but the control being explained.
                    Color.black.opacity(0.62)
                        .mask {
                            ZStack {
                                Rectangle()
                                RoundedRectangle(cornerRadius: GVSplashDock.radius, style: .continuous)
                                    .frame(width: framed.width, height: framed.height)
                                    .position(x: framed.midX, y: framed.midY)
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                        }

                    GVTrackerBrackets(arm: 12)
                        .stroke(GVSplashDock.lime, style: StrokeStyle(lineWidth: 1.5, lineCap: .square))
                        .frame(width: framed.width, height: framed.height)
                        .position(x: framed.midX, y: framed.midY)

                    GVTrackerTag(text: "TIP \(index + 1)/\(steps.count)")
                        .position(x: framed.minX + 26, y: framed.minY - 8)

                    card(for: target, isLast: index == steps.count - 1)
                        .frame(width: min(320, proxy.size.width - 32))
                        .position(
                            x: min(max(framed.midX, 176), proxy.size.width - 176),
                            y: below ? framed.maxY + 86 : framed.minY - 86
                        )
                }
                .contentShape(Rectangle())
                .onTapGesture { advance() }
                .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82), value: index)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
            }
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }

    private func card(for target: GVTipTarget, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(target.title.uppercased())
                .font(GVTheme.mono(12, .bold))
                .tracking(1.4)
                .foregroundStyle(GVTheme.bone)
            Text(target.detail)
                .font(.system(size: 14))
                .foregroundStyle(GVTheme.bone.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Skip", action: onFinish)
                    .font(GVTheme.mono(12, .medium))
                    .foregroundStyle(GVTheme.bone.opacity(0.6))
                    .frame(minWidth: GVMetrics.touchTarget, minHeight: GVMetrics.touchTarget, alignment: .leading)
                    .accessibilityIdentifier("workspace.chip.coach.close")
                Spacer()
                Button(isLast ? "Got it" : "Next") { advance() }
                    .font(GVTheme.mono(12, .bold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .background(GVSplashDock.lime, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .frame(minHeight: GVMetrics.touchTarget)
                    .accessibilityIdentifier("workspace.tips.next")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .gvChromePlate(RoundedRectangle(cornerRadius: GVSplashDock.radius, style: .continuous))
    }

    private func advance() {
        if step + 1 >= steps.count {
            onFinish()
        } else {
            step += 1
        }
        GVInteractionHaptics.select()
    }
}
