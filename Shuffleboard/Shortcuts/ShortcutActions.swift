import Foundation

// MARK: - CardCriteria

/// Which cards Find Cards returns. With nothing set, every card that isn't done, on every board.
struct CardCriteria: Sendable {
    /// Words the card's title, description, labels or assignees must all have, as the app's search matches them.
    var text: String?
    /// Only cards due before this.
    var dueBefore: Date?
    /// Only cards assigned to the signed-in user.
    var assignedToMe = false
    /// Done cards too.
    var includeDone = false
    /// Only this board's cards.
    var boardId: Int?

    /// Whether `card` matches, given the signed-in user's id (needed only with `assignedToMe`).
    func matches(_ card: Card, userId: String?) -> Bool {
        if !includeDone, card.isDone {
            return false
        }
        if let dueBefore {
            guard let due = card.dueDate, due < dueBefore else { return false }
        }
        if assignedToMe {
            guard let userId, CardReminders.isAssigned(card, to: userId) else { return false }
        }
        if let text {
            let words = CardSearch.words(in: text)
            if !words.isEmpty, !CardSearch.matches(card, words: words) {
                return false
            }
        }
        return true
    }
}

// MARK: - ShortcutActions

/// What the Shortcuts actions do (#161), against the signed-in accounts' servers through `DeckAPI`, without the app's
/// state or windows (see `ShortcutsEnvironment`). Errors are `ShortcutError`s, which Shortcuts shows.
struct ShortcutActions: Sendable {
    var environment: ShortcutsEnvironment = .current

    /// Boards fetched at once when searching every board, as the app's search does.
    private static let concurrency = 4

    // MARK: Accounts

    func signedInAccounts() -> [Account] {
        environment.savedAccounts().accounts
    }

    /// The credentials of `accountId`, or of the account in use in the app when it's nil.
    func credentials(for accountId: Account.ID?) throws -> Credentials {
        let saved = environment.savedAccounts()
        guard let active = saved.active else { throw ShortcutError.signedOut }
        guard let accountId else { return active }
        guard let credentials = saved.credentials(for: accountId) else {
            throw ShortcutError.accountSignedOut(accountId)
        }
        return credentials
    }

    /// Runs `body` with a client for `accountId` (the account in use when nil), turning its errors into
    /// `ShortcutError`s; a 404 becomes `notFound`.
    private func withAPI<Result>(
        _ accountId: Account.ID?,
        notFound: ShortcutError,
        _ body: (DeckAPI, Account) async throws -> Result
    ) async throws
        -> Result {
        let credentials = try credentials(for: accountId)
        let api = DeckAPI(
            serverURL: credentials.serverURL,
            username: credentials.username,
            appPassword: credentials.appPassword,
            session: environment.session
        )
        do {
            return try await body(api, credentials.account)
        } catch {
            throw ShortcutError.from(error, account: credentials.account, notFound: notFound)
        }
    }

    // MARK: Boards and lists

    /// The boards the app's sidebar lists, in its order: those that aren't archived, then archived ones. Deleted
    /// boards are left out.
    static func shownBoards(_ boards: [Board]) -> [Board] {
        let kept = boards.filter { !$0.isDeleted }
        return kept.filter { !$0.archived } + kept.filter(\.archived)
    }

    /// `accountId`'s boards (the account in use when nil).
    func boards(accountId: Account.ID?) async throws -> [BoardEntity] {
        try await withAPI(accountId, notFound: .boardNotFound) { api, account in
            try await Self.shownBoards(api.getBoards()).map { BoardEntity($0, accountId: account.id) }
        }
    }

    /// Every signed-in account's boards. An account whose server can't be reached is left out, unless none can be.
    func allBoards() async throws -> [BoardEntity] {
        let accounts = signedInAccounts()
        guard !accounts.isEmpty else { throw ShortcutError.signedOut }
        var boards: [BoardEntity] = []
        var firstError: Error?
        for account in accounts {
            do {
                boards += try await self.boards(accountId: account.id)
            } catch {
                firstError = firstError ?? error
            }
        }
        if boards.isEmpty, let firstError {
            throw firstError
        }
        return boards
    }

    /// The lists of board `boardId`, in board order.
    func lists(accountId: Account.ID, boardId: Int) async throws -> [ListEntity] {
        try await withAPI(accountId, notFound: .boardNotFound) { api, account in
            let board = try await api.getBoard(id: boardId)
            let stacks = try await api.getStacks(boardId: boardId)
            return AppState.sorted(stacks).map { ListEntity($0, boardTitle: board.title, accountId: account.id) }
        }
    }

    // MARK: Cards

    /// Adds a card at the end of `list`, or of the board's first list without one, and returns it.
    func addCard(
        to board: BoardEntity,
        list: ListEntity?,
        title: String,
        details: String?,
        dueDate: Date?
    ) async throws
        -> CardEntity {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ShortcutError.emptyTitle }
        guard title.count <= ShortcutError.maxTitleLength else { throw ShortcutError.titleTooLong }
        if let list, list.accountId != board.accountId || list.boardId != board.boardId {
            throw ShortcutError.listNotOnBoard
        }
        let details = details?.trimmingCharacters(in: .whitespacesAndNewlines)
        let card = try await withAPI(
            board.accountId,
            notFound: list == nil ? .boardNotFound : .listNotFound
        ) { api, _ in
            let stack: Stack
            if let list {
                stack = try await api.getStack(boardId: board.boardId, stackId: list.stackId)
            } else {
                guard let first = try await AppState.sorted(api.getStacks(boardId: board.boardId)).first else {
                    throw ShortcutError.boardHasNoLists(board.title)
                }
                stack = first
            }
            let card = try await api.createCard(
                boardId: board.boardId,
                stackId: stack.id,
                title: title,
                description: details?.isEmpty == false ? details : nil,
                duedate: dueDate.map(DeckDate.string(from:))
            )
            return CardEntity(
                card,
                listTitle: stack.title,
                boardId: board.boardId,
                boardTitle: board.title,
                accountId: board.accountId
            )
        }
        await environment.boardChanged(board.accountId, board.boardId)
        return card
    }

    /// The cards of `accountId` (the account in use when nil) that match `criteria`, in board order: by board as the
    /// sidebar lists them, then by list, then by position in the list. Archived cards are left out.
    func findCards(accountId: Account.ID?, matching criteria: CardCriteria) async throws -> [CardEntity] {
        try await withAPI(accountId, notFound: .boardNotFound) { api, account in
            var boards: [Board] = if let boardId = criteria.boardId {
                try await [api.getBoard(id: boardId)]
            } else {
                try await Self.shownBoards(api.getBoards())
            }
            var userId: String?
            if criteria.assignedToMe {
                userId = try await api.currentUserId()
            }
            var stacks: [Int: [Stack]] = [:]
            for start in stride(from: 0, to: boards.count, by: Self.concurrency) {
                let batch = boards[start ..< min(start + Self.concurrency, boards.count)].map(\.id)
                try await withThrowingTaskGroup(of: (Int, [Stack]).self) { group in
                    for id in batch {
                        group.addTask { try await (id, api.getStacks(boardId: id)) }
                    }
                    for try await (id, boardStacks) in group {
                        stacks[id] = boardStacks
                    }
                }
            }
            return boards.flatMap { board in
                AppState.sorted(stacks[board.id] ?? []).flatMap { stack in
                    stack.activeCards
                        .filter { criteria.matches($0, userId: userId) }
                        .map {
                            CardEntity(
                                $0,
                                listTitle: stack.title,
                                boardId: board.id,
                                boardTitle: board.title,
                                accountId: account.id
                            )
                        }
                }
            }
        }
    }

    /// Marks `card` done, or not done, and returns it as it is now. A card already that way is left as it is.
    func setDone(_ card: CardEntity, done: Bool) async throws -> CardEntity {
        var changed = false
        let updated = try await withAPI(card.accountId, notFound: .cardNotFound) { api, account in
            // The card as it is now, so the update (which sends every field) changes nothing else.
            var current = try await api.getCard(boardId: card.boardId, stackId: card.stackId, cardId: card.cardId)
            if current.stackId == 0 {
                current.stackId = card.stackId
            }
            if current.isDone != done {
                let edited = current.withSchedule(
                    startDate: current.startDate,
                    dueDate: current.dueDate,
                    isDone: done,
                    now: environment.now()
                )
                // The card's list now, not when the shortcut found it: Deck moves a card to the list in the URL.
                let stackId = current.stackId
                current = try await api.updateCard(boardId: card.boardId, stackId: stackId, card: edited)
                if current.stackId == 0 {
                    current.stackId = stackId
                }
                changed = true
            }
            var listTitle = card.listTitle
            if current.stackId != card.stackId {
                listTitle = try await api.getStack(boardId: card.boardId, stackId: current.stackId).title
            }
            return CardEntity(
                current,
                listTitle: listTitle,
                boardId: card.boardId,
                boardTitle: card.boardTitle,
                accountId: account.id
            )
        }
        if changed {
            await environment.boardChanged(card.accountId, card.boardId)
        }
        return updated
    }

    // MARK: Opening

    /// Shows `destination` in the app, if its account is still signed in.
    @MainActor
    func open(_ destination: WindowDestination) throws {
        let accountId = switch destination {
        case let .board(accountId, _), let .card(accountId, _, _): accountId
        }
        _ = try credentials(for: accountId)
        environment.open(destination)
    }
}
