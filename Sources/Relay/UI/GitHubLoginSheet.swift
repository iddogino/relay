import AppKit
import SwiftUI

/// Device-flow login: shows the user code to enter at
/// github.com/login/device while Relay polls for the token in the
/// background.
struct GitHubLoginSheet: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Log In to GitHub")
                .font(.title3.weight(.semibold))

            switch model.gitHubLogin {
            case nil:
                intro
            case .requesting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Requesting a login code…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            case .waiting(let code, let url):
                waiting(code: code, url: url)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 10) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Button("Try Again") { model.beginGitHubLogin() }
                }
            }

            HStack {
                Spacer()
                Button(model.gitHubLogin == nil ? "Close" : "Cancel") {
                    model.cancelGitHubLogin()
                    model.gitHubLoginPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        // Any exit path (Esc, success, Cancel) stops the poll loop.
        .onDisappear { model.cancelGitHubLogin() }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Relay shows pull-request status — checks and mergeability — via the GitHub API. Log in with a one-time code at github.com; Relay never sees your password, and keeps the sign-in in your keychain.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Get Login Code") {
                model.beginGitHubLogin()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func waiting(code: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter this code at \(url.absoluteString.replacingOccurrences(of: "https://", with: "")):")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Text(code)
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .textSelection(.enabled)
                Button {
                    copyCode(code)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy code")
            }

            HStack(spacing: 12) {
                Button("Open GitHub…") {
                    copyCode(code)
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for authorization…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func copyCode(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }
}
