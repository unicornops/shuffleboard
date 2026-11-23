import Foundation

// MARK: - DeleteConfirmation

/// Wording for delete confirmations, each a whole sentence so it can be translated (#162).
///
/// Deck soft-deletes boards, lists and cards: they can be restored until the server's cleanup job removes them,
/// after its trash retention (`trashRetentionHours`, 5 hours by default). Boards can be restored from "Recently
/// Deleted" in the sidebar; lists and cards from Deck in the browser.
enum DeleteConfirmation {
    /// Deleting the card titled `title`.
    static func card(_ title: String) -> String {
        String(
            localized: """
            “\(title)” will be deleted. You can restore it from Deck in your browser until the server clears \
            deleted items (after 5 hours by default).
            """,
            comment: "Confirming deleting a card; the card's title is in quotes."
        )
    }

    /// Deleting the card whose sheet is open.
    static var thisCard: String {
        String(
            localized: """
            This card will be deleted. You can restore it from Deck in your browser until the server clears \
            deleted items (after 5 hours by default).
            """,
            comment: "Confirming deleting the card that is open."
        )
    }

    /// Deleting the list titled `title`, with its cards.
    static func list(_ title: String) -> String {
        String(
            localized: """
            “\(title)” and all its cards will be deleted. You can restore it from Deck in your browser until the \
            server clears deleted items (after 5 hours by default).
            """,
            comment: "Confirming deleting a list; the list's title is in quotes."
        )
    }

    /// Deleting the board titled `title`.
    static func board(_ title: String) -> String {
        String(
            localized: """
            “\(title)” and all its lists and cards will be deleted. You can restore it from Recently Deleted in the \
            sidebar until the server clears deleted items (after 5 hours by default).
            """,
            comment: "Confirming deleting a board; the board's title is in quotes. Recently Deleted is in the sidebar."
        )
    }
}
