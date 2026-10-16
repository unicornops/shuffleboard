import Foundation
import XCTest
@testable import Shuffleboard

/// `AppState` behaviour against `StubURLProtocol`, with credentials kept in memory.
@MainActor
final class AppStateTests: XCTestCase {
    private var store: InMemoryCredentialStore!
    private nonisolated static let boardsJSON = #"[{"id": 1, "title": "One", "archived": false}, {"id": 2, "title": "Two", "archived": false}]"#

    override func setUp() async throws {
        StubURLProtocol.reset()
        store = .signedIn()
    }

    override func tearDown() async throws {
        StubURLProtocol.reset()
    }

    private nonisolated static func stacksJSON(_ ids: [Int], board: Int) -> String {
        "[" + ids.enumerated().map { index, id in
            #"{"id": \#(id), "title": "S\#(id)", "boardId": \#(board), "order": \#(index), "cards": []}"#
        }.joined(separator: ",") + "]"
    }

    private nonisolated static func boardId(fromStacksPath path: String) -> Int? {
        let parts = path.split(separator: "/")
        guard let index = parts.firstIndex(of: "boards"), parts.last == "stacks" else { return nil }
        return Int(parts[parts.index(after: index)])
    }

    /// An `AppState` signed in against the stub, with board 1 selected and its lists loaded.
    private func makeSignedInApp() async -> AppState {
        let app = AppState(credentialStore: store, session: StubURLProtocol.session(), openURL: { _ in })
        await waitUntil { app.window.selectedBoardId == 1 && !app.isLoading }
        await app.loadStacks(boardId: 1)
        return app
    }

    // MARK: - Lists (#56)

    func testSlowResponseForPreviousBoardDoesNotReplaceCurrentBoard() async {
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/boards") {
                return .json(Self.boardsJSON)
            }
            guard let board = Self.boardId(fromStacksPath: request.path) else { return .status(404) }
            return .json(Self.stacksJSON([board * 10], board: board), delay: board == 1 ? 0.5 : 0.05)
        }
        let app = await makeSignedInApp()

        let slow = Task { await app.loadStacks(boardId: 1) }
        await sleep(seconds: 0.05)
        app.window.selectBoard(app.boards[1])
        await app.loadStacks(boardId: 2)
        await slow.value

        XCTAssertEqual(app.window.stacks.map(\.boardId), [2])
        XCTAssertFalse(app.window.isLoadingStacks)
    }

    func testRefreshingSameBoardKeepsListsVisible() async {
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/boards") {
                return .json(Self.boardsJSON)
            }
            return .json(Self.stacksJSON([10, 20], board: 1), delay: 0.3)
        }
        let app = await makeSignedInApp()

        let refresh = Task { await app.loadStacks(boardId: 1) }
        await sleep(seconds: 0.1)
        XCTAssertTrue(app.window.isLoadingStacks)
        XCTAssertEqual(app.window.stacks.map(\.id), [10, 20], "lists must not flash empty while refreshing")
        await refresh.value
    }

    // MARK: - Ended session (#57)

    func testUnauthorizedSignsOutAndClearsCredentials() async {
        StubURLProtocol.handler = { request in
            request.path.hasSuffix("/boards") ? .json(Self.boardsJSON) : .status(401)
        }
        let app = await makeSignedInApp()

        await app.deleteCard(boardId: 1, stackId: 10, cardId: 5)

        XCTAssertFalse(app.isLoggedIn)
        XCTAssertTrue(app.showingLogin)
        XCTAssertNil(store.credentials)
        XCTAssertNil(app.actionError)
        XCTAssertNotNil(app.errorMessage, "the login screen explains why")
    }

    func testForbiddenShowsBannerAndStaysSignedIn() async {
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/boards") {
                return .json(Self.boardsJSON)
            }
            if request.method == "DELETE" {
                return .status(403)
            }
            return .json(Self.stacksJSON([10], board: 1))
        }
        let app = await makeSignedInApp()

        await app.deleteCard(boardId: 1, stackId: 10, cardId: 5)

        XCTAssertTrue(app.isLoggedIn)
        XCTAssertEqual(app.actionError, DeckAPIError.permissionDenied.localizedDescription)
    }

    // MARK: - Sign out (#58)

    func testSignOutRevokesAppPassword() async {
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/boards") {
                return .json(Self.boardsJSON)
            }
            return .json(Self.stacksJSON([10], board: 1))
        }
        let app = await makeSignedInApp()

        await app.signOut()

        XCTAssertFalse(app.isLoggedIn)
        XCTAssertNil(store.credentials)
        XCTAssertTrue(StubURLProtocol.requests.contains { $0.line == "DELETE /ocs/v2.php/core/apppassword" })
    }

    func testSignOutSucceedsOffline() async {
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/apppassword") {
                return StubResponse(error: URLError(.notConnectedToInternet))
            }
            if request.path.hasSuffix("/boards") {
                return .json(Self.boardsJSON)
            }
            return .json(Self.stacksJSON([10], board: 1))
        }
        let app = await makeSignedInApp()

        await app.signOut()

        XCTAssertFalse(app.isLoggedIn)
        XCTAssertNil(app.actionError)
        XCTAssertNil(app.errorMessage)
    }

    // MARK: - List reorder (#60)

    func testFailedReorderStopsAndReloads() async {
        let serverOrder = Locked([10, 20, 30, 40])
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/boards") {
                return .json(Self.boardsJSON)
            }
            if request.method == "PUT" {
                guard let id = Int(request.path.split(separator: "/").last ?? ""), id != 10 else { return .status(500) }
                let order = request.json?["order"] as? Int ?? 0
                serverOrder.withLock { ids in
                    ids.removeAll { $0 == id }
                    ids.insert(id, at: min(order, ids.count))
                }
                return .json(#"{"id": \#(id), "title": "S", "boardId": 1, "order": \#(order)}"#)
            }
            return .json(Self.stacksJSON(serverOrder.withLock { $0 }, board: 1))
        }
        let app = await makeSignedInApp()
        XCTAssertEqual(app.window.stacks.map(\.id), [10, 20, 30, 40])

        // Move the last list to the front: 40 is saved, then 10's update fails.
        await app.reorderStacks(boardId: 1, fromIndex: 3, toIndex: 0)

        let puts = StubURLProtocol.requests.filter { $0.method == "PUT" }.map { $0.path.split(separator: "/").last }
        XCTAssertEqual(puts, ["40", "10"], "stops after the failed update")
        XCTAssertNotNil(app.actionError)
        XCTAssertEqual(
            app.window.stacks.map(\.id),
            serverOrder.withLock { $0 },
            "the board shows what the server saved"
        )
    }

    // MARK: - Due dates and done state (#73)

    private nonisolated static let cardJSON = """
    {"id": 5, "title": "Card", "stackId": 10, "order": 0, "archived": false, "owner": "rob"}
    """

    func testSavingTheSheetSendsDueDateAndDone() async throws {
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/boards") {
                return .json(Self.boardsJSON)
            }
            if request.method == "PUT" {
                return .json(Self.cardJSON)
            }
            return .json(Self.stacksJSON([10], board: 1))
        }
        let app = await makeSignedInApp()
        let card = try JSONDecoder().decode(Card.self, from: Data(Self.cardJSON.utf8))
        let start = try XCTUnwrap(DeckDate.parse("2026-10-03T09:00:00+00:00"))
        let due = try XCTUnwrap(DeckDate.parse("2026-10-10T12:00:00+00:00"))

        let saved = await app.updateCard(
            boardId: 1,
            stackId: 10,
            card: card,
            edits: CardEdits(title: "Card", description: "", startDate: start, dueDate: due, isDone: true)
        )

        XCTAssertTrue(saved)
        let put = try XCTUnwrap(StubURLProtocol.requests.first { $0.method == "PUT" })
        XCTAssertEqual(put.path, "/index.php/apps/deck/api/v1.0/boards/1/stacks/10/cards/5")
        XCTAssertEqual(DeckDate.parse(put.json?["duedate"] as? String), due)
        XCTAssertEqual(DeckDate.parse(put.json?["startdate"] as? String), start)
        XCTAssertNotNil(DeckDate.parse(put.json?["done"] as? String))

        // A start after the due date isn't sent: Deck would accept it.
        let before = StubURLProtocol.requests.count
        let refused = await app.updateCard(
            boardId: 1,
            stackId: 10,
            card: card,
            edits: CardEdits(title: "Card", description: "", startDate: due, dueDate: start, isDone: false)
        )
        XCTAssertFalse(refused)
        XCTAssertEqual(app.errorMessage, CardEdits.datesOutOfOrderMessage)
        XCTAssertEqual(StubURLProtocol.requests.count, before)
    }

    func testMarkingDoneFromTheBoard() async throws {
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/boards") {
                return .json(Self.boardsJSON)
            }
            if request.method == "PUT" {
                return .json(Self.cardJSON)
            }
            return .json(Self.stacksJSON([10], board: 1))
        }
        let app = await makeSignedInApp()
        let card = try JSONDecoder().decode(Card.self, from: Data(Self.cardJSON.utf8))

        await app.setCardDone(boardId: 1, card: card, done: true)

        let put = try XCTUnwrap(StubURLProtocol.requests.first { $0.method == "PUT" })
        XCTAssertNotNil(DeckDate.parse(put.json?["done"] as? String))
        XCTAssertNil(app.actionError)
    }

    // MARK: - Assignments (#74)

    func testAssigningReportsErrorsInTheBanner() async throws {
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/boards") {
                return .json(Self.boardsJSON)
            }
            if request.path.hasSuffix("/assignUser") {
                return .json(#"{"status": 400, "message": "The user is not part of the board"}"#, status: 400)
            }
            return .json(Self.stacksJSON([10], board: 1))
        }
        let app = await makeSignedInApp()
        let card = try JSONDecoder().decode(Card.self, from: Data(Self.cardJSON.utf8))

        await app.assignUser(DeckUser(uid: "mallory"), boardId: 1, card: card)

        XCTAssertEqual(app.actionError, "The user is not part of the board")
    }

    // MARK: - Automatic refresh (#79)

    /// A fake Deck server whose ETags change whenever its data does.
    private final class FakeDeck: Sendable {
        struct State {
            var boardIds = [1, 2]
            var stackIds = [10, 20]
            var version = 1
            var stacksStatus = 200
            /// Real Deck sends none for the lists (#141).
            var stacksHaveETag = true
        }

        let state = Locked(State())

        func handle(_ request: RecordedRequest) -> StubResponse {
            let current = state.withLock { $0 }
            let etag = "\"v\(current.version)\""
            if request.path.hasSuffix("/boards") {
                if request.header("If-None-Match") == etag {
                    return .status(304)
                }
                let boards = current.boardIds.map { #"{"id": \#($0), "title": "B\#($0)", "archived": false}"# }
                return StubResponse(body: Data("[\(boards.joined(separator: ","))]".utf8), headers: ["ETag": etag])
            }
            if current.stacksStatus != 200 {
                return .status(current.stacksStatus)
            }
            guard current.stacksHaveETag else {
                return .json(AppStateTests.stacksJSON(current.stackIds, board: 1))
            }
            if request.header("If-None-Match") == etag {
                return .status(304)
            }
            return StubResponse(
                body: Data(AppStateTests.stacksJSON(current.stackIds, board: 1).utf8),
                headers: ["ETag": etag]
            )
        }
    }

    private func makeFakeDeckApp() async -> (AppState, FakeDeck) {
        let deck = FakeDeck()
        StubURLProtocol.handler = { deck.handle($0) }
        return await (makeSignedInApp(), deck)
    }

    func testRefreshPicksUpChangesMadeElsewhere() async {
        let (app, deck) = await makeFakeDeckApp()
        XCTAssertEqual(app.window.stacks.map(\.id), [10, 20])

        deck.state.withLock { $0.stackIds = [10, 20, 30]
            $0.version = 2
        }
        await app.refreshIfChanged()

        XCTAssertEqual(app.window.stacks.map(\.id), [10, 20, 30])
        XCTAssertFalse(app.window.isLoadingStacks)
    }

    func testUnchangedRefreshIsAConditionalNoOp() async {
        let (app, _) = await makeFakeDeckApp()
        let before = StubURLProtocol.requests.count

        await app.refreshIfChanged()

        let refreshRequests = StubURLProtocol.requests.dropFirst(before)
        XCTAssertEqual(refreshRequests.count, 2, "one conditional request for boards, one for lists")
        XCTAssertTrue(refreshRequests.allSatisfy { $0.header("If-None-Match") == "\"v1\"" })
        XCTAssertEqual(app.window.stacks.map(\.id), [10, 20])
    }

    /// An app whose clock the test moves: `clock` starts when the boards and lists were loaded.
    private func makeFakeDeckAppWithClock() async -> (AppState, FakeDeck, Locked<Date>) {
        let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let deck = FakeDeck()
        deck.state.withLock { $0.stacksHaveETag = false }
        StubURLProtocol.handler = { deck.handle($0) }
        let app = AppState(credentialStore: store, session: StubURLProtocol.session(), openURL: { _ in })
        app.now = { clock.withLock { $0 } }
        await waitUntil { app.window.selectedBoardId == 1 && !app.isLoading }
        await app.loadStacks(boardId: 1)
        return (app, deck, clock)
    }

    private func requests(during action: () async -> Void) async -> [String] {
        let before = StubURLProtocol.requests.count
        await action()
        return StubURLProtocol.requests.dropFirst(before).map(\.line)
    }

    /// #141: Deck's lists have no ETag, so they are only downloaded when the board list changed.
    func testUnchangedBoardListSkipsDownloadingTheLists() async {
        let (app, _, clock) = await makeFakeDeckAppWithClock()
        // The lists on screen came in the same second as the board list's ETag, so they are fetched once more.
        clock.withLock { $0 += 60 }
        let first = await requests { await app.refreshIfChanged() }
        XCTAssertEqual(first.count, 2, "lists fetched in the ETag's second are fetched again")

        clock.withLock { $0 += 60 }
        let second = await requests { await app.refreshIfChanged() }
        XCTAssertEqual(
            second,
            ["GET /index.php/apps/deck/api/v1.0/boards?details=true"],
            "unchanged board list: no lists download"
        )
        XCTAssertEqual(app.window.stacks.map(\.id), [10, 20])
    }

    func testChangedBoardListDownloadsTheLists() async {
        let (app, deck, clock) = await makeFakeDeckAppWithClock()
        clock.withLock { $0 += 60 }
        await app.refreshIfChanged()

        deck.state.withLock { $0.stackIds = [10, 20, 30]
            $0.version = 2
        }
        clock.withLock { $0 += 60 }
        await app.refreshIfChanged()

        XCTAssertEqual(app.window.stacks.map(\.id), [10, 20, 30])
    }

    /// A change in the same second as the board list's ETag doesn't change it; the lists still pick it up.
    func testChangeInTheETagsSecondIsNotMissed() async {
        let (app, deck, clock) = await makeFakeDeckAppWithClock()
        deck.state.withLock { $0.stackIds = [10, 20, 30] } // Same ETag.

        clock.withLock { $0 += 0.5 }
        await app.refreshIfChanged()

        XCTAssertEqual(app.window.stacks.map(\.id), [10, 20, 30])
    }

    func testRefreshErrorsAreSilent() async {
        let (app, deck) = await makeFakeDeckApp()
        deck.state.withLock { $0.stacksStatus = 500 }

        await app.refreshIfChanged()

        XCTAssertNil(app.actionError)
        XCTAssertNil(app.window.stacksError)
        XCTAssertEqual(app.window.stacks.map(\.id), [10, 20], "keeps the lists it has")
    }

    func testRefreshMovesOffABoardDeletedElsewhere() async {
        let (app, deck) = await makeFakeDeckApp()
        deck.state.withLock { $0.boardIds = [2]
            $0.version = 2
        }

        await app.refreshIfChanged()

        XCTAssertEqual(app.window.selectedBoardId, 2)
    }

    func testRefreshSignsOutWhenThePasswordIsRevoked() async {
        let (app, _) = await makeFakeDeckApp()
        StubURLProtocol.handler = { _ in .status(401) }

        await app.refreshIfChanged()

        XCTAssertFalse(app.isLoggedIn)
        XCTAssertNil(store.credentials)
    }

    // MARK: - Comments (#75)

    func testCommentFailuresGoToTheBanner() async throws {
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/boards") {
                return .json(Self.boardsJSON)
            }
            if request.path.contains("/comments") {
                return .json(#"{"ocs": {"meta": {"message": "Comment too long"}, "data": []}}"#, status: 400)
            }
            return .json(Self.stacksJSON([10], board: 1))
        }
        let app = await makeSignedInApp()
        let card = try JSONDecoder().decode(Card.self, from: Data(Self.cardJSON.utf8))

        let comment = await app.addComment("x", to: card)

        XCTAssertNil(comment)
        XCTAssertEqual(app.actionError, "Comment too long")
        XCTAssertEqual(app.currentUserId, "rob", "edit/delete are offered on the signed-in user's own comments")
    }

    // MARK: - Archive (#76)

    func testArchivingReloadsTheBoard() async throws {
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/boards") {
                return .json(Self.boardsJSON)
            }
            if request.method == "PUT" {
                return .json("{}")
            }
            return .json(Self.stacksJSON([10], board: 1))
        }
        let app = await makeSignedInApp()
        let card = try JSONDecoder().decode(Card.self, from: Data(Self.cardJSON.utf8))
        let before = StubURLProtocol.requests.count

        await app.archiveCard(card, boardId: 1)

        let after = StubURLProtocol.requests.dropFirst(before).map(\.line)
        XCTAssertEqual(after.first, "PUT /index.php/apps/deck/api/v1.0/boards/1/stacks/10/cards/5/archive")
        XCTAssertEqual(after.last, "GET /index.php/apps/deck/api/v1.0/boards/1/stacks")
        XCTAssertNil(app.actionError)
    }

    func testUnarchiveFailureIsReported() async throws {
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/boards") {
                return .json(Self.boardsJSON)
            }
            if request.path.hasSuffix("/unarchive") {
                return .status(403)
            }
            return .json(Self.stacksJSON([10], board: 1))
        }
        let app = await makeSignedInApp()
        let card = try JSONDecoder().decode(Card.self, from: Data(Self.cardJSON.utf8))

        let restored = await app.unarchiveCard(card, boardId: 1)

        XCTAssertFalse(restored)
        XCTAssertEqual(app.actionError, DeckAPIError.permissionDenied.localizedDescription)
    }

    // MARK: - Sharing (#80)

    func testSharingRefreshesTheBoard() async throws {
        let sharedBoard = #"{"id": 1, "title": "One", "archived": false, "acl": [{"id": 3, "participant": {"uid": "alice"}, "type": 0, "permissionEdit": false, "permissionShare": false, "permissionManage": false}]}"#
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/boards") {
                return .json(Self.boardsJSON)
            }
            if request.path.hasSuffix("/acl") {
                return .json("{}")
            }
            if request.path.hasSuffix("/boards/1") {
                return .json(sharedBoard)
            }
            return .json(Self.stacksJSON([10], board: 1))
        }
        let app = await makeSignedInApp()
        let board = try XCTUnwrap(app.boards.first)

        let shared = await app.share(board, with: Sharee(participantId: "alice", label: "Alice", source: "users"))

        XCTAssertTrue(shared)
        XCTAssertEqual(app.boards.first?.acl.first?.participant?.uid, "alice", "sharing list refreshed")
        let lines = StubURLProtocol.requests.map(\.line)
        XCTAssertEqual(lines.suffix(2), [
            "POST /index.php/apps/deck/api/v1.0/boards/1/acl",
            "GET /index.php/apps/deck/api/v1.0/boards/1",
        ])
    }
}

// MARK: - Moving cards

extension AppStateTests {
    private nonisolated static let twoListsJSON = """
    [{"id": 10, "title": "To do", "boardId": 1, "order": 0, "cards": [{"id": 5, "title": "Card", "stackId": 10, "order": 0}]},
     {"id": 20, "title": "Done", "boardId": 1, "order": 1, "cards": []}]
    """

    func testMovedCardShowsInItsNewListStraightAway() async {
        let moved = Locked(false)
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/boards") {
                return .json(Self.boardsJSON)
            }
            if request.path.hasSuffix("/reorder") {
                moved.withLock { $0 = true }
                return .json("[]", delay: 0.3)
            }
            return .json(moved.withLock { $0 } ? Self.twoListsJSON.replacingOccurrences(
                of: "\"stackId\": 10",
                with: "\"stackId\": 20"
            ) : Self.twoListsJSON)
        }
        let app = await makeSignedInApp()

        let move = Task { await app.moveCard(boardId: 1, cardId: 5, fromStackId: 10, toStackId: 20, order: 0) }
        await waitUntil { moved.withLock { $0 } }

        XCTAssertEqual(app.window.stacks.map { $0.activeCards.map(\.id) }, [[], [5]], "no snapping back while saving")
        await move.value
    }

    func testFailedMovePutsTheCardBack() async {
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/boards") {
                return .json(Self.boardsJSON)
            }
            if request.path.hasSuffix("/reorder") {
                return .status(500)
            }
            return .json(Self.twoListsJSON)
        }
        let app = await makeSignedInApp()

        await app.moveCard(boardId: 1, cardId: 5, fromStackId: 10, toStackId: 20, order: 0)

        XCTAssertEqual(app.window.stacks.map { $0.activeCards.map(\.id) }, [[5], []])
        XCTAssertNotNil(app.actionError)
    }
}

// MARK: - Editing boards (#133)

extension AppStateTests {
    func testEditingABoardUpdatesItInPlace() async {
        StubURLProtocol.handler = { request in
            if request.method == "PUT" {
                return .json(#"{"id": 2, "title": "Renamed", "color": "9C59B6", "archived": false}"#)
            }
            if request.path.hasSuffix("/boards") {
                return .json(Self.boardsJSON)
            }
            return .json(Self.stacksJSON([10], board: 1))
        }
        let app = await makeSignedInApp()
        let before = StubURLProtocol.requests.count

        let saved = await app.updateBoard(id: 2, title: "  Renamed ", color: "9C59B6")

        XCTAssertTrue(saved)
        XCTAssertEqual(app.boards.map(\.title), ["One", "Renamed"], "renamed in place, order kept")
        XCTAssertEqual(app.boards.last?.color, "9C59B6")
        let sent = StubURLProtocol.requests.dropFirst(before)
        XCTAssertEqual(sent.map(\.line), ["PUT /index.php/apps/deck/api/v1.0/boards/2"], "no reload needed")
        XCTAssertEqual(sent.first?.json?["title"] as? String, "Renamed", "title is trimmed")
        XCTAssertEqual(sent.first?.json?["archived"] as? Bool, false)
        XCTAssertEqual(app.window.selectedBoardId, 1, "editing another board keeps the open one")
    }

    func testFailedBoardEditKeepsTheBoardAndExplains() async {
        StubURLProtocol.handler = { request in
            if request.method == "PUT" {
                return .status(403)
            }
            if request.path.hasSuffix("/boards") {
                return .json(Self.boardsJSON)
            }
            return .json(Self.stacksJSON([10], board: 1))
        }
        let app = await makeSignedInApp()

        let saved = await app.updateBoard(id: 1, title: "Renamed", color: "9C59B6")

        XCTAssertFalse(saved)
        XCTAssertEqual(app.boards.first?.title, "One")
        XCTAssertEqual(app.errorMessage, DeckAPIError.permissionDenied.localizedDescription, "shown in the sheet")
        XCTAssertTrue(app.isLoggedIn)
    }

    func testBlankBoardTitleIsNotSent() async {
        StubURLProtocol.handler = { request in
            request.path.hasSuffix("/boards") ? .json(Self.boardsJSON) : .json(Self.stacksJSON([10], board: 1))
        }
        let app = await makeSignedInApp()
        let before = StubURLProtocol.requests.count

        let saved = await app.updateBoard(id: 1, title: "  ", color: "9C59B6")

        XCTAssertFalse(saved)
        XCTAssertEqual(StubURLProtocol.requests.count, before)
    }
}

// MARK: - Renaming lists (#134)

extension AppStateTests {
    func testRenamedListShowsStraightAwayAndKeepsItsPlace() async throws {
        let saving = Locked(false)
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/boards") {
                return .json(Self.boardsJSON)
            }
            if request.method == "PUT" {
                saving.withLock { $0 = true }
                return .json(#"{"id": 20, "title": "Finished", "boardId": 1, "order": 1}"#, delay: 0.3)
            }
            return .json(Self.stacksJSON([10, 20], board: 1))
        }
        let app = await makeSignedInApp()
        let before = StubURLProtocol.requests.count

        let rename = Task { await app.renameStack(boardId: 1, stackId: 20, title: " Finished ") }
        await waitUntil { saving.withLock { $0 } }
        XCTAssertEqual(app.window.stacks.map(\.title), ["S10", "Finished"], "new title shown while saving")
        await rename.value

        let sent = StubURLProtocol.requests.dropFirst(before)
        XCTAssertEqual(sent.map(\.line), ["PUT /index.php/apps/deck/api/v1.0/boards/1/stacks/20"])
        let body = try XCTUnwrap(sent.first?.json)
        XCTAssertEqual(body["title"] as? String, "Finished")
        XCTAssertEqual(body["order"] as? Int, 1, "the list keeps its place")
        XCTAssertEqual(app.window.stacks.map(\.id), [10, 20])
        XCTAssertNil(app.actionError)
    }

    func testFailedRenamePutsTheOldTitleBack() async {
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/boards") {
                return .json(Self.boardsJSON)
            }
            if request.method == "PUT" {
                return .status(403)
            }
            return .json(Self.stacksJSON([10, 20], board: 1))
        }
        let app = await makeSignedInApp()

        await app.renameStack(boardId: 1, stackId: 10, title: "Renamed")

        XCTAssertEqual(app.window.stacks.map(\.title), ["S10", "S20"])
        XCTAssertEqual(app.actionError, DeckAPIError.permissionDenied.localizedDescription)
    }

    func testBlankOrUnchangedListTitleIsNotSent() async {
        StubURLProtocol.handler = { request in
            request.path.hasSuffix("/boards") ? .json(Self.boardsJSON) : .json(Self.stacksJSON([10], board: 1))
        }
        let app = await makeSignedInApp()
        let before = StubURLProtocol.requests.count

        await app.renameStack(boardId: 1, stackId: 10, title: "   ")
        await app.renameStack(boardId: 1, stackId: 10, title: "S10 ")

        XCTAssertEqual(StubURLProtocol.requests.count, before)
        XCTAssertEqual(app.window.stacks.map(\.title), ["S10"])
    }
}

// MARK: - Labels (#135)

extension AppStateTests {
    private nonisolated static let labelledBoardJSON = #"{"id": 1, "title": "One", "labels": [{"id": 7, "title": "Urgent", "color": "FF7A66"}, {"id": 8, "title": "Later", "color": "31CC7C"}]}"#

    /// Board 1 with labels 7 and 8; `changed` (from the handler) answers PUT/DELETE and drops label 7 afterwards.
    private func makeLabelledApp(failing: Bool = false) async -> AppState {
        let changed = Locked(false)
        StubURLProtocol.handler = { request in
            if request.path.contains("/labels/") {
                guard !failing else { return .json(#"{"status": 400, "message": "Label is in use"}"#, status: 400) }
                changed.withLock { $0 = true }
                return .json(#"{"id": 7, "title": "Critical", "color": "9C59B6"}"#)
            }
            if request.path.hasSuffix("/boards/1") {
                let renamed = Self.labelledBoardJSON.replacingOccurrences(of: "Urgent", with: "Critical")
                return .json(changed.withLock { $0 } ? renamed : Self.labelledBoardJSON)
            }
            if request.path.hasSuffix("/boards") {
                return .json("[" + Self.labelledBoardJSON + "]")
            }
            return .json(Self.stacksJSON([10], board: 1))
        }
        let app = AppState(credentialStore: store, session: StubURLProtocol.session(), openURL: { _ in })
        await waitUntil { app.window.selectedBoardId == 1 && !app.isLoading }
        await app.loadStacks(boardId: 1)
        return app
    }

    func testEditingALabelReloadsTheBoardAndItsLists() async throws {
        let app = await makeLabelledApp()
        let label = try XCTUnwrap(app.boards.first?.labels.first)
        let before = StubURLProtocol.requests.count

        let saved = await app.updateLabel(label, boardId: 1, title: " Critical ", color: "9C59B6")

        XCTAssertTrue(saved)
        XCTAssertEqual(app.boards.first?.labels.map(\.title), ["Critical", "Later"])
        let sent = StubURLProtocol.requests.dropFirst(before)
        XCTAssertEqual(sent.map(\.line), [
            "PUT /index.php/apps/deck/api/v1.0/boards/1/labels/7",
            "GET /index.php/apps/deck/api/v1.0/boards/1",
            "GET /index.php/apps/deck/api/v1.0/boards/1/stacks",
        ], "the board's labels, then the cards that carry them")
        XCTAssertEqual(sent.first?.json?["title"] as? String, "Critical", "title is trimmed")
    }

    func testDeletingALabelStopsFilteringByIt() async throws {
        let app = await makeLabelledApp()
        let label = try XCTUnwrap(app.boards.first?.labels.first)
        app.window.cardFilter.labelIds = [7, 8]

        let deleted = await app.deleteLabel(label, boardId: 1)

        XCTAssertTrue(deleted)
        XCTAssertEqual(app.window.cardFilter.labelIds, [8])
        XCTAssertEqual(StubURLProtocol.requests.map(\.line).suffix(3), [
            "DELETE /index.php/apps/deck/api/v1.0/boards/1/labels/7",
            "GET /index.php/apps/deck/api/v1.0/boards/1",
            "GET /index.php/apps/deck/api/v1.0/boards/1/stacks",
        ])
    }

    func testLabelFailuresGoToTheBanner() async throws {
        let app = await makeLabelledApp(failing: true)
        let label = try XCTUnwrap(app.boards.first?.labels.first)
        app.window.cardFilter.labelIds = [7]

        let deleted = await app.deleteLabel(label, boardId: 1)
        let renamed = await app.updateLabel(label, boardId: 1, title: "Critical", color: "9C59B6")

        XCTAssertFalse(deleted)
        XCTAssertFalse(renamed)
        XCTAssertEqual(app.actionError, "Label is in use")
        XCTAssertEqual(app.window.cardFilter.labelIds, [7], "a label that wasn't deleted stays in the filter")
        XCTAssertEqual(app.boards.first?.labels.map(\.title), ["Urgent", "Later"])
    }

    func testBlankLabelTitleIsNotSent() async throws {
        let app = await makeLabelledApp()
        let label = try XCTUnwrap(app.boards.first?.labels.first)
        let before = StubURLProtocol.requests.count

        let saved = await app.updateLabel(label, boardId: 1, title: "  ", color: "9C59B6")

        XCTAssertFalse(saved)
        XCTAssertEqual(StubURLProtocol.requests.count, before)
    }
}

// MARK: - Restoring boards (#136)

extension AppStateTests {
    /// Boards 1 and 2, and board 3 deleted, unless `restored`; restoring answers `restoreStatus`, and the
    /// capabilities say Deck `deckVersion`.
    private func makeAppWithDeletedBoard(restoreStatus: Int = 200, deckVersion: String = "1.18.5") async -> AppState {
        let restored = Locked(false)
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/undo_delete") {
                if restoreStatus == 200 {
                    restored.withLock { $0 = true }
                }
                return .status(restoreStatus)
            }
            if request.method == "DELETE" {
                return .json("{}")
            }
            if request.path.hasSuffix("/cloud/capabilities") {
                return .json(#"{"ocs": {"data": {"capabilities": {"deck": {"version": "\#(deckVersion)"}}}}}"#)
            }
            if request.path.hasSuffix("/boards") {
                let deletedAt = restored.withLock { $0 } ? 0 : 1_700_000_000
                return .json(#"[{"id": 1, "title": "One"}, {"id": 2, "title": "Two"}, "#
                    + #"{"id": 3, "title": "Old", "deletedAt": \#(deletedAt)}]"#)
            }
            guard let board = Self.boardId(fromStacksPath: request.path) else { return .status(404) }
            return .json(Self.stacksJSON([board * 10], board: board))
        }
        return await makeSignedInApp()
    }

    func testDeletedBoardMovesToRecentlyDeleted() async {
        let app = await makeAppWithDeletedBoard()
        XCTAssertEqual(app.deletedBoards.map(\.id), [3])

        await app.deleteBoard(id: 1)

        XCTAssertEqual(app.activeBoards.map(\.id), [2])
        XCTAssertEqual(app.deletedBoards.map(\.id), [1, 3], "most recently deleted first")
        XCTAssertEqual(app.window.selectedBoardId, 2, "moves to a board that isn't deleted")
        XCTAssertNil(app.actionError)
    }

    func testRestoringABoardOpensIt() async {
        let app = await makeAppWithDeletedBoard()

        await app.window.restoreBoard(id: 3)

        XCTAssertTrue(StubURLProtocol.requests.map(\.line).contains(
            "POST /index.php/apps/deck/api/v1.0/boards/3/undo_delete"
        ))
        XCTAssertEqual(app.activeBoards.map(\.id), [1, 2, 3])
        XCTAssertTrue(app.deletedBoards.isEmpty)
        XCTAssertEqual(app.window.selectedBoardId, 3)
        XCTAssertNil(app.actionError)
    }

    func testRestoreOnDeckBefore117ExplainsWhy() async {
        let app = await makeAppWithDeletedBoard(restoreStatus: 403, deckVersion: "1.16.8")

        await app.window.restoreBoard(id: 3)

        XCTAssertEqual(app.actionError, AppState.restoreUnsupportedMessage(deckVersion: "1.16.8"))
        XCTAssertEqual(app.deletedBoards.map(\.id), [3])
        XCTAssertEqual(app.window.selectedBoardId, 1)
    }

    func testRestoreRefusedOnNewerDeckIsPermissionDenied() async {
        let app = await makeAppWithDeletedBoard(restoreStatus: 403, deckVersion: "1.18.5")

        await app.window.restoreBoard(id: 3)

        XCTAssertEqual(app.actionError, DeckAPIError.permissionDenied.localizedDescription)
    }

    func testRefreshMovesOffABoardDeletedInTheBrowser() async {
        let deleted = Locked(false)
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/boards") {
                // Deck keeps listing a deleted board, with the time it was deleted.
                return .json(deleted.withLock { $0 }
                    ? #"[{"id": 1, "title": "One", "deletedAt": 1700000000}, {"id": 2, "title": "Two"}]"#
                    : Self.boardsJSON)
            }
            guard let board = Self.boardId(fromStacksPath: request.path) else { return .status(404) }
            return .json(Self.stacksJSON([board * 10], board: board))
        }
        let app = await makeSignedInApp()
        deleted.withLock { $0 = true }

        await app.refreshIfChanged()

        XCTAssertEqual(app.window.selectedBoardId, 2)
        XCTAssertEqual(app.deletedBoards.map(\.id), [1])
    }

    func testLaunchingDoesNotOpenADeletedBoard() async {
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/boards") {
                return .json(#"[{"id": 1, "title": "Gone", "deletedAt": 1700000000}, {"id": 2, "title": "Two"}]"#)
            }
            return .json(Self.stacksJSON([20], board: 2))
        }
        let app = AppState(credentialStore: store, session: StubURLProtocol.session(), openURL: { _ in })

        await waitUntil { !app.boards.isEmpty && !app.isLoading }

        XCTAssertEqual(app.window.selectedBoardId, 2)
    }
}

// MARK: - Duplicating boards (#137)

extension AppStateTests {
    /// Board 1 has a list with a card; the copy is board 9, which Deck gives a default label. `failLists` makes
    /// creating the copy's lists fail.
    private func makeCopyingApp(failLists: Bool = false) async -> AppState {
        let copied = Locked(false)
        StubURLProtocol.handler = { request in
            let path = request.path.replacingOccurrences(of: "/index.php/apps/deck/api/v1.0", with: "")
            switch (request.method, path) {
            case ("GET", "/boards"):
                let copy = copied.withLock { $0 } ? #", {"id": 9, "title": "One (copy)"}"# : ""
                return .json(#"[{"id": 1, "title": "One", "color": "9C59B6"}, {"id": 2, "title": "Two"}"# + copy + "]")
            case ("GET", "/boards/1/stacks"):
                return .json(
                    #"[{"id": 10, "title": "To do", "boardId": 1, "order": 0, "cards": [{"id": 5, "title": "Card", "stackId": 10, "order": 0}]}]"#
                )
            case ("GET", "/boards/1"):
                return .json(#"{"id": 1, "title": "One", "labels": []}"#)
            case ("POST", "/boards"):
                return .json(#"{"id": 9, "title": "One (copy)", "color": "9C59B6"}"#)
            case ("GET", "/boards/9"):
                return .json(#"{"id": 9, "title": "One (copy)", "labels": [{"id": 70, "title": "Finished"}]}"#)
            case ("POST", "/boards/9/stacks"):
                return failLists ? .status(500) : .json(#"{"id": 90, "title": "To do", "boardId": 9, "order": 0}"#)
            case ("POST", "/boards/9/stacks/90/cards"):
                copied.withLock { $0 = true }
                return .json(#"{"id": 95, "title": "Card", "stackId": 90, "order": 0}"#)
            case ("DELETE", _):
                return .json("{}")
            default:
                return .json(Self.stacksJSON([], board: 9))
            }
        }
        return await makeSignedInApp()
    }

    func testDuplicatingABoardOpensTheCopy() async {
        let app = await makeCopyingApp()
        let before = StubURLProtocol.requests.count

        let duplicated = await app.window.duplicateBoard(
            id: 1,
            options: BoardCopyOptions(title: " One (copy) ", withCards: true)
        )

        XCTAssertTrue(duplicated, app.errorMessage ?? "")
        XCTAssertEqual(app.window.selectedBoardId, 9)
        XCTAssertNil(app.boardCopyProgress, "progress cleared when done")
        let sent = StubURLProtocol.requests.dropFirst(before)
        let create = sent.first { $0.method == "POST" && $0.path.hasSuffix("/boards") }
        XCTAssertEqual(create?.json?["title"] as? String, "One (copy)", "title is trimmed")
        XCTAssertEqual(create?.json?["color"] as? String, "9C59B6", "the source's colour")
        let lines = sent.map(\.line)
        XCTAssertTrue(lines.contains("DELETE /index.php/apps/deck/api/v1.0/boards/9/labels/70"), "default label kept")
        XCTAssertTrue(lines.contains("POST /index.php/apps/deck/api/v1.0/boards/9/stacks/90/cards"), "card not copied")
        XCTAssertFalse(lines.contains("DELETE /index.php/apps/deck/api/v1.0/boards/9"))
    }

    func testFailedDuplicateIsDeletedAndExplained() async {
        let app = await makeCopyingApp(failLists: true)

        let duplicated = await app.window.duplicateBoard(
            id: 1,
            options: BoardCopyOptions(title: "Copy", withCards: true)
        )

        XCTAssertFalse(duplicated)
        XCTAssertNotNil(app.errorMessage, "shown in the sheet")
        XCTAssertEqual(app.window.selectedBoardId, 1)
        XCTAssertNil(app.boardCopyProgress)
        XCTAssertEqual(
            StubURLProtocol.requests.last?.line,
            "DELETE /index.php/apps/deck/api/v1.0/boards/9",
            "the half-made copy is deleted"
        )
    }
}

// MARK: - Restoring attachments (#139)

extension AppStateTests {
    func testRestoringAnAttachmentReloadsTheLists() async throws {
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/restore") {
                return request.path.contains("/file/") ? .json(#"{"status": 403, "message": "x"}"#, status: 403)
                    : .json(#"{"id": 4, "type": "deck_file", "deletedAt": 0}"#)
            }
            return request.path.hasSuffix("/boards") ? .json(Self.boardsJSON) : .json(Self.stacksJSON([10], board: 1))
        }
        let app = await makeSignedInApp()
        let decode = { (json: String) in try JSONDecoder().decode(Attachment.self, from: Data(json.utf8)) }
        let before = StubURLProtocol.requests.count

        let restored = try await app.restoreAttachment(
            decode(#"{"id": 4, "type": "deck_file", "deletedAt": 5}"#),
            boardId: 1,
            stackId: 10,
            cardId: 5
        )

        XCTAssertTrue(restored)
        XCTAssertEqual(StubURLProtocol.requests.dropFirst(before).map(\.line), [
            "PUT /index.php/apps/deck/api/v1.1/boards/1/stacks/10/cards/5/attachments/deck_file/4/restore",
            "GET /index.php/apps/deck/api/v1.0/boards/1/stacks",
        ])

        let refused = try await app.restoreAttachment(
            decode(#"{"id": 6, "type": "file", "deletedAt": 5}"#),
            boardId: 1,
            stackId: 10,
            cardId: 5
        )
        XCTAssertFalse(refused)
        XCTAssertEqual(app.actionError, DeckAPIError.permissionDenied.localizedDescription)
    }
}

// MARK: - Start dates (#138)

extension AppStateTests {
    private func makeApp(deckVersion: String?) async -> AppState {
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/cloud/capabilities") {
                guard let deckVersion else { return .status(404) }
                return .json(#"{"ocs": {"data": {"capabilities": {"deck": {"version": "\#(deckVersion)"}}}}}"#)
            }
            return request.path.hasSuffix("/boards") ? .json(Self.boardsJSON) : .json(Self.stacksJSON([10], board: 1))
        }
        return await makeSignedInApp()
    }

    func testStartDatesNeedDeck118() async {
        let new = await makeApp(deckVersion: "1.18.5")
        XCTAssertEqual(new.serverDeckVersion, "1.18.5")
        XCTAssertTrue(new.supportsStartDates)

        let old = await makeApp(deckVersion: "1.17.2")
        XCTAssertFalse(old.supportsStartDates)

        let unknown = await makeApp(deckVersion: nil)
        XCTAssertFalse(unknown.supportsStartDates, "not offered when the server doesn't say")
    }

    func testDeckVersionIsAskedOncePerAccount() async {
        let app = await makeApp(deckVersion: nil)
        await app.loadBoards()
        await app.refresh()

        let asked = StubURLProtocol.requests.filter { $0.path.hasSuffix("/cloud/capabilities") }
        XCTAssertEqual(asked.count, 1)
    }
}

// MARK: - Keyboard commands (#159)

extension AppStateTests {
    /// "To do" (10) has cards 1, 2 and 3; "Done" (20) has card 4.
    private nonisolated static let keyboardListsJSON = """
    [{"id": 10, "title": "To do", "boardId": 1, "order": 0, "cards": [
        {"id": 1, "title": "One", "stackId": 10, "order": 0},
        {"id": 2, "title": "Two", "stackId": 10, "order": 1},
        {"id": 3, "title": "Three", "stackId": 10, "order": 2}]},
     {"id": 20, "title": "Done", "boardId": 1, "order": 1, "cards": [
        {"id": 4, "title": "Four", "stackId": 20, "order": 0}]}]
    """

    private func makeKeyboardApp(handling handler: (@Sendable (RecordedRequest) -> StubResponse?)? = nil) async
        -> AppState {
        StubURLProtocol.handler = { request in
            if let response = handler?(request) {
                return response
            }
            if request.path.hasSuffix("/boards") {
                return .json(Self.boardsJSON)
            }
            return .json(Self.keyboardListsJSON)
        }
        return await makeSignedInApp()
    }

    func testTheArrowKeysMoveTheSelection() async {
        let app = await makeKeyboardApp()

        app.window.selectCard(.down)
        XCTAssertEqual(app.window.selectedCardId, 1, "nothing selected: the first card")
        app.window.selectCard(.down)
        app.window.selectCard(.right)
        XCTAssertEqual(app.window.selectedCardId, 4)
        app.window.selectCard(.left)
        XCTAssertEqual(app.window.selectedCardId, 1)

        app.window.cardFilter.text = "Three"
        XCTAssertNil(app.window.selectedCard, "hidden by the filter")
        app.window.selectCard(.down)
        XCTAssertEqual(app.window.selectedCardId, 3)
    }

    func testSwitchingBoardsClearsTheSelection() async {
        let app = await makeKeyboardApp()
        app.window.selectedCardId = 2
        app.window.newCardListId = 10

        app.window.selectBoard(offset: 1)

        XCTAssertEqual(app.window.selectedBoardId, 2)
        XCTAssertNil(app.window.selectedCardId)
        XCTAssertNil(app.window.newCardListId)
        app.window.selectBoard(offset: 1)
        XCTAssertEqual(app.window.selectedBoardId, 2, "no board after the last")
        app.window.selectBoard(offset: -1)
        XCTAssertEqual(app.window.selectedBoardId, 1)
    }

    func testMovingTheSelectedCardToTheNextList() async {
        let app = await makeKeyboardApp { request in
            request.path.hasSuffix("/reorder") ? .json("[]") : nil
        }
        app.window.selectedCardId = 2

        await app.window.moveSelectedCard(.right)

        XCTAssertTrue(StubURLProtocol.requests.contains {
            $0.line == "PUT /index.php/apps/deck/api/v1.0/boards/1/stacks/20/cards/2/reorder"
        })
        XCTAssertEqual(app.window.selectedCardId, 2, "still selected")
    }

    func testMovingIsOffWhileFiltering() async {
        let app = await makeKeyboardApp()
        app.window.selectedCardId = 2
        app.window.cardFilter.text = "Two"

        XCTAssertFalse(app.window.canMoveSelectedCard)
        await app.window.moveSelectedCard(.right)

        XCTAssertFalse(StubURLProtocol.requests.contains { $0.path.hasSuffix("/reorder") })
    }

    func testArchivingTheSelectedCardSelectsTheNextOne() async {
        let archived = Locked(false)
        let app = await makeKeyboardApp { request in
            if request.path.hasSuffix("/archive") {
                archived.withLock { $0 = true }
                return .json("{}")
            }
            if request.path.hasSuffix("/stacks"), archived.withLock({ $0 }) {
                return .json(Self.keyboardListsJSON.replacingOccurrences(
                    of: #""title": "Two", "stackId": 10"#,
                    with: #""title": "Two", "archived": true, "stackId": 10"#
                ))
            }
            return nil
        }
        app.window.selectedCardId = 2

        await app.window.archiveSelectedCard()

        XCTAssertEqual(app.window.selectedCardId, 3)
    }

    func testDeletingTheSelectedCardAsksFirstThenSelectsTheOneBefore() async {
        let app = await makeKeyboardApp { request in
            request.method == "DELETE" ? .json("{}") : nil
        }
        app.window.selectedCardId = 3

        app.window.requestDeletingSelectedCard()
        XCTAssertEqual(app.window.cardPendingDelete?.id, 3)
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.method == "DELETE" }, "not before it's confirmed")
        await app.window.deletePendingCard()

        XCTAssertTrue(StubURLProtocol.requests.contains {
            $0.line == "DELETE /index.php/apps/deck/api/v1.0/boards/1/stacks/10/cards/3"
        })
        XCTAssertNil(app.window.cardPendingDelete)
        XCTAssertEqual(app.window.selectedCardId, 2, "the last card in the list: the one before it")
    }

    func testANewCardGoesInTheSelectedCardsListAndIsSelected() async {
        let app = await makeKeyboardApp { request in
            request.method == "POST" ? .json(#"{"id": 9, "title": "New", "stackId": 20, "order": 1}"#) : nil
        }
        app.window.startNewCard()
        XCTAssertEqual(app.window.newCardListId, 10, "nothing selected: the first list")
        app.window.selectedCardId = 4
        app.window.startNewCard()
        XCTAssertEqual(app.window.newCardListId, 20)

        await app.window.createCard(boardId: 1, stackId: 20, title: "New")

        XCTAssertEqual(app.window.selectedCardId, 9)
    }
}

// MARK: - Searching all boards (#158)

extension AppStateTests {
    private nonisolated static let searchBoardsJSON = """
    [{"id": 1, "title": "One", "archived": false, "lastModified": 100},
     {"id": 2, "title": "Two", "archived": false, "lastModified": 200}]
    """

    private nonisolated static func searchStacksJSON(board: Int, cards: String) -> String {
        #"[{"id": \#(board * 10), "title": "List \#(board)", "boardId": \#(board), "order": 0, "cards": [\#(cards)]}]"#
    }

    /// Board 1 has "Paint door"; board 2 has "Paint office" and, archived, "Paint shed".
    private func makeSearchApp() async -> AppState {
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/boards") {
                return .json(Self.searchBoardsJSON)
            }
            let board = request.path.contains("/boards/2/") ? 2 : 1
            if request.path.hasSuffix("/stacks/archived") {
                return .json(Self.searchStacksJSON(
                    board: board,
                    cards: board == 2 ?
                        #"{"id": 23, "title": "Paint shed", "stackId": 20, "order": 0, "archived": true}"# : ""
                ))
            }
            return .json(Self.searchStacksJSON(
                board: board,
                cards: board == 2 ? #"{"id": 22, "title": "Paint office", "stackId": 20, "order": 0}"#
                    : #"{"id": 11, "title": "Paint door", "stackId": 10, "order": 0}"#
            ))
        }
        return await makeSignedInApp()
    }

    /// Requests for paths ending in `suffix` after the first `skipping` requests.
    private func requestCount(_ suffix: String, skipping skipped: Int) -> Int {
        StubURLProtocol.requests.dropFirst(skipped).count { $0.path.hasSuffix(suffix) }
    }

    func testLoadingAllCardsSkipsBoardsThatHaventChanged() async {
        let app = await makeSearchApp()
        let before = StubURLProtocol.requests.count
        func requestCount(_ suffix: String) -> Int {
            self.requestCount(suffix, skipping: before)
        }
        var clock = Date()
        app.now = { clock }

        await app.loadAllCards()
        XCTAssertEqual(requestCount("/boards/1/stacks") + requestCount("/boards/2/stacks"), 2)
        XCTAssertEqual(app.allCards[2]?.stacks.first?.cards?.first?.title, "Paint office")

        clock += 60
        await app.loadAllCards()
        XCTAssertEqual(
            requestCount("/boards/1/stacks") + requestCount("/boards/2/stacks"), 4,
            "fetched in the second the change was reported: fetched again to be sure"
        )

        clock += 60
        await app.loadAllCards()
        XCTAssertEqual(requestCount("/boards/1/stacks") + requestCount("/boards/2/stacks"), 4, "unchanged: skipped")

        app.boards[1].lastModified = 300
        clock += 60
        await app.loadAllCards()
        XCTAssertEqual(requestCount("/boards/1/stacks"), 2, "board 1 unchanged")
        XCTAssertEqual(requestCount("/boards/2/stacks"), 3, "board 2 changed")
        XCTAssertEqual(requestCount("/stacks/archived"), 0, "archived cards only when asked")
    }

    func testSearchingFindsCardsOnEveryBoardIncludingArchivedOnes() async {
        let app = await makeSearchApp()
        let before = StubURLProtocol.requests.count

        app.window.cardSearchText = "paint"
        await app.loadCardsForSearch()

        let groups = app.window.cardSearchResults
        XCTAssertEqual(groups.map(\.board.title), ["One", "Two"])
        XCTAssertEqual(groups.flatMap(\.results).map(\.card.title), ["Paint door", "Paint office", "Paint shed"])
        XCTAssertEqual(requestCount("/stacks/archived", skipping: before), 2)
    }

    func testOpeningASearchResultOpensItsBoardAndCard() async throws {
        let app = await makeSearchApp()
        app.window.cardSearchText = "paint"
        await app.loadCardsForSearch()
        let results = app.window.cardSearchResults.flatMap(\.results)

        try app.window.open(XCTUnwrap(results.first { $0.card.title == "Paint office" }))
        XCTAssertEqual(app.window.selectedBoardId, 2)
        XCTAssertEqual(app.window.selectedCardId, 22)
        XCTAssertEqual(app.window.openedCard?.id, 22)
        XCTAssertFalse(app.window.showingArchivedCards)

        app.window.openedCard = nil
        try app.window.open(XCTUnwrap(results.first { $0.card.title == "Paint shed" }))
        XCTAssertNil(app.window.openedCard)
        XCTAssertTrue(app.window.showingArchivedCards, "an archived card shows in the board's archived cards")
    }
}

// MARK: - Notifications (#157)

extension AppStateTests {
    func testClickingANotificationOpensItsBoardAndCard() async throws {
        let app = await makeKeyboardApp()
        let account = try XCTUnwrap(app.activeAccount)
        app.window.selectedBoardId = 2

        await app.window.openCard(id: 4, boardId: 1, accountId: account.id)

        XCTAssertEqual(app.window.selectedBoardId, 1)
        XCTAssertEqual(app.window.selectedCardId, 4)
        XCTAssertEqual(app.window.openedCard?.title, "Four")
    }

    func testANotificationForACardThatHasGoneOpensNothing() async throws {
        let app = await makeKeyboardApp()
        let account = try XCTUnwrap(app.activeAccount)

        await app.window.openCard(id: 99, boardId: 1, accountId: account.id)
        XCTAssertNil(app.window.openedCard)
        await app.window.openCard(id: 4, boardId: 1, accountId: "someone@else.example")
        XCTAssertNil(app.window.openedCard, "an account that isn't signed in")
    }
}
