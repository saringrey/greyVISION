import SwiftUI
import UIKit

/// Shows the pairing code a Mac app needs in order to accept this phone's
/// stream.
///
/// This exists because the link is authenticated by a key derived from a code
/// the user reads here and types into the Mac. Before, the phone derived that
/// key from a string literal compiled into the app and the Mac derived it from
/// the same literal, so the key was in the binary of anyone who downloaded it
/// — and the camera extension derived it from a real code instead, which is why
/// it could never connect to either.
///
/// The sheet is deliberately plain: a code, a way to copy it, and a way to
/// replace it. Anything that made the code look like a setting would invite the
/// reading that it is one.
struct GVPairingCodeSheet: View {
    let code: String
    let onRegenerate: () -> String
    let onDismiss: () -> Void

    @State private var copied = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives its own arrival so the scrim can fade while the card settles in
    /// from just under full size. Scaling the scrim too would pull a
    /// full-bleed layer off the screen edges mid-travel.
    @State private var hasArrived = false

    private var grouped: String {
        stride(from: 0, to: code.count, by: 4).map { offset -> String in
            let start = code.index(code.startIndex, offsetBy: offset)
            let end = code.index(start, offsetBy: min(4, code.distance(from: start, to: code.endIndex)))
            return String(code[start..<end])
        }.joined(separator: " ")
    }

    var body: some View {
        ZStack {
            Color.black.opacity(hasArrived ? 0.78 : 0).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                header

                Text(grouped)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(GVTheme.acid)
                    .textSelection(.enabled)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(GVTheme.bone.opacity(0.06))
                    )
                    .accessibilityIdentifier("workspace.pairing.code")

                Text("Type this into greyVISION virtual camera — or the Mac camera app — on the computer you want to attach. It is the only thing that lets one accept this phone's picture; nobody else on the network can see the stream without it.")
                    .font(.system(size: 12))
                    .foregroundStyle(GVTheme.bone.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)

                actions
            }
            .padding(22)
            .frame(maxWidth: 380)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(red: 0.07, green: 0.07, blue: 0.075))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(GVTheme.bone.opacity(0.14), lineWidth: 1)
            )
            .padding(.horizontal, 28)
            .opacity(hasArrived ? 1 : 0)
            .scaleEffect(reduceMotion || hasArrived ? 1 : 0.96)
        }
        .animation(GVMotion.resolved(GVMotion.tear, reduceMotion: reduceMotion), value: hasArrived)
        .onAppear { hasArrived = true }
        .accessibilityIdentifier("workspace.pairing.sheet")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MAC CAMERA PAIRING")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(GVTheme.bone.opacity(0.6))
            Text("Read this code on the Mac")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(GVTheme.bone)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                UIPasteboard.general.string = code
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    copied = false
                }
            } label: {
                Text(copied ? "COPIED" : "COPY")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(GVTheme.bone.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(GVTheme.bone.opacity(0.22), lineWidth: 1)
                    )
            }
            .buttonStyle(GVPressStyle())
            .accessibilityIdentifier("workspace.pairing.copy")

            Button {
                _ = onRegenerate()
                copied = false
            } label: {
                Text("NEW CODE")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(GVTheme.bone.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(GVTheme.bone.opacity(0.22), lineWidth: 1)
                    )
            }
            .buttonStyle(GVPressStyle())
            .accessibilityIdentifier("workspace.pairing.regenerate")

            Button {
                onDismiss()
            } label: {
                Text("CLOSE")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(GVTheme.bone.opacity(0.88))
                    )
            }
            .buttonStyle(GVPressStyle())
            .accessibilityIdentifier("workspace.pairing.close")
        }
    }
}