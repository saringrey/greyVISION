import SwiftUI

/// The splash chooser's sections. Declared beside the rail rather than inside
/// the boot view so the dock that opens a section and the rail that draws it
/// share one vocabulary — a section can no longer exist in one and not the
/// other.
enum SplashDockSection: String, CaseIterable, Identifiable {
    case codec
    case frameRate = "fps"
    case resolution

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .codec: "CODEC"
        case .frameRate: "FPS"
        case .resolution: "RES"
        }
    }
}

/// One option in the splash chooser, flattened.
///
/// Codec, frame rate and resolution were three near-identical card bodies that
/// had drifted apart at the edges. They differ in what they set and what they
/// have to say about themselves, which is data, not structure — so the card is
/// built once from this and each section only supplies values.
struct GVSplashOption: Identifiable {
    /// Scroll anchor. Opening a section pins its first option, so this is also
    /// what makes "always starts at the top of the list" true.
    let id: String
    /// Accessibility identifier. The boot tests drive the chooser through
    /// these, so they are per-section and per-option, never per index.
    let identifier: String
    /// Card headline: the full name, because the card is where the operator
    /// compares them.
    let label: String
    /// Micro line under the headline. The two facts that actually separate the
    /// options from each other, not a repeat of the name.
    let spec: String
    /// Prose status. Printed in the footer when this option is selected, and
    /// spoken as the hint when it is not.
    let note: String
    /// 1...5 relative load, for the card's ladder.
    let meter: Int
    /// Footer readout for this option, already paired.
    let chips: [GVSplashSpecChip]
    let enabled: Bool
    let apply: () -> Void
}

/// One label/value pair in the rail's footer readout.
struct GVSplashSpecChip: Identifiable {
    let caption: String
    let value: String
    /// 0 draws no ladder. 1...5 draws one beside the value.
    var meter: Int = 0

    var id: String {
        caption
    }
}

/// The splash chooser's rail: a header, a scroller of option cards, and a
/// footer readout of whatever is armed.
///
/// This is the screen the operator decides what the take *is* on. It used to be
/// a black strip of small plates that repeated the dock back at them, which
/// told them nothing the dock had not already said. What it is now is an
/// instrument panel: the header states the section and how much of it is live,
/// the cards carry the two facts that separate one format from another, and the
/// footer reads the selected format out the way a camera body prints its
/// current mode — chroma, depth, tier, and how much of the signal the format
/// keeps.
struct GVSplashChoiceRail: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Stagger token. Cards step in behind each other when a section opens,
    /// which reads as a mechanism indexing rather than as a plate appearing.
    @State private var reveal = false

    let section: SplashDockSection
    let options: [GVSplashOption]
    /// Option currently in force, for the inverted plate and the footer.
    let selectedID: String
    @Binding var scrollID: String?
    let onSelect: (GVSplashOption) -> Void

    private var selected: GVSplashOption? {
        options.first { $0.id == selectedID } ?? options.first
    }

    private var liveCount: Int {
        options.filter(\.enabled).count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            optionScroller
            if let selected {
                readout(for: selected)
            }
        }
        .background { chrome }
        .clipShape(plate)
        .overlay { plate.strokeBorder(stroke, lineWidth: 1) }
        .overlay { GVSplashRegistration(color: .white.opacity(0.22), inset: 7) }
        .overlay {
            // Light passing over the glass rather than a lit rectangle: the
            // band is clipped to the panel and added to whatever is drawn
            // underneath it.
            GVSplashRailSweep()
                .clipShape(plate)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.62), radius: 18, y: 10)
        .shadow(color: .white.opacity(0.10), radius: 14, y: 2)
        .frame(maxWidth: .infinity)
        .task(id: section) {
            reveal = false
            guard !reduceMotion else {
                reveal = true
                return
            }
            // One frame at zero, so the stagger has somewhere to move from.
            await Task.yield()
            withAnimation(GVMotion.resolved(GVMotion.panel, reduceMotion: reduceMotion)) { reveal = true }
        }
    }

    /// Cut corners rather than a stock rounded rectangle, with the registration
    /// marks opposite them. Same shape signature as the workspace chrome, which
    /// is most of why the two screens read as one instrument.
    private var plate: GVChamferedPlate {
        GVChamferedPlate(cut: 13)
    }

    private var stroke: LinearGradient {
        LinearGradient(
            colors: [.white.opacity(0.30), .white.opacity(0.08), .black.opacity(0.55)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var chrome: some View {
        ZStack {
            LinearGradient(
                colors: [SplashPalette.charcoal, SplashPalette.deep],
                startPoint: .top,
                endPoint: .bottom
            )
            // Just enough tube to sit in the same air as the splash behind it.
            GVScanlines(opacity: 0.05, frequency: 34)
        }
    }
}

// MARK: - Header

extension GVSplashChoiceRail {
    var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: GVMetrics.stepInternal) {
                Text(section.label)
                    .font(GVTheme.mono(8.5, .black))
                    .tracking(1.5)
                    .foregroundStyle(GVTheme.bone)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background {
                        GVChamferedPlate(cut: 4, diagonal: false)
                            .fill(Color.white.opacity(0.07))
                    }
                    .overlay {
                        GVChamferedPlate(cut: 4, diagonal: false)
                            .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.75)
                    }

                Text("\(options.count) OPTIONS")
                    .font(GVTheme.mono(8, .bold))
                    .tracking(1.2)
                    .foregroundStyle(GVTheme.ash)

                Spacer(minLength: 8)

                // The one number on this panel that is a fact about the device
                // rather than about the format list.
                HStack(spacing: GVMetrics.gapTight) {
                    Rectangle()
                        .fill(liveCount == options.count ? GVTheme.bone : GVTheme.ash)
                        .frame(width: 4, height: 4)
                        .shadow(color: .white.opacity(0.8), radius: 4)
                    Text("\(liveCount) LIVE")
                        .font(GVTheme.mono(8, .black))
                        .tracking(1.3)
                        .foregroundStyle(GVTheme.bone.opacity(0.78))
                }
            }
            .padding(.horizontal, GVMetrics.stepRelated)
            .padding(.top, GVMetrics.stepInternal)
            .padding(.bottom, GVMetrics.gapTight)

            GVSplashTickRule(height: 6)
        }
    }
}

// MARK: - Options

extension GVSplashChoiceRail {
    var optionScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: GVMetrics.stepRelated) {
                if section == .frameRate { Spacer(minLength: 0) }
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    card(option, index: index)
                }
                if section == .frameRate { Spacer(minLength: 0) }
            }
            .frame(maxWidth: .infinity, alignment: section == .frameRate ? .center : .leading)
            .padding(.vertical, GVMetrics.stepInternal)
            .scrollTargetLayout()
            .gvLiquidGlassContainer(spacing: GVMetrics.stepRelated)
        }
        .scrollPosition(id: $scrollID, anchor: .leading)
        .defaultScrollAnchor(.leading)
        .contentMargins(.horizontal, GVMetrics.stepStandard, for: .scrollContent)
        // Clipped to the rail, so a card scrolling out ends at the panel's own
        // edge and the fade reads as "more this way" rather than as a rendering
        // fault. Same treatment as the workspace effect rail.
        .gvHorizontalEdgeFade()
        .clipShape(RoundedRectangle(cornerRadius: GVMetrics.radius, style: .continuous))
        .accessibilityIdentifier("boot.choices.\(section.rawValue)")
    }

    func card(_ option: GVSplashOption, index: Int) -> some View {
        let isSelected = option.id == selectedID
        return Button {
            onSelect(option)
        } label: {
            VStack(alignment: .leading, spacing: GVMetrics.gapTight) {
                HStack(spacing: GVMetrics.gapTight) {
                    GVTerminalText(
                        text: option.label,
                        size: 11.5,
                        weight: .medium,
                        tracking: 0.7,
                        baseColor: isSelected ? GVTheme.violet : GVTheme.bone,
                        intensity: 0.2
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .layoutPriority(1)
                    if !option.enabled {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(GVTheme.ash)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: GVMetrics.gapTight) {
                    Text(option.spec)
                        .font(GVTheme.mono(7.5, .bold))
                        .tracking(1.0)
                        .foregroundStyle(GVTheme.ash)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    GVSplashMeterLadder(level: option.meter)
                }
            }
            .padding(.horizontal, GVMetrics.stepInternal)
            .frame(width: 130, height: 60, alignment: .leading)
            .overlay {
                if isSelected {
                    // Drawn inside the label, so it inverts with the plate. The
                    // marks are authored white because the selected plate is
                    // white: inversion is what turns them black, and a black
                    // mark here would come out white on white and vanish.
                    ZStack {
                        GVScanlines(opacity: 0.14).padding(2)
                        GVPlateRegistration(color: .white.opacity(0.55), inset: 5)
                    }
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(GVSplashButtonStyle(active: isSelected))
        .accessibilityValue(isSelected ? "selected" : "not selected")
        .disabled(!option.enabled)
        .opacity((option.enabled ? 1 : 0.42) * (reveal ? 1 : 0))
        .offset(y: reveal ? 0 : GVMetrics.stepInternal)
        .animation(
            GVMotion.resolved(GVMotion.normal.delay(Double(index) * 0.035), reduceMotion: reduceMotion),
            value: reveal
        )
        .accessibilityLabel(option.label)
        .accessibilityHint(option.enabled ? option.note : "Unavailable. \(option.note)")
        .accessibilityIdentifier(option.identifier)
        .id(option.id)
    }
}

// MARK: - Footer readout

extension GVSplashChoiceRail {
    func readout(for option: GVSplashOption) -> some View {
        VStack(spacing: 0) {
            GVSplashTickRule(height: 6)

            HStack(spacing: GVMetrics.gap) {
                Rectangle()
                    .fill(GVTheme.violet.opacity(option.enabled ? 0.95 : 0.35))
                    .frame(width: 4, height: 4)
                    .shadow(color: GVTheme.violet.opacity(option.enabled ? 0.85 : 0), radius: 4)

                Text(option.note)
                    .font(GVTheme.mono(8.5, .bold))
                    .tracking(1.1)
                    .foregroundStyle(GVTheme.bone.opacity(0.66))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.opacity)

                Spacer(minLength: GVMetrics.gapTight)

                Text(option.enabled ? "AVAILABLE" : "UNAVAILABLE")
                    .font(GVTheme.mono(8, .black))
                    .tracking(1.4)
                    .foregroundStyle(option.enabled ? GVTheme.bone.opacity(0.82) : GVTheme.ash)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, GVMetrics.stepRelated)
            .padding(.top, GVMetrics.gap)
            .padding(.bottom, GVMetrics.gapTight)

            HStack(spacing: 0) {
                ForEach(Array(option.chips.enumerated()), id: \.element.id) { index, chip in
                    if index > 0 {
                        Rectangle()
                            .fill(GVTheme.separator)
                            .frame(width: 1, height: 20)
                    }
                    chipView(chip)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, GVMetrics.stepInternal)
            .accessibilityHidden(true)
        }
    }

    func chipView(_ chip: GVSplashSpecChip) -> some View {
        VStack(alignment: .leading, spacing: GVMetrics.gapHair) {
            Text(chip.caption)
                .font(GVTheme.mono(7.5, .bold))
                .tracking(1.3)
                .foregroundStyle(GVTheme.ash)
            HStack(spacing: GVMetrics.gapTight) {
                Text(chip.value)
                    .font(GVTheme.mono(10.5, .black))
                    .tracking(0.5)
                    .foregroundStyle(GVTheme.bone.opacity(0.92))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                if chip.meter > 0 {
                    GVSplashMeterLadder(level: chip.meter, height: 11)
                }
            }
        }
        .padding(.horizontal, GVMetrics.stepInternal)
    }
}

/// Five-step load ladder. Relative by construction — a filled segment means
/// "more than the step below it", never a number — so one component can measure
/// fidelity, motion and detail without pretending they share units.
struct GVSplashMeterLadder: View {
    let level: Int
    /// Height of the tallest step. The ladder is drawn from the baseline up, so
    /// the silhouette itself carries the reading.
    var height: CGFloat = 9

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0 ..< 5, id: \.self) { step in
                RoundedRectangle(cornerRadius: 0.75, style: .continuous)
                    .fill(Color.white.opacity(step < level ? 0.92 : 0.18))
                    .frame(width: 2, height: height * (0.45 + CGFloat(step) * 0.1375))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A measuring scale along a rule.
///
/// Machine-facing panels in this instrument carry one; it is most of what
/// separates a control surface from a settings sheet, and it costs one canvas.
struct GVSplashTickRule: View {
    var height: CGFloat = 6
    var spacing: CGFloat = 7
    var color: Color = .white

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var index = 0
            var x: CGFloat = 0
            while x <= size.width {
                let tick = index.isMultiple(of: 5) ? height : height * 0.45
                path.move(to: CGPoint(x: x, y: size.height - tick))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
                index += 1
            }
            context.stroke(path, with: .color(color.opacity(0.16)), lineWidth: 0.75)
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Registration marks on the two corners the chamfer does not cut.
///
/// The workspace plate draws these only when a control is selected, as state.
/// On the rail they are always present and always at the panel's corners, so
/// they read as the fixture the panel is mounted on rather than as a second
/// selection signal competing with the inverted card.
struct GVSplashRegistration: View {
    var color: Color
    var inset: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Path { path in
                path.move(to: CGPoint(x: inset, y: size.height - inset))
                path.addLine(to: CGPoint(x: inset + 7, y: size.height - inset))
                path.move(to: CGPoint(x: size.width - inset - 7, y: inset))
                path.addLine(to: CGPoint(x: size.width - inset, y: inset))
            }
            .stroke(color, lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The rail's specular band.
///
/// Slow, wide and low contrast: this is glass catching light, not a progress
/// indicator. Driven off the clock rather than by a repeating animation, so it
/// stops dead under Reduce Motion instead of being re-timed, and so nothing
/// keeps a display link alive once the rail closes.
private struct GVSplashRailSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: reduceMotion)) { timeline in
            GeometryReader { geometry in
                let period = 7.5
                let phase = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period
                let width = geometry.size.width
                LinearGradient(
                    colors: [.clear, .white.opacity(0.07), .white.opacity(0.02), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: width * 0.36, height: geometry.size.height * 1.8)
                .rotationEffect(.degrees(14))
                .offset(
                    x: (CGFloat(phase) * 1.55 - 0.55) * width,
                    y: -geometry.size.height * 0.4
                )
                .blendMode(.plusLighter)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The splash chooser's material — same charcoal family as the workspace dock
/// and parameter decks, so boot and camera read as one instrument.
private enum SplashPalette {
    static let charcoal = Color(white: 0.045)
    static let deep = Color.black
}
