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

/// A compact instrument panel with reactive tiles and a restrained light field.
/// The heading stays in place while longer groups scroll inside the plate.
struct GVSettingsConsolePanel<Content: View>: View {
    var status: String?
    let maximumHeight: CGFloat
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content
    @ScaledMetric(relativeTo: .caption) private var headingSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var statusSize: CGFloat = 11

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Label("SETTINGS", systemImage: "slider.horizontal.3")
                    .font(GVTheme.mono(headingSize, .semibold))
                    .tracking(1.1)
                    .foregroundStyle(GVTheme.bone)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                if let status {
                    Text(status)
                        .font(GVTheme.mono(statusSize, .medium))
                        .foregroundStyle(GVTheme.bone.opacity(0.65))
                        .lineLimit(1)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(GVTheme.bone.opacity(0.75))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(GVPressStyle())
                .accessibilityLabel("Close settings")
                .accessibilityIdentifier("workspace.settings.close")
            }
            .padding(.leading, 16)
            .padding(.trailing, 4)
            .padding(.vertical, 3)

            Rectangle()
                .fill(GVTheme.bone.opacity(0.1))
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
        .background { GVSettingsLightField() }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .gvChromePlate(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// Compact camera console. Settings use the same sections and actions in
/// a scrolling tile layout through `GVSettingsConsolePanel`.
struct GVConsolePanel<Content: View>: View {
    let title: String
    var status: String?
    @ViewBuilder let content: () -> Content

    private static var radius: CGFloat { 20 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(GVTheme.mono(12, .bold))
                    .tracking(1.4)
                    .foregroundStyle(GVTheme.bone)
                if let status {
                    Text("// \(status)")
                        .font(GVTheme.mono(10, .medium))
                        .foregroundStyle(GVTheme.bone.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            GVSplashPlate()
                .clipShape(shape)
        }
        .modifier(GVSplashBorder(radius: Self.radius))
        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
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
            Text(usesSettingsTiles ? label.capitalized : label)
                .font(usesSettingsTiles ? .system(size: headingSize, weight: .medium) : GVTheme.mono(9, .semibold))
                .tracking(usesSettingsTiles ? 1.1 : 1.6)
                .foregroundStyle(GVTheme.bone.opacity(usesSettingsTiles ? 0.6 : 0.45))
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
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
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
            .background(active ? Color.white.opacity(0.08) : Color.white.opacity(0.025), in: shape)
            .overlay {
                shape.strokeBorder(.white.opacity(active ? 0.18 : 0.04), lineWidth: 0.65)
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
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
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

/// A lightweight procedural light field, rendered only while the settings deck is visible.
/// Its clock invalidates this decoration rather than the controls or camera workspace.
private struct GVSettingsLightField: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20,
                                paused: reduceMotion || scenePhase != .active)) { timeline in
            Canvas { context, size in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                let center = CGPoint(x: size.width * (0.5 + 0.3 * sin(time * 0.25)),
                                     y: size.height * (0.35 + 0.2 * cos(time * 0.2)))
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                    Gradient(colors: [.white.opacity(0.09), .clear]),
                    center: center, startRadius: 0, endRadius: max(size.width, size.height) * 0.7))
                var grid = Path()
                for x in stride(from: CGFloat(0), through: size.width, by: 24) {
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: CGFloat(0), through: size.height, by: 24) {
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(.white.opacity(0.025)), lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
