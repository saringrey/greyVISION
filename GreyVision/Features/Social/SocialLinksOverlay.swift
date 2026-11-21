import SwiftUI

struct SocialLinksOverlay: View {
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Dismiss creator panel")
                .accessibilityAddTraits(.isButton)

            GVPanel("CREATOR // GREY") {
                // Layout is driven by the links, exactly as before, and the
                // mark is a background behind them. Sizing the panel from the
                // image instead — scaledToFill inside an aspectRatio — let the
                // image dictate width and pushed the panel off the display.
                VStack(spacing: GVMetrics.gapTight) {
                    socialLink(
                        symbol: "camera",
                        label: "INSTAGRAM",
                        handle: "@bigbabygrey",
                        destination: URL(string: "https://instagram.com/bigbabygrey")!
                    )
                    socialLink(
                        symbol: "chevron.left.forwardslash.chevron.right",
                        label: "GITHUB",
                        handle: "@saringrey",
                        destination: URL(string: "https://github.com/saringrey")!
                    )
                    GVInstrumentButton(label: "CLOSE", symbol: "xmark", action: { isPresented = false })
                }
                .padding(GVMetrics.stepRelated)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 300, alignment: .bottom)
                .background {
                    Image("CreatorMark")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        // Clipped to the panel's bounds, so filling the box
                        // cannot change the box.
                        .clipped()
                        .overlay { GVCreatorScreenEffect() }
                        .overlay {
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.30), .black.opacity(0.85)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                        .accessibilityHidden(true)
                }
                .clipped()
            }
            .frame(maxWidth: 360)
            .padding(GVMetrics.stepSection)
            .accessibilityIdentifier("creator.overlay")
        }
    }

    private func socialLink(symbol: String, label: String, handle: String, destination: URL) -> some View {
        Link(destination: destination) {
            HStack(spacing: GVMetrics.stepInternal) {
                Image(systemName: symbol)
                    .frame(width: 22)
                    .foregroundStyle(GVTheme.violet)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .gvMono(9, .bold)
                        .tracking(1.4)
                    Text(handle)
                        .gvMono(8, .medium)
                        .foregroundStyle(GVTheme.ash)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(GVTheme.bone)
            .padding(GVMetrics.stepRelated)
            .background(GVTheme.surfacePrimary)
            .overlay(Rectangle().strokeBorder(GVTheme.separator, lineWidth: GVMetrics.hairline))
        }
        .buttonStyle(GVPressStyle())
        .accessibilityIdentifier("creator.link.\(label.lowercased())")
    }
}
