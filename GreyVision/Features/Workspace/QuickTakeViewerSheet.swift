import AVKit
import SwiftUI

struct QuickTakeViewerSheet: View {
    let capture: GVLastCapture
    @Binding var isPresented: Bool

    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            GVPanel("MEDIA // QUICK TAKE") {
                VStack(spacing: GVMetrics.gapTight) {
                    mediaContent
                        .frame(maxWidth: .infinity)
                        .frame(height: 360)
                        .clipped()
                        .background(Color.black)
                        .overlay(
                            Rectangle()
                                .strokeBorder(GVTheme.separator, lineWidth: GVMetrics.hairline)
                        )

                    HStack(spacing: 8) {
                        switch capture.mediaType {
                        case let .still(image):
                            ShareLink(
                                item: Image(uiImage: UIImage(cgImage: image)),
                                preview: SharePreview("greyVISION Still", image: Image(uiImage: UIImage(cgImage: image)))
                            ) {
                                HStack(spacing: 4) {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("SHARE")
                                }
                                .gvMono(9, .bold)
                                .tracking(1.4)
                                .foregroundStyle(GVTheme.bone)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(GVTheme.violetDeep.opacity(0.55))
                                .overlay(Rectangle().strokeBorder(GVTheme.separator, lineWidth: GVMetrics.hairline))
                            }
                        case let .video(url):
                            ShareLink(item: url) {
                                HStack(spacing: 4) {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("SHARE")
                                }
                                .gvMono(9, .bold)
                                .tracking(1.4)
                                .foregroundStyle(GVTheme.bone)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(GVTheme.violetDeep.opacity(0.55))
                                .overlay(Rectangle().strokeBorder(GVTheme.separator, lineWidth: GVMetrics.hairline))
                            }
                        }

                        Spacer()

                        GVInstrumentButton(label: "CLOSE", symbol: "xmark") {
                            player?.pause()
                            isPresented = false
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(14)
            }
            .frame(maxWidth: 380)
            .padding(20)
        }
        .onAppear {
            if case let .video(url) = capture.mediaType {
                let avPlayer = AVPlayer(url: url)
                avPlayer.actionAtItemEnd = .none
                NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: avPlayer.currentItem,
                    queue: .main
                ) { _ in
                    avPlayer.seek(to: .zero)
                    avPlayer.play()
                }
                self.player = avPlayer
                avPlayer.play()
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    @ViewBuilder private var mediaContent: some View {
        switch capture.mediaType {
        case let .still(image):
            Image(uiImage: UIImage(cgImage: image))
                .resizable()
                .scaledToFit()
        case .video:
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView()
                    .tint(GVTheme.violet)
            }
        }
    }
}
