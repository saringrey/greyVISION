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
    static let cornerRadius: CGFloat = 4
    let model: GVEffectTileModel

    var body: some View {
        VStack(spacing: 4) {
            preview
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(model.active ? 0.5 : 0.08),
                                      lineWidth: model.active ? 1 : 0.75)
                }
                .overlay {
                    // A live effect is a tracked object, as on the splash.
                    if model.active {
                        GVTrackerBrackets(arm: 10)
                            .stroke(GVSplashDock.lime, style: StrokeStyle(lineWidth: 1, lineCap: .square))
                            .padding(-2)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .topTrailing) { badges }
            Text(model.name)
                .gvSystemFont(11.5, model.active ? .semibold : .medium, maxScale: 1.3)
                .foregroundStyle(model.active ? GVTheme.bone : GVTheme.bone.opacity(0.8))
                .lineLimit(2)
                // A single long word ("Burnthrough") shrinks to fit rather
                // than breaking mid-word onto a second line.
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .top)
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

/// Static loading placeholder. Distilled: no animated sweep, just a quiet plate.
private struct GVTileShimmer: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.045))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.05), lineWidth: 0.75)
                    .padding(12)
            }
            .accessibilityHidden(true)
    }
}

/// Press response for tiles: a sink, a lift of the preview and a sheen.
///
/// The preview zoom is the face's own image scaling under a fixed clip, so the
/// tile's footprint never changes — neighbours do not shuffle while a finger
/// is down.
struct GVEffectTileStyle: ButtonStyle {
    static let cornerRadius: CGFloat = 4
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
                reduceMotion ? GVMotion.reduced : GVMotion.softPress(pressed),
                value: pressed
            )
    }
}

extension View {
    /// Distilled: keep tiles visually stable while scrolling (no 3D tilt/fade).
    func gvTileScrollDepth(reduceMotion: Bool) -> some View {
        self
    }

    /// Distilled: no staggered entrance animation; content appears immediately.
    func gvTileEntrance(index: Int, reduceMotion: Bool) -> some View {
        self
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
