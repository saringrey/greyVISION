import SwiftUI

struct GVTerminalText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.gvTerminalTextScale) private var textScale

    let text: String
    var size: CGFloat = 8
    var weight: Font.Weight = .bold
    var tracking: CGFloat = 1.2
    var baseColor = GVTheme.bone
    var alignment: TextAlignment = .center
    var intensity = 1.0
    /// Kept configurable so the splash can remain strictly monochrome without
    /// changing the workspace terminal treatment.
    var emissiveColor = GVTheme.violet
    var emissiveShadowColor = GVTheme.violetDeep

    private var scaledTracking: CGFloat { tracking * textScale }

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 24, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let seedPhase = Double(stableTextSeed % 10000) / 10000
            let pulseSpeed = 1.62 + Double((stableTextSeed >> 8) % 93) / 100
            let sweepSpeed = 0.46 + Double((stableTextSeed >> 17) % 61) / 100
            let sweepDirection = (stableTextSeed & 1) == 0 ? 1.0 : -1.0
            let localTime = time + seedPhase * 3.7
            let pulse = reduceMotion ? 0.5 : 0.5 + sin(localTime * pulseSpeed) * 0.5
            let scan = reduceMotion
                ? seedPhase
                : 0.5 + sin(time * sweepSpeed * sweepDirection + seedPhase * .pi * 2) * 0.5
            let characterTick = Int(localTime.rounded(.down))
            let characterPhase = localTime.truncatingRemainder(dividingBy: 1)
            let start = UnitPoint(x: max(0, scan - 0.42), y: 0.5)
            let end = UnitPoint(x: min(1, scan + 0.42), y: 0.5)

            Text(text)
                .gvMono(size, weight)
                .tracking(scaledTracking)
                .multilineTextAlignment(alignment)
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            baseColor.opacity(0.68),
                            baseColor,
                            .white,
                            emissiveColor.opacity(0.88),
                            baseColor.opacity(0.72)
                        ],
                        startPoint: start,
                        endPoint: end
                    )
                )
                .shadow(
                    color: emissiveShadowColor.opacity((0.22 + pulse * 0.46) * intensity),
                    radius: 2 + pulse * 5
                )
                .overlay {
                    if !reduceMotion {
                        ZStack {
                            Text(text)
                                .gvMono(size, weight)
                                .tracking(scaledTracking)
                                .multilineTextAlignment(alignment)
                                .foregroundStyle(emissiveColor.opacity(0.10 * intensity))
                                .offset(x: sin(time * 13.0) * 0.7, y: cos(time * 9.0) * 0.35)

                            Text(mutatedText(tick: characterTick))
                                .gvMono(size, weight)
                                .tracking(scaledTracking)
                                .multilineTextAlignment(alignment)
                                .foregroundStyle(
                                    .white.opacity(
                                        (0.08 + (1 - characterPhase) * 0.16) * intensity
                                    )
                                )
                                .offset(x: sin(localTime * 37 + seedPhase * 11) * 1.25)
                        }
                        .blendMode(.screen)
                        .accessibilityHidden(true)
                    }
                }
        }
    }

    private func mutatedText(tick: Int) -> String {
        var characters = Array(text)
        let eligible = characters.indices.filter { characters[$0] != " " && characters[$0] != "\n" }
        guard !eligible.isEmpty else { return text }

        let symbols = Array("#/01<>[]*+")
        let tickSeed = UInt64(bitPattern: Int64(tick))
        let seed = stableTextSeed &+ tickSeed &* 31 &+ UInt64(characters.count) &* 17
        let first = eligible[Int(seed % UInt64(eligible.count))]
        characters[first] = symbols[Int((seed &* 7 &+ 3) % UInt64(symbols.count))]
        if eligible.count > 7 {
            let second = eligible[Int((seed &* 13 &+ 5) % UInt64(eligible.count))]
            characters[second] = symbols[Int((seed &* 19 &+ 1) % UInt64(symbols.count))]
        }
        return String(characters)
    }

    private var stableTextSeed: UInt64 {
        text.unicodeScalars.reduce(1_469_598_103_934_665_603) { partial, scalar in
            (partial ^ UInt64(scalar.value)) &* 1_099_511_628_211
        }
    }
}

struct GVAnimatedGlassPanel<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var cornerRadius: CGFloat = 28
    var tint = GVTheme.violetDeep
    var fillOpacity = 0.68
    var isTransparent = false
    @ViewBuilder let content: Content

    init(
        cornerRadius: CGFloat = 28,
        tint: Color = GVTheme.violetDeep,
        fillOpacity: Double = 0.68,
        isTransparent: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.fillOpacity = fillOpacity
        self.isTransparent = isTransparent
        self.content = content()
    }

    var body: some View {
        content
            .background { panelBackground }
            .overlay { animatedBorder }
            .shadow(color: tint.opacity(0.24), radius: 18, y: 7)
            .shadow(color: GVTheme.violet.opacity(0.13), radius: 4)
    }

    private var panelBackground: some View {
        if isTransparent { return AnyView(EmptyView()) }

        let baseTint = Color.black.opacity(fillOpacity)

        return AnyView(
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(baseTint)
            }
        )
    }

    private var animatedBorder: some View {
        TimelineView(
            .animation(minimumInterval: reduceMotion ? 1 : 1 / 24, paused: reduceMotion)
        ) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let phase = reduceMotion ? 0.28 : 0.5 + sin(time * 0.86) * 0.5
            let start = UnitPoint(x: max(0, phase - 0.48), y: 0)
            let end = UnitPoint(x: min(1, phase + 0.48), y: 1)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            tint.opacity(0.22),
                            tint.opacity(0.92),
                            .white.opacity(0.62),
                            GVTheme.violet.opacity(0.76),
                            tint.opacity(0.18)
                        ],
                        startPoint: start,
                        endPoint: end
                    ),
                    lineWidth: 1.1
                )
        }
        .allowsHitTesting(false)
    }
}

struct GVTopGlassPanel<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var cornerRadius: CGFloat = 38
    var fillOpacity = 0.10
    var isTransparent = false
    @ViewBuilder let content: Content

    init(
        cornerRadius: CGFloat = 38,
        fillOpacity: Double = 0.10,
        isTransparent: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.fillOpacity = fillOpacity
        self.isTransparent = isTransparent
        self.content = content()
    }

    var body: some View {
        content
            .background { panelBackground }
            .overlay { animatedBorder }
            .shadow(color: .black.opacity(0.62), radius: 20, y: 11)
            .shadow(color: GVTheme.violetDeep.opacity(0.2), radius: 10, y: 3)
    }

    private var panelBackground: some View {
        if isTransparent { return AnyView(EmptyView()) }

        let baseTint = Color.black.opacity(fillOpacity)

        return AnyView(
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(baseTint)
            }
        )
    }

    private var animatedBorder: some View {
        TimelineView(
            .animation(minimumInterval: reduceMotion ? 1 : 1 / 24, paused: reduceMotion)
        ) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let phase = reduceMotion ? 0.3 : 0.5 + sin(time * 0.72) * 0.5

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            GVTheme.violetDeep.opacity(0.18),
                            GVTheme.violet.opacity(0.92),
                            .white.opacity(0.52),
                            GVTheme.violetDeep.opacity(0.16)
                        ],
                        startPoint: UnitPoint(x: max(0, phase - 0.46), y: 0),
                        endPoint: UnitPoint(x: min(1, phase + 0.46), y: 1)
                    ),
                    lineWidth: 1.15
                )
        }
        .allowsHitTesting(false)
    }
}

struct GVDualScanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var isActive = true
    var tint = GVTheme.violet

    @State private var firstProgress: CGFloat = -0.06
    @State private var secondProgress: CGFloat = -0.13
    @State private var scannerOpacity = 0.0
    @State private var hasRun = false
    @State private var scanTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                scannerLine(
                    width: geometry.size.width,
                    y: geometry.size.height * firstProgress,
                    color: tint
                )
                scannerLine(
                    width: geometry.size.width,
                    y: geometry.size.height * secondProgress,
                    color: .white
                )
            }
            .opacity(scannerOpacity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: isActive, initial: true) { _, active in
            if active {
                startScanIfNeeded()
            }
        }
        .onDisappear {
            scanTask?.cancel()
            scanTask = nil
        }
    }

    @MainActor
    private func startScanIfNeeded() {
        guard !hasRun, isActive, !reduceMotion else { return }
        hasRun = true
        scannerOpacity = 1
        withAnimation(.linear(duration: 2.75)) {
            firstProgress = 1.04
        }
        withAnimation(.linear(duration: 3.15).delay(0.16)) {
            secondProgress = 1.04
        }
        scanTask?.cancel()
        scanTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.34))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.36)) {
                scannerOpacity = 0
            }
        }
    }

    private func scannerLine(width: CGFloat, y: CGFloat, color: Color) -> some View {
        ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, color.opacity(0.92), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: width, height: 1)
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, color.opacity(0.34), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: width, height: 9)
                .blur(radius: 5)
        }
        .position(x: width / 2, y: y)
        .blendMode(.screen)
    }
}

struct GVSnowField: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let particles = GVSnowParticle.seeded(count: 138, seed: 0x534E_4F57_4756)
    var accent = GVTheme.violet

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                for particle in particles {
                    let travel = (particle.y + time * particle.speed)
                        .truncatingRemainder(dividingBy: 1.12) - 0.06
                    let drift = sin(time * particle.driftSpeed + particle.phase) * particle.drift
                    let x = (particle.x + drift) * size.width
                    let y = travel * size.height
                    let flicker = reduceMotion ? 0.58 : 0.46 + sin(time * 3.2 + particle.phase) * 0.22
                    let rect = CGRect(x: x, y: y, width: particle.size, height: particle.size)
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(
                            (particle.isViolet ? accent : .white)
                                .opacity(max(0.08, flicker))
                        )
                    )
                }
            }
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct GVSnowParticle: Sendable {
    let x: Double
    let y: Double
    let size: Double
    let speed: Double
    let drift: Double
    let driftSpeed: Double
    let phase: Double
    let isViolet: Bool

    static func seeded(count: Int, seed: UInt64) -> [GVSnowParticle] {
        var generator = GVSnowGenerator(state: seed)
        return (0 ..< count).map { _ in
            GVSnowParticle(
                x: generator.nextUnit(),
                y: generator.nextUnit(),
                size: 0.45 + generator.nextUnit() * 1.7,
                speed: 0.018 + generator.nextUnit() * 0.075,
                drift: 0.003 + generator.nextUnit() * 0.018,
                driftSpeed: 0.4 + generator.nextUnit() * 1.4,
                phase: generator.nextUnit() * .pi * 2,
                isViolet: generator.nextUnit() > 0.88
            )
        }
    }
}

private struct GVSnowGenerator: Sendable {
    var state: UInt64

    mutating func nextUnit() -> Double {
        state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
        return Double(state >> 11) / Double(1 << 53)
    }
}
