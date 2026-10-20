import SwiftUI

struct GVRule: View {
    var opacity = 1.0

    var body: some View {
        Rectangle()
            .fill(GVTheme.separator.opacity(opacity))
            .frame(height: 1 / UIScreen.main.scale)
            .accessibilityHidden(true)
    }
}

struct GVBrackets: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var color = Color.white.opacity(0.14)
    var length: CGFloat = 26
    var lineWidth: CGFloat = 1
    /// Radius of the corner the bracket wraps. Zero draws a square elbow; set
    /// this to the display's own corner radius, less the inset, and the
    /// brackets follow the glass instead of cutting across it.
    var cornerRadius: CGFloat = 0
    var breathing = true

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30, paused: reduceMotion || !breathing)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let breath = reduceMotion || !breathing ? 1 : 0.86 + sin(time * 0.52) * 0.14
            BracketShape(length: length, cornerRadius: cornerRadius)
                .stroke(color.opacity(breath), style: StrokeStyle(lineWidth: lineWidth, lineCap: .square))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct BracketShape: Shape {
    let length: CGFloat
    var cornerRadius: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        // Radius can never exceed half the shorter side, and the straight arms
        // are measured from the end of the arc rather than from the corner, so
        // a large radius shortens the arms instead of overlapping them.
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)
        let arm = max(length, 0)
        var path = Path()

        if radius <= 0 {
            corner(&path, at: CGPoint(x: rect.minX, y: rect.minY), dx: 1, dy: 1, arm: arm)
            corner(&path, at: CGPoint(x: rect.maxX, y: rect.minY), dx: -1, dy: 1, arm: arm)
            corner(&path, at: CGPoint(x: rect.maxX, y: rect.maxY), dx: -1, dy: -1, arm: arm)
            corner(&path, at: CGPoint(x: rect.minX, y: rect.maxY), dx: 1, dy: -1, arm: arm)
            return path
        }

        // Top leading.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + radius + arm))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + radius + arm, y: rect.minY))

        // Top trailing.
        path.move(to: CGPoint(x: rect.maxX - radius - arm, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
            radius: radius,
            startAngle: .degrees(270),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + radius + arm))

        // Bottom trailing.
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - radius - arm))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
            radius: radius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius - arm, y: rect.maxY))

        // Bottom leading.
        path.move(to: CGPoint(x: rect.minX + radius + arm, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
            radius: radius,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius - arm))
        return path
    }

    private func corner(_ path: inout Path, at point: CGPoint, dx: CGFloat, dy: CGFloat, arm: CGFloat) {
        path.move(to: CGPoint(x: point.x, y: point.y + dy * arm))
        path.addLine(to: point)
        path.addLine(to: CGPoint(x: point.x + dx * arm, y: point.y))
    }
}

struct GVPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Rectangle()
                    .fill(GVTheme.violetDeep)
                    .frame(width: 5, height: 5)
                    .shadow(color: GVTheme.violetDeep, radius: 5)
                Text(title.uppercased())
                    .gvMono(GVMetrics.textBody, .bold)
                    .tracking(1.8)
                    .foregroundStyle(GVTheme.bone)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            GVRule()

            content
        }
        .padding(.horizontal, GVMetrics.stepInternal)
        .padding(.vertical, GVMetrics.stepRelated)
        .gvGlass(.primary, radius: GVMetrics.radiusPanel)
    }
}

struct GVInstrumentButton: View {
    let label: String
    var detail: String?
    var symbol: String?
    var roleColor = GVTheme.violetDeep
    var isEnabled = true
    var testIdentifier: String?
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(label.uppercased())
                        .gvMono(GVMetrics.textBody, .bold)
                        .tracking(1.4)
                    if let detail {
                        Text(detail.uppercased())
                            .gvMono(GVMetrics.textMicro, .medium)
                            .tracking(1.0)
                            .foregroundStyle(GVTheme.ash)
                    }
                }
                Spacer(minLength: 0)
                Text("[ ENTER ]")
                    .gvMono(GVMetrics.textMicro, .bold)
                    .foregroundStyle(roleColor)
            }
            .foregroundStyle(isEnabled ? GVTheme.bone : GVTheme.ash)
            .padding(.horizontal, 13)
            .frame(minHeight: 46)
        }
        .buttonStyle(GVGlassButtonStyle(roleColor: roleColor, isEnabled: isEnabled))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.42)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint(detail ?? "Activate instrument control")
        .accessibilityIdentifier(testIdentifier ?? "instrument.\(label.lowercased())")
    }
}

private struct GVGlassButtonStyle: ButtonStyle {
    let roleColor: Color
    let isEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pulseTint: SIMD3<Float> {
        SIMD3<Float>(0.7, 0.2, 1.0)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .gvGlassButton(radius: GVMetrics.radius, active: configuration.isPressed)
            .overlay(
                RoundedRectangle(cornerRadius: GVMetrics.radius, style: .continuous)
                    .strokeBorder(
                        isEnabled ? roleColor.opacity(configuration.isPressed ? 0.85 : 0.68) : GVTheme.separator,
                        lineWidth: configuration.isPressed ? 1.3 : 1
                    )
            )
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.975 : 1))
            .colorEffect(
                ShaderLibrary.pressPulse(
                    .float(Float(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))),
                    .float2(120, 46),
                    .float(configuration.isPressed && !reduceMotion ? 1.0 : 0.0),
                    .float3(pulseTint.x, pulseTint.y, pulseTint.z)
                )
            )
            .animation(GVMotion.resolved(GVMotion.micro, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

enum GVScanlineDirection: String, CaseIterable, Identifiable, Sendable {
    case horizontal
    case vertical
    case diagonal

    var id: String {
        rawValue
    }

    var label: String {
        rawValue.uppercased()
    }
}

struct GVScanlines: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var opacity = 0.14
    var frequency = 25.0
    var direction = GVScanlineDirection.horizontal
    var speed = 0.0

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion || speed == 0 ? 1 : 1 / 30)) { timeline in
            Canvas { context, size in
                let spacing = max(2.2, CGFloat(100 / max(frequency, 1)))
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                let rawPhase = CGFloat(time * speed * 34).truncatingRemainder(dividingBy: spacing)
                let phase = rawPhase < 0 ? rawPhase + spacing : rawPhase
                var path = Path()

                switch direction {
                case .horizontal:
                    for y in stride(from: -spacing + phase, through: size.height + spacing, by: spacing) {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                case .vertical:
                    for x in stride(from: -spacing + phase, through: size.width + spacing, by: spacing) {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                case .diagonal:
                    for x in stride(
                        from: -size.height - spacing + phase,
                        through: size.width + spacing,
                        by: spacing
                    ) {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                    }
                }

                context.stroke(path, with: .color(.white.opacity(opacity)), lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct GVGridField: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let spacing: CGFloat = 36
            for x in stride(from: CGFloat.zero, through: size.width, by: spacing) {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: CGFloat.zero, through: size.height, by: spacing) {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(GVTheme.violetDeep.opacity(0.09)), lineWidth: 0.5)
        }
        .mask(
            RadialGradient(
                colors: [.white, .clear],
                center: .center,
                startRadius: 20,
                endRadius: 420
            )
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Cut-corner rectangle used for dock chrome.
///
/// Replaces the stock capsule: an oval reads as a system control, whereas a
/// chamfered plate reads as a panel on a machine. The corner cut is a fixed
/// dimension rather than a ratio so buttons of different widths stay visually
/// related, and the footprint is identical to the capsule it replaced.
struct GVChamferedPlate: Shape, InsettableShape {
    var cut: CGFloat = 7
    /// Cuts only the leading-top and trailing-bottom corners. The deliberate
    /// asymmetry is what stops a row of these looking machine-stamped.
    var diagonal = true
    /// Inset for `strokeBorder` and other InsettableShape consumers. Unused by
    /// `path(in:)` below — the inset path is the same outline pulled inward.
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let c = min(cut, min(rect.width, rect.height) / 2)
        var path = Path()
        if diagonal {
            path.move(to: CGPoint(x: rect.minX + c, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - c))
            path.addLine(to: CGPoint(x: rect.maxX - c, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + c))
        } else {
            path.move(to: CGPoint(x: rect.minX + c, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - c, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + c))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - c))
            path.addLine(to: CGPoint(x: rect.maxX - c, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + c, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - c))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + c))
        }
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var plate = self
        plate.insetAmount += amount
        return plate.chamferedInsetPath
    }

    /// The inset variant of the chamfered outline.
    private var chamferedInsetPath: GVChamferedPlate {
        var plate = self
        plate.cut = max(0, cut - insetAmount)
        return plate
    }
}

/// A single quiet rule used to terminate the top and bottom chrome.
///
/// Replaces the enclosing capsule/oval borders. A full outline draws a box
/// around the chrome and competes with the camera behind it; one lit edge
/// states the boundary and leaves the frame alone. The gradient falls off at
/// both ends so the rule never collides with the screen edge.
struct GVEdgeRule: View {
    var height: CGFloat = 1
    var intensity: Double = 0.72

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: Color.white.opacity(0.08 * intensity), location: 0.14),
                        .init(color: Color.white.opacity(0.14 * intensity), location: 0.5),
                        .init(color: Color.white.opacity(0.08 * intensity), location: 0.86),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
