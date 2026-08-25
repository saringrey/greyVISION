@preconcurrency import AVFoundation
import SwiftUI
import UIKit

struct RawCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let position: CapturePosition
    let onFocus: @MainActor (CGPoint) -> Void

    func makeUIView(context _: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.previewLayer.session = session
        view.position = position
        view.onFocus = onFocus
        return view
    }

    func updateUIView(_ view: CameraPreviewUIView, context _: Context) {
        if view.previewLayer.session !== session {
            view.previewLayer.session = session
        }
        view.position = position
        view.onFocus = onFocus
        view.updateConnectionGeometry()
    }

    static func dismantleUIView(_ view: CameraPreviewUIView, coordinator _: Void) {
        view.onFocus = nil
        view.previewLayer.session = nil
    }
}

final class CameraPreviewUIView: UIView {
    var onFocus: (@MainActor (CGPoint) -> Void)?
    var position = CapturePosition.rear

    override static var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let previewLayer = layer as? AVCaptureVideoPreviewLayer else {
            preconditionFailure("CameraPreviewUIView requires AVCaptureVideoPreviewLayer")
        }
        return previewLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
        isAccessibilityElement = true
        accessibilityLabel = "Raw camera preview. Tap to focus."
        accessibilityIdentifier = "camera.raw.preview"
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        updateConnectionGeometry()
    }

    func updateConnectionGeometry() {
        guard let connection = previewLayer.connection else { return }
        let interfaceOrientation = window?.windowScene?.interfaceOrientation ?? .portrait
        let angle: CGFloat = switch interfaceOrientation {
        case .portrait:
            90
        case .portraitUpsideDown:
            270
        case .landscapeLeft:
            0
        case .landscapeRight:
            180
        default:
            90
        }
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = position == .front
    }

    @objc
    private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let layerPoint = recognizer.location(in: self)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        onFocus?(devicePoint)
        showFocusReticle(at: layerPoint)
    }

    private func showFocusReticle(at point: CGPoint) {
        let reticle = CAShapeLayer()
        reticle.name = "gv.focus.reticle"
        reticle.bounds = CGRect(x: 0, y: 0, width: 54, height: 54)
        reticle.position = point
        reticle.path = UIBezierPath(rect: reticle.bounds.insetBy(dx: 2, dy: 2)).cgPath
        reticle.strokeColor = UIColor(red: 0.72, green: 0.35, blue: 1, alpha: 0.95).cgColor
        reticle.fillColor = UIColor.clear.cgColor
        reticle.lineWidth = 1
        previewLayer.sublayers?
            .filter { $0.name == "gv.focus.reticle" }
            .forEach { $0.removeFromSuperlayer() }
        previewLayer.addSublayer(reticle)

        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 1.25
        animation.toValue = 0.82
        animation.duration = 0.24
        animation.autoreverses = true
        reticle.add(animation, forKey: "focus")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak reticle] in
            reticle?.removeFromSuperlayer()
        }
    }
}
