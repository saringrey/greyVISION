import SwiftUI

/// The workspace's drop-down consoles — camera tools and system settings —
/// built from one set of parts so they read as one instrument.
///
/// A dithered black plate with a white glow edge, a mono masthead, short
/// section labels, and compact keys four across. Everything fits without
/// scrolling on a phone: the old decks were tall stacks of grey tiles that
/// clipped their last row mid-key. Keys are 48pt: the top deck shares the
/// screen with the dock, and on a 6.1-inch phone that leaves ~320pt.
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

    private static var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(GVTheme.mono(9, .semibold))
                .tracking(1.6)
                .foregroundStyle(GVTheme.bone.opacity(0.45))
            LazyVGrid(columns: Self.columns, spacing: 6) {
                content()
            }
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

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        Button(action: action) {
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
        .buttonStyle(GVPressStyle(scale: 0.95))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .animation(GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion), value: active)
        .accessibilityLabel(label)
        .accessibilityValue([value, active ? "on" : nil].compactMap { $0 }.joined(separator: ", "))
    }
}
