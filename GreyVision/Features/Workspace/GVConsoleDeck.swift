import SwiftUI

private struct GVConsoleTilesKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var consoleUsesSettingsTiles: Bool {
        get { self[GVConsoleTilesKey.self] }
        set { self[GVConsoleTilesKey.self] = newValue }
    }
}

/// The camera deck's plate: the splash tracker surface with the deck's name
/// hung off its corner as a lime tag. The tag is the heading; the row under
/// it carries only the live status and the way out. Longer groups scroll
/// inside the plate while that row stays put.
struct GVSettingsConsolePanel<Content: View>: View {
    var title = "SETTINGS"
    var symbol = "slider.horizontal.3"
    var status: String?
    let maximumHeight: CGFloat
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content
    @ScaledMetric(relativeTo: .caption2) private var statusSize: CGFloat = 11

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: GVSplashDock.radius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(GVTheme.bone.opacity(0.7))
                    .accessibilityHidden(true)
                Text(status.map { "// \($0)" } ?? "// READY")
                    .font(GVTheme.mono(statusSize, .medium))
                    .tracking(0.8)
                    .foregroundStyle(GVTheme.bone.opacity(0.6))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(GVTheme.bone.opacity(0.75))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(GVPressStyle())
                .accessibilityLabel("Close \(title.lowercased())")
                .accessibilityIdentifier("workspace.settings.close")
            }
            .padding(.leading, 16)
            .padding(.trailing, 4)
            .padding(.top, 4)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title.capitalized)
            .accessibilityAddTraits(.isHeader)

            Rectangle()
                .fill(GVSplashDock.lime.opacity(0.25))
                .frame(height: 0.5)
                .padding(.horizontal, 16)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    content()
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .environment(\.consoleUsesSettingsTiles, true)
        }
        .frame(maxHeight: maximumHeight)
        .clipShape(shape)
        .gvChromePlate(shape, tag: title)
        // The tag hangs above the plate; keep it clear of the row above.
        .padding(.top, 14)
        .accessibilityElement(children: .contain)
    }
}

/// A labelled group of keys inside a console.
struct GVConsoleSection<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    @Environment(\.consoleUsesSettingsTiles) private var usesSettingsTiles
    @ScaledMetric(relativeTo: .caption2) private var headingSize: CGFloat = 11

    private static var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(GVTheme.mono(usesSettingsTiles ? headingSize - 1 : 9, .semibold))
                .tracking(1.6)
                .foregroundStyle(GVTheme.bone.opacity(0.5))
                .padding(.horizontal, usesSettingsTiles ? 4 : 0)
                .padding(.bottom, usesSettingsTiles ? 3 : 0)
                .accessibilityAddTraits(.isHeader)
            if usesSettingsTiles {
                GVSettingsGrid { content() }
            } else {
                LazyVGrid(columns: Self.columns, spacing: 6) {
                    content()
                }
            }
        }
    }
}

/// Shared sizing for every settings group, including advanced controls.
struct GVSettingsGrid<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @ScaledMetric(relativeTo: .caption) private var tileMinimum: CGFloat = 92

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: tileMinimum), spacing: 8)], spacing: 8) {
            content()
        }
    }
}

/// One console key: glyph over a mono label, with an optional live value.
///
/// Off it is dark glass with a hairline; on it fills white with black type
/// and glows — the same "this is on" language as the selector plates.
struct GVConsoleKey: View {
    let symbol: String
    let label: String
    var value: String?
    var active = false
    var enabled = true
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.consoleUsesSettingsTiles) private var usesSettingsTiles
    @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var valueSize: CGFloat = 11

    var body: some View {
        if usesSettingsTiles {
            settingsTile
        } else {
            key
        }
    }

    private var settingsTile: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return Button(action: action) {
            VStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: symbol)
                        .font(.system(size: 27, weight: .ultraLight))
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: active)
                        .symbolEffectsRemoved(reduceMotion)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .shadow(color: .white.opacity(active ? 0.3 : 0), radius: 8)
                    Image(systemName: active ? "checkmark.circle.fill" : (value == nil ? "arrow.up.right" : "circle"))
                        .font(.system(size: active ? 10 : 8, weight: .medium))
                        .foregroundStyle(GVTheme.bone.opacity(active ? 0.95 : 0.35))
                        .accessibilityHidden(true)
                }
                Text(label)
                    .font(.system(size: labelSize, weight: active ? .semibold : .medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let readout = value ?? (active ? "ON" : nil) {
                    Text(readout.uppercased())
                        .font(GVTheme.mono(valueSize, .medium))
                        .foregroundStyle(GVTheme.bone.opacity(active ? 0.85 : 0.55))
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.numericText())
                }
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(GVTheme.bone.opacity(active ? 1 : 0.75))
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 100)
            .background(active ? Color.white.opacity(0.09) : Color.white.opacity(0.025), in: shape)
            .overlay {
                shape.strokeBorder(.white.opacity(active ? 0.18 : 0.05), lineWidth: 0.65)
            }
            .overlay {
                // An on key is a tracked object: it gets the splash brackets.
                if active {
                    GVTrackerBrackets(arm: 8)
                        .stroke(GVSplashDock.lime.opacity(0.85), style: StrokeStyle(lineWidth: 1, lineCap: .square))
                        .accessibilityHidden(true)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(GVPressStyle())
        .sensoryFeedback(.selection, trigger: active)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .animation(GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion), value: active)
        .accessibilityLabel(label)
        .accessibilityValue([value, active && value == nil ? "on" : nil].compactMap { $0 }.joined(separator: ", "))
    }

    private var key: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(height: 16)
                Text(label.uppercased())
                    .font(GVTheme.mono(8.5, .bold))
                    .tracking(0.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let value {
                    Text(value.uppercased())
                        .font(GVTheme.mono(8, .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .opacity(0.6)
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(active ? Color.black : GVTheme.bone.opacity(0.82))
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background {
                if active {
                    shape.fill(GVTheme.bone)
                        .shadow(color: .white.opacity(0.35), radius: 8)
                } else {
                    shape.fill(Color.white.opacity(0.05))
                        .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 0.75))
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(GVPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .animation(GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion), value: active)
        .accessibilityLabel(label)
        .accessibilityValue([value, active ? "on" : nil].compactMap { $0 }.joined(separator: ", "))
    }
}
