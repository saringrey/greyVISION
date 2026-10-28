import SwiftUI

/// Glyph-level corruption: characters swapped for block and symbol glyphs,
/// re-rolled at 20 Hz so the damage crawls rather than sitting still.
enum GVGlyphCorruption {
    private static let glyphs = Array("░▒▓█#%&@$/\\<>_=+*01")

    static func apply(_ text: String, amount: Double, salt: Int, time: Double) -> String {
        guard amount > 0 else { return text }
        let tick = (time * 20).rounded(.down)
        return String(text.enumerated().map { index, character in
            guard character != " ", character != "\n" else { return character }
            let roll = GVTerminalBootTimeline.hash(Double(salt * 97 + index) + tick * 13.1)
            guard roll < amount else { return character }
            return glyphs[Int(roll * 1000) % glyphs.count]
        })
    }
}

/// Windows 95 system colours, for the two screens that borrow its look.
private enum GVWin95 {
    static let face = Color(red: 0.753, green: 0.753, blue: 0.753)
    static let shadow = Color(red: 0.502, green: 0.502, blue: 0.502)
    static let highlight = Color.white
    static let navy = Color(red: 0, green: 0, blue: 0.502)
    static let stopBlue = Color(red: 0, green: 0, blue: 0.667)
    static let stopGrey = Color(red: 0.667, green: 0.667, blue: 0.667)
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
/// the codec selection screen it hands over to — that never finishes.
struct GVBootSetupDialog: View {
    /// Bar position, 0...1.
    let load: Double

    private static let messages = [
        "Copying files...",
        "Loading SHADER.VXD",
        "Loading CAPTURE.DRV",
        "Loading TRACKING.DLL",
        "Loading CODEC.VXD",
    ]
    private static let blocks = 22

    var body: some View {
        let message = Self.messages[min(Int(load / 0.87 * Double(Self.messages.count)), Self.messages.count - 1)]
        VStack(spacing: 0) {
            titleBar
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 26))
                        .foregroundStyle(.black)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("grey//VISION Setup is preparing the codec drivers.")
                        Text(message).foregroundStyle(GVWin95.navy)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.black)
                }
                progressBox
                HStack {
                    Text("\(Int(load * 100))% complete")
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
        .background(GVWin95.navy)
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

/// Stage three: the fatal exception. A Win95 stop screen, blamed on the
/// codec driver, corrupting more the longer it is on screen.
struct GVBootFatalException: View {
    let corruption: Double
    let cursorOn: Bool
    let time: Double

    private static let body1 = """
    A fatal exception 0E has occurred at 0028:C0DEC0DE in VXD CODEC(01) + 00004A1F. \
    The current application will be terminated.
    """
    private static let body2 = """
    *  Press any key to terminate the current application.
    *  Press CTRL+ALT+DEL again to restart your device. You will
       lose any unsaved information in all applications.
    """

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 500
            ZStack {
                GVWin95.stopBlue
                VStack(spacing: compact ? 12 : 22) {
                    Text(" grey//VISION ")
                        .font(GVTheme.mono(14, .bold))
                        .foregroundStyle(GVWin95.stopBlue)
                        .background(GVWin95.stopGrey)
                    VStack(alignment: .leading, spacing: compact ? 10 : 18) {
                        Text(GVGlyphCorruption.apply(Self.body1, amount: corruption, salt: 1, time: time))
                        Text(GVGlyphCorruption.apply(Self.body2, amount: corruption, salt: 2, time: time))
                    }
                    .font(GVTheme.mono(12, .medium))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    Text("Press any key to continue \(cursorOn ? "█" : " ")")
                        .font(GVTheme.mono(12, .medium))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, compact ? 80 : 26)
            }
        }
    }
}
