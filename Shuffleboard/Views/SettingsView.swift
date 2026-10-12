import SwiftUI

/// Shuffleboard > Settings… (⌘,) (#165). Changes apply straight away; everything is kept in `UserDefaults`, never
/// credentials.
struct SettingsView: View {
    @ObservedObject var updater: SoftwareUpdater

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            NotificationSettings()
                .tabItem { Label("Notifications", systemImage: "bell") }
            UpdateSettings(updater: updater)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 460)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage(AppSettings.refreshIntervalKey) private var refreshInterval = AppSettings.defaultRefreshInterval
    @AppStorage(AppSettings.refreshWhenActivatedKey) private var refreshWhenActivated = true
    @AppStorage(AppSettings.launchAccountKey) private var launchAccount = ""

    var body: some View {
        Form {
            Section {
                Picker("Check for changes", selection: $refreshInterval) {
                    ForEach(AppSettings.refreshIntervals, id: \.self) { seconds in
                        Text(AppSettings.refreshIntervalTitle(seconds)).tag(seconds)
                    }
                }
                .accessibilityIdentifier("refresh interval")
                Toggle("Check when Shuffleboard comes to the front", isOn: $refreshWhenActivated)
                    .accessibilityIdentifier("refresh when activated")
            } header: {
                Text("Changes made elsewhere")
            } footer: {
                footnote("Changes on the web or in other apps show up at these times; ⌘R refreshes any time.")
            }
            if appState.accounts.count > 1 {
                Section("At launch") {
                    Picker("Open", selection: launchAccountSelection) {
                        Text("The account used last").tag("")
                        ForEach(appState.accounts) { account in
                            Text(account.id).tag(account.id)
                        }
                    }
                    .accessibilityIdentifier("launch account")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// An account that has since signed out reads as the one used last, which is what happens at launch then.
    private var launchAccountSelection: Binding<String> {
        Binding(
            get: { appState.accounts.contains { $0.id == launchAccount } ? launchAccount : "" },
            set: { launchAccount = $0 }
        )
    }
}

// MARK: - Notifications

private struct NotificationSettings: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage(CardReminderSync.dueRemindersKey) private var remindDue = true
    @AppStorage(CardReminderSync.assignedRemindersKey) private var notifyAssigned = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $remindDue) {
                    Text("Due dates")
                    Text("A day before a card is due, and when it's due, for the cards Deck notifies you about.")
                }
                .accessibilityIdentifier("due date notifications")
                Toggle(isOn: $notifyAssigned) {
                    Text("New assignments")
                    Text("When someone assigns a card to you.")
                }
                .accessibilityIdentifier("assignment notifications")
            } footer: {
                footnote(
                    "Shuffleboard checks your boards while it's open. Due date reminders are scheduled ahead, so they "
                        + "arrive even after you quit. Reminders are for the account you're using."
                )
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: remindDue) { updateReminders() }
        .onChange(of: notifyAssigned) { updateReminders() }
    }

    private func updateReminders() {
        Task { await appState.updateReminders() }
    }
}

// MARK: - Updates

private struct UpdateSettings: View {
    @ObservedObject var updater: SoftwareUpdater

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                    .accessibilityIdentifier("check for updates automatically")
                Toggle("Download and install updates automatically", isOn: $updater.automaticallyDownloadsUpdates)
                    .disabled(!updater.automaticallyChecksForUpdates)
                    .accessibilityIdentifier("install updates automatically")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    footnote("Updates are checked once a day. Automatic installs happen when you quit.")
                    Spacer()
                    Button("Check Now") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private func footnote(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
}
