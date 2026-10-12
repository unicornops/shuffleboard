import Foundation

// MARK: - Keyboard commands (#159)

/// What the File, Card and View menu commands do. They act on the selected card (`selectedCardId`), which the arrow
/// keys move around the open board.
@MainActor
extension AppState {
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
    /// counts the cards the filter hides.
    var canMoveSelectedCard: Bool {
        selectedCard != nil && !cardFilter.isActive
    }

    /// Moves the selected card up or down its list, or to the list on either side; it stays selected.
    func moveSelectedCard(_ direction: CardDirection) async {
        guard canMoveSelectedCard, let boardId = selectedBoardId, let card = selectedCard,
              let destination = stacks.destination(movingCard: card.id, direction) else { return }
        await reorderCard(
            boardId: boardId,
            fromStackId: card.stackId,
            cardId: card.id,
            toStackId: destination.stackId,
            order: destination.order
        )
    }

    func toggleSelectedCardDone() async {
        guard let boardId = selectedBoardId, let card = selectedCard else { return }
        await setCardDone(boardId: boardId, card: card, done: !card.isDone)
    }

    /// Archives the selected card and selects the one after it (or before it, at the end of the list).
    func archiveSelectedCard() async {
        guard let boardId = selectedBoardId, let card = selectedCard else { return }
        let next = cardAfterRemoving(card)
        await archiveCard(card, boardId: boardId)
        if selectedCardId == card.id, selectedBoardId == boardId, selectedCard == nil {
            selectedCardId = next
        }
    }

    /// Asks to delete the selected card; `deletePendingCard()` deletes it once confirmed.
    func requestDeletingSelectedCard() {
        cardPendingDelete = selectedCard
    }

    /// Deletes the card waiting for confirmation, selecting the next one if it was selected.
    func deletePendingCard() async {
        guard let card = cardPendingDelete, let boardId = selectedBoardId else { return }
        cardPendingDelete = nil
        let next = cardAfterRemoving(card)
        let wasSelected = selectedCardId == card.id
        if await deleteCard(boardId: boardId, stackId: card.stackId, cardId: card.id), wasSelected,
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
        newCardListId = selectedCard?.stackId ?? stacks.first?.id
    }

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

    /// Opens the board before (`offset` -1) or after (1) the open one in the sidebar.
    func selectBoard(offset: Int) {
        let boards = boardsInSidebarOrder
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
}
