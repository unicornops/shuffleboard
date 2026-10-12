import AppKit
import Foundation

#if DEBUG
/// Debug builds only: how the UI tests (`ShuffleboardUITests`) start the app against a test server.
///
/// The tests pass the accounts to sign in with in the launch environment; they are kept in memory, so a UI test
/// never reads or writes the Keychain and never sees the developer's own accounts. Release builds don't contain
/// this code, so the shipped app always uses the Keychain and Login Flow v2.
enum UITestLaunch {
    /// JSON array of `Credentials`; the first account is the active one.
    static let accountsKey = "SHUFFLEBOARD_UITEST_ACCOUNTS"
    /// `light` or `dark`, so screenshots don't depend on the Mac's setting.
    static let appearanceKey = "SHUFFLEBOARD_UITEST_APPEARANCE"
    /// `fresh` or `keep`: keep a copy of the boards (#156) in `UITestBoards` in the app's Application Support folder
    /// (the sandbox only lets the app write in its own container), emptied first with `fresh`. Without it, UI tests
    /// keep none.
    static let boardCacheKey = "SHUFFLEBOARD_UITEST_BOARD_CACHE"

    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    /// True when the UI tests launched the app.
    static var isActive: Bool {
        environment[accountsKey] != nil
    }

    /// The accounts the UI test signed in with; nil when the app wasn't launched by a UI test.
    static var savedAccounts: SavedAccounts? {
        guard let json = environment[accountsKey] else { return nil }
        var saved = SavedAccounts()
        let all = (try? JSONDecoder().decode([Credentials].self, from: Data(json.utf8))) ?? []
        for credentials in all {
            saved.add(credentials)
        }
        if let first = all.first {
            saved.activate(first.account.id)
        }
        return saved
    }

    /// The copy of the boards the UI test asked for, if any.
    static var boardCache: FileBoardCacheStore? {
        let fileManager = FileManager.default
        guard let mode = environment[boardCacheKey],
              let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = support.appendingPathComponent("UITestBoards", isDirectory: true)
        if mode == "fresh" {
            try? fileManager.removeItem(at: directory)
        }
        return FileBoardCacheStore(directory: directory)
    }

    /// Applies the appearance the UI test asked for, if any.
    @MainActor
    static func applyAppearance() {
        switch environment[appearanceKey] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }
}

/// Credentials for the UI tests, in memory only.
final class UITestCredentialStore: CredentialStore {
    private var saved: SavedAccounts

    init(_ saved: SavedAccounts) {
        self.saved = saved
    }

    func load() -> SavedAccounts {
        saved
    }

    func save(_ accounts: SavedAccounts) throws {
        saved = accounts
    }
}
#endif

extension AppState {
    /// The app's state at launch: signed in from the Keychain, or, in Debug builds launched by a UI test, from
    /// the accounts the test passed (see `UITestLaunch`).
    @MainActor
    static func atLaunch() -> AppState {
        #if DEBUG
        if let saved = UITestLaunch.savedAccounts {
            return AppState(credentialStore: UITestCredentialStore(saved), boardCache: UITestLaunch.boardCache)
        }
        #endif
        return AppState(
            reminders: CardReminderSync(notifications: SystemReminderNotifications()),
            launchAccountId: AppSettings.launchAccountId(),
            boardCache: FileBoardCacheStore.standard()
        )
    }
}
