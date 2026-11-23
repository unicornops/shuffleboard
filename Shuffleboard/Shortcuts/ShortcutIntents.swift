import AppIntents
import Foundation

// MARK: - Add Card

/// Adds a card to a list on a board (#161). Runs without opening a window.
struct AddCardIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Card"
    static let description = IntentDescription("Adds a card to the end of a list on one of your boards.")

    @Parameter(title: "Board")
    var board: BoardEntity

    @Parameter(
        title: "List",
        description: "The list to add the card to. Without one, it goes in the board's first list."
    )
    var list: ListEntity?

    @Parameter(title: "Title")
    var cardTitle: String

    @Parameter(title: "Description")
    var details: String?

    @Parameter(title: "Due Date")
    var dueDate: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$cardTitle) to \(\.$list) on \(\.$board)") {
            \.$details
            \.$dueDate
        }
    }

    init() {}

    init(board: BoardEntity, list: ListEntity?, title: String, details: String? = nil, dueDate: Date? = nil) {
        self.board = board
        self.list = list
        self.cardTitle = title
        self.details = details
        self.dueDate = dueDate
    }

    func perform() async throws -> some IntentResult & ReturnsValue<CardEntity> & ProvidesDialog {
        let card = try await ShortcutActions().addCard(
            to: board,
            list: list,
            title: cardTitle,
            details: details,
            dueDate: dueDate
        )
        return .result(value: card, dialog: "Added \(card.title) to \(card.listTitle).")
    }
}

// MARK: - Find Cards

/// Finds cards by text, due date and assignment (#161), and returns them for the rest of the shortcut.
struct FindCardsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Cards"
    static let description = IntentDescription(
        "Finds the cards on your boards that match. Leaves out archived cards, and done cards unless you include them."
    )

    @Parameter(title: "Containing", description: "Words the card's title, description, labels or assignees must have.")
    var text: String?

    @Parameter(title: "Due Before")
    var dueBefore: Date?

    @Parameter(title: "Assigned to Me", default: false)
    var assignedToMe: Bool

    @Parameter(title: "Include Done Cards", default: false)
    var includeDone: Bool

    @Parameter(title: "Board", description: "Only this board's cards.")
    var board: BoardEntity?

    @Parameter(
        title: "Account",
        description: "Which account to search, if you're signed in to several. Without one, the account you're using."
    )
    var account: AccountEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Find cards containing \(\.$text)") {
            \.$dueBefore
            \.$assignedToMe
            \.$includeDone
            \.$board
            \.$account
        }
    }

    init() {}

    init(criteria: CardCriteria, board: BoardEntity? = nil, account: AccountEntity? = nil) {
        self.text = criteria.text
        self.dueBefore = criteria.dueBefore
        self.assignedToMe = criteria.assignedToMe
        self.includeDone = criteria.includeDone
        self.board = board
        self.account = account
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[CardEntity]> {
        var criteria = CardCriteria()
        criteria.text = text
        criteria.dueBefore = dueBefore
        criteria.assignedToMe = assignedToMe
        criteria.includeDone = includeDone
        criteria.boardId = board?.boardId
        // A board belongs to one account, so choosing one chooses its account.
        let cards = try await ShortcutActions().findCards(
            accountId: board?.accountId ?? account?.id,
            matching: criteria
        )
        return .result(value: cards)
    }
}

// MARK: - Mark Card as Done

/// Marks a card done, or not done (#161). Runs without opening a window.
struct MarkCardDoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Card as Done"
    static let description = IntentDescription("Marks a card as done, or as not done.")

    @Parameter(title: "Card")
    var card: CardEntity

    @Parameter(title: "Done", default: true)
    var isDone: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Mark \(\.$card) as done") {
            \.$isDone
        }
    }

    init() {}

    init(card: CardEntity, isDone: Bool = true) {
        self.card = card
        self.isDone = isDone
    }

    func perform() async throws -> some IntentResult & ReturnsValue<CardEntity> & ProvidesDialog {
        let updated = try await ShortcutActions().setDone(card, done: isDone)
        let dialog: IntentDialog = isDone
            ? "Marked \(updated.title) as done."
            : "Marked \(updated.title) as not done."
        return .result(value: updated, dialog: dialog)
    }
}

// MARK: - Open Board and Open Card

/// Opens a board in Shuffleboard's window in front (#161).
struct OpenBoardIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Board"
    static let description = IntentDescription("Opens a board in Shuffleboard.")
    static let openAppWhenRun = true

    @Parameter(title: "Board")
    var target: BoardEntity

    init() {}

    init(board: BoardEntity) {
        self.target = board
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try ShortcutActions().open(.board(accountId: target.accountId, boardId: target.boardId))
        return .result()
    }
}

/// Opens a card on its board in Shuffleboard's window in front (#161).
struct OpenCardIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Card"
    static let description = IntentDescription("Opens a card in Shuffleboard.")
    static let openAppWhenRun = true

    @Parameter(title: "Card")
    var target: CardEntity

    init() {}

    init(card: CardEntity) {
        self.target = card
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try ShortcutActions().open(.card(accountId: target.accountId, boardId: target.boardId, cardId: target.cardId))
        return .result()
    }
}

// MARK: - App Shortcuts

/// The actions offered in Spotlight and the Shortcuts app without making a shortcut first.
struct ShuffleboardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddCardIntent(),
            phrases: ["Add a card in \(.applicationName)"],
            shortTitle: "Add Card",
            systemImageName: "plus.rectangle.on.rectangle"
        )
        AppShortcut(
            intent: FindCardsIntent(),
            phrases: ["Find cards in \(.applicationName)"],
            shortTitle: "Find Cards",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: OpenBoardIntent(),
            phrases: ["Open a board in \(.applicationName)"],
            shortTitle: "Open Board",
            systemImageName: "rectangle.split.3x1"
        )
    }
}
