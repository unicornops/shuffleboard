import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var isLoggedIn = false
    /// Every signed-in account, in the order they were added; `activeAccount` is the one in use.
    @Published private(set) var accounts: [Account] = []
    @Published var boards: [Board] = [] {
        didSet {
            recordBoards()
            for window in windows {
                window.boardsDidChange()
            }
        }
    }

    /// The lists and cards of the boards open in windows, by board id (#160).
    @Published private(set) var lists: [Int: BoardLists] = [:]

    /// Why the server can't be reached, if it can't (#156). The boards on the Mac are shown read-only meanwhile.
    @Published private(set) var connectionProblem: ConnectionProblem?
    @Published var isLoading = false
    /// Errors shown inline where they happen: the login screen, the empty sidebar and the create sheets.
    @Published var errorMessage: String?
    /// Errors from actions that have no UI of their own (moving, deleting, labelling…), shown as a banner.
    @Published var actionError: String?
    @Published var showingLogin = false
    @Published var showingAbout = false
    /// The server's Deck version (e.g. "1.18.5"), read once per account; nil until known.
    @Published private(set) var serverDeckVersion: String?
    /// The server has no Activity app, so the card sheet leaves out the card's history (#164).
    @Published private(set) var activityIsUnavailable = false
    /// Set while a board is being duplicated.
    @Published private(set) var boardCopyProgress: BoardCopyProgress?
    /// Every board's cards, by board id, for searching all boards (#158); see `loadAllCards`.
    @Published private(set) var allCards: [Int: BoardCards] = [:]
    @Published private(set) var isLoadingAllCards = false

    private var deckAPI: DeckAPI?
    /// Where credentials are kept: the Keychain in the app, an in-memory store in tests.
    private let credentialStore: CredentialStore
    /// The URL session for all server requests; tests pass one that talks to a stub server.
    private let session: URLSession
    /// Opens the browser for sign-in.
    private let openURL: @MainActor @Sendable (URL) -> Void
    /// Notifications about due and newly assigned cards (#157); nil in tests and UI tests.
    let reminders: CardReminderSync?
    /// The windows on this app's boards; see `register(_:)`.
    private var windowRefs: [WeakBoardWindow] = []
    /// Where the copy of each account's boards is kept (#156); nil in tests that don't use one.
    let boardCache: BoardCacheStore?
    /// The copy of the active account's boards, as last saved or about to be; see AppState+Offline.
    var cacheSnapshot: BoardCacheSnapshot?
    /// The account `cacheSnapshot` belongs to; nil while nothing is being recorded (switching accounts).
    var cacheAccountId: Account.ID?
    /// Saves `cacheSnapshot` shortly after it changes.
    var cacheWriteTask: Task<Void, Never>?
    /// The ETag of the last board list, and when it arrived, for `refreshIfChanged()`.
    private var boardsETag: String?
    private var boardsETagDate: Date?
    /// The clock; tests move it forward.
    var now: () -> Date = Date.init
    private var credentials: Credentials?
    /// Whether `serverDeckVersion` was asked for, so a server that doesn't say isn't asked again.
    private var checkedDeckVersion = false
    /// What `credentialStore` holds: every account and which one is active.
    private var savedAccounts = SavedAccounts()

    /// The account whose boards are shown.
    var activeAccount: Account? {
        credentials?.account
    }

    init(
        credentialStore: CredentialStore = KeychainCredentialStore(),
        session: URLSession = .shared,
        openURL: @escaping @MainActor @Sendable (URL) -> Void = { url in _ = NSWorkspace.shared.open(url) },
        reminders: CardReminderSync? = nil,
        launchAccountId: Account.ID? = nil,
        boardCache: BoardCacheStore? = nil
    ) {
        self.credentialStore = credentialStore
        self.session = session
        self.openURL = openURL
        self.reminders = reminders
        self.boardCache = boardCache
        self.savedAccounts = credentialStore.load()
        // The account chosen in Settings, if it's still signed in; otherwise the one used last.
        if let launchAccountId {
            savedAccounts.activate(launchAccountId)
        }
        self.accounts = savedAccounts.accounts
        if let creds = savedAccounts.active {
            self.credentials = creds
            self.deckAPI = makeAPI(creds)
            self.isLoggedIn = true
            // The boards on the Mac straight away; then what the server has.
            restoreFromCache()
            Task { await loadBoards() }
        } else {
            self.showingLogin = true
        }
    }

    private func makeAPI(_ creds: Credentials) -> DeckAPI {
        DeckAPI(serverURL: creds.serverURL, username: creds.username, appPassword: creds.appPassword, session: session)
    }

    /// The in-flight browser sign-in, if any; cancelled by `cancelLogin()`.
    private var loginTask: Task<Void, Never>?
    /// Identifies the current sign-in attempt, so a cancelled one can't change the state of a newer one.
    private var loginAttempt = 0

    /// Starts signing in via the browser (Login Flow v2). Supports 2FA: the user completes login and 2FA
    /// in the browser while the app waits. `cancelLogin()` stops waiting.
    func startBrowserLogin(serverURL: URL) {
        loginTask?.cancel()
        loginTask = Task { await loginWithBrowser(serverURL: serverURL) }
    }

    /// Stops waiting for a browser sign-in started with `startBrowserLogin(serverURL:)`.
    func cancelLogin() {
        loginTask?.cancel()
        loginTask = nil
        loginAttempt += 1
        isLoading = false
    }

    /// Sign in via browser (Login Flow v2). Supports 2FA — user completes login and 2FA in the browser.
    func loginWithBrowser(serverURL: URL) async {
        loginAttempt += 1
        let attempt = loginAttempt
        isLoading = true
        errorMessage = nil
        defer {
            if attempt == loginAttempt {
                isLoading = false
            }
        }
        do {
            let (url, loginName, appPassword) = try await NextcloudAuth.loginWithBrowser(
                serverURL: serverURL,
                session: session,
                openURL: openURL
            )
            try Task.checkCancellation()
            try await finishSignIn(Credentials(serverURL: url, username: loginName, appPassword: appPassword))
        } catch {
            // Cancelled by the user: either `CancellationError` or a request torn down mid-flight.
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Shows `error` in the action error banner.
    func report(_ error: Error) {
        guard !endSessionIfUnauthorized(error) else { return }
        noteConnectionProblem(error)
        actionError = error.localizedDescription
    }

    /// If `error` means the app password was revoked or has expired, signs the active account out. With
    /// other accounts signed in it switches to the next one and says why in the banner; otherwise it returns
    /// to the login screen with an explanation. Returns `true` if it did, so the caller shows nothing further.
    @discardableResult
    func endSessionIfUnauthorized(_ error: Error) -> Bool {
        guard case .unauthorized? = error as? DeckAPIError else { return false }
        // Requests still in flight from the ended session may fail the same way; handle it once.
        if isLoggedIn, let account = activeAccount {
            logout()
            if isLoggedIn {
                actionError = "Signed out of \(account.id): \(error.localizedDescription)"
            } else {
                errorMessage = error.localizedDescription
            }
        }
        return true
    }

    /// Signs the active account out at the user's request: ends its session locally straight away, then
    /// revokes the app password on the server so it stops working and leaves the user's Nextcloud device list.
    /// Revocation failures (offline, server unreachable) are ignored; the local sign-out has already happened.
    func signOut() async {
        let api = deckAPI
        logout()
        try? await api?.revokeAppPassword()
    }

    /// Ends the active account's session locally and forgets its credentials. If another account is signed
    /// in, switches to it; otherwise returns to the login screen. Does not contact the server; see `signOut()`.
    func logout() {
        if let account = activeAccount {
            Task { [reminders] in await reminders?.forget(accountId: account.id) }
            forgetCache(of: account.id)
            savedAccounts.remove(account.id)
            try? credentialStore.save(savedAccounts)
        }
        if let next = savedAccounts.active {
            activate(next)
            Task { await loadBoards() }
            return
        }
        resetSession()
        credentials = nil
        deckAPI = nil
        accounts = []
        isLoggedIn = false
        showingLogin = true
    }

    func loadBoards() async {
        guard let api = deckAPI else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let fetched = try await api.fetchBoards(ifNoneMatch: nil)
            // Switched accounts meanwhile: these are another account's boards.
            guard api === deckAPI, let fetched else { return }
            let wereOpen = openBoardIds
            // A window without a board opens one now (see `BoardWindow.boardsDidChange`); its BoardDetailView's
            // `.task(id: selectedBoardId)` loads the board's lists.
            boards = fetched.value
            boardsETag = fetched.etag
            boardsETagDate = now()
            serverWasReached(boardsSyncedAt: now())
            await checkDeckVersion(api)
            for boardId in openBoardIds.intersection(wereOpen).sorted() {
                await loadStacks(boardId: boardId)
            }
        } catch {
            guard api === deckAPI, !endSessionIfUnauthorized(error) else { return }
            // Can't reach the server: the boards on the Mac stay on screen, under the offline banner.
            if noteConnectionProblem(error), !boards.isEmpty {
                return
            }
            errorMessage = error.localizedDescription
            // The sidebar only shows `errorMessage` when there are no boards; a failed refresh needs the banner.
            if !boards.isEmpty {
                report(error)
            }
        }
    }

    /// Call when main interface appears so boards are loaded (e.g. after launch with Keychain or after login).
    func loadBoardsIfNeeded() async {
        guard isLoggedIn else { return }
        await loadBoards()
    }

    /// Loads the lists of `boardId`, if a window has it open.
    ///
    /// The current lists stay on screen while the board is refreshed; a board just opened shows its lists as saved on
    /// the Mac, if they were, until the server's arrive. If loads of a board overlap, only the most recent one's
    /// result is applied, so a slow response can never replace newer lists.
    func loadStacks(boardId: Int) async {
        guard let api = deckAPI, openBoardIds.contains(boardId) else { return }
        openLists(of: boardId)
        let generation = (lists[boardId]?.generation ?? 0) + 1
        updateLists(of: boardId) {
            $0.generation = generation
            $0.error = nil
            $0.isLoading = true
        }

        let started = now()
        let result: Result<Tagged<[Stack]>, Error>
        do {
            guard let loaded = try await api.fetchStacks(boardId: boardId, ifNoneMatch: nil) else {
                throw DeckAPIError.invalidResponse
            }
            result = .success(loaded)
        } catch {
            result = .failure(error)
        }

        guard lists[boardId]?.generation == generation else { return }
        switch result {
        case let .success(loaded):
            updateLists(of: boardId, newStacks: true) {
                $0.isLoading = false
                $0.isFromServer = true
                $0.stacks = Self.sorted(loaded.value)
                $0.etag = loaded.etag
                $0.fetchDate = started
            }
            serverWasReached()

        case let .failure(error):
            updateLists(of: boardId) {
                $0.isLoading = false
                $0.fetchDate = nil
            }
            guard !endSessionIfUnauthorized(error) else { return }
            if noteConnectionProblem(error) {
                // The saved lists stay on screen under the offline banner; without them, say why there are none.
                if lists[boardId]?.stacks.isEmpty == true {
                    updateLists(of: boardId) {
                        $0.error = "This board's lists haven't been saved on this Mac yet, so they can't be shown "
                            + "until the server can be reached."
                    }
                }
                return
            }
            // A cancelled load (the board view went away) is not an error worth showing.
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                updateLists(of: boardId) { $0.error = error.localizedDescription }
            }
        }
    }

    func refresh() async {
        await loadBoards()
    }

    /// Returns `true` if the stack was created successfully, `false` otherwise (and sets `errorMessage`).
    func createStack(boardId: Int, title: String) async -> Bool {
        guard let api = deckAPI else { return false }
        do {
            _ = try await api.createStack(boardId: boardId, title: title)
            await loadStacks(boardId: boardId)
            return true
        } catch {
            guard !endSessionIfUnauthorized(error) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// True while `reorderStacks` is saving, so a second drag can't interleave its updates with the first.
    private var isReorderingStacks = false

    /// Reorders stacks by moving the stack at `fromIndex` to `toIndex`, then
    /// persists the new order values to the server.
    ///
    /// The Deck API has no bulk reorder, so each moved stack is updated in turn. If one update fails the
    /// rest are not sent, the error is shown and the lists are reloaded so the screen matches the server.
    func reorderStacks(boardId: Int, fromIndex: Int, toIndex: Int) async {
        guard let api = deckAPI, !isReorderingStacks, var stacks = lists[boardId]?.stacks else { return }
        guard fromIndex != toIndex,
              fromIndex >= 0, fromIndex < stacks.count,
              toIndex >= 0, toIndex <= stacks.count else { return }
        isReorderingStacks = true
        defer { isReorderingStacks = false }

        // Move the stack in the local array
        let moving = stacks.remove(at: fromIndex)
        let insertAt = toIndex > fromIndex ? toIndex - 1 : toIndex
        stacks.insert(moving, at: insertAt)

        // Assign sequential order values and persist to server
        let changes = stacks.enumerated().filter { $0.element.order != $0.offset }
        for (idx, _) in changes {
            stacks[idx].order = idx
        }
        setStacks(stacks, of: boardId)
        for (newOrder, stack) in changes {
            do {
                _ = try await api.updateStack(
                    boardId: boardId,
                    stackId: stack.id,
                    title: stack.title,
                    order: newOrder
                )
            } catch {
                report(error)
                await loadStacks(boardId: boardId)
                return
            }
        }
    }

    /// Renames a list, keeping its position. The new title shows straight away; if the server refuses it, the error
    /// goes to the banner and the lists are reloaded so the old title comes back. Blank or unchanged titles are
    /// ignored.
    func renameStack(boardId: Int, stackId: Int, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api = deckAPI, !trimmed.isEmpty, var stacks = lists[boardId]?.stacks,
              let idx = stacks.firstIndex(where: { $0.id == stackId }),
              stacks[idx].title != trimmed else { return }
        let order = stacks[idx].order
        stacks[idx].title = trimmed
        setStacks(stacks, of: boardId)
        do {
            _ = try await api.updateStack(boardId: boardId, stackId: stackId, title: trimmed, order: order)
        } catch {
            report(error)
            await loadStacks(boardId: boardId)
        }
    }

    /// Deletes the stack and its cards. Deck keeps them restorable until the server clears deleted items.
    func deleteStack(boardId: Int, stackId: Int) async {
        guard let api = deckAPI else { return }
        do {
            try await api.deleteStack(boardId: boardId, stackId: stackId)
            await loadStacks(boardId: boardId)
        } catch {
            report(error)
        }
    }

    func assignLabel(boardId: Int, stackId: Int, cardId: Int, labelId: Int) async {
        guard let api = deckAPI else { return }
        do {
            try await api.assignLabel(boardId: boardId, stackId: stackId, cardId: cardId, labelId: labelId)
            await loadStacks(boardId: boardId)
        } catch {
            report(error)
        }
    }

    func removeLabel(boardId: Int, stackId: Int, cardId: Int, labelId: Int) async {
        guard let api = deckAPI else { return }
        do {
            try await api.removeLabel(boardId: boardId, stackId: stackId, cardId: cardId, labelId: labelId)
            await loadStacks(boardId: boardId)
        } catch {
            report(error)
        }
    }

    /// Creates a new label on the board and refreshes board/stacks. Returns the new label id if successful.
    func createLabel(boardId: Int, title: String, color: String) async -> Int? {
        guard let api = deckAPI else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let label = try await api.createLabel(boardId: boardId, title: trimmed, color: color)
            // Reloads the board's labels and, for the selected board, its lists.
            await loadBoards()
            return label.id
        } catch {
            report(error)
            return nil
        }
    }
}

// MARK: - Boards

@MainActor
extension AppState {
    /// Boards that are not archived and not soft-deleted.
    var activeBoards: [Board] {
        boards.filter { !$0.archived && !$0.isDeleted }
    }

    /// Boards that are archived but not soft-deleted.
    var archivedBoards: [Board] {
        boards.filter { $0.archived && !$0.isDeleted }
    }

    /// Soft-deleted boards that can still be restored, most recently deleted first.
    var deletedBoards: [Board] {
        boards.filter(\.isDeleted).sorted { ($0.deletedAt ?? 0, $0.id) > ($1.deletedAt ?? 0, $1.id) }
    }

    /// The boards in the order the sidebar lists them.
    var boardsInSidebarOrder: [Board] {
        activeBoards + archivedBoards
    }

    func archiveBoard(id: Int) async {
        guard let api = deckAPI,
              let board = boards.first(where: { $0.id == id }) else { return }
        do {
            _ = try await api.updateBoard(id: id, title: board.title, color: board.color, archived: true)
            if let idx = boards.firstIndex(where: { $0.id == id }) {
                boards[idx].archived = true
            }
            for window in windows where window.selectedBoardId == id {
                window.selectedBoardId = activeBoards.first?.id
            }
        } catch {
            report(error)
        }
    }

    func unarchiveBoard(id: Int) async {
        guard let api = deckAPI,
              let board = boards.first(where: { $0.id == id }) else { return }
        do {
            _ = try await api.updateBoard(id: id, title: board.title, color: board.color, archived: false)
            if let idx = boards.firstIndex(where: { $0.id == id }) {
                boards[idx].archived = false
            }
        } catch {
            report(error)
        }
    }

    /// Renames and recolours a board, keeping its archived state. The sidebar and the board's title change as
    /// soon as the server confirms. Returns `true` if the board was saved, `false` otherwise (and sets
    /// `errorMessage`, which the edit sheet shows).
    func updateBoard(id: Int, title: String, color: String) async -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api = deckAPI, !trimmed.isEmpty,
              let board = boards.first(where: { $0.id == id }) else { return false }
        do {
            let saved = try await api.updateBoard(id: id, title: trimmed, color: color, archived: board.archived)
            guard api === deckAPI else { return false }
            if let idx = boards.firstIndex(where: { $0.id == id }) {
                boards[idx].title = saved.title
                boards[idx].color = saved.color ?? color
            }
            return true
        } catch {
            guard !endSessionIfUnauthorized(error) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Returns `true` if the board was created successfully, `false` otherwise (and sets `errorMessage`).
    func createBoard(title: String, color: String) async -> Bool {
        guard let api = deckAPI else { return false }
        do {
            _ = try await api.createBoard(title: title, color: color)
            await loadBoards()
            return true
        } catch {
            guard !endSessionIfUnauthorized(error) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }
}

// MARK: - Deleting and restoring boards

@MainActor
extension AppState {
    /// Restores a deleted board; returns `true` if it was (`BoardWindow.restoreBoard` then opens it). Deck before
    /// 1.17 refuses with 403 (a server bug, fixed in Deck 1.17.0); the banner then says so instead of "Permission
    /// denied".
    @discardableResult
    func restoreBoard(id: Int) async -> Bool {
        guard let api = deckAPI else { return false }
        do {
            try await api.undoDeleteBoard(id: id)
            await loadBoards()
            return true
        } catch DeckAPIError.permissionDenied {
            if let version = try? await api.deckVersion(), !DeckAPI.version(version, isAtLeast: "1.17") {
                actionError = Self.restoreUnsupportedMessage(deckVersion: version)
            } else {
                report(DeckAPIError.permissionDenied)
            }
        } catch {
            report(error)
        }
        return false
    }

    nonisolated static func restoreUnsupportedMessage(deckVersion: String) -> String {
        "This server has Deck \(deckVersion), which can't restore deleted boards. Deck 1.17 or later can; "
            + "your Nextcloud administrator can update it."
    }

    /// Deletes a board. Deck keeps it restorable for a while, so it moves to "Recently Deleted" in the sidebar.
    func deleteBoard(id: Int) async {
        guard let api = deckAPI else { return }
        do {
            try await api.deleteBoard(id: id)
            if let idx = boards.firstIndex(where: { $0.id == id }) {
                boards[idx].deletedAt = Int(Date().timeIntervalSince1970)
            }
            for window in windows where window.selectedBoardId == id {
                window.selectedBoardId = activeBoards.first?.id
            }
        } catch {
            report(error)
        }
    }
}

// MARK: - Duplicating boards

@MainActor
extension AppState {
    /// Copies a board (see `DeckAPI.copyBoard`), with `boardCopyProgress` counting the lists and cards done, and
    /// returns the copy's id (`BoardWindow.duplicateBoard` then opens it). Returns nil for a blank title or a failure,
    /// which sets `errorMessage` for the sheet; a failed copy is deleted again.
    func duplicateBoard(id: Int, options: BoardCopyOptions) async -> Int? {
        var options = options
        options.title = options.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api = deckAPI, !options.title.isEmpty,
              let source = boards.first(where: { $0.id == id }) else { return nil }
        boardCopyProgress = nil
        defer { boardCopyProgress = nil }
        do {
            let copy = try await api.copyBoard(source, options: options) { [weak self] done, total in
                self?.boardCopyProgress = BoardCopyProgress(done: done, total: total)
            }
            guard api === deckAPI else { return nil }
            await loadBoards()
            return copy.id
        } catch {
            guard !endSessionIfUnauthorized(error) else { return nil }
            errorMessage = error.localizedDescription
            return nil
        }
    }
}

/// How far `AppState.duplicateBoard` has got: lists and cards copied out of all of them.
struct BoardCopyProgress: Equatable {
    let done: Int
    let total: Int
}

// MARK: - Background refresh

@MainActor
extension AppState {
    /// Picks up changes made elsewhere (the web UI, other devices) without spinners or error messages.
    ///
    /// Uses ETags, so when nothing has changed the board list is a 304 with no body. Deck's lists have no ETag, but
    /// the board list's ETag changes whenever anything on any board does, so an unchanged board list means the lists
    /// are unchanged too and aren't downloaded (#141). Deck's ETags change at most once a second, though: lists fetched
    /// in the same second as the board list's ETag could have missed a change made in that second, so they are only
    /// trusted once fetched comfortably after it. Skipped while boards are
    /// loading, a list reorder is saving or a list is being dragged. A 401 still signs out; other failures are
    /// ignored until the next refresh. A full `loadStacks` that starts meanwhile wins.
    func refreshIfChanged() async {
        guard let api = deckAPI, !isLoading, !isReorderingStacks, !isDraggingStack else { return }
        let boardsChanged: Bool
        do {
            let fetched = try await api.fetchBoards(ifNoneMatch: boardsETag)
            guard api === deckAPI else { return }
            serverWasReached(boardsSyncedAt: now())
            boardsChanged = fetched != nil
            if let fetched {
                // A window whose board was deleted elsewhere opens another (see `BoardWindow.boardsDidChange`), and
                // its `.task(id: selectedBoardId)` loads it.
                boards = fetched.value
                boardsETag = fetched.etag
                boardsETagDate = now()
            }
        } catch {
            if api === deckAPI, !endSessionIfUnauthorized(error) {
                noteConnectionProblem(error)
            }
            return
        }

        for boardId in openBoardIds.sorted() {
            guard api === deckAPI else { return }
            await refreshLists(of: boardId, api: api, boardsChanged: boardsChanged)
        }
    }

    /// `refreshIfChanged` for one open board's lists.
    private func refreshLists(of boardId: Int, api: DeckAPI, boardsChanged: Bool) async {
        guard let entry = lists[boardId], !entry.isLoading else { return }
        if !boardsChanged, entry.etag == nil, listsAreSettled(entry) {
            listsAreCurrent(boardId: boardId)
            return
        }
        let started = now()
        do {
            guard let fetched = try await api.fetchStacks(boardId: boardId, ifNoneMatch: entry.etag) else { return }
            guard lists[boardId]?.generation == entry.generation, !isReorderingStacks, !isDraggingStack else { return }
            updateLists(of: boardId, newStacks: true) {
                $0.isFromServer = true
                $0.stacks = Self.sorted(fetched.value)
                $0.etag = fetched.etag
                $0.fetchDate = started
                $0.error = nil
            }
        } catch {
            if api === deckAPI {
                endSessionIfUnauthorized(error)
            }
        }
    }

    /// Whether `lists` were requested well after the board list's ETag arrived, so an unchanged board list means
    /// they are current. The margin covers Deck's whole-second ETags.
    private func listsAreSettled(_ lists: BoardLists) -> Bool {
        guard let fetched = lists.fetchDate, let etagDate = boardsETagDate else { return false }
        return fetched.timeIntervalSince(etagDate) >= 1.5
    }

    /// Reads the server's Deck version the first time boards load for an account.
    private func checkDeckVersion(_ api: DeckAPI) async {
        guard !checkedDeckVersion else { return }
        checkedDeckVersion = true
        let version = try? await api.deckVersion()
        if api === deckAPI {
            serverDeckVersion = version
        }
    }

    /// Whether cards have start dates: Deck 1.18 added them; older versions drop them silently.
    var supportsStartDates: Bool {
        serverDeckVersion.map { DeckAPI.version($0, isAtLeast: "1.18") } ?? false
    }

    /// Lists in board order.
    nonisolated static func sorted(_ stacks: [Stack]) -> [Stack] {
        stacks.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }
}

// MARK: - Sharing

@MainActor
extension AppState {
    /// Shares `board` with `sharee`, read-only to start, then refreshes the board's sharing list.
    func share(_ board: Board, with sharee: Sharee) async -> Bool {
        guard let type = sharee.shareType else { return false }
        return await sharingAction(on: board) {
            try await $0.addShare(
                boardId: board.id,
                type: type,
                participant: sharee.participantId,
                permissions: SharePermissions()
            )
        }
    }

    func updateShare(_ entry: ACLEntry, on board: Board, permissions: SharePermissions) async {
        guard let aclId = entry.id else { return }
        _ = await sharingAction(on: board) {
            try await $0.updateShare(boardId: board.id, aclId: aclId, permissions: permissions)
        }
    }

    func removeShare(_ entry: ACLEntry, from board: Board) async {
        guard let aclId = entry.id else { return }
        _ = await sharingAction(on: board) { try await $0.removeShare(boardId: board.id, aclId: aclId) }
    }

    /// Search results for the share field; empty (and the banner) on failure.
    func searchSharees(_ query: String) async -> [Sharee] {
        guard let api = deckAPI else { return [] }
        do {
            return try await api.searchSharees(query)
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                report(error)
            }
            return []
        }
    }

    /// Runs a sharing change, then re-fetches just this board so its sharing list and rights are current.
    private func sharingAction(on board: Board, _ action: (DeckAPI) async throws -> Void) async -> Bool {
        await boardChange(boardId: board.id, action)
    }

    /// Runs a change to a board's settings, then re-fetches just that board (and, with `reloadingLists`, its lists
    /// if it is open) so the screen matches the server. Errors go to the banner.
    private func boardChange(
        boardId: Int,
        reloadingLists: Bool = false,
        _ action: (DeckAPI) async throws -> Void
    ) async
        -> Bool {
        guard let api = deckAPI else { return false }
        do {
            try await action(api)
            let updated = try await api.getBoard(id: boardId)
            guard api === deckAPI else { return false }
            if let index = boards.firstIndex(where: { $0.id == boardId }) {
                boards[index] = updated
            }
        } catch {
            report(error)
            return false
        }
        if reloadingLists {
            await loadStacks(boardId: boardId)
        }
        return true
    }
}

// MARK: - Labels

@MainActor
extension AppState {
    /// Renames and recolours a label, then reloads the board's labels and its lists, whose cards carry the label.
    /// Returns `false` for a blank title or a failure (shown in the banner).
    func updateLabel(_ label: DeckLabel, boardId: Int, title: String, color: String) async -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await boardChange(boardId: boardId, reloadingLists: true) {
            _ = try await $0.updateLabel(boardId: boardId, labelId: label.id, title: trimmed, color: color)
        }
    }

    /// Deletes a label from the board and its cards, then reloads them; the card filter stops using it.
    func deleteLabel(_ label: DeckLabel, boardId: Int) async -> Bool {
        let deleted = await boardChange(boardId: boardId, reloadingLists: true) {
            try await $0.deleteLabel(boardId: boardId, labelId: label.id)
        }
        if deleted {
            for window in windows {
                window.cardFilter.labelIds.remove(label.id)
            }
        }
        return deleted
    }
}

// MARK: - Comments

@MainActor
extension AppState {
    /// The signed-in user's id; only a comment's author can edit or delete it.
    var currentUserId: String? {
        credentials?.username
    }

    /// A page of the card's comments, newest first; nil (and the banner) on failure.
    func comments(for card: Card, offset: Int) async -> [CardComment]? {
        await commentAction { try await $0.getComments(cardId: card.id, offset: offset) }
    }

    func addComment(_ message: String, to card: Card) async -> CardComment? {
        await commentAction { try await $0.addComment(cardId: card.id, message: message) }
    }

    func updateComment(_ comment: CardComment, message: String, on card: Card) async -> CardComment? {
        await commentAction { try await $0.updateComment(cardId: card.id, commentId: comment.id, message: message) }
    }

    func deleteComment(_ comment: CardComment, from card: Card) async -> Bool {
        await commentAction { try await $0.deleteComment(cardId: card.id, commentId: comment.id) } != nil
    }

    /// A page of the card's history (#164), newest first, older than the event `since`; nil (and the banner) on
    /// failure. Notes a server without the Activity app, so the history is left out from then on.
    func activity(for card: Card, since: Int?, limit: Int) async -> CardActivityPage? {
        let page = await commentAction { try await $0.getCardActivity(cardId: card.id, since: since, limit: limit) }
        if page == .unavailable {
            activityIsUnavailable = true
        }
        return page
    }

    private func commentAction<Result: Sendable>(_ action: (DeckAPI) async throws -> Result) async -> Result? {
        guard let api = deckAPI else { return nil }
        do {
            return try await action(api)
        } catch {
            report(error)
            return nil
        }
    }
}

// MARK: - Cards

/// What the card sheet edits.
struct CardEdits {
    var title: String
    var description: String
    /// nil removes the start date.
    var startDate: Date?
    /// nil removes the due date.
    var dueDate: Date?
    var isDone: Bool

    /// Deck accepts a start date after the due date, so the app checks it.
    var datesAreInOrder: Bool {
        guard let startDate, let dueDate else { return true }
        return startDate <= dueDate
    }

    static let datesOutOfOrderMessage = "The start date is after the due date."
}

@MainActor
extension AppState {
    /// Saves the card sheet's edits to `card`, keeping its other fields as they are.
    /// Returns `true` if the card was saved, `false` otherwise (and sets `errorMessage`).
    func updateCard(boardId: Int, stackId: Int, card: Card, edits: CardEdits) async -> Bool {
        guard let api = deckAPI else { return false }
        guard edits.datesAreInOrder else {
            errorMessage = CardEdits.datesOutOfOrderMessage
            return false
        }
        var updated = card.withSchedule(startDate: edits.startDate, dueDate: edits.dueDate, isDone: edits.isDone)
        updated.title = edits.title
        updated.description = edits.description
        do {
            _ = try await api.updateCard(boardId: boardId, stackId: stackId, card: updated)
            await loadStacks(boardId: boardId)
            return true
        } catch {
            guard !endSessionIfUnauthorized(error) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Creates a card at the end of the list and returns its id (`BoardWindow.createCard` then selects it); nil on
    /// failure, which goes to the banner.
    @discardableResult
    func createCard(boardId: Int, stackId: Int, title: String) async -> Int? {
        guard let api = deckAPI else { return nil }
        do {
            let card = try await api.createCard(boardId: boardId, stackId: stackId, title: title)
            await loadStacks(boardId: boardId)
            return card.id
        } catch {
            report(error)
            return nil
        }
    }

    /// Archives the card and reloads the lists (errors go to the banner).
    func archiveCard(_ card: Card, boardId: Int) async {
        guard let api = deckAPI else { return }
        do {
            try await api.archiveCard(boardId: boardId, stackId: card.stackId, cardId: card.id)
            await loadStacks(boardId: boardId)
        } catch {
            report(error)
        }
    }

    /// Returns `true` if the card was unarchived; reloads the lists so it reappears.
    @discardableResult
    func unarchiveCard(_ card: Card, boardId: Int) async -> Bool {
        guard let api = deckAPI else { return false }
        do {
            try await api.unarchiveCard(boardId: boardId, stackId: card.stackId, cardId: card.id)
            await loadStacks(boardId: boardId)
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// The board's lists holding their archived cards; nil (and the banner) on failure.
    func archivedStacks(boardId: Int) async -> [Stack]? {
        guard let api = deckAPI else { return nil }
        do {
            return try await Self.sorted(api.getArchivedStacks(boardId: boardId))
        } catch {
            report(error)
            return nil
        }
    }

    /// Assigns `user` to the card (errors go to the banner).
    func assignUser(_ user: DeckUser, boardId: Int, card: Card) async {
        guard let api = deckAPI else { return }
        if user.uid == currentUserId {
            reminders?.noteSelfAssigned(cardId: card.id)
        }
        do {
            try await api.assignUser(boardId: boardId, stackId: card.stackId, cardId: card.id, userId: user.uid)
            await loadStacks(boardId: boardId)
        } catch {
            report(error)
        }
    }

    /// Removes an assignment from the card (errors go to the banner).
    func unassign(_ assignment: CardAssignment, boardId: Int, card: Card) async {
        guard let api = deckAPI else { return }
        do {
            try await api.unassignUser(
                boardId: boardId,
                stackId: card.stackId,
                cardId: card.id,
                userId: assignment.participant.uid,
                type: assignment.type
            )
            await loadStacks(boardId: boardId)
        } catch {
            report(error)
        }
    }

    /// Marks a card done or not done from the board (errors go to the banner).
    func setCardDone(boardId: Int, card: Card, done: Bool) async {
        guard let api = deckAPI, card.isDone != done else { return }
        do {
            let updated = card.withSchedule(startDate: card.startDate, dueDate: card.dueDate, isDone: done)
            _ = try await api.updateCard(boardId: boardId, stackId: card.stackId, card: updated)
            await loadStacks(boardId: boardId)
        } catch {
            report(error)
        }
    }

    /// Returns `true` if the card was deleted, `false` otherwise (and shows the error banner).
    @discardableResult
    func deleteCard(boardId: Int, stackId: Int, cardId: Int) async -> Bool {
        guard let api = deckAPI else { return false }
        do {
            try await api.deleteCard(boardId: boardId, stackId: stackId, cardId: cardId)
            await loadStacks(boardId: boardId)
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Moves a card to position `order` in `toStackId`, which may be the stack it is already in.
    func reorderCard(boardId: Int, fromStackId: Int, cardId: Int, toStackId: Int, order: Int) async {
        guard let api = deckAPI else { return }
        // Show the move straight away; the reload below (or after a failure) replaces it with the server's lists.
        if let moved = lists[boardId]?.stacks.movingCard(cardId, toStack: toStackId, at: order) {
            // Drop any refresh already in flight, so it can't put the card back where it was.
            updateLists(of: boardId) { $0.generation += 1 }
            setStacks(moved, of: boardId)
        }
        do {
            try await api.reorderCard(
                boardId: boardId,
                cardId: cardId,
                order: order,
                newStackId: toStackId
            )
            await loadStacks(boardId: boardId)
        } catch {
            report(error)
            await loadStacks(boardId: boardId)
        }
    }

    /// Moves a card into a different stack at position `order`.
    func moveCard(boardId: Int, cardId: Int, fromStackId: Int, toStackId: Int, order: Int) async {
        guard fromStackId != toStackId else { return }
        await reorderCard(
            boardId: boardId,
            fromStackId: fromStackId,
            cardId: cardId,
            toStackId: toStackId,
            order: order
        )
    }
}

// MARK: - Attachments

@MainActor
extension AppState {

    /// Fetches the full card (including attachments) from the API.
    func getFullCard(boardId: Int, stackId: Int, cardId: Int) async -> Card? {
        guard let api = deckAPI else { return nil }
        do {
            return try await api.getCard(boardId: boardId, stackId: stackId, cardId: cardId)
        } catch {
            report(error)
            return nil
        }
    }

    /// Fetches attachments for a card.
    func getAttachments(boardId: Int, stackId: Int, cardId: Int) async -> [Attachment] {
        guard let api = deckAPI else { return [] }
        do {
            return try await api.getAttachments(boardId: boardId, stackId: stackId, cardId: cardId)
        } catch {
            report(error)
            return []
        }
    }

    /// Downloads an attachment and saves it to the user's chosen location.
    func downloadAttachment(
        boardId: Int,
        stackId: Int,
        cardId: Int,
        attachment: Attachment,
        saveURL: URL
    ) async
        -> Bool {
        guard let api = deckAPI else { return false }
        do {
            let data = try await api.downloadAttachment(
                boardId: boardId,
                stackId: stackId,
                cardId: cardId,
                attachmentId: attachment.id,
                type: attachment.type
            )
            try data.write(to: saveURL)
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Uploads a file as an attachment to a card. Refreshes stacks on success.
    /// Returns `true` if the upload succeeded, `false` otherwise (and shows the error banner).
    func uploadAttachment(boardId: Int, stackId: Int, cardId: Int, fileURL: URL) async -> Bool {
        guard let api = deckAPI else { return false }
        do {
            try await api.uploadAttachment(
                boardId: boardId,
                stackId: stackId,
                cardId: cardId,
                fileURL: fileURL,
                filename: fileURL.lastPathComponent
            )
            await loadStacks(boardId: boardId)
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Deletes an attachment from a card. Returns `true` if it was deleted (errors go to the banner).
    @discardableResult
    func deleteAttachment(
        boardId: Int,
        stackId: Int,
        cardId: Int,
        attachmentId: Int,
        type: String? = nil
    ) async
        -> Bool {
        guard let api = deckAPI else { return false }
        do {
            try await api.deleteAttachment(
                boardId: boardId,
                stackId: stackId,
                cardId: cardId,
                attachmentId: attachmentId,
                type: type
            )
            await loadStacks(boardId: boardId)
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Restores a deleted attachment (only `deck_file` ones can be). Returns `true` if it was restored.
    func restoreAttachment(_ attachment: Attachment, boardId: Int, stackId: Int, cardId: Int) async -> Bool {
        guard let api = deckAPI else { return false }
        do {
            try await api.restoreAttachment(
                boardId: boardId,
                stackId: stackId,
                cardId: cardId,
                attachmentId: attachment.id,
                type: attachment.type
            )
            await loadStacks(boardId: boardId)
            return true
        } catch {
            report(error)
            return false
        }
    }
}

// MARK: - Accounts

@MainActor
extension AppState {
    /// Shows the login screen to sign in to another account; `cancelAddingAccount()` goes back.
    func addAccount() {
        errorMessage = nil
        showingLogin = true
    }

    /// Leaves the login screen opened by `addAccount()` without signing in.
    func cancelAddingAccount() {
        cancelLogin()
        errorMessage = nil
        showingLogin = !isLoggedIn
    }

    /// Saves `creds` as a signed-in account (replacing that account's earlier sign-in, whose app password is
    /// then revoked), makes it active and loads its boards.
    func finishSignIn(_ creds: Credentials) async throws {
        var updated = savedAccounts
        let replaced = updated.add(creds)
        try credentialStore.save(updated)
        savedAccounts = updated
        activate(creds)
        if let replaced, replaced.appPassword != creds.appPassword {
            let oldAPI = makeAPI(replaced)
            Task { try? await oldAPI.revokeAppPassword() }
        }
        await loadBoards()
    }

    /// Shows `account`'s boards instead of the current account's.
    func switchAccount(to account: Account) async {
        guard account.id != activeAccount?.id, let creds = savedAccounts.credentials(for: account.id) else { return }
        savedAccounts.activate(account.id)
        try? credentialStore.save(savedAccounts)
        activate(creds)
        await loadBoards()
    }

    /// Makes `creds` the account in use, starting from an empty board list.
    private func activate(_ creds: Credentials) {
        resetSession()
        credentials = creds
        deckAPI = makeAPI(creds)
        accounts = savedAccounts.accounts
        isLoggedIn = true
        showingLogin = false
        restoreFromCache()
    }

    /// Forgets everything shown for the previous account.
    private func resetSession() {
        stopRecordingCache()
        connectionProblem = nil
        boards = []
        lists = [:]
        boardsETag = nil
        boardsETagDate = nil
        serverDeckVersion = nil
        checkedDeckVersion = false
        activityIsUnavailable = false
        for window in windows {
            window.sessionDidReset()
        }
        actionError = nil
        errorMessage = nil
    }
}

// MARK: - Searching all boards (#158)

@MainActor
extension AppState {
    /// Boards fetched at once by `loadAllCards`.
    private static let allCardsConcurrency = 4

    /// Fetches the cards of every board in the sidebar into `allCards`, skipping boards that haven't changed since
    /// they were last fetched (see `BoardCards.isCurrent`). With `includingArchived`, fetches archived cards too.
    /// A board that fails to load keeps what it had and is tried again next time; boards no longer listed are
    /// dropped.
    func loadAllCards(includingArchived: Bool = false) async {
        guard let api = deckAPI else { return }
        let boards = boardsInSidebarOrder
        let started = now()
        let listedAt = boardsETagDate ?? started
        let cached = allCards
        let stale = boards.filter { board in
            guard let cards = cached[board.id], cards.isCurrent(for: board) else { return true }
            return includingArchived && cards.archivedStacks == nil
        }
        isLoadingAllCards = true
        defer { isLoadingAllCards = false }
        var fetched: [Int: (stacks: [Stack], archived: [Stack]?)] = [:]
        for start in stride(from: 0, to: stale.count, by: Self.allCardsConcurrency) {
            let batch = stale[start ..< min(start + Self.allCardsConcurrency, stale.count)]
            await withTaskGroup(of: (Int, [Stack], [Stack]?)?.self) { group in
                for id in batch.map(\.id) {
                    group.addTask {
                        await Self.fetchCards(ofBoard: id, api: api, includingArchived: includingArchived)
                    }
                }
                for await result in group {
                    if let (id, stacks, archived) = result {
                        fetched[id] = (stacks, archived)
                    }
                }
            }
        }
        guard api === deckAPI else { return }
        var updated = cached.filter { id, _ in boards.contains { $0.id == id } }
        for board in boards {
            guard let (stacks, archived) = fetched[board.id] else { continue }
            let previous = updated[board.id]
            updated[board.id] = BoardCards(
                stacks: stacks,
                archivedStacks: archived,
                lastModified: board.lastModified,
                lastModifiedSeen: previous?.lastModified == board.lastModified
                    ? previous?.lastModifiedSeen ?? listedAt
                    : listedAt,
                fetched: started
            )
        }
        allCards = updated
    }

    /// One board's lists, and with `includingArchived` its archived cards; nil if the lists fail to load.
    private nonisolated static func fetchCards(
        ofBoard id: Int,
        api: DeckAPI,
        includingArchived: Bool
    ) async
        -> (Int, [Stack], [Stack]?)? {
        guard let stacks = try? await api.fetchStacks(boardId: id, ifNoneMatch: nil) else { return nil }
        let archived = includingArchived ? try? await api.getArchivedStacks(boardId: id) : nil
        return (id, stacks.value, archived)
    }

    /// Brings the board list and every board's cards up to date for the sidebar's search.
    func loadCardsForSearch() async {
        await refreshIfChanged()
        await loadAllCards(includingArchived: true)
    }

    /// What searching finds on `board`: its lists as shown if a window has it open and they've come from the server,
    /// else its cards from `allCards`, else what the Mac has.
    func searchableCards(of board: Board) -> SearchableCards {
        let cards = allCards[board.id]
        let open = lists[board.id]
        let stacks = open?.isFromServer == true ? open?.stacks : cards?.stacks ?? open?
            .stacks ?? cachedLists(of: board.id)
        return SearchableCards(stacks: stacks ?? [], archivedStacks: cards?.archivedStacks ?? [])
    }

    /// The cards matching `text`, grouped by board, for a window's sidebar search.
    func cardSearchResults(for text: String) -> [BoardSearchResults] {
        CardSearch.results(for: text, in: boardsInSidebarOrder, cards: searchableCards(of:))
    }
}

// MARK: - Notifications (#157)

@MainActor
extension AppState {
    /// Every active card on the boards that aren't archived, for reminders.
    var remindableCards: [RemindableCard] {
        activeBoards.flatMap { board in
            searchableCards(of: board).stacks.flatMap { stack in
                stack.activeCards.map { RemindableCard(card: $0, board: board, listTitle: stack.title) }
            }
        }
    }

    /// Fetches the boards that changed and updates the active account's reminders; with reminders off, does nothing.
    func updateReminders() async {
        guard let reminders, let api = deckAPI, let account = activeAccount else { return }
        if reminders.userId(for: account.id) == nil, let userId = try? await api.currentUserId() {
            reminders.setUserId(userId, for: account.id)
        }
        await loadAllCards()
        // Offline, only some boards' cards are known; the reminders already scheduled stay as they are (#156).
        guard activeAccount?.id == account.id, connectionProblem == nil else { return }
        // Until the server says, the name the user signed in with, which is usually their user id.
        let userId = reminders.userId(for: account.id) ?? account.username
        await reminders.update(cards: remindableCards, userId: userId, accountId: account.id, now: now())
    }
}

// MARK: - The copy on the Mac, and working offline (#156)

/// Each account's boards, and the lists and cards of the boards that were opened, are kept on the Mac (see
/// `BoardCacheStore`): shown at launch before the server answers, and read-only while it can't be reached.
@MainActor
extension AppState {
    /// Whether changes are turned off because the server can't be reached.
    var isReadOnly: Bool {
        connectionProblem != nil
    }

    /// When what's shown last came from the server: `boardId`'s lists, else the board list.
    func offlineDataDate(boardId: Int?) -> Date? {
        if let id = boardId, let lists = cacheSnapshot?.lists[id] {
            return lists.syncedAt
        }
        return cacheSnapshot?.boardsSyncedAt
    }

    /// `boardId`'s lists as saved on the Mac, in board order; nil if they weren't.
    func cachedLists(of boardId: Int) -> [Stack]? {
        cacheSnapshot?.lists[boardId].map { Self.sorted($0.stacks) }
    }

    /// Shows the active account's boards as saved on the Mac, with windows opening the board that was open (see
    /// `boardToOpen`), and starts recording what the server sends.
    private func restoreFromCache() {
        guard let account = activeAccount else { return }
        let snapshot = boardCache?.load(accountId: account.id) ?? BoardCacheSnapshot()
        cacheSnapshot = snapshot
        boards = snapshot.boards
        cacheAccountId = account.id
    }

    private func recordBoards() {
        guard cacheAccountId != nil else { return }
        guard var snapshot = cacheSnapshot else { return }
        let ids = Set(boards.map(\.id))
        snapshot.boards = boards
        snapshot.lists = snapshot.lists.filter { ids.contains($0.key) }
        cacheSnapshot = snapshot
        scheduleCacheWrite()
    }

    /// Records the board a window opened, to open again at launch.
    private func recordSelectedBoard(_ boardId: Int?) {
        guard cacheAccountId != nil, cacheSnapshot?.selectedBoardId != boardId else { return }
        cacheSnapshot?.selectedBoardId = boardId
        scheduleCacheWrite()
    }

    /// Records `boardId`'s lists as current now.
    private func recordLists(_ stacks: [Stack], boardId: Int) {
        guard cacheAccountId != nil else { return }
        cacheSnapshot?.lists[boardId] = BoardCacheSnapshot.Lists(stacks: stacks, syncedAt: now())
        scheduleCacheWrite()
    }

    /// An open board's lists were found to be unchanged on the server.
    private func listsAreCurrent(boardId: Int) {
        if let entry = lists[boardId], entry.isFromServer {
            recordLists(entry.stacks, boardId: boardId)
        }
    }

    /// Saves the copy a second after the last change, so a burst of changes is one write.
    private func scheduleCacheWrite() {
        guard boardCache != nil else { return }
        cacheWriteTask?.cancel()
        cacheWriteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flushCache()
        }
    }

    /// Saves the copy now, if anything from the server has been recorded.
    func flushCache() {
        cacheWriteTask?.cancel()
        cacheWriteTask = nil
        guard let cacheAccountId, let cacheSnapshot, cacheSnapshot.boardsSyncedAt != nil else { return }
        boardCache?.save(cacheSnapshot, accountId: cacheAccountId)
    }

    /// Saves the copy and stops recording, before switching accounts.
    private func stopRecordingCache() {
        flushCache()
        cacheAccountId = nil
        cacheSnapshot = nil
    }

    /// Deletes `accountId`'s copy, when signing out of it.
    private func forgetCache(of accountId: Account.ID) {
        if cacheAccountId == accountId {
            cacheWriteTask?.cancel()
            cacheWriteTask = nil
            cacheAccountId = nil
            cacheSnapshot = nil
        }
        boardCache?.remove(accountId: accountId)
    }

    /// If `error` means the server can't be reached, says so (showing the offline banner) and returns `true`.
    @discardableResult
    func noteConnectionProblem(_ error: Error) -> Bool {
        guard let problem = ConnectionProblem(error) else { return false }
        if connectionProblem != problem {
            connectionProblem = problem
        }
        return true
    }

    /// The server answered: editing is back on. With `boardsSyncedAt`, the board list is current as of then.
    private func serverWasReached(boardsSyncedAt: Date? = nil) {
        if connectionProblem != nil {
            connectionProblem = nil
        }
        if let boardsSyncedAt, cacheAccountId != nil {
            cacheSnapshot?.boardsSyncedAt = boardsSyncedAt
            scheduleCacheWrite()
        }
    }

    /// Tries the server again: the offline banner's Try Again, and every so often while it can't be reached.
    func reconnect() async {
        if boards.isEmpty {
            await loadBoards()
        } else {
            await refreshIfChanged()
        }
        if connectionProblem == nil {
            await updateReminders()
        }
    }
}

// MARK: - Windows and their boards' lists (#160)

/// The lists and cards of a board open in a window, in `AppState.lists`.
struct BoardLists {
    var stacks: [Stack] = []
    /// Whether `stacks` came from the server (and changes made since), rather than from the copy on the Mac.
    var isFromServer = false
    var isLoading = false
    var error: String?
    /// The lists' ETag, if Deck sent one, and when they were requested, for `refreshIfChanged()`.
    var etag: String?
    var fetchDate: Date?
    /// Incremented by every load of the board's lists; a response is only applied if no newer load has started.
    var generation = 0
}

@MainActor
extension AppState {
    /// The open windows.
    var windows: [BoardWindow] {
        windowRefs.compactMap(\.window)
    }

    /// The boards open in windows.
    var openBoardIds: Set<Int> {
        Set(windows.compactMap(\.selectedBoardId))
    }

    /// Whether a list is being dragged in any window, which holds off the background refresh.
    var isDraggingStack: Bool {
        windows.contains(where: \.isDraggingStack)
    }

    /// Keeps track of `window` (without keeping it open), so changes to the boards reach it.
    func register(_ window: BoardWindow) {
        windowRefs = windowRefs.filter { $0.window != nil } + [WeakBoardWindow(window: window)]
    }

    /// Whether a window can show `boardId`: it's in the board list and not deleted.
    func canOpen(_ boardId: Int) -> Bool {
        boards.contains { $0.id == boardId && !$0.isDeleted }
    }

    /// The board a window opens when it has none: the one open last, else the first in the sidebar.
    var boardToOpen: Int? {
        if let id = cacheSnapshot?.selectedBoardId, canOpen(id) {
            return id
        }
        return (activeBoards.first ?? archivedBoards.first)?.id
    }

    /// `window` opened `boardId` (or closed its board, for nil): shows the board's lists, as saved on the Mac until
    /// they load, and lets go of the lists of boards no window shows.
    func window(_ window: BoardWindow, opened boardId: Int?) {
        if let boardId {
            openLists(of: boardId)
            recordSelectedBoard(boardId)
        }
        let open = openBoardIds
        if lists.keys.contains(where: { !open.contains($0) }) {
            lists = lists.filter { open.contains($0.key) }
        }
    }

    /// Starts `boardId`'s lists from the copy on the Mac, unless they're already open.
    private func openLists(of boardId: Int) {
        guard lists[boardId] == nil else { return }
        lists[boardId] = BoardLists(stacks: cachedLists(of: boardId) ?? [])
    }

    /// Changes `boardId`'s lists, if they're open. With `newStacks`, the change gave it new lists, which the copy on
    /// the Mac records if they're the server's.
    private func updateLists(of boardId: Int, newStacks: Bool = false, _ change: (inout BoardLists) -> Void) {
        guard var entry = lists[boardId] else { return }
        change(&entry)
        lists[boardId] = entry
        if newStacks, entry.isFromServer {
            recordLists(entry.stacks, boardId: boardId)
        }
    }

    /// Shows `stacks` as `boardId`'s lists, ahead of the server, as when a card or list is moved.
    private func setStacks(_ stacks: [Stack], of boardId: Int) {
        updateLists(of: boardId, newStacks: true) { $0.stacks = stacks }
    }
}
