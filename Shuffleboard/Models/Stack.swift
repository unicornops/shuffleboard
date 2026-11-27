import Foundation

struct Stack: Identifiable, Codable {
    let id: Int
    var title: String
    var boardId: Int
    var deletedAt: Int?
    var lastModified: Int?
    var cards: [Card]?
    var order: Int

    init(
        id: Int,
        title: String,
        boardId: Int,
        deletedAt: Int? = nil,
        lastModified: Int? = nil,
        cards: [Card]? = nil,
        order: Int = 999
    ) {
        self.id = id
        self.title = title
        self.boardId = boardId
        self.deletedAt = deletedAt
        self.lastModified = lastModified
        self.cards = cards
        self.order = order
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIntOrString(forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.boardId = try c.decodeIntOrString(forKey: .boardId)
        self.deletedAt = try c.decodeIntOrStringIfPresent(forKey: .deletedAt)
        self.lastModified = try c.decodeIntOrStringIfPresent(forKey: .lastModified)
        self.order = try c.decodeIntOrStringIfPresent(forKey: .order) ?? 999
        if c.contains(.cards) {
            var decoded = (try? c.decode([Card].self, forKey: .cards)) ?? []
            // Ensure each card has the correct stackId (some Deck servers omit it
            // from the nested card objects since it is implicit from the parent stack).
            for i in decoded.indices where decoded[i].stackId == 0 {
                decoded[i].stackId = id
            }
            self.cards = decoded
        } else {
            self.cards = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, boardId, deletedAt, lastModified, cards, order
    }
}

extension Stack {
    /// The stack's cards that aren't archived, in board order.
    var activeCards: [Card] {
        (cards ?? []).filter { !$0.archived }.sorted { $0.order < $1.order }
    }

    /// The stack's archived cards, most recently changed first.
    var archivedCards: [Card] {
        (cards ?? []).filter(\.archived).sorted { ($0.lastModified ?? 0) > ($1.lastModified ?? 0) }
    }
}

extension [Stack] {
    /// These stacks with card `cardId` moved to position `index` among stack `stackId`'s active cards, numbered
    /// the way Deck renumbers them; `nil` if either isn't here. Shows a move straight away, before the server
    /// confirms it.
    func movingCard(_ cardId: Int, toStack stackId: Int, at index: Int) -> [Stack]? {
        guard let (stacks, card) = removingCard(cardId) else { return nil }
        return stacks.insertingCard(card, toStack: stackId, at: index)
    }

    /// These stacks without card `cardId`, and the card; `nil` if it isn't here. With `insertingCard`, shows a card
    /// moved to another board straight away (#204).
    func removingCard(_ cardId: Int) -> (stacks: [Stack], card: Card)? {
        guard let fromStack = firstIndex(where: { $0.cards?.contains { $0.id == cardId } == true }),
              let card = self[fromStack].cards?.first(where: { $0.id == cardId }) else { return nil }
        var stacks = self
        stacks[fromStack].cards?.removeAll { $0.id == cardId }
        return (stacks, card)
    }

    /// These stacks with `card` put at position `index` among stack `stackId`'s active cards, numbered the way Deck
    /// renumbers them; `nil` if the stack isn't here.
    func insertingCard(_ card: Card, toStack stackId: Int, at index: Int) -> [Stack]? {
        guard let toStack = firstIndex(where: { $0.id == stackId }) else { return nil }
        var stacks = self
        var card = card
        card.stackId = stackId
        var active = stacks[toStack].activeCards.filter { $0.id != card.id }
        active.insert(card, at: Swift.min(Swift.max(index, 0), active.count))
        for position in active.indices {
            active[position].order = position
        }
        stacks[toStack].cards = active + stacks[toStack].archivedCards
        return stacks
    }
}
