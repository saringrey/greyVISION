import SwiftUI
import WebKit

/// The splash title: Neon Loop's two linked rings of extruded neon capitals
/// spelling GREY VISION, rendered by the bundled NeonLoop.html (a WebGL2 port
/// of the React component) in a transparent web view over the splash film.
struct GVNeonLoopTitle: UIViewRepresentable {
    var text = "GREY VISION · "
    var still = false

    func makeUIView(context _: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        load(into: view)
        return view
    }

    func updateUIView(_: WKWebView, context _: Context) {}

    private func load(into view: WKWebView) {
        guard let url = Bundle.main.url(forResource: "NeonLoop", withExtension: "html"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return }
        components.queryItems = [
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "still", value: still ? "1" : "0"),
            URLQueryItem(name: "zoom", value: "2.2"),
            URLQueryItem(name: "mono", value: "1"),
            // Monochrome: chalk white on the lit front falling to graphite.
            URLQueryItem(name: "colors", value: "#ffffff,#e4e6ea,#b9bdc4,#8a8f97,#5b5f66")
        ]
        guard let target = components.url else { return }
        view.loadFileURL(target, allowingReadAccessTo: url.deletingLastPathComponent())
    }
}
