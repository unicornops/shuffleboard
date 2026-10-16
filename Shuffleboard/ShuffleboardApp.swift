import SwiftUI

@main
struct ShuffleboardApp: App {
    // Not @StateObject: the app's body would then be rebuilt, menu bar and all, on every change to the app's state,
    // which made the toolbar flicker while dragging cards. The app is created once, so these live as long as it.
    private let appState: AppState
    private let commandState: BoardCommandState
    private let backgroundWork: BackgroundWork
    @StateObject private var updater = SoftwareUpdater()

    init() {
        let appState = AppState.atLaunch()
        let commandState = BoardCommandState(appState: appState)
        self.appState = appState
        self.commandState = commandState
        // Before the app finishes launching, so a click on a notification that launches it isn't missed.
        CardReminderClicks.shared.start()
        self.backgroundWork = BackgroundWork(appState: appState, commandState: commandState)
    }

    var body: some Scene {
        // Each window shows a board of its own (#160); SwiftUI restores them, with their boards, at launch.
        WindowGroup(for: BoardWindowValue.self) { $value in
            BoardWindowRoot(
                appState: appState,
                commandState: commandState,
                backgroundWork: backgroundWork,
                value: $value
            )
            #if DEBUG
            .onAppear { UITestLaunch.applyAppearance() }
            #endif
        } defaultValue: {
            BoardWindowValue()
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1000, height: 700)
        .commands {
            BoardCommands(appState: appState, state: commandState)
            CommandGroup(replacing: .appInfo) {
                AboutButton()
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
        // A window of its own, so it doesn't open in every board window.
        Window("About Shuffleboard", id: AboutSheet.windowId) {
            AboutSheet()
        }
        .windowResizability(.contentSize)
        Settings {
            SettingsView(updater: updater)
                .environmentObject(appState)
        }
    }
}
