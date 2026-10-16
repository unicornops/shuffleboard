import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var appState: AppState
    @State private var serverInput = ""
    @FocusState private var serverFieldFocused: Bool

    private var serverURL: URL? {
        var s = serverInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasPrefix("http") {
            s = "https://" + s
        }
        // Require HTTPS for security (App Store and best practice).
        if s.hasPrefix("http://") {
            s = "https://" + s.dropFirst(7)
        }
        return URL(string: s)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 28) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 56, weight: .medium))
                    .foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative)

                Text(appState.isLoggedIn ? "Add Account" : "Shuffleboard")
                    .font(.title.weight(.semibold))

                Text(
                    appState.isLoggedIn
                        ? "Sign in to another account. You can switch between accounts from the account menu."
                        : "Sign in with your Nextcloud server to view and manage your Deck boards."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Server URL")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("https://your-nextcloud.com", text: $serverInput)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.URL)
                        .focused($serverFieldFocused)
                        .onSubmit { signIn() }
                }
                .frame(width: 320)

                if let msg = appState.errorMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    signIn()
                } label: {
                    Group {
                        if appState.isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.9)
                        } else {
                            SwiftUI.Label("Sign in with browser", systemImage: "safari")
                        }
                    }
                    .frame(width: 320, height: 36)
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isLoading || serverURL == nil)
                .keyboardShortcut(.return, modifiers: .command)

                if appState.isLoggedIn, !appState.isLoading {
                    Button("Cancel") {
                        appState.cancelAddingAccount()
                    }
                    .keyboardShortcut(.cancelAction)
                }

                if appState.isLoading {
                    VStack(spacing: 8) {
                        Text("Finish signing in in your browser, then come back here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Cancel") {
                            appState.cancelLogin()
                        }
                        .keyboardShortcut(.cancelAction)
                    }
                    .frame(maxWidth: 320)
                }
            }
            .padding(40)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 20, y: 10)

            Spacer()

            Text(
                "Credentials are stored securely in the Keychain.\n"
                    + "Shuffleboard is an unofficial client, not affiliated with Nextcloud."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            .padding(.bottom, 24)
        }
        .frame(minWidth: 480, minHeight: 480)
        .onAppear {
            serverFieldFocused = true
        }
    }

    private func signIn() {
        guard let url = serverURL else { return }
        appState.startBrowserLogin(serverURL: url)
    }
}

#Preview {
    LoginView()
        .previewEnvironment()
}
