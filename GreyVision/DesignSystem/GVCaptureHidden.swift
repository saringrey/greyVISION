import SwiftUI
import UIKit

/// Keeps a piece of interface out of screenshots and screen recordings while
/// it stays fully visible and usable on the glass.
///
/// iOS leaves the contents of a secure text field out of every capture:
/// system screenshots, Control Centre screen recording and ReplayKit, which
/// is what the take recorder uses. Hosting the view inside that field's
/// canvas gives it the same treatment, so a take shows the effected image and
/// not the effect menu used to make it.
///
/// The hosted view is a separate SwiftUI tree, so the caller's whole
/// environment (environment objects included) is forwarded into it.
struct GVCaptureHidden<Content: View>: View {
    @Environment(\.self) private var environment
    @ViewBuilder let content: () -> Content
    /// The hosted content's own height, reported back from inside the host
    /// so the outer layout sizes to it exactly.
    @State private var height: CGFloat = 0

    var body: some View {
        GVSecureHost(rootView: AnyView(
            content()
                .environment(\.self, environment)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
                    if abs(newHeight - height) > 0.5 { height = newHeight }
                }
                .frame(maxHeight: .infinity, alignment: .top)
        ))
        .frame(height: height)
    }
}

private struct GVSecureHost: UIViewRepresentable {
    let rootView: AnyView

    @MainActor
    final class Coordinator {
        let host: UIHostingController<AnyView>
        init(rootView: AnyView) {
            host = UIHostingController(rootView: rootView)
            host.view.backgroundColor = .clear
            host.safeAreaRegions = []
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(rootView: rootView)
    }

    func makeUIView(context: Context) -> UIView {
        let container = GVSecureContainer()
        container.backgroundColor = .clear
        let hostView = context.coordinator.host.view!
        hostView.translatesAutoresizingMaskIntoConstraints = false
        container.canvas.addSubview(hostView)
        NSLayoutConstraint.activate([
            hostView.leadingAnchor.constraint(equalTo: container.canvas.leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: container.canvas.trailingAnchor),
            hostView.topAnchor.constraint(equalTo: container.canvas.topAnchor),
            hostView.bottomAnchor.constraint(equalTo: container.canvas.bottomAnchor),
        ])
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.host.rootView = rootView
    }
}

/// A view whose `canvas` is the secure field's capture-excluded layer.
/// Falls back to an ordinary view (visible in captures) if UIKit ever stops
/// exposing that layer, so the interface never disappears from the glass.
private final class GVSecureContainer: UIView {
    let canvas: UIView
    private let field = UITextField()

    init() {
        field.isSecureTextEntry = true
        if let secure = field.subviews.first {
            secure.subviews.forEach { $0.removeFromSuperview() }
            secure.isUserInteractionEnabled = true
            canvas = secure
        } else {
            canvas = UIView()
        }
        super.init(frame: .zero)
        canvas.translatesAutoresizingMaskIntoConstraints = false
        addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.topAnchor.constraint(equalTo: topAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

extension View {
    /// Visible on screen, absent from screenshots and recordings.
    func gvHiddenFromCapture() -> some View {
        GVCaptureHidden { self }
    }
}
