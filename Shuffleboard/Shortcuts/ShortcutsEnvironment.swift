import Foundation

// MARK: - ShortcutsEnvironment

/// What the Shortcuts actions (#161) need from the app: the signed-in accounts, a URL session to reach their servers,
/// and the app's windows to open boards and cards in.
///
/// The actions run in the app's process, but they don't use `AppState` or any window: when the app isn't open, macOS
/// starts it to run one, and the action reads the accounts from the Keychain itself, as the app does at launch. While
/// the app is open, `boardChanged` lets it show a change straight away. Tests replace `current` with one that talks to
/// a stub server.
struct ShortcutsEnvironment: Sendable {
    /// The signed-in accounts, read each time an action runs, so it uses whoever is signed in now.
    var savedAccounts: @Sendable () -> SavedAccounts
    /// The session for all server requests.
    var session: URLSession
    /// The clock, for the date a card is marked done.
    var now: @Sendable () -> Date = { Date() }
    /// Called after an action changes a board of an account, so the app catches up if it's showing it.
    var boardChanged: @Sendable (Account.ID, Int) async -> Void = { _, _ in }
    /// Shows a board or card in the app's window in front.
    var open: @MainActor @Sendable (WindowDestination) -> Void

    /// The accounts in the Keychain and the shared session; boards and cards open through `ShortcutRequests`.
    static let standard = Self(
        savedAccounts: { KeychainCredentialStore().load() },
        session: .shared,
        open: { ShortcutRequests.shared.destination = $0 }
    )

    private static let lock = NSLock()
    private nonisolated(unsafe) static var stored = standard

    /// The environment the actions use: `standard` until the app replaces it at launch (see `forApp`), or a test does.
    static var current: Self {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// `standard`, telling `appState` about changes; in Debug builds launched by a UI test, with the test's accounts
    /// instead of the Keychain's (see `UITestLaunch`).
    @MainActor
    static func forApp(_ appState: AppState) -> Self {
        var environment = standard
        #if DEBUG
        if let saved = UITestLaunch.savedAccounts {
            environment.savedAccounts = { saved }
        }
        #endif
        environment.boardChanged = { accountId, _ in
            await appState.shortcutChangedBoard(accountId: accountId)
        }
        return environment
    }
}

// MARK: - Opening boards and cards

/// A board, or a card on it, to show in a window: from a clicked notification (#157) or a shortcut (#161).
enum WindowDestination: Equatable, Sendable {
    case board(accountId: Account.ID, boardId: Int)
    case card(accountId: Account.ID, boardId: Int, cardId: Int)
}

/// Boards and cards the Open Board and Open Card actions ask the app to show. `BackgroundWork` opens each in the window
/// in front, or the next window to open, as it does a clicked notification's card.
@MainActor
final class ShortcutRequests: ObservableObject {
    static let shared = ShortcutRequests()

    @Published var destination: WindowDestination?
}

// MARK: - Errors

/// Why a Shortcuts action failed, as Shortcuts shows it.
enum ShortcutError: Error, Equatable, CustomLocalizedStringResourceConvertible, LocalizedError {
    /// No account is signed in.
    case signedOut
    /// The account the shortcut uses (by `Account.id`) has signed out.
    case accountSignedOut(String)
    /// The server turned down the account's app password (by `Account.id`).
    case sessionEnded(String)
    /// The Mac has no network connection.
    case offline
    /// The server (by `Account.serverName`) doesn't answer.
    case serverUnreachable(String)
    case boardNotFound
    case listNotFound
    /// The list chosen isn't on the board chosen.
    case listNotOnBoard
    /// The board (by title) has no lists to add a card to.
    case boardHasNoLists(String)
    case cardNotFound
    case notAllowed
    case emptyTitle
    case titleTooLong
    /// The server refused, with its reason.
    case server(String)

    /// The longest card title Deck accepts.
    static let maxTitleLength = 255

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut:
            "You're not signed in. Open Shuffleboard and sign in, then try again."

        case let .accountSignedOut(account):
            "\(account) is no longer signed in to Shuffleboard. Sign in to it again, or choose another account."

        case let .sessionEnded(account):
            "The server no longer accepts the sign-in for \(account): it may have been revoked. Open Shuffleboard and sign in again."

        case .offline:
            "You're offline. Connect to the internet and try again."

        case let .serverUnreachable(server):
            "Can't reach \(server). Check that the server is running, then try again."

        case .boardNotFound:
            "Couldn't find that board. It may have been deleted, or it's no longer shared with you."

        case .listNotFound:
            "Couldn't find that list. It may have been deleted."

        case .listNotOnBoard:
            "That list isn't on the board you chose. Choose one of the board's lists."

        case let .boardHasNoLists(board):
            "The board \(board) has no lists to add a card to."

        case .cardNotFound:
            "Couldn't find that card. It may have been deleted, or its board is no longer shared with you."

        case .notAllowed:
            "You don't have permission to do that on this board."

        case .emptyTitle:
            "A card needs a title."

        case .titleTooLong:
            "A card's title can be at most 255 characters long."

        case let .server(message):
            "The server couldn't do that: \(message)"
        }
    }

    var errorDescription: String? {
        String(localized: localizedStringResource)
    }

    /// `error` from a request for `account`, as a `ShortcutError`; `notFound` for a 404. Cancellation stays as it is.
    static func from(_ error: Error, account: Account, notFound: Self) -> Error {
        if error is Self || error is CancellationError {
            return error
        }
        switch ConnectionProblem(error) {
        case .offline: return offline
        case .serverUnreachable: return serverUnreachable(account.serverName)
        case nil: break
        }
        switch error as? DeckAPIError {
        case .unauthorized: return sessionEnded(account.id)
        case .permissionDenied: return notAllowed
        case .httpStatus(404): return notFound
        default: return server(error.localizedDescription)
        }
    }
}
