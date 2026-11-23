import AppIntents
import Foundation

// MARK: - References

/// Which account's board, list or card a Shortcuts entity (#161) is, and its ids on that account's server: the board's;
/// the board's and the list's; or the board's and the card's. Entities use it as their `id`, written as
/// `3,12|rob@cloud.example`, so a saved shortcut keeps pointing at the same item.
struct ItemReference: Hashable, Sendable {
    let accountId: Account.ID
    let ids: [Int]

    init(accountId: Account.ID, ids: [Int]) {
        self.accountId = accountId
        self.ids = ids
    }

    /// Reads `string` (see `string`), if it has `count` ids and an account.
    init?(_ string: String, count: Int) {
        guard let bar = string.firstIndex(of: "|") else { return nil }
        let ids = string[..<bar].split(separator: ",").compactMap { Int($0) }
        let accountId = String(string[string.index(after: bar)...])
        guard ids.count == count, !accountId.isEmpty else { return nil }
        self.init(accountId: accountId, ids: ids)
    }

    var string: String {
        ids.map(String.init).joined(separator: ",") + "|" + accountId
    }
}

// MARK: - Accounts

/// A signed-in account, for choosing which one a shortcut uses when there are several.
struct AccountEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
    static let defaultQuery = AccountQuery()

    let id: Account.ID
    let username: String
    let server: String

    init(_ account: Account) {
        self.id = account.id
        self.username = account.username
        self.server = account.serverName
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(username)", subtitle: "\(server)")
    }
}

struct AccountQuery: EntityQuery {
    func entities(for identifiers: [AccountEntity.ID]) async throws -> [AccountEntity] {
        ShortcutActions().signedInAccounts().filter { identifiers.contains($0.id) }.map(AccountEntity.init)
    }

    func suggestedEntities() async throws -> [AccountEntity] {
        ShortcutActions().signedInAccounts().map(AccountEntity.init)
    }
}

// MARK: - Boards

/// A board of a signed-in account.
struct BoardEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Board"
    static let defaultQuery = BoardQuery()

    let id: String
    let reference: ItemReference
    @Property(title: "Name")
    var title: String
    @Property(title: "Archived")
    var isArchived: Bool

    init(_ board: Board, accountId: Account.ID) {
        let reference = ItemReference(accountId: accountId, ids: [board.id])
        self.reference = reference
        self.id = reference.string
        self.title = board.title
        self.isArchived = board.archived
    }

    var accountId: Account.ID {
        reference.accountId
    }

    var boardId: Int {
        reference.ids[0]
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(accountId)")
    }
}

struct BoardQuery: EntityStringQuery {
    func entities(for identifiers: [BoardEntity.ID]) async throws -> [BoardEntity] {
        let references = identifiers.compactMap { ItemReference($0, count: 1) }
        let accountIds = Set(references.map(\.accountId))
        var found: [BoardEntity] = []
        for accountId in accountIds.sorted() {
            found += try await ShortcutActions().boards(accountId: accountId)
        }
        return found.filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [BoardEntity] {
        try await ShortcutActions().allBoards().filter { $0.title.localizedStandardContains(string) }
    }

    func suggestedEntities() async throws -> [BoardEntity] {
        try await ShortcutActions().allBoards()
    }
}

// MARK: - Lists

/// A list (a stack, in Deck's API) on a board.
struct ListEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "List"
    static let defaultQuery = ListQuery()

    let id: String
    let reference: ItemReference
    @Property(title: "Name")
    var title: String
    @Property(title: "Board")
    var boardTitle: String

    init(_ stack: Stack, boardTitle: String, accountId: Account.ID) {
        let reference = ItemReference(accountId: accountId, ids: [stack.boardId, stack.id])
        self.reference = reference
        self.id = reference.string
        self.title = stack.title
        self.boardTitle = boardTitle
    }

    var accountId: Account.ID {
        reference.accountId
    }

    var boardId: Int {
        reference.ids[0]
    }

    var stackId: Int {
        reference.ids[1]
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(boardTitle)")
    }
}

struct ListQuery: EntityQuery {
    /// The board chosen in Add Card, so only its lists are offered.
    @IntentParameterDependency<AddCardIntent>(\.$board)
    var addCard

    func entities(for identifiers: [ListEntity.ID]) async throws -> [ListEntity] {
        let references = identifiers.compactMap { ItemReference($0, count: 2) }
        let boards = Set(references.map { ItemReference(accountId: $0.accountId, ids: [$0.ids[0]]) })
        var found: [ListEntity] = []
        for board in boards.sorted(by: { $0.string < $1.string }) {
            found += try await ShortcutActions().lists(accountId: board.accountId, boardId: board.ids[0])
        }
        return found.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ListEntity] {
        let actions = ShortcutActions()
        if let board = addCard?.board {
            return try await actions.lists(accountId: board.accountId, boardId: board.boardId)
        }
        var lists: [ListEntity] = []
        for board in try await actions.allBoards() where !board.isArchived {
            lists += try await actions.lists(accountId: board.accountId, boardId: board.boardId)
        }
        return lists
    }
}

// MARK: - Cards

/// A card, with what Shortcuts can show or pass on: its title, description, due date, whether it's done, and its list
/// and board.
struct CardEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Card"
    static let defaultQuery = CardQuery()

    /// Its board and card; not its list, so a card moved to another list is still the same card.
    let id: String
    let reference: ItemReference
    /// The card's list when it was found.
    let stackId: Int
    @Property(title: "Title")
    var title: String
    @Property(title: "Description")
    var details: String
    @Property(title: "Due Date")
    var dueDate: Date?
    @Property(title: "Done")
    var isDone: Bool
    @Property(title: "List")
    var listTitle: String
    @Property(title: "Board")
    var boardTitle: String

    init(_ card: Card, listTitle: String, boardId: Int, boardTitle: String, accountId: Account.ID) {
        let reference = ItemReference(accountId: accountId, ids: [boardId, card.id])
        self.reference = reference
        self.id = reference.string
        self.stackId = card.stackId
        self.title = card.title
        self.details = card.description ?? ""
        self.dueDate = card.dueDate
        self.isDone = card.isDone
        self.listTitle = listTitle
        self.boardTitle = boardTitle
    }

    var accountId: Account.ID {
        reference.accountId
    }

    var boardId: Int {
        reference.ids[0]
    }

    var cardId: Int {
        reference.ids[1]
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(listTitle) on \(boardTitle)")
    }
}

struct CardQuery: EntityStringQuery {
    func entities(for identifiers: [CardEntity.ID]) async throws -> [CardEntity] {
        let references = identifiers.compactMap { ItemReference($0, count: 2) }
        let boards = Set(references.map { ItemReference(accountId: $0.accountId, ids: [$0.ids[0]]) })
        var found: [CardEntity] = []
        for board in boards.sorted(by: { $0.string < $1.string }) {
            var criteria = CardCriteria()
            criteria.boardId = board.ids[0]
            criteria.includeDone = true
            found += try await ShortcutActions().findCards(accountId: board.accountId, matching: criteria)
        }
        return found.filter { identifiers.contains($0.id) }
    }

    /// Cards in the account in use whose title, description, labels or assignees have every word of `string`.
    func entities(matching string: String) async throws -> [CardEntity] {
        var criteria = CardCriteria()
        criteria.text = string
        return try await ShortcutActions().findCards(accountId: nil, matching: criteria)
    }

    /// The cards assigned to you in the account in use that aren't done yet.
    func suggestedEntities() async throws -> [CardEntity] {
        var criteria = CardCriteria()
        criteria.assignedToMe = true
        return try await ShortcutActions().findCards(accountId: nil, matching: criteria)
    }
}
