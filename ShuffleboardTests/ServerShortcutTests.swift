import Foundation
import XCTest
@testable import Shuffleboard

/// The Shortcuts actions (#161) against a real Nextcloud server with Deck: Add Card run as Shortcuts runs it, with the
/// board and list picked through the actions' entity queries, then the card checked on the server; and Find Cards and
/// Mark Card as Done on that card. Credentials stay in memory. Skipped without a test server (see `TestServer`).
@MainActor
final class ServerShortcutTests: XCTestCase {
    private var server: TestServer!
    private var previousEnvironment: ShortcutsEnvironment!

    override func setUp() async throws {
        server = try TestServer.require()
        previousEnvironment = ShortcutsEnvironment.current
    }

    override func tearDown() async throws {
        if let previousEnvironment {
            ShortcutsEnvironment.current = previousEnvironment
        }
    }

    func testAddCardShortcutAddsTheCardOnTheServer() async throws {
        let credentials = try await server.credentials(for: TestServer.alice)
        var saved = SavedAccounts()
        saved.add(credentials)
        let accounts = saved
        ShortcutsEnvironment.current = ShortcutsEnvironment(
            savedAccounts: { accounts },
            session: URLSession(configuration: .ephemeral),
            open: { _ in }
        )
        let api = DeckAPI(
            serverURL: credentials.serverURL,
            username: credentials.username,
            appPassword: credentials.appPassword,
            session: URLSession(configuration: .ephemeral)
        )

        try await withTemporaryBoard(api, title: uniqueTitle("E2E shortcuts")) { board in
            _ = try await api.createStack(boardId: board.id, title: "Inbox", order: 0)
            let later = try await api.createStack(boardId: board.id, title: "Later", order: 1)

            // Picked the way the Shortcuts editor offers them.
            let boards = try await BoardQuery().suggestedEntities()
            let boardEntity = try XCTUnwrap(boards.first { $0.boardId == board.id })
            let lists = try await ShortcutActions().lists(accountId: boardEntity.accountId, boardId: board.id)
            XCTAssertEqual(lists.map(\.title), ["Inbox", "Later"])
            let list = try XCTUnwrap(lists.first { $0.stackId == later.id })

            let title = uniqueTitle("Shortcut card")
            let due = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded() * 60 + 3 * 86400)
            let intent = AddCardIntent(
                board: boardEntity,
                list: list,
                title: title,
                details: "Added by a shortcut",
                dueDate: due
            )
            _ = try await intent.perform()

            // On the server, in the list chosen, as the shortcut said.
            let stacks = try await api.getStacks(boardId: board.id)
            let added = try XCTUnwrap(
                stacks.first { $0.id == later.id }?.activeCards.first { $0.title == title },
                "The card isn't in the list on \(server.version)"
            )
            XCTAssertEqual(added.description, "Added by a shortcut")
            XCTAssertEqual(try XCTUnwrap(added.dueDate).timeIntervalSince1970, due.timeIntervalSince1970, accuracy: 1)
            XCTAssertFalse(added.isDone)

            // Find Cards finds it, and Mark Card as Done marks it done there.
            var criteria = CardCriteria()
            criteria.text = title
            criteria.boardId = board.id
            let found = try await ShortcutActions().findCards(accountId: nil, matching: criteria)
            XCTAssertEqual(found.map(\.cardId), [added.id])
            let card = try XCTUnwrap(found.first)
            XCTAssertEqual(card.listTitle, "Later")

            _ = try await MarkCardDoneIntent(card: card).perform()
            let marked = try await api.getCard(boardId: board.id, stackId: later.id, cardId: added.id)
            XCTAssertTrue(marked.isDone, "Not marked done on \(server.version)")
            XCTAssertEqual(marked.title, title, "Marking it done changed nothing else")
            XCTAssertEqual(marked.description, "Added by a shortcut")
        }
    }
}
