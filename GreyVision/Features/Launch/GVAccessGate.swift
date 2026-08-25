import SwiftUI
import UIKit

/// Access ceremony. Four digits before the instrument will boot.
///
/// The code is a compile-time constant. That is honest about what this is: it
/// keeps a curious hand out of the app, and anyone with the source can read it
/// in one grep. It is not a secret store and should not be treated as one.
enum GVAccessCode {
    /// Change this to change the code. Nothing else needs editing.
    static let value = "3914"
    static let length = 4
}

/// A small mac-terminal window floating on black: traffic-light dots, a
/// `end//user` host line centred under the bar, one prompt, four decaying
/// digits, and a blinking block cursor. Everything else is subtraction.
struct GVAccessGate: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Called once, on the correct code.
    let onUnlocked: () -> Void

    private enum GatePhase {
        case entering
        case denied
        case granted
    }

    @State private var isFormPresented = false
    @State private var entered = ""
    @State private var phase: GatePhase = .entering
    @State private var failedAttempts = 0
    @State private var shake: CGFloat = 0
    @State private var pulseSlot: Int?

    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", ""]

    var body: some View {
        ZStack {
            GVTheme.void.ignoresSafeArea()

            GateMarquee(text: "my memories have teeth", direction: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)

            GateMarquee(text: "and they still know where to bite", direction: .trailing)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)

            if isFormPresented {
                terminalWindow
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            } else {
                lockButton
                    .transition(.opacity)
            }

            // Violet port ring around the Dynamic Island.
            GeometryReader { geometry in
                GVIslandHalo(topInset: geometry.safeAreaInsets.top)
            }
            .allowsHitTesting(false)

            // Analog display pass over everything: scanlines, tracking band,
            // dropout streaks, vignette.
            GateCRTOverlay()
        }
        .animation(GVMotion.resolved(GVMotion.tear, reduceMotion: reduceMotion), value: isFormPresented)
        .accessibilityIdentifier("access.gate")
    }

    // MARK: - Lock (pre-prompt)

    /// Pure black, one lock, and a failing fluorescent tube above it. The
    /// spotlight flickers at mains cadence — occasional brownouts, rare
    /// dropouts — and the lock itself is only ever as lit as the light.
    private var lockButton: some View {
        Button {
            GVSoundEngine.shared.play(.keypad)
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.6)
            isFormPresented = true
        } label: {
            TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 24, paused: false)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let level = reduceMotion ? 0.75 : Self.spotlightLevel(at: t)

                ZStack {
                    // Wide soft pool — the light hitting the floor around it.
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [
                                    .white.opacity(0.13 * level),
                                    .white.opacity(0.045 * level),
                                    .clear
                                ],
                                center: .center,
                                startRadius: 4,
                                endRadius: 105
                            )
                        )
                        .frame(width: 230, height: 160)
                        .blur(radius: 9)

                    // Tight core directly behind the glyph, so the lock reads
                    // as the object IN the beam rather than beside it.
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    .white.opacity(0.30 * level),
                                    .white.opacity(0.08 * level),
                                    .clear
                                ],
                                center: .center,
                                startRadius: 1,
                                endRadius: 34
                            )
                        )
                        .frame(width: 70, height: 70)
                        .blur(radius: 3)

                    VStack(spacing: 10) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 19, weight: .light))
                            .foregroundStyle(.white.opacity(0.18 + 0.80 * level))
                            .shadow(color: .white.opacity(0.55 * level), radius: 5 * level + 1)
                            .shadow(color: .white.opacity(0.20 * level), radius: 14)

                        Text("end//user")
                            .font(.system(size: 9, weight: .regular, design: .monospaced))
                            .tracking(2.6)
                            .foregroundStyle(.white.opacity(0.30 * level))
                            .shadow(color: .black.opacity(0.8), radius: 1)
                    }
                }
                .frame(width: 150, height: 120)
                .contentShape(Rectangle())
            }
            .animation(GVMotion.micro, value: isFormPresented)
        }
        .buttonStyle(GVPressStyle())
        .accessibilityLabel("Unlock")
    }

    /// Deterministic mains flicker: mostly steady, periodic brownouts, rare
    /// near-blackout blinks, all sampled at ballast rate. Same hash trick the
    /// glitch shader uses so every device flickers identically.
    nonisolated private static func spotlightLevel(at time: TimeInterval) -> Double {
        let fastBucket = Int(time * 14)
        let roll = hashValue(fastBucket)
        var level = 1.0
        if roll > 0.962 {
            level = 0.10
        } else if roll > 0.88 {
            level = 0.48 + hashValue(fastBucket &+ 7) * 0.28
        }
        let surge = 0.90 + 0.10 * sin(time * 0.7)
        return max(min(level * surge, 1), 0)
    }

    nonisolated private static func hashValue(_ value: Int) -> Double {
        var mixed = UInt64(bitPattern: Int64(value)) &* 6_364_136_223_846_793_005
        mixed = mixed &+ 1_442_695_040_888_963_407
        return Double((mixed >> 33) % 100_000) / 100_000
    }

    // MARK: - Terminal window

    private var terminalWindow: some View {
        VStack(spacing: 0) {
            titleBar
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            VStack(spacing: 15) {
                promptBlock
                keypad
            }
            .padding(.horizontal, 21)
            .padding(.vertical, 17)
        }
        .frame(width: 342)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.016))
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(0.32), lineWidth: 0.7)
                .shadow(color: .white.opacity(0.40), radius: 5)
                .shadow(color: .white.opacity(0.14), radius: 14)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
        .offset(x: shake)
        .padding(.horizontal, GVMetrics.stepSection)
        .animation(GVMotion.micro, value: phase)
    }

    /// Traffic lights in charcoal — shape without colour — and the host name,
    /// breathing white.
    private var titleBar: some View {
        HStack(spacing: 5) {
            ForEach(0 ..< 3, id: \.self) { _ in
                Circle()
                    .fill(Color(white: 0.135))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.06), lineWidth: 0.8))
                    .frame(width: 8, height: 8)
            }
            Spacer(minLength: 0)
            ZStack {
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.16), .white.opacity(0.05), .clear],
                            center: .center,
                            startRadius: 2,
                            endRadius: 58
                        )
                    )
                    .blur(radius: 6)
                    .frame(width: 118, height: 30)

                GVTerminalText(
                    text: "end//user",
                    size: 11,
                weight: .regular,
                tracking: 2.2,
                alignment: .center,
                intensity: 0.55
            )
            }
            Spacer(minLength: 0)
            Color.clear.frame(width: 31, height: 6.5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// The host identity, dead centre, as asked: end//user.

    // MARK: - Prompt

    /// One shell line: the command, the four slots as they fill, the block
    /// cursor waiting at the end. Refusal prints its own stderr line below.
    private var promptBlock: some View {
        VStack(alignment: .center, spacing: 6) {
            HStack(spacing: 12) {
                ForEach(0 ..< GVAccessCode.length, id: \.self) { index in
                    let filled = index < entered.count
                    let character = filled
                        ? String(entered[entered.index(entered.startIndex, offsetBy: index)])
                        : ""
                    GlitchyDigit(character: filled ? character : " ", seed: index, isActive: filled || pulseSlot == index)
                        .scaleEffect(pulseSlot == index ? 1.16 : 1)
                        .animation(GVMotion.resolved(GVMotion.press, reduceMotion: reduceMotion), value: pulseSlot)
                }
            }
            .frame(maxWidth: .infinity)

            if phase == .denied {
                Text("zsh: access denied // permission refused" + (failedAttempts > 1 ? " (\(failedAttempts) attempts)" : ""))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            } else if phase == .granted {
                Text("session opened · welcome back")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }
        }
        .animation(GVMotion.micro, value: phase)
    }

    // MARK: - Keypad

    private var keypad: some View {
        let columns = Array(repeating: GridItem(.fixed(88), spacing: 8), count: 3)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                if key.isEmpty {
                    Color.clear.frame(height: 42)
                } else {
                    keyButton(key)
                }
            }
        }
    }

    private func keyButton(_ key: String) -> some View {
        Button {
            press(key)
        } label: {
            Group {
                if key.isEmpty {
                    Color.clear
                } else {
                    Text(key)
                        .font(.system(size: 20, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.82))
                }
            }
            .frame(width: 88, height: 42)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.020))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GateKeyStyle())
        .accessibilityLabel(key.isEmpty ? "Unused" : key)
    }

    private func press(_ key: String) {
        guard !key.isEmpty else { return }
        // Keyboard click, quiet by design.
        GVSoundEngine.shared.play(.keypad)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.35)

        guard entered.count < GVAccessCode.length else { return }
        entered.append(key)
        if phase == .denied { phase = .entering }
        pulseSlot = entered.count - 1
        clearPulse()

        // Auto-submit on the fourth digit.
        if entered.count == GVAccessCode.length {
            entered == GVAccessCode.value ? accept() : reject()
        }
    }

    private func clearPulse() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            pulseSlot = nil
        }
    }

    private func accept() {
        // The one moment worth a real confirmation: a rising resolution that
        // lands instead of chopping off.
        GVSoundEngine.shared.play(.accept)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        phase = .granted
        let hold = reduceMotion ? 0 : 0.38
        Task { @MainActor in
            if hold > 0 {
                try? await Task.sleep(for: .seconds(hold))
            }
            onUnlocked()
        }
    }

    private func reject() {
        phase = .denied
        failedAttempts += 1
        GVSoundEngine.shared.play(.error)
        UINotificationFeedbackGenerator().notificationOccurred(.error)

        guard !reduceMotion else {
            entered = ""
            return
        }
        // Three decaying swings, then clear. Long enough to read as a refusal,
        // short enough not to punish a mistyped digit.
        withAnimation(.linear(duration: 0.05).repeatCount(6, autoreverses: true)) {
            shake = 7
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(340))
            shake = 0
            phase = .entering
            entered = ""
        }
    }
}

/// Endless terminal ticker along the top or bottom edge. The line is laid
/// out once, measured, and wrapped by its own width so the loop is seamless;
/// the screen edges feather it out instead of guillotining it.
private struct GateMarquee: View {
    enum Direction { case leading, trailing }

    let text: String
    let direction: Direction

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copyWidth: CGFloat = 0

    private var repeated: String {
        text + "   \u{00B7}   " + text + "   \u{00B7}   " + text
    }

    var body: some View {
        GeometryReader { geometry in
            let screenW = max(geometry.size.width, 1)
            let wrapW = max(copyWidth, 1)

            TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 60, paused: false)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let speed: CGFloat = 52
                let travel = CGFloat(fmod(t * Double(speed), Double(wrapW)))

                // Leading drifts left off its natural start; trailing is the
                // mirror — same clock, reversed travel — so the two lines
                // scroll against each other forever without ever syncing up.
                let baseX: CGFloat = direction == .leading
                    ? -travel
                    : -(wrapW * 2) + travel

                let line = Text(repeated)
                    .font(.system(size: 26, weight: .regular, design: .monospaced))
                    .tracking(3.4)

                ZStack {
                    // Soft white bloom sitting behind the glyphs.
                    line
                        .foregroundStyle(.white.opacity(0.14))
                        .blur(radius: 9)

                    // VHS chroma fringe: red/cyan split reads as tape bleed.
                    line
                        .foregroundStyle(Color(red: 1, green: 0.25, blue: 0.30).opacity(0.20))
                        .shadow(color: .clear, radius: 0)
                        .offset(x: 1.6)

                    line
                        .foregroundStyle(Color(red: 0.25, green: 0.95, blue: 1).opacity(0.18))
                        .shadow(color: .clear, radius: 0)
                        .offset(x: -1.6)

                    line
                        .foregroundStyle(Color(white: 0.52))
                        .shadow(color: .white.opacity(0.22), radius: 2.5)
                }
                .fixedSize()
                .offset(x: baseX)
                .background(
                    GeometryReader { probe in
                        Color.clear
                            .preference(key: MarqueeWidthKey.self, value: probe.size.width / 3)
                    }
                )
                .onPreferenceChange(MarqueeWidthKey.self) { copyWidth = $0 }
                .frame(width: screenW, alignment: .leading)
            }
        }
        .frame(height: 44)
        // Feathered edges: the line dissolves into black at both ends rather
        // than being cut by the display.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.14),
                    .init(color: .black, location: 0.86),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .padding(.vertical, 10)
    }
}

private struct MarqueeWidthKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Full-screen analog display pass for the gate: static scanlines, a slow
/// VHS tracking band drifting down the panel, rare dropout streaks, a
/// head-switching noise strip at the bottom edge, and corner vignette.
/// Everything is deterministic and deliberately faint — the screen should
/// read as tired hardware, not as a broken one. Never hit-testable.
private struct GateCRTOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            scanlines

            if !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    Canvas { context, size in
                        drawTrackingBand(t: t, size: size, into: &context)
                        drawDropouts(t: t, size: size, into: &context)
                        drawHeadSwitch(t: t, size: size, into: &context)
                    }
                }
            }

            vignette
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Static phosphor lines, drawn once per layout — no timeline cost.
    private var scanlines: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            while y < size.height {
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 1.1)),
                    with: .color(.black.opacity(0.26))
                )
                y += 3.4
            }
        }
    }

    /// The bright band that rolls down a tape image every few seconds.
    private func drawTrackingBand(t: TimeInterval, size: CGSize, into context: inout GraphicsContext) {
        let bandHeight: CGFloat = 130
        let period = Double(size.height + bandHeight * 2)
        let y = CGFloat(fmod(t * 42, period)) - bandHeight
        let gradient = Gradient(stops: [
            .init(color: .white.opacity(0), location: 0),
            .init(color: .white.opacity(0.055), location: 0.55),
            .init(color: .white.opacity(0.10), location: 0.72),
            .init(color: .white.opacity(0.03), location: 0.92),
            .init(color: .white.opacity(0), location: 1)
        ])
        context.fill(
            Path(CGRect(x: 0, y: y, width: size.width, height: bandHeight)),
            with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: y), endPoint: CGPoint(x: 0, y: y + bandHeight))
        )
    }

    /// Occasional single-line dropouts — the tape momentarily losing oxide.
    /// Hash-bucketed like the glitch digits so every device decays alike.
    private func drawDropouts(t: TimeInterval, size: CGSize, into context: inout GraphicsContext) {
        let bucket = Int(t * 2)
        guard Self.hash(bucket) < 0.22 else { return }
        let y = Self.hash(bucket &+ 7) * Double(size.height - 40) + 20
        let x = Self.hash(bucket &+ 13) * Double(size.width) * 0.6
        let width = size.width * (0.18 + CGFloat(Self.hash(bucket &+ 19)) * 0.4)
        context.fill(
            Path(CGRect(x: x, y: y, width: width, height: 1.6)),
            with: .color(.white.opacity(0.10))
        )
    }

    /// Head-switching noise: a strip of jittered horizontal tearing hugging
    /// the bottom edge, exactly where a VCR never tracked cleanly.
    private func drawHeadSwitch(t: TimeInterval, size: CGSize, into context: inout GraphicsContext) {
        let frame = Int(t * 24)
        let baseY = size.height - 16
        for line in 0 ..< 7 {
            let jitterX = (Self.hash(frame &+ line &* 131) - 0.5) * 26
            let y = baseY + CGFloat(line) * 2.1
            context.fill(
                Path(CGRect(x: jitterX, y: y, width: size.width + 26, height: 0.9)),
                with: .color(.white.opacity(line % 2 == 0 ? 0.035 : 0.06))
            )
        }
    }

    private var vignette: some View {
        LinearGradient(
            colors: [.black.opacity(0.34), .clear],
            startPoint: .bottom,
            endPoint: UnitPoint(x: 0.5, y: 0.55)
        )
        .blendMode(.multiply)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.12),
                    .init(color: .clear, location: 0.30)
                ],
                startPoint: .bottom,
                endPoint: .top
            )
        )
    }

    nonisolated private static func hash(_ value: Int) -> Double {
        var mixed = UInt64(bitPattern: Int64(value)) &* 6_364_136_223_846_793_005
        mixed = mixed &+ 1_442_695_040_888_963_407
        return Double((mixed >> 33) % 100_000) / 100_000
    }
}

/// Press feedback: sink into the plate, one quiet wash of white, spring back.
private struct GateKeyStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.93 : 1))
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.06 : 0))
                    .shadow(color: .white.opacity(configuration.isPressed ? 0.20 : 0), radius: configuration.isPressed ? 6 : 0)
            }
            .animation(
                GVMotion.resolved(
                    configuration.isPressed ? GVMotion.micro : GVMotion.press,
                    reduceMotion: reduceMotion
                ),
                value: configuration.isPressed
            )
    }
}

/// One character of the access code, drawn as tired-but-futuristic hardware:
/// most frames it is simply there; occasionally the tube drops a scanline and
/// the glyph decays for a beat before recovering. Deterministic per bucket so
/// the corruption reads as the display failing, not as noise.
private struct GlitchyDigit: View {
    let character: String
    let seed: Int
    var isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Glyphs the tube collapses into when it misfires.
    private static let decayGlyphs = ["▚", "▞", "░", "▒", "/", "\\", "¦", "#"]

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 12, paused: reduceMotion || !isActive)) { timeline in
            glyph(at: timeline.date)
        }
        .frame(width: 18, height: 23)
    }

    @ViewBuilder
    private func glyph(at date: Date) -> some View {
        let bucket = Int(date.timeIntervalSinceReferenceDate * 8)
        let roll = hash(bucket &* 7919 &+ seed &* 104_729)
        let corrupt = character != " " && roll < 0.055

        if corrupt {
            Text(decayGlyph(for: bucket))
                .font(digitFont)
                .foregroundStyle(.white.opacity(0.30))
                .offset(x: hash(bucket &+ 9) > 0.5 ? 1.0 : -1.0, y: 0.5)
        } else {
            Text(character)
                .font(digitFont)
                .foregroundStyle(.white.opacity(0.88))
                .shadow(color: .black.opacity(0.85), radius: 0.6)
        }
    }

    private var digitFont: Font {
        .system(size: 19, weight: .regular, design: .monospaced)
    }

    private func decayGlyph(for bucket: Int) -> String {
        let glyphs = Self.decayGlyphs
        return glyphs[Int(hash(bucket &+ (seed &+ 17)) * Double(glyphs.count))]
    }

    /// Stable 0...1 from an integer mix — the same trick the glitch shader
    /// uses, kept in Swift so the digits need no layer effect.
    private func hash(_ value: Int) -> Double {
        var mixed = UInt64(bitPattern: Int64(value)) &* 6_364_136_223_846_793_005
        mixed = mixed &+ 1_442_695_040_888_963_407
        return Double((mixed >> 33) % 100_000) / 100_000
    }
}
