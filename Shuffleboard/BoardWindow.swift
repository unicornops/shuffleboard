import Foundation

// MARK: - BoardWindow

/// What one window shows (#160): its board, the card selected on it, the board's filter, the sidebar's search, and
/// the sheets and fields open in it. Everything else is the app's, in `AppState`: the accounts, the boards, and the
/// lists of every board open in a window, so windows on the same board show the same lists and a change made in one
/// shows in the others straight away.
///
/// Views read the board's lists through it but observe `AppState` too, which publishes their changes.
@MainActor
final class BoardWindow: ObservableObject {
    let app: AppState

    /// The open board; changing it clears the card selection and opens the board's lists in `AppState`.
    @Published var selectedBoardId: Int? {
        didSet {
            guard selectedBoardId != oldValue else { return }
            selectedCardId = nil
            newCardListId = nil
            app.window(self, opened: selectedBoardId)
        }
    }

    /// The card on the open board that the Card menu acts on, outlined on the board (#159).
    @Published var selectedCardId: Int?
    /// The card whose sheet is open, on the open board.
    @Published var openedCard: Card?
    /// The list showing its "new card" field.
    @Published var newCardListId: Int?
    /// The card waiting for the user to confirm deleting it.
    @Published var cardPendingDelete: Card?
    /// Which cards the open board shows; reset when switching boards.
    @Published var cardFilter = CardFilter()
    @Published var showingNewStack = false
    @Published var showingNewBoard = false
    @Published var showingArchivedCards = false
    /// Incremented by Edit > Filter Cards, to put the cursor in the filter field.
    @Published var filterFocusRequest = 0
    /// What the sidebar's search field is searching every board for.
    @Published var cardSearchText = ""
    /// Incremented by Edit > Search All Boards, to put the cursor in the sidebar's search field.
    @Published var cardSearchFocusRequest = 0
    /// A list is being dragged in this window, so the gaps between lists take drops.
    @Published var isDraggingStack = false

    /// A window on `boardId`, or on the board the app opens by default (see `AppState.boardToOpen`).
    init(app: AppState, boardId: Int? = nil) {
        self.app = app
        app.register(self)
        self.selectedBoardId = boardId.flatMap { app.canOpen($0) ? $0 : nil } ?? app.boardToOpen
        // Property observers don't run in an initialiser.
        app.window(self, opened: selectedBoardId)
    }

    var selectedBoard: Board? {
        guard let id = selectedBoardId else { return nil }
        return app.boards.first { $0.id == id }
    }

    /// The open board's lists in `AppState`; nil without a board.
    private var lists: BoardLists? {
        selectedBoardId.flatMap { app.lists[$0] }
    }

    /// The open board's lists and cards.
    var stacks: [Stack] {
        lists?.stacks ?? []
    }

    var isLoadingStacks: Bool {
        lists?.isLoading ?? false
    }

    var stacksError: String? {
        lists?.error
    }

    /// When what's shown last came from the server, for the offline banner (#156).
    var offlineDataDate: Date? {
        app.offlineDataDate(boardId: selectedBoardId)
    }

    /// The app's boards changed: a window whose board has gone (or was deleted) opens another, as does one without a
    /// board.
    func boardsDidChange() {
        if let id = selectedBoardId, app.canOpen(id) {
            return
        }
        selectedBoardId = app.boardToOpen
    }

    /// The app switched accounts: a new account's boards start unfiltered.
    func sessionDidReset() {
        cardFilter = CardFilter()
    }

    func selectBoard(_ board: Board) {
        // BoardDetailView's `.task(id: selectedBoardId)` loads the lists.
        selectedBoardId = board.id
    }

    /// Opens the board before (`offset` -1) or after (1) the open one in the sidebar.
    func selectBoard(offset: Int) {
        let boards = app.boardsInSidebarOrder
        guard !boards.isEmpty else { return }
        guard let current = boards.firstIndex(where: { $0.id == selectedBoardId }) else {
            selectedBoardId = boards.first?.id
            return
        }
        let next = current + offset
        if boards.indices.contains(next) {
            selectedBoardId = boards[next].id
        }
    }

    // MARK: - Boards and cards

    /// Creates a card at the end of the list and selects it, if the window is still on its board.
    func createCard(boardId: Int, stackId: Int, title: String) async {
        let cardId = await app.createCard(boardId: boardId, stackId: stackId, title: title)
        if let cardId, selectedBoardId == boardId {
            selectedCardId = cardId
        }
    }

    /// Restores a deleted board and opens it.
    func restoreBoard(id: Int) async {
        if await app.restoreBoard(id: id), app.canOpen(id) {
            selectedBoardId = id
        }
    }

    /// Copies a board and opens the copy; see `AppState.duplicateBoard`.
    func duplicateBoard(id: Int, options: BoardCopyOptions) async -> Bool {
        guard let copyId = await app.duplicateBoard(id: id, options: options) else { return false }
        selectedBoardId = copyId
        return true
    }

    // MARK: - Searching all boards (#158)

    /// The cards matching the sidebar's search, grouped by board.
    var cardSearchResults: [BoardSearchResults] {
        app.cardSearchResults(for: cardSearchText)
    }

    /// Opens a search result's board and the card; an archived card shows in the board's archived cards.
    func open(_ result: CardSearchResult) {
        selectedBoardId = result.boardId
        if result.card.archived {
            showingArchivedCards = true
        } else {
            selectedCardId = result.card.id
            openedCard = result.card
        }
    }

    /// Opens a card from a clicked notification (#157): switches to its account if need be, then opens its board
    /// and the card. Does nothing if the account has signed out or the card has gone.
    func openCard(id cardId: Int, boardId: Int, accountId: Account.ID) async {
        if app.activeAccount?.id != accountId, let account = app.accounts.first(where: { $0.id == accountId }) {
            await app.switchAccount(to: account)
        }
        guard app.activeAccount?.id == accountId, app.boards.contains(where: { $0.id == boardId }) else { return }
        selectedBoardId = boardId
        await app.loadStacks(boardId: boardId)
        guard selectedBoardId == boardId,
              let card = stacks.lazy.flatMap(\.activeCards).first(where: { $0.id == cardId }) else { return }
        selectedCardId = card.id
        openedCard = card
    }
}

// MARK: - Keyboard commands (#159)

/// What the File, Card and View menu commands do. They act on the selected card (`selectedCardId`), which the arrow
/// keys move around the open board.
extension BoardWindow {
    /// The selected card, while it's on the open board and the filter shows it.
    var selectedCard: Card? {
        guard let id = selectedCardId else { return nil }
        return stacks.lazy.flatMap(shownCards(in:)).first { $0.id == id }
    }

    /// The cards of `stack` that the board's filter shows, in order.
    func shownCards(in stack: Stack) -> [Card] {
        stack.activeCards.filter { cardFilter.matches($0) }
    }

    /// Moves the selection to the next card in `direction`, or to the first card if none is selected.
    func selectCard(_ direction: CardDirection) {
        if let id = stacks.cardId(from: selectedCard?.id, moving: direction, shown: shownCards(in:)) {
            selectedCardId = id
        }
    }

    func openSelectedCard() {
        openedCard = selectedCard
    }

    /// Whether the selected card can be moved: not while filtering, as with dragging, since a card's position
    /// counts the cards the filter hides, nor while the server can't be reached.
    var canMoveSelectedCard: Bool {
        selectedCard != nil && !cardFilter.isActive && !app.isReadOnly
    }

    /// Whether the selected card can be changed (marked done, archived, deleted).
    var canChangeSelectedCard: Bool {
        selectedCard != nil && !app.isReadOnly
    }

    /// Moves the selected card up or down its list, or to the list on either side; it stays selected.
    func moveSelectedCard(_ direction: CardDirection) async {
        guard canMoveSelectedCard, let boardId = selectedBoardId, let card = selectedCard,
              let destination = stacks.destination(movingCard: card.id, direction) else { return }
        await app.reorderCard(
            boardId: boardId,
            fromStackId: card.stackId,
            cardId: card.id,
            toStackId: destination.stackId,
            order: destination.order
        )
    }

    func toggleSelectedCardDone() async {
        guard canChangeSelectedCard, let boardId = selectedBoardId, let card = selectedCard else { return }
        await app.setCardDone(boardId: boardId, card: card, done: !card.isDone)
    }

    /// Archives the selected card and selects the one after it (or before it, at the end of the list).
    func archiveSelectedCard() async {
        guard canChangeSelectedCard, let boardId = selectedBoardId, let card = selectedCard else { return }
        let next = cardAfterRemoving(card)
        await app.archiveCard(card, boardId: boardId)
        if selectedCardId == card.id, selectedBoardId == boardId, selectedCard == nil {
            selectedCardId = next
        }
    }

    /// Asks to delete the selected card; `deletePendingCard()` deletes it once confirmed.
    func requestDeletingSelectedCard() {
        guard canChangeSelectedCard else { return }
        cardPendingDelete = selectedCard
    }

    /// Deletes the card waiting for confirmation, selecting the next one if it was selected.
    func deletePendingCard() async {
        guard let card = cardPendingDelete, let boardId = selectedBoardId else { return }
        cardPendingDelete = nil
        let next = cardAfterRemoving(card)
        let wasSelected = selectedCardId == card.id
        if await app.deleteCard(boardId: boardId, stackId: card.stackId, cardId: card.id), wasSelected,
           selectedBoardId == boardId {
            selectedCardId = next
        }
    }

    /// The card to select once `card` leaves its list: the next one shown, else the one before.
    private func cardAfterRemoving(_ card: Card) -> Int? {
        guard let stack = stacks.first(where: { $0.id == card.stackId }) else { return nil }
        let shown = shownCards(in: stack)
        guard let index = shown.firstIndex(where: { $0.id == card.id }) else { return nil }
        if index + 1 < shown.count {
            return shown[index + 1].id
        }
        return index > 0 ? shown[index - 1].id : nil
    }

    /// Shows the "new card" field in the selected card's list, or else the first list.
    func startNewCard() {
        guard !app.isReadOnly else { return }
        newCardListId = selectedCard?.stackId ?? stacks.first?.id
    }
}

/// `AppState`'s hold on a window, which doesn't keep it open.
struct WeakBoardWindow {
    weak var window: BoardWindow?
}
