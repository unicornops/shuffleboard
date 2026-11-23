import AppIntents
import Foundation
import XCTest
@testable import Shuffleboard

/// The Shortcuts actions (#161) against `StubURLProtocol`, with the accounts in memory: what they ask the server, what
/// they return, and the errors Shortcuts shows.
@MainActor
final class ShortcutTests: XCTestCase {
    private var previousEnvironment: ShortcutsEnvironment!
    private let opened = Locked<[WindowDestination]>([])
    private let changedBoards = Locked<[Int]>([])
    private let rob = Credentials(serverURL: testServer, username: "rob", appPassword: "rob-app-password")
    private let amy = Credentials(
        serverURL: URL(string: "https://other.example/nextcloud")!,
        username: "amy",
        appPassword: "amy-app-password"
    )

    private nonisolated static let api = "/index.php/apps/deck/api/v1.0"
    private nonisolated static let now = Date(timeIntervalSince1970: 1_795_000_000)

    override func setUp() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.handler = Self.deckServer
        previousEnvironment = ShortcutsEnvironment.current
        signIn(rob)
    }

    override func tearDown() async throws {
        ShortcutsEnvironment.current = previousEnvironment
        StubURLProtocol.reset()
    }

    /// Makes the actions use `accounts`, the first one active.
    private func signIn(_ accounts: Credentials...) {
        var saved = SavedAccounts()
        for credentials in accounts {
            saved.add(credentials)
        }
        if let first = accounts.first {
            saved.activate(first.account.id)
        }
        let frozen = saved
        let opened = opened
        let changedBoards = changedBoards
        ShortcutsEnvironment.current = ShortcutsEnvironment(
            savedAccounts: { frozen },
            session: StubURLProtocol.session(),
            now: { Self.now },
            boardChanged: { _, boardId in changedBoards.withLock { $0.append(boardId) } },
            open: { destination in opened.withLock { $0.append(destination) } }
        )
    }

    // MARK: - The stub server

    /// Boards 1 (Home) and 2 (Work), archived board 3 (Old) and deleted board 4. Home has "To do" (cards 100–102)
    /// and "Done"; Work has "Inbox" (card 200).
    private nonisolated static let boardsJSON = """
    [{"id": 3, "title": "Old", "archived": true},
     {"id": 1, "title": "Home", "archived": false},
     {"id": 4, "title": "Gone", "archived": false, "deletedAt": 1700000000},
     {"id": 2, "title": "Work", "archived": false}]
    """

    private nonisolated static let homeCards = """
    [{"id": 100, "title": "Paint the shed", "stackId": 10, "order": 0, "archived": false,
      "duedate": "2026-11-20T12:00:00+00:00",
      "assignedUsers": [{"id": 1, "participant": {"uid": "rob", "displayname": "Rob"}, "type": 0}]},
     {"id": 101, "title": "Buy paint", "stackId": 10, "order": 1, "archived": false,
      "done": "2026-11-01T09:00:00+00:00"},
     {"id": 102, "title": "Paint the gate", "stackId": 10, "order": 2, "archived": true}]
    """

    private nonisolated static let workCards = """
    [{"id": 200, "title": "Write report", "description": "Paint costs", "stackId": 20, "order": 0, "archived": false,
      "duedate": "2026-12-01T12:00:00+00:00",
      "assignedUsers": [{"id": 2, "participant": {"uid": "bob", "displayname": "Bob"}, "type": 0}]}]
    """

    private nonisolated static let getResponses: [String: String] = [
        "/boards": boardsJSON,
        "/boards/1": #"{"id": 1, "title": "Home", "archived": false}"#,
        "/boards/2": #"{"id": 2, "title": "Work", "archived": false}"#,
        "/boards/1/stacks": #"""
        [{"id": 11, "title": "Done", "boardId": 1, "order": 1, "cards": []},
         {"id": 10, "title": "To do", "boardId": 1, "order": 0, "cards": \#(homeCards)}]
        """#,
        "/boards/1/stacks/10": #"{"id": 10, "title": "To do", "boardId": 1, "order": 0}"#,
        "/boards/1/stacks/11": #"{"id": 11, "title": "Done", "boardId": 1, "order": 1}"#,
        "/boards/2/stacks": #"[{"id": 20, "title": "Inbox", "boardId": 2, "order": 0, "cards": \#(workCards)}]"#,
        "/boards/3/stacks": "[]",
        "/boards/1/stacks/10/cards/100": #"{"id": 100, "title": "Paint the shed", "stackId": 10, "order": 0}"#,
    ]

    /// Answers like a Deck server with the boards above; a new card is card 300, echoing what was sent.
    private nonisolated static func deckServer(_ request: RecordedRequest) -> StubResponse {
        if request.path == "/ocs/v2.php/cloud/user" {
            return .json(#"{"ocs": {"meta": {"status": "ok"}, "data": {"id": "rob"}}}"#)
        }
        // The second account's server is at /nextcloud.
        var fullPath = request.path
        if fullPath.hasPrefix("/nextcloud/") {
            fullPath.removeFirst("/nextcloud".count)
        }
        guard fullPath.hasPrefix(api) else { return .status(404) }
        let path = String(fullPath.dropFirst(api.count))
        switch request.method {
        case "GET":
            return getResponses[path].map { .json($0) } ?? .status(404)
        case "POST" where path.hasSuffix("/cards"):
            var card = request.json ?? [:]
            card["id"] = 300
            card["stackId"] = Int(path.split(separator: "/").dropLast().last ?? "") ?? 0
            card["archived"] = false
            return .json(String(decoding: (try? JSONSerialization.data(withJSONObject: card)) ?? Data(), as: UTF8.self))
        case "PUT":
            var card = request.json ?? [:]
            card["id"] = Int(path.split(separator: "/").last ?? "") ?? 0
            card["stackId"] = Int(path.split(separator: "/").dropLast(2).last ?? "") ?? 0
            return .json(String(decoding: (try? JSONSerialization.data(withJSONObject: card)) ?? Data(), as: UTF8.self))
        default:
            return .status(404)
        }
    }

    private func requests(_ method: String, _ path: String) -> [RecordedRequest] {
        StubURLProtocol.requests.filter { $0.method == method && $0.path == Self.api + path }
    }

    private var home: BoardEntity {
        BoardEntity(Board(id: 1, title: "Home"), accountId: rob.account.id)
    }

    private func list(_ id: Int, _ title: String, board: Int = 1, boardTitle: String = "Home") -> ListEntity {
        ListEntity(Stack(id: id, title: title, boardId: board), boardTitle: boardTitle, accountId: rob.account.id)
    }

    private func cardEntity(id: Int = 100, stackId: Int = 10, listTitle: String = "To do") throws -> CardEntity {
        let json = #"{"id": \#(id), "title": "Paint the shed", "stackId": \#(stackId), "order": 0}"#
        let card = try JSONDecoder().decode(Card.self, from: Data(json.utf8))
        return CardEntity(card, listTitle: listTitle, boardId: 1, boardTitle: "Home", accountId: rob.account.id)
    }

    private func assertThrows(
        _ expected: ShortcutError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> some Any
    ) async {
        do {
            _ = try await body()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ShortcutError, expected, file: file, line: line)
        }
    }

    // MARK: - Add Card

    func testAddCardAddsTheCardToTheChosenList() async throws {
        let due = Date(timeIntervalSince1970: 1_796_000_000)
        let card = try await ShortcutActions().addCard(
            to: home,
            list: list(11, "Done"),
            title: "  Oil the hinges ",
            details: "Both doors",
            dueDate: due
        )

        let posted = try XCTUnwrap(requests("POST", "/boards/1/stacks/11/cards").first?.json)
        XCTAssertEqual(posted["title"] as? String, "Oil the hinges")
        XCTAssertEqual(posted["description"] as? String, "Both doors")
        XCTAssertEqual(posted["duedate"] as? String, DeckDate.string(from: due))
        XCTAssertEqual(card.cardId, 300)
        XCTAssertEqual(card.title, "Oil the hinges")
        XCTAssertEqual(card.listTitle, "Done")
        XCTAssertEqual(card.boardTitle, "Home")
        XCTAssertEqual(card.dueDate, due)
        XCTAssertEqual(changedBoards.withLock { $0 }, [1], "the app is told, so it shows the card")
    }

    func testAddCardIntentWithoutAListAddsToTheBoardsFirstList() async throws {
        let intent = AddCardIntent(board: home, list: nil, title: "Sweep the yard")
        _ = try await intent.perform()

        let posted = try XCTUnwrap(requests("POST", "/boards/1/stacks/10/cards").first?.json)
        XCTAssertEqual(posted["title"] as? String, "Sweep the yard")
        XCTAssertNil(posted["description"] as? String)
        XCTAssertEqual(posted["order"] as? Int, 999, "at the end of the list")
    }

    func testAddCardRejectsABlankOrTooLongTitleWithoutAskingTheServer() async {
        await assertThrows(.emptyTitle) {
            try await ShortcutActions().addCard(to: home, list: nil, title: " \n ", details: nil, dueDate: nil)
        }
        await assertThrows(.titleTooLong) {
            try await ShortcutActions().addCard(
                to: home,
                list: nil,
                title: String(repeating: "a", count: 256),
                details: nil,
                dueDate: nil
            )
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testAddCardRejectsAListFromAnotherBoard() async {
        await assertThrows(.listNotOnBoard) {
            try await ShortcutActions().addCard(
                to: home,
                list: list(20, "Inbox", board: 2, boardTitle: "Work"),
                title: "Misplaced",
                details: nil,
                dueDate: nil
            )
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testAddCardToABoardWithNoListsSaysSo() async {
        await assertThrows(.boardHasNoLists("Old")) {
            try await ShortcutActions().addCard(
                to: BoardEntity(Board(id: 3, title: "Old", archived: true), accountId: rob.account.id),
                list: nil,
                title: "Nowhere to go",
                details: nil,
                dueDate: nil
            )
        }
    }

    // MARK: - Find Cards

    private func findTitles(_ change: (inout CardCriteria) -> Void) async throws -> [String] {
        var criteria = CardCriteria()
        change(&criteria)
        return try await ShortcutActions().findCards(accountId: nil, matching: criteria).map(\.title)
    }

    func testFindCardsSearchesEveryShownBoardInSidebarOrder() async throws {
        let titles = try await findTitles { _ in }
        XCTAssertEqual(titles, ["Paint the shed", "Write report"], "done and archived cards are left out")
        XCTAssertTrue(requests("GET", "/boards/4/stacks").isEmpty, "a deleted board isn't searched")
        XCTAssertEqual(requests("GET", "/boards/3/stacks").count, 1, "an archived board is")
    }

    func testFindCardsByTextDueDateAndAssignment() async throws {
        let byText = try await findTitles { $0.text = "paint" }
        XCTAssertEqual(byText, ["Paint the shed", "Write report"], "title or description")
        let withDone = try await findTitles {
            $0.text = "paint"
            $0.includeDone = true
        }
        XCTAssertEqual(withDone, ["Paint the shed", "Buy paint", "Write report"])
        let dueSoon = try await findTitles { $0.dueBefore = DeckDate.parse("2026-11-25T00:00:00Z") }
        XCTAssertEqual(dueSoon, ["Paint the shed"])
        let mine = try await findTitles { $0.assignedToMe = true }
        XCTAssertEqual(mine, ["Paint the shed"])
        let onWork = try await findTitles { $0.boardId = 2 }
        XCTAssertEqual(onWork, ["Write report"])
    }

    func testFindCardsIntentReturnsCardEntities() async throws {
        var criteria = CardCriteria()
        criteria.text = "report"
        let intent = FindCardsIntent(criteria: criteria)
        _ = try await intent.perform()

        let found = try await ShortcutActions().findCards(accountId: nil, matching: criteria)
        let card = try XCTUnwrap(found.first)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(card.id, "2,200|rob@cloud.example")
        XCTAssertEqual(card.details, "Paint costs")
        XCTAssertEqual(card.listTitle, "Inbox")
        XCTAssertEqual(card.boardTitle, "Work")
        XCTAssertEqual(card.dueDate, DeckDate.parse("2026-12-01T12:00:00+00:00"))
        XCTAssertFalse(card.isDone)
    }

    // MARK: - Accounts

    func testActionsUseTheChosenAccountOrTheOneInUse() async throws {
        signIn(rob, amy)
        _ = try await ShortcutActions().boards(accountId: nil)
        XCTAssertEqual(
            StubURLProtocol.requests.last?.header("Authorization"),
            TestServer.basicAuth("rob", "rob-app-password")
        )

        _ = try await ShortcutActions().boards(accountId: amy.account.id)
        let request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(request.header("Authorization"), TestServer.basicAuth("amy", "amy-app-password"))
        XCTAssertEqual(request.path, "/nextcloud" + Self.api + "/boards")
    }

    func testBoardSuggestionsListEveryAccountsBoards() async throws {
        signIn(rob, amy)
        let boards = try await BoardQuery().suggestedEntities()
        XCTAssertEqual(boards.map(\.title), ["Home", "Work", "Old", "Home", "Work", "Old"])
        XCTAssertEqual(Set(boards.map(\.accountId)), [rob.account.id, amy.account.id])

        let found = try await BoardQuery().entities(for: [boards[4].id])
        XCTAssertEqual(found.map(\.id), [boards[4].id])
        XCTAssertEqual(found.first?.accountId, amy.account.id)
        let accounts = try await AccountQuery().suggestedEntities()
        XCTAssertEqual(accounts.map(\.id), [rob.account.id, amy.account.id])
    }

    func testListAndCardEntitiesAreFoundAgainByTheirIds() async throws {
        let lists = try await ShortcutActions().lists(accountId: rob.account.id, boardId: 1)
        XCTAssertEqual(lists.map(\.title), ["To do", "Done"])
        let again = try await ListQuery().entities(for: [lists[1].id])
        XCTAssertEqual(again.map(\.title), ["Done"])

        let card = try cardEntity(stackId: 11)
        let found = try await CardQuery().entities(for: [card.id])
        XCTAssertEqual(found.map(\.title), ["Paint the shed"], "the same card, though it has moved list")
        XCTAssertEqual(found.first?.stackId, 10)
    }

    func testItemReferencesRoundTrip() {
        let reference = ItemReference(accountId: "rob@cloud.example/nextcloud", ids: [3, 12])
        XCTAssertEqual(ItemReference(reference.string, count: 2), reference)
        XCTAssertNil(ItemReference(reference.string, count: 3))
        XCTAssertNil(ItemReference("3,12", count: 2))
    }

    // MARK: - Errors

    func testSignedOutAccountsGiveClearErrors() async {
        signIn()
        await assertThrows(.signedOut) { try await ShortcutActions().boards(accountId: nil) }
        await assertThrows(.signedOut) { try await BoardQuery().suggestedEntities() }

        signIn(rob)
        await assertThrows(.accountSignedOut(amy.account.id)) {
            try await ShortcutActions().boards(accountId: amy.account.id)
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testServerProblemsGiveClearErrors() async {
        StubURLProtocol.handler = { _ in StubResponse(error: URLError(.cannotConnectToHost)) }
        await assertThrows(.serverUnreachable("cloud.example")) { try await ShortcutActions().boards(accountId: nil) }

        StubURLProtocol.handler = { _ in StubResponse(error: URLError(.notConnectedToInternet)) }
        await assertThrows(.offline) { try await ShortcutActions().boards(accountId: nil) }

        StubURLProtocol.handler = { _ in .status(503) }
        await assertThrows(.serverUnreachable("cloud.example")) { try await ShortcutActions().boards(accountId: nil) }

        StubURLProtocol.handler = { _ in .status(401) }
        await assertThrows(.sessionEnded(rob.account.id)) { try await ShortcutActions().boards(accountId: nil) }

        StubURLProtocol.handler = { _ in .status(404) }
        await assertThrows(.cardNotFound) { try await ShortcutActions().setDone(self.cardEntity(), done: true) }
    }

    func testErrorMessagesSayWhatWentWrong() {
        let unreachable = ShortcutError.serverUnreachable("cloud.example").errorDescription ?? ""
        XCTAssertTrue(unreachable.contains("cloud.example"), unreachable)
        let ended = ShortcutError.sessionEnded("rob@cloud.example").errorDescription ?? ""
        XCTAssertTrue(ended.contains("rob@cloud.example") && ended.contains("sign in again"), ended)
        XCTAssertEqual(
            ShortcutError.signedOut.errorDescription,
            "You're not signed in. Open Shuffleboard and sign in, then try again."
        )
    }

    // MARK: - Mark Card as Done

    func testMarkCardDoneUpdatesTheCardAsItIsNow() async throws {
        let intent = try MarkCardDoneIntent(card: cardEntity())
        _ = try await intent.perform()

        let put = try XCTUnwrap(requests("PUT", "/boards/1/stacks/10/cards/100").first?.json)
        XCTAssertEqual(put["done"] as? String, DeckDate.string(from: Self.now))
        XCTAssertEqual(put["title"] as? String, "Paint the shed")
        XCTAssertEqual(changedBoards.withLock { $0 }, [1])
    }

    func testMarkCardDoneUsesTheListTheCardIsInNow() async throws {
        StubURLProtocol.handler = { request in
            if request.method == "GET", request.path.hasSuffix("/cards/100") {
                return .json(#"{"id": 100, "title": "Paint the shed", "stackId": 11, "order": 0}"#)
            }
            return Self.deckServer(request)
        }
        let card = try await ShortcutActions().setDone(cardEntity(), done: true)

        XCTAssertEqual(requests("PUT", "/boards/1/stacks/11/cards/100").count, 1, "not moved back to its old list")
        XCTAssertTrue(card.isDone)
        XCTAssertEqual(card.listTitle, "Done")
    }

    func testMarkingACardNotDoneWhenItIsntChangesNothing() async throws {
        let card = try await ShortcutActions().setDone(cardEntity(), done: false)
        XCTAssertFalse(card.isDone)
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.method == "PUT" })
        XCTAssertTrue(changedBoards.withLock { $0 }.isEmpty)
    }

    // MARK: - Open Board and Open Card

    func testOpenIntentsAskTheAppToShowTheBoardOrCard() async throws {
        _ = try await OpenBoardIntent(board: home).perform()
        _ = try await OpenCardIntent(card: cardEntity()).perform()

        XCTAssertEqual(opened.withLock { $0 }, [
            .board(accountId: rob.account.id, boardId: 1),
            .card(accountId: rob.account.id, boardId: 1, cardId: 100),
        ])
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "the app loads what it needs")
    }

    func testOpeningABoardOfASignedOutAccountFails() async {
        let board = BoardEntity(Board(id: 1, title: "Home"), accountId: amy.account.id)
        await assertThrows(.accountSignedOut(amy.account.id)) { try await OpenBoardIntent(board: board).perform() }
        XCTAssertTrue(opened.withLock { $0 }.isEmpty)
    }

    func testAWindowOpensTheBoardAShortcutAsksFor() async throws {
        let store = InMemoryCredentialStore.signedIn()
        let app = AppState(credentialStore: store, session: StubURLProtocol.session(), openURL: { _ in })
        await waitUntil { !app.boards.isEmpty && !app.isLoading }
        let account = try XCTUnwrap(app.activeAccount)

        await app.window.openBoard(id: 2, accountId: account.id)
        XCTAssertEqual(app.window.selectedBoardId, 2)
        await app.window.openBoard(id: 4, accountId: account.id)
        XCTAssertEqual(app.window.selectedBoardId, 2, "a deleted board doesn't open")
        await app.window.openBoard(id: 1, accountId: "someone@else.example")
        XCTAssertEqual(app.window.selectedBoardId, 2, "an account that isn't signed in")
    }
}
