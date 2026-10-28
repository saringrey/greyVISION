import SwiftUI

/// Windows 95 system colours, for the setup dialog that borrows its look.
private enum GVWin95 {
    static let face = Color(red: 0.753, green: 0.753, blue: 0.753)
    static let shadow = Color(red: 0.502, green: 0.502, blue: 0.502)
    static let highlight = Color.white
    static let navy = Color(red: 0, green: 0, blue: 0.502)
    /// The inactive title bar Win95 drew once a window stopped responding.
    static let inactiveTitle = Color(red: 0.502, green: 0.502, blue: 0.502)
}

/// The raised (or sunken) two-tone bevel every Win95 control is built from.
private struct GVWin95Bevel: ViewModifier {
    var sunken = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(sunken ? GVWin95.shadow : GVWin95.highlight).frame(height: 1)
                    Rectangle().fill(sunken ? GVWin95.shadow : GVWin95.highlight).frame(width: 1)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                ZStack(alignment: .bottomTrailing) {
                    Rectangle().fill(sunken ? GVWin95.highlight : Color.black).frame(height: 1)
                    Rectangle().fill(sunken ? GVWin95.highlight : Color.black).frame(width: 1)
                }
            }
    }
}

/// Stage two of the cold start: a setup dialog loading "codec drivers" —
/// the codec selection screen it hands over to — that never finishes. When
/// it fails it says so plainly, the way an installer would: no drama, the
/// title bar greys out and the message changes.
struct GVBootSetupDialog: View {
    /// Bar position, 0...1.
    let load: Double
    var failed = false

    private static let messages = [
        "Copying files...",
        "Checking system configuration...",
        "Loading METAL.VXD",
        "Loading SHADER.VXD",
        "Loading CAPTURE.DRV",
        "Loading AUDIODSP.DRV",
        "Loading TRACKING.DLL",
        "Building effect graph...",
        "Loading CODEC.VXD",
    ]
    private static let blocks = 22

    var body: some View {
        let message = Self.messages[min(Int(load / 0.87 * Double(Self.messages.count)), Self.messages.count - 1)]
        VStack(spacing: 0) {
            titleBar
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: failed ? "exclamationmark.triangle" : "desktopcomputer")
                        .font(.system(size: 26))
                        .foregroundStyle(.black)
                    VStack(alignment: .leading, spacing: 3) {
                        if failed {
                            Text("Setup could not load CODEC.VXD.")
                            Text("The device is not responding.")
                        } else {
                            Text("grey//VISION Setup is preparing the codec drivers.")
                            Text(message).foregroundStyle(GVWin95.navy)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.black)
                }
                progressBox
                HStack {
                    Text(failed ? "Setup cannot continue." : "\(Int(load * 100))% complete")
                        .font(.system(size: 11))
                        .foregroundStyle(.black)
                        .monospacedDigit()
                    Spacer()
                    Text("Cancel")
                        .font(.system(size: 11))
                        .foregroundStyle(.black)
                        .frame(width: 72, height: 22)
                        .background(GVWin95.face)
                        .modifier(GVWin95Bevel())
                }
            }
            .padding(12)
        }
        .background(GVWin95.face)
        .modifier(GVWin95Bevel())
        .frame(maxWidth: 320)
    }

    private var titleBar: some View {
        HStack(spacing: 6) {
            Text("grey//VISION Setup")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            Text("×")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.black)
                .frame(width: 16, height: 14)
                .background(GVWin95.face)
                .modifier(GVWin95Bevel())
        }
        .padding(.horizontal, 4)
        .frame(height: 20)
        .background(failed ? GVWin95.inactiveTitle : GVWin95.navy)
        .padding(3)
    }

    private var progressBox: some View {
        let filled = Int(load * Double(Self.blocks))
        return HStack(spacing: 2) {
            ForEach(0 ..< Self.blocks, id: \.self) { index in
                Rectangle()
                    .fill(index < filled ? GVWin95.navy : Color.clear)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(3)
        .frame(height: 22)
        .background(Color.white)
        .modifier(GVWin95Bevel(sunken: true))
    }
}
