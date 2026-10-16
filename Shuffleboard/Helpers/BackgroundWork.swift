import AppKit
import Combine

// MARK: - BackgroundWork

/// The work the app does for all its windows, once however many are open (#160):
/// - loading the boards and the reminders once signed in;
/// - looking for changes every so often and when the app comes to the front, as set in Settings (#165);
/// - trying the server again every 15 seconds while it can't be reached, so editing comes back on by itself (#156);
/// - saving the copy on the Mac at quit;
/// - opening the card of a clicked notification (#157) in the window in front, or the next window to open.
@MainActor
final class BackgroundWork {
    private let appState: AppState
    private let commandState: BoardCommandState
    private var subscriptions: Set<AnyCancellable> = []
    private var refreshTask: Task<Void, Never>?
    /// The background refresh interval `refreshTask` was started with; nil for never.
    private var refreshInterval: TimeInterval?
    private var reconnectTask: Task<Void, Never>?
    /// A clicked notification waiting for a window to open its card in.
    private var pendingClick: ClickedReminder?

    /// How long to wait between tries while the server can't be reached.
    private static let reconnectInterval: Duration = .seconds(15)

    init(appState: AppState, commandState: BoardCommandState) {
        self.appState = appState
        self.commandState = commandState
        restartRefreshing()

        // Signed in, at launch or later: the boards (again, as the main window used to) and the reminders.
        appState.$showingLogin
            .removeDuplicates()
            .filter { !$0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.signedIn()
                }
            }
            .store(in: &subscriptions)
        appState.$connectionProblem
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] problem in
                MainActor.assumeIsolated {
                    self?.connectionChanged(problem)
                }
            }
            .store(in: &subscriptions)
        // Settings writes the refresh interval to the user defaults; a new one restarts the refresh loop.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AppSettings.refreshInterval() != refreshInterval else { return }
                    restartRefreshing()
                }
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [appState] _ in
                Task { @MainActor in await appState.appDidBecomeActive() }
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [appState] _ in
                MainActor.assumeIsolated {
                    appState.flushCache()
                }
            }
            .store(in: &subscriptions)
        CardReminderClicks.shared.$clicked
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] clicked in
                MainActor.assumeIsolated {
                    CardReminderClicks.shared.clicked = nil
                    self?.open(clicked)
                }
            }
            .store(in: &subscriptions)
    }

    /// A window opened: it opens the card of a notification clicked while no window was open.
    func windowOpened(_ window: BoardWindow) {
        guard let clicked = pendingClick else { return }
        pendingClick = nil
        open(clicked, in: window)
    }

    private func signedIn() {
        guard appState.isLoggedIn else { return }
        Task {
            await appState.loadBoardsIfNeeded()
            await appState.updateReminders()
        }
    }

    /// Looks for changes every so often, as often as Settings says, until it's changed.
    private func restartRefreshing() {
        refreshTask?.cancel()
        refreshInterval = AppSettings.refreshInterval()
        refreshTask = Task { [appState] in
            await appState.refreshPeriodically()
        }
    }

    /// While the server can't be reached, keeps trying, whatever the refresh setting.
    private func connectionChanged(_ problem: ConnectionProblem?) {
        reconnectTask?.cancel()
        reconnectTask = nil
        guard problem != nil else { return }
        reconnectTask = Task { [appState] in
            while appState.connectionProblem != nil {
                do {
                    try await Task.sleep(for: Self.reconnectInterval)
                } catch {
                    return
                }
                await appState.reconnect()
            }
        }
    }

    /// Opens a clicked notification's card in the window in front, or in the next window to open.
    private func open(_ clicked: ClickedReminder) {
        guard let window = commandState.window else {
            pendingClick = clicked
            return
        }
        open(clicked, in: window)
    }

    private func open(_ clicked: ClickedReminder, in window: BoardWindow) {
        Task {
            await window.openCard(id: clicked.cardId, boardId: clicked.boardId, accountId: clicked.accountId)
        }
    }
}
