import Foundation

/// A notification about a card (#157): it's due soon, it's overdue, or it was just assigned to you; or, at startup,
/// the cards that are already overdue.
struct CardReminder: Equatable, Sendable {
    enum Kind: String, Sendable {
        case dueSoon
        case overdue
        case assigned
        case overdueSummary
    }

    let kind: Kind
    let accountId: String
    let boardId: Int
    let cardId: Int
    let title: String
    let body: String
    /// When it's due to be shown; on or before now means straight away.
    let date: Date
    /// For a due-date reminder, the due date it's for: a new due date makes a new reminder.
    let dueDate: Date?

    /// Stable for a card, kind and due date, so a reminder isn't shown twice and a changed due date replaces it.
    var id: String {
        let due = dueDate.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        return "card-reminder|\(kind.rawValue)|\(accountId)|\(cardId)|\(due)"
    }
}

/// A card that could have reminders: an active card on a board that isn't archived, with where it is.
struct RemindableCard {
    let card: Card
    let board: Board
    let listTitle: String
}

/// Which reminders the cards need (#157). Due dates follow the same rule as Deck's own overdue notifications (see
/// `wantsDueReminders`), and only while the card isn't done; archived cards and cards on archived boards aren't
/// passed in.
enum CardReminders {
    /// How long before a card's due date the "due soon" reminder is shown.
    static let dueSoonLead: TimeInterval = 24 * 60 * 60

    static func isAssigned(_ card: Card, to userId: String) -> Bool {
        card.assignments.contains { $0.type == CardAssignment.userType && $0.participant.uid == userId }
    }

    /// Whether `userId` gets reminders for `item`'s due date, as Deck decides for its own notifications: never if the
    /// board's due date notifications are off, always if they're set to all cards or the board is the user's own and
    /// not shared, and otherwise (the default, "assigned") when the card is assigned to them.
    static func wantsDueReminders(_ item: RemindableCard, userId: String) -> Bool {
        switch item.board.settings?.notifyDue {
        case "off":
            false

        case "all":
            true

        default:
            (item.board.owner?.uid == userId && item.board.acl.isEmpty) || isAssigned(item.card, to: userId)
        }
    }

    /// For each undone card with a due date that `userId` wants reminders for: a reminder a day before it's due (or
    /// straight away
    /// if that has passed but the card isn't due yet) and one when it's due.
    static func dueReminders(for cards: [RemindableCard], userId: String, accountId: String, now: Date)
        -> [CardReminder] {
        cards.flatMap { item -> [CardReminder] in
            guard let due = item.card.dueDate, !item.card.isDone,
                  wantsDueReminders(item, userId: userId) else { return [] }
            let soon = CardReminder(
                kind: .dueSoon,
                accountId: accountId,
                boardId: item.board.id,
                cardId: item.card.id,
                title: "Due soon: \(item.card.title)",
                body: "\(place(item)) \u{00b7} due \(due.formatted(date: .abbreviated, time: .shortened))",
                date: max(due.addingTimeInterval(-dueSoonLead), min(now, due)),
                dueDate: due
            )
            let overdue = CardReminder(
                kind: .overdue,
                accountId: accountId,
                boardId: item.board.id,
                cardId: item.card.id,
                title: "Overdue: \(item.card.title)",
                body: "\(place(item)) \u{00b7} was due \(due.formatted(date: .abbreviated, time: .shortened))",
                date: due,
                dueDate: due
            )
            // Once it's overdue, "due soon" is old news.
            return due > now ? [soon, overdue] : [overdue]
        }
    }

    /// A reminder that `item` was just assigned to the user.
    static func assignedReminder(for item: RemindableCard, accountId: String, now: Date) -> CardReminder {
        CardReminder(
            kind: .assigned,
            accountId: accountId,
            boardId: item.board.id,
            cardId: item.card.id,
            title: "Assigned to you: \(item.card.title)",
            body: place(item),
            date: now,
            dueDate: nil
        )
    }

    /// One notification for every undone card `userId` wants reminders for that is already overdue, shown when the app
    /// starts instead of one per card; nil if none is. It opens the card that has been overdue longest.
    static func overdueSummary(for cards: [RemindableCard], userId: String, accountId: String, now: Date)
        -> CardReminder? {
        let overdue = cards
            .filter { wantsDueReminders($0, userId: userId) && $0.card.isOverdue(at: now) }
            .sorted { ($0.card.dueDate ?? now) < ($1.card.dueDate ?? now) }
        guard let first = overdue.first else { return nil }
        let title: String
        let body: String
        if overdue.count == 1 {
            title = "Overdue: \(first.card.title)"
            body = place(first)
        } else {
            title = "\(overdue.count) cards are overdue"
            let named = overdue.prefix(3).map(\.card.title).joined(separator: ", ")
            body = overdue.count > 3 ? "\(named) and \(overdue.count - 3) more" : named
        }
        return CardReminder(
            kind: .overdueSummary,
            accountId: accountId,
            boardId: first.board.id,
            cardId: first.card.id,
            title: title,
            body: body,
            date: now,
            // Unique per startup, so it's never mistaken for one already shown.
            dueDate: now
        )
    }

    private static func place(_ item: RemindableCard) -> String {
        "\(item.board.title) \u{203a} \(item.listTitle)"
    }
}
