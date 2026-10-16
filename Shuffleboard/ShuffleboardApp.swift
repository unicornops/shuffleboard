import SwiftUI

@main
struct ShuffleboardApp: App {
    // Not @StateObject: the app's body would then be rebuilt, menu bar and all, on every change to the app's state,
    // which made the toolbar flicker while dragging cards. The app is created once, so these live as long as it.
    private let appState: AppState
    private let commandState: BoardCommandState
    @StateObject private var updater = SoftwareUpdater()

    init() {
        let appState = AppState.atLaunch()
        self.appState = appState
        self.commandState = BoardCommandState(appState: appState)
        // Before the app finishes launching, so a click on a notification that launches it isn't missed.
        CardReminderClicks.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            BoardWindowRoot(appState: appState, commandState: commandState)
                #if DEBUG
                .onAppear { UITestLaunch.applyAppearance() }
                #endif
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1000, height: 700)
        .commands {
            BoardCommands(appState: appState, state: commandState)
            CommandGroup(replacing: .appInfo) {
                Button("About Shuffleboard") {
                    appState.showingAbout = true
                }
                CheckForUpdatesButton(updater: updater)
            }
            CommandGroup(replacing: .help) {
                Button("Deck API Reference") {
                    if let url = URL(string: "https://deck.readthedocs.io/en/latest/API/") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        Settings {
            SettingsView(updater: updater)
                .environmentObject(appState)
        }
    }
}
