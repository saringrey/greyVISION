import SwiftUI

/// About panel opened from the Settings deck. It holds the version line and
/// two sub-pages: Credits and the Privacy Policy, which is an empty
/// placeholder until the real policy text is written.
struct GVAboutOverlay: View {
    @Binding var isPresented: Bool

    private enum Page { case about, credits, privacy }
    @State private var page: Page = .about
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "5.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "VERSION \(version) (\(build))"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Dismiss about panel")
                .accessibilityAddTraits(.isButton)

            Group {
                switch page {
                case .about: aboutPage
                case .credits: creditsPage
                case .privacy: privacyPage
                }
            }
            .frame(maxWidth: 360)
            .padding(GVMetrics.stepSection)
            .transition(.opacity)
        }
        .accessibilityIdentifier("about.overlay")
    }

    private func go(_ next: Page) {
        withAnimation(GVMotion.resolved(GVMotion.collapse, reduceMotion: reduceMotion)) {
            page = next
        }
    }

    // MARK: Pages

    private var aboutPage: some View {
        GVPanel("ABOUT") {
            VStack(spacing: GVMetrics.gapTight) {
                VStack(spacing: 6) {
                    Text("greyVISION")
                        .gvMono(18, .bold)
                        .tracking(2)
                        .foregroundStyle(GVTheme.bone)
                    Text(versionLine)
                        .gvMono(8, .medium)
                        .tracking(1.4)
                        .foregroundStyle(GVTheme.ash)
                    Text("Live camera effects, rendered on device with Metal.")
                        .gvMono(9, .medium)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(GVTheme.ash)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, GVMetrics.stepRelated)

                row(symbol: "person.2", label: "CREDITS", id: "about.credits") { go(.credits) }
                row(symbol: "hand.raised", label: "PRIVACY POLICY", id: "about.privacy") { go(.privacy) }
                GVInstrumentButton(label: "CLOSE", symbol: "xmark", action: { isPresented = false })
            }
            .padding(GVMetrics.stepRelated)
        }
    }

    private var creditsPage: some View {
        GVPanel("CREDITS") {
            VStack(spacing: GVMetrics.gapTight) {
                VStack(alignment: .leading, spacing: 12) {
                    credit(role: "CREATED BY", name: "GREY")
                    credit(role: "DESIGN + DEVELOPMENT", name: "GREY")
                    credit(role: "BUILT WITH", name: "SwiftUI, Metal, AVFoundation")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, GVMetrics.stepRelated)

                GVInstrumentButton(label: "BACK", symbol: "chevron.left", action: { go(.about) })
            }
            .padding(GVMetrics.stepRelated)
        }
        .accessibilityIdentifier("about.credits.page")
    }

    private var privacyPage: some View {
        GVPanel("PRIVACY POLICY") {
            VStack(spacing: GVMetrics.gapTight) {
                // Placeholder: intentionally empty until the policy is written.
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 160)

                GVInstrumentButton(label: "BACK", symbol: "chevron.left", action: { go(.about) })
            }
            .padding(GVMetrics.stepRelated)
        }
        .accessibilityIdentifier("about.privacy.page")
    }

    // MARK: Pieces

    private func credit(role: String, name: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(role)
                .gvMono(8, .bold)
                .tracking(1.4)
                .foregroundStyle(GVTheme.violet)
            Text(name)
                .gvMono(10, .medium)
                .foregroundStyle(GVTheme.bone)
        }
    }

    private func row(symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: GVMetrics.stepInternal) {
                Image(systemName: symbol)
                    .frame(width: 22)
                    .foregroundStyle(GVTheme.violet)
                Text(label)
                    .gvMono(9, .bold)
                    .tracking(1.4)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(GVTheme.bone)
            .padding(GVMetrics.stepRelated)
            .background(GVTheme.surfacePrimary)
            .overlay(Rectangle().strokeBorder(GVTheme.separator, lineWidth: GVMetrics.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(GVPressStyle())
        .accessibilityIdentifier(id)
    }
}
