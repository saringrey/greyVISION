import SwiftUI

/// The cold-start sequence: a lone dot beeps three times, a CRT terminal
/// powers on and POSTs the device, a Win95-style setup dialog stalls loading
/// codec drivers, the machine "crashes" to a fatal-exception screen, and the
/// wreckage decays into the codec selection splash.
///
/// Everything on screen — type, HUD and black field — is one layer run
/// through `terminalBoot` in TerminalBootShaders.metal, so power-on, tears,
/// scanlines and the final block decay act on the picture as a whole, the way
/// a tube would. The RGB split is the one stage composed here instead (see
/// `chroma`), since the shader must sample its layer only once. Choreography lives in `GVTerminalBootTimeline`; the printed
/// values come from `GVTerminalBootReport`.
///
/// Decorative only: it never gates the engine, and a tap skips to the decay.
struct GVTerminalBoot: View {
    let report: GVTerminalBootReport
    let onFinished: () -> Void

    @State private var origin = Date()
    @State private var skippedAt: Double?
    @State private var seed = Float.random(in: 0 ... 64)

    private static let glow = Color(red: 0.55, green: 0.93, blue: 1.0)

    var body: some View {
        let timeline = GVTerminalBootTimeline(lineCount: report.lines.count, skippedAt: skippedAt)
        let lengths = report.lengths
        let seed = seed
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSince(origin)
            let frame = timeline.frame(at: time, lineLengths: lengths)
            chroma(frame, time: time)
                .visualEffect { content, proxy in
                    content.layerEffect(
                        ShaderLibrary.terminalBoot(
                            .float2(proxy.size), .float(Float(time)), .float(Float(frame.power)),
                            .float(Float(frame.tear)), .float(Float(frame.decay)), .float(seed),
                            .float(Float(frame.dot))
                        ),
                        maxSampleOffset: CGSize(width: 64, height: 0)
                    )
                }
                .opacity(frame.opacity)
                .sensoryFeedback(.impact(weight: .light, intensity: 0.5), trigger: frame.statusCount)
                .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.8), trigger: frame.beeps)
                .sensoryFeedback(trigger: frame.phase) { _, phase in phase == .crash ? .error : nil }
                .onChange(of: frame.beeps) { _, beeps in
                    if beeps > 0 { GVSoundEngine.shared.play(.postBeep) }
                }
                .onChange(of: frame.phase) { _, phase in
                    if phase == .crash { GVSoundEngine.shared.play(.crash) }
                }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {
            if skippedAt == nil { skippedAt = Date().timeIntervalSince(origin) }
        }
        .task(id: skippedAt) {
            let remaining = timeline.end - Date().timeIntervalSince(origin)
            try? await Task.sleep(for: .seconds(max(remaining, 0)))
            guard !Task.isCancelled else { return }
            onFinished()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Starting grey//VISION")
        .accessibilityHint("Double tap to skip")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("boot.terminal")
    }

    // MARK: - Screen

    /// RGB separation as three additive channel copies of the raster, red
    /// pushed right and blue left. Split widens with tears and decay.
    private func chroma(_ frame: GVTerminalBootTimeline.Frame, time: Double) -> some View {
        let split = 0.8 + frame.tear * 5 + frame.decay * 9
        return ZStack {
            // Each copy is flattened before it is blended: unflattened, the
            // additive blend applies per element, so dark type and fills add
            // onto whatever is under them instead of covering it.
            screen(frame, time: time).colorMultiply(Color(red: 1, green: 0, blue: 0)).compositingGroup()
                .offset(x: split)
            screen(frame, time: time).colorMultiply(Color(red: 0, green: 1, blue: 0)).compositingGroup()
                .blendMode(.plusLighter)
            screen(frame, time: time).colorMultiply(Color(red: 0, green: 0, blue: 1)).compositingGroup()
                .offset(x: -split).blendMode(.plusLighter)
        }
        .compositingGroup()
        .background(Color.black)
    }

    private func screen(_ frame: GVTerminalBootTimeline.Frame, time: Double) -> some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 500
            ZStack(alignment: .topLeading) {
                Color.black
                switch frame.phase {
                case .dot:
                    EmptyView()
                case .post:
                    VStack(alignment: .leading, spacing: compact ? 3 : 6) {
                        ForEach(report.lines) { line in
                            lineView(line, frame: frame, time: time)
                        }
                    }
                    .padding(.horizontal, compact ? 64 : 24)
                    .padding(.top, compact ? 40 : 112)
                    .shadow(color: Self.glow.opacity(0.5), radius: 5)
                    hud(frame, time: time, size: geometry.size, compact: compact)
                case .loading:
                    GVBootSetupDialog(load: frame.load)
                        .padding(.horizontal, 28)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    hud(frame, time: time, size: geometry.size, compact: compact)
                case .crash:
                    GVBootFatalException(corruption: max(frame.corruption, frame.decay * 0.9),
                                         cursorOn: frame.cursorOn, time: time)
                }
            }
        }
    }

    @ViewBuilder
    private func lineView(_ line: GVTerminalBootReport.Line, frame: GVTerminalBootTimeline.Frame, time: Double) -> some View {
        let shown = frame.revealed[line.id]
        if shown > 0 {
            let full = Array(line.typed)
            let count = min(shown, full.count)
            let typing = count < full.count
            let isLast = line.id == report.lines.count - 1
            let text = GVGlyphCorruption.apply(String(full.prefix(count)), amount: frame.decay * 0.9, salt: line.id, time: time)
            let key = String(text.prefix(line.keyLength))
            let rest = String(text.dropFirst(line.keyLength))
            let cursor = (typing || isLast) && frame.cursorOn ? "█" : ""
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Text(key).foregroundStyle(GVTheme.bone.opacity(0.5)))\(Text(rest))\(Text(cursor).foregroundStyle(Self.glow))")
                    .font(font(line.style))
                    .foregroundStyle(line.style == .subtitle ? GVTheme.bone.opacity(0.55) : GVTheme.bone)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.bottom, line.style == .subtitle ? 10 : 0)
                if line.status != .none {
                    Spacer(minLength: 4)
                    Text(line.id < frame.statusCount ? line.status.token : "")
                        .font(GVTheme.mono(12, .bold))
                        .foregroundStyle(color(line.status))
                }
            }
        }
    }

    private func font(_ style: GVTerminalBootReport.Style) -> Font {
        switch style {
        case .title: GVTheme.terminal(34, .heavy)
        case .subtitle: GVTheme.mono(10, .medium)
        case .entry: GVTheme.mono(12, .medium)
        case .prompt: GVTheme.mono(13, .bold)
        }
    }

    private func color(_ status: GVTerminalBootReport.Status) -> Color {
        switch status {
        case .ok: GVTheme.acid
        case .wait: Color(red: 1, green: 0.74, blue: 0.2)
        case .fail: GVTheme.record
        case .none: .clear
        }
    }

    // MARK: - HUD

    /// Corner brackets, a running timecode and frame counter, and the boot
    /// progress bar — the same instrument language as the workspace HUD.
    private func hud(_ frame: GVTerminalBootTimeline.Frame, time: Double, size: CGSize, compact: Bool) -> some View {
        let inset: CGFloat = compact ? 22 : 26
        let top: CGFloat = compact ? 14 : 58
        let bottom: CGFloat = compact ? 14 : 40
        return ZStack {
            Canvas { context, canvasSize in
                let arm: CGFloat = 18
                let rect = CGRect(x: inset, y: top, width: canvasSize.width - inset * 2, height: canvasSize.height - top - bottom)
                var path = Path()
                for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0),
                                         (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                         (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0),
                                         (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)]
                {
                    path.move(to: CGPoint(x: corner.x + arm * dx, y: corner.y))
                    path.addLine(to: corner)
                    path.addLine(to: CGPoint(x: corner.x, y: corner.y + arm * dy))
                }
                context.stroke(path, with: .color(GVTheme.bone.opacity(0.7)), lineWidth: 1.2)
                // Progress rail along the bottom bracket.
                let rail = CGRect(x: rect.minX + arm + 8, y: rect.maxY - 1, width: rect.width - (arm + 8) * 2, height: 2)
                context.fill(Path(rail), with: .color(GVTheme.bone.opacity(0.15)))
                context.fill(Path(CGRect(x: rail.minX, y: rail.minY, width: rail.width * frame.progress, height: 2)),
                             with: .color(Self.glow))
            }
            VStack {
                HStack {
                    Text("SYS//BOOT")
                    Spacer()
                    Text(Self.timecode(time))
                }
                Spacer()
                HStack {
                    Text("CORE \(Int(frame.progress * 100))%")
                    Spacer()
                    Text(String(format: "FRM %04d", Int(time * 60)))
                }
            }
            .font(GVTheme.mono(9, .semibold))
            .foregroundStyle(GVTheme.bone.opacity(0.6))
            .monospacedDigit()
            .padding(.horizontal, inset + 8)
            .padding(.top, top + 6)
            .padding(.bottom, bottom + 8)
        }
        .frame(width: size.width, height: size.height)
    }

    static func timecode(_ time: Double) -> String {
        let centiseconds = Int(max(time, 0) * 100)
        return String(format: "T+%02d:%02d.%02d", centiseconds / 6000, centiseconds / 100 % 60, centiseconds % 100)
    }
}

extension EnvironmentValues {
    /// True while the cold-start terminal covers the screen. The splash
    /// defers anything that would interrupt it, such as permission prompts.
    @Entry var gvBootCeremonyActive = false
}
