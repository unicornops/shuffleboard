import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.showingLogin {
                LoginView()
            } else {
                mainInterface
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.showingLogin)
        .sheet(isPresented: $appState.showingAbout) {
            AboutSheet()
        }
    }

    /// How often to look for changes, from Settings; changing it restarts the refresh loop.
    @AppStorage(AppSettings.refreshIntervalKey) private var refreshInterval = AppSettings.defaultRefreshInterval

    private var mainInterface: some View {
        NavigationSplitView {
            BoardListView()
        } detail: {
            BoardDetailView()
        }
        .actionErrorBanner(appState)
        .task {
            await appState.loadBoardsIfNeeded()
            await appState.updateReminders()
        }
        // Pick up changes made elsewhere: when the app comes back to the front, and every so often while open
        // (each check is a 304 with no body when nothing has changed). Both are set in Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await appState.appDidBecomeActive() }
        }
        .task(id: refreshInterval) {
            await appState.refreshPeriodically()
        }
        .onReceive(CardReminderClicks.shared.$clicked) { clicked in
            guard let clicked else { return }
            CardReminderClicks.shared.clicked = nil
            Task { await appState.openCard(id: clicked.cardId, boardId: clicked.boardId, accountId: clicked.accountId) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    accountSection
                    Divider()
                    Button("About Shuffleboard", systemImage: "info.circle") {
                        appState.showingAbout = true
                    }
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await appState.refresh() }
                    }
                } label: {
                    Image(systemName: "person.circle")
                }
                .help(appState.activeAccount.map { "Signed in as \($0.id)" } ?? "Account and actions")
                .accessibilityLabel("Account menu")
            }
        }
    }
}

// MARK: - Accounts

private extension ContentView {
    /// The signed-in accounts, with the active one ticked, plus adding and signing out of accounts.
    @ViewBuilder
    var accountSection: some View {
        Picker("Account", selection: activeAccountId) {
            ForEach(appState.accounts) { account in
                Text(account.id)
                    .tag(Optional(account.id))
            }
        }
        .pickerStyle(.inline)
        Button("Add Account…", systemImage: "person.badge.plus") {
            appState.addAccount()
        }
        if let account = appState.activeAccount {
            Button("Sign Out of \(account.id)", systemImage: "rectangle.portrait.and.arrow.right") {
                Task { await appState.signOut() }
            }
        }
    }

    var activeAccountId: Binding<Account.ID?> {
        Binding(
            get: { appState.activeAccount?.id },
            set: { id in
                guard let account = appState.accounts.first(where: { $0.id == id }) else { return }
                Task { await appState.switchAccount(to: account) }
            }
        )
    }
}

private enum BuildMetadata {
    /// String values from BuildInfo.plist (written by the "Write Build Info" build phase).
    private static let buildInfo: [String: String] = {
        guard let url = Bundle.main.url(forResource: "BuildInfo", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return [:]
        }
        return info.compactMapValues { $0 as? String }
    }()

    static let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Shuffleboard"
    static let version = buildInfo["BuildVersion"]
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "Unknown"
    static let buildNumber = buildInfo["BuildNumber"]
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        ?? "Unknown"
    static let gitCommit = buildInfo["BuildGitCommit"]
        ?? Bundle.main.object(forInfoDictionaryKey: "BuildGitCommit") as? String
        ?? "unknown"
    static let buildRef = buildInfo["BuildRef"]
        ?? Bundle.main.object(forInfoDictionaryKey: "BuildRef") as? String
        ?? "local"
    static let buildDateUTC = buildInfo["BuildDateUTC"]
        ?? Bundle.main.object(forInfoDictionaryKey: "BuildDateUTC") as? String
        ?? "unknown"

    /// Nextcloud's trademark guidelines ask third-party clients to say they are not the official client.
    static let unofficialNotice = "An unofficial client for Nextcloud Deck. "
        + "Shuffleboard is an independent project and is not affiliated with or endorsed by Nextcloud."

    static var shortCommit: String {
        gitCommit == "unknown" ? gitCommit : String(gitCommit.prefix(7))
    }

    static var summary: String {
        """
        Version: \(version)
        Build: \(buildNumber)
        Ref: \(buildRef)
        Commit: \(gitCommit)
        Built: \(buildDateUTC)
        """
    }
}

private struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(spacing: 4) {
                Text(BuildMetadata.appName)
                    .font(.title2.weight(.semibold))
                Text("Version \(BuildMetadata.version) (\(BuildMetadata.buildNumber))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(BuildMetadata.unofficialNotice)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    metadataLabel("Ref")
                    metadataValue(BuildMetadata.buildRef)
                }
                GridRow {
                    metadataLabel("Commit")
                    metadataValue(BuildMetadata.shortCommit)
                }
                GridRow {
                    metadataLabel("Built")
                    metadataValue(BuildMetadata.buildDateUTC)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack {
                Button("Copy Build Info") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(BuildMetadata.summary, forType: .string)
                }
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func metadataLabel(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
    }

    private func metadataValue(_ value: String) -> some View {
        Text(value)
            .textSelection(.enabled)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
