import SwiftUI

/// What one browser tile shows. Plain values, so the face can be previewed and
/// reasoned about without an editor, a thumbnail store or a running camera.
struct GVEffectTileModel: Equatable {
    let name: String
    let image: UIImage?
    let previewUnavailable: Bool
    let active: Bool
    let favorite: Bool
    /// 0...3, the catalogue's render-cost tier.
    let cost: Int
    let needsAudio: Bool
}

/// The image-first tile face: full-bleed preview, name set over a scrim, and
/// the state glyphs in the top corners. Square and dense — the dashboard
/// pages four across on a phone, so type and glyphs are sized for that.
struct GVEffectTileFace: View {
    static let cornerRadius: CGFloat = 14
    let model: GVEffectTileModel

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { preview }
            .overlay(alignment: .bottom) { caption }
            .overlay(alignment: .top) { badges }
            .background(Color.white.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .overlay { GVEffectActiveRing(active: model.active, cornerRadius: Self.cornerRadius) }
    }

    @ViewBuilder
    private var preview: some View {
        if let image = model.image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .transition(.opacity)
        } else if model.previewUnavailable {
            Image(systemName: "eye.slash")
                .font(.title3.weight(.light))
                .foregroundStyle(GVTheme.bone.opacity(0.5))
                .accessibilityHidden(true)
        } else {
            GVTileShimmer()
        }
    }

    private var caption: some View {
        Text(model.name.uppercased())
            .font(GVTheme.mono(9, model.active ? .bold : .semibold))
            .foregroundStyle(GVTheme.bone)
            .lineLimit(2)
            .minimumScaleFactor(0.75)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.top, 16)
            .padding(.bottom, 5)
            .background {
                LinearGradient(colors: [.clear, .black.opacity(0.62), .black.opacity(0.86)],
                               startPoint: .top, endPoint: .bottom)
            }
    }

    private var badges: some View {
        HStack(spacing: 5) {
            if model.cost > 1 {
                GVCostPips(cost: model.cost)
            }
            if model.needsAudio {
                badge("waveform")
            }
            Spacer(minLength: 0)
            if model.favorite {
                badge("star.fill")
            }
            if model.active {
                badge("checkmark")
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .padding(4)
        .accessibilityHidden(true)
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 7.5, weight: .bold))
            .foregroundStyle(GVTheme.bone)
            .frame(width: 16, height: 16)
            .background(.black.opacity(0.55), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
    }
}

/// Render-cost tier as filled pips. Only drawn for the expensive tiers, so the
/// common case carries no glyph at all.
private struct GVCostPips: View {
    let cost: Int
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< 3, id: \.self) { index in
                Capsule()
                    .fill(GVTheme.bone.opacity(index < cost ? 0.95 : 0.25))
                    .frame(width: 3, height: 6)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 16)
        .background(.black.opacity(0.55), in: Capsule())
    }
}

/// A slow conic sweep around an active tile. It is the only animated element
/// on an idle grid, and only tiles that are actually rendering carry it.
private struct GVEffectActiveRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let active: Bool
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if active {
            TimelineView(GVAmbientClock.ambient(hertz: 30, scenePhase: scenePhase, isActive: !reduceMotion)) { clock in
                let turn = reduceMotion ? 0 : clock.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4
                shape
                    .strokeBorder(
                        AngularGradient(
                            colors: [GVTheme.bone.opacity(0.95), GVTheme.bone.opacity(0.18),
                                     GVTheme.bone.opacity(0.55), GVTheme.bone.opacity(0.18),
                                     GVTheme.bone.opacity(0.95)],
                            center: .center,
                            angle: .degrees(turn * 360)
                        ),
                        lineWidth: 1.5
                    )
                    .shadow(color: .white.opacity(0.28), radius: 8)
            }
            .transition(.opacity)
        } else {
            shape.strokeBorder(.white.opacity(0.07), lineWidth: 0.75)
        }
    }
}

/// Loading placeholder. A diagonal sheen passes over the empty plate while the
/// thumbnail store renders, so "not ready" reads as progress, not as broken.
private struct GVTileShimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        GeometryReader { geometry in
            LinearGradient(colors: [.clear, .white.opacity(0.09), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(width: geometry.size.width * 1.6)
                .offset(x: sweep ? geometry.size.width : -geometry.size.width * 1.6)
        }
        .clipped()
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: false)) { sweep = true }
        }
    }
}

/// Press response for tiles: a sink, a lift of the preview and a sheen.
///
/// The preview zoom is the face's own image scaling under a fixed clip, so the
/// tile's footprint never changes — neighbours do not shuffle while a finger
/// is down.
struct GVEffectTileStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: GVEffectTileFace.cornerRadius, style: .continuous)
                    .fill(.white.opacity(pressed ? 0.10 : 0))
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
            .scaleEffect(reduceMotion ? 1 : (pressed ? 0.955 : 1))
            .shadow(color: .black.opacity(pressed ? 0.2 : 0.4), radius: pressed ? 3 : 8, y: pressed ? 1 : 4)
            .animation(
                reduceMotion ? GVMotion.reduced : (pressed ? GVMotion.micro : .spring(response: 0.34, dampingFraction: 0.62)),
                value: pressed
            )
    }
}

extension View {
    /// Tiles tip back and fade as they scroll toward either edge, and settle
    /// flat in the middle of the grid.
    func gvTileScrollDepth(reduceMotion: Bool) -> some View {
        scrollTransition(.interactive, axis: .vertical) { content, phase in
            content
                .opacity(phase.isIdentity ? 1 : 0.55)
                .scaleEffect(reduceMotion || phase.isIdentity ? 1 : 0.94)
                .rotation3DEffect(.degrees(reduceMotion ? 0 : phase.value * -10),
                                  axis: (x: 1, y: 0, z: 0), perspective: 0.6)
        }
    }

    /// Staggered rise for the first screenful after a shelf change. Later
    /// tiles, created lazily as the grid scrolls, arrive without delay so a
    /// fast fling never waits on an entrance.
    func gvTileEntrance(index: Int, reduceMotion: Bool) -> some View {
        modifier(GVTileEntrance(index: index, reduceMotion: reduceMotion))
    }
}

private struct GVTileEntrance: ViewModifier {
    let index: Int
    let reduceMotion: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 18)
            .onAppear {
                guard !reduceMotion, !shown else { return }
                let delay = index < 12 ? Double(index) * 0.028 : 0
                withAnimation(.spring(response: 0.46, dampingFraction: 0.78).delay(delay)) { shown = true }
            }
    }
}
