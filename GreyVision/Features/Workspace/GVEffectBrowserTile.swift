import SwiftUI

/// What one browser tile shows. Plain values, so the face can be reasoned
/// about without a thumbnail store or a running camera.
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

/// The image-first tile face.
///
/// A preview of what the effect actually does, rendered by the production
/// shader over a frame tapped from the live camera, with the effect's name
/// set plainly beneath it.
///
/// The picture is the point. An earlier version of this grid drew a small
/// procedural diagram per effect, and every effect in a family drew the same
/// diagram — a screenful of near-identical scribbles that the operator had
/// to decode before they could choose anything. A picture of the effect
/// needs no decoding: the tile says what it is.
///
/// The name sits below the image rather than over it. A caption on a scrim
/// has to fight the picture for the same square, and the effect's picture is
/// the more useful of the two.
struct GVEffectTileFace: View {
    static let cornerRadius: CGFloat = 14
    let model: GVEffectTileModel

    var body: some View {
        VStack(spacing: 6) {
            preview
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(model.active ? 0.9 : 0.09),
                                      lineWidth: model.active ? 1.5 : 0.75)
                }
                .overlay(alignment: .topTrailing) { badges }
            Text(model.name)
                .gvSystemFont(12.5, model.active ? .semibold : .medium, maxScale: 1.45)
                .foregroundStyle(model.active ? GVTheme.bone : GVTheme.bone.opacity(0.8))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                // Two lines are reserved whether or not the name fills them,
                // so a row of tiles stays a row of tiles however long the
                // names are and however large the type is set.
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .top)
        }
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
            // The effect cannot be previewed on this device. Say so quietly
            // rather than showing an empty plate that reads as a broken tile.
            Image(systemName: "eye.slash")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(GVTheme.bone.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.045))
                .accessibilityHidden(true)
        } else {
            GVTileShimmer()
        }
    }

    /// Only the state a creator can act on is drawn on the tile itself: that
    /// it is on, that they starred it, and that it listens to the
    /// microphone. Render cost is not drawn here — it is a property of the
    /// composition rather than of the effect, and it is spelled out in the
    /// tile's menu instead of adding a badge to every face.
    private var badges: some View {
        HStack(spacing: 4) {
            if model.needsAudio {
                badge("waveform", opacity: 0.85)
            }
            if model.favorite {
                badge("star.fill", opacity: 0.85)
            }
            Spacer(minLength: 0)
            if model.active {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(Color.black)
                    .frame(width: 17, height: 17)
                    .background(GVTheme.bone, in: Circle())
                    .accessibilityHidden(true)
            }
        }
        .padding(5)
        .accessibilityHidden(true)
    }

    private func badge(_ symbol: String, opacity: Double) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(GVTheme.bone.opacity(opacity))
            .frame(width: 17, height: 17)
            .background(.black.opacity(0.55), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
    }
}

/// Loading placeholder. A diagonal sheen passes over the empty plate while
/// the thumbnail store renders, so "not ready" reads as progress, not as
/// broken.
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
        .background(Color.white.opacity(0.045))
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
    static let cornerRadius: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: GVEffectTileStyle.cornerRadius, style: .continuous)
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
