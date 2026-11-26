import Foundation
import XCTest
@testable import Shuffleboard

/// Several windows on one `AppState` (#160): each has its own board, selection and filter, while windows on the same
/// board share its lists.
@MainActor
final class WindowTests: XCTestCase {
    /// Whether board 1 has gained a list elsewhere (the web UI, say).
    private let boardOneChanged = Locked(false)

    override func setUp() async throws {
        StubURLProtocol.reset()
        let changed = boardOneChanged
        StubURLProtocol.handler = { request in
            let parts = request.path.split(separator: "/")
            if request.path.hasSuffix("/boards") {
                return .json("[" + [1, 2, 3].map(Self.boardJSON).joined(separator: ",") + "]")
            }
            if let index = parts.firstIndex(of: "boards"), parts.indices.contains(index + 1),
               let board = Int(parts[index + 1]) {
                if parts.last == "stacks" {
                    return .json(Self.stacksJSON(board: board, extraList: board == 1 && changed.withLock { $0 }))
                }
                if parts.count == index + 2, request.method == "GET" {
                    return .json(Self.boardJSON(board))
                }
            }
            return .json("{}")
        }
    }

    override func tearDown() async throws {
        StubURLProtocol.reset()
    }

    private nonisolated static func boardJSON(_ id: Int) -> String {
        #"{"id": \#(id), "title": "B\#(id)", "archived": false, "labels": [{"id": 5, "title": "Red", "color": "ff0000"}]}"#
    }

    /// Board `board` has lists `board`0 and `board`1 (and `board`2 with `extraList`); the first holds `cards`, by
    /// default cards `board`00 and `board`01.
    private nonisolated static func stacksJSON(board: Int, extraList: Bool = false, cards ids: [Int]? = nil) -> String {
        let cards = (ids ?? [board * 100, board * 100 + 1]).enumerated().map { order, id in
            #"{"id": \#(id), "title": "C\#(id)", "stackId": \#(board * 10), "order": \#(order)}"#
        }
        let lists = (extraList ? 0 ... 2 : 0 ... 1).map { offset in
            #"{"id": \#(board * 10 + offset), "title": "L\#(offset)", "boardId": \#(board), "order": \#(offset), "#
                + #""cards": [\#(offset == 0 ? cards.joined(separator: ",") : "")]}"#
        }
        return "[" + lists.joined(separator: ",") + "]"
    }

    private func makeApp(_ store: InMemoryCredentialStore = .signedIn()) async -> AppState {
        let app = AppState(credentialStore: store, session: StubURLProtocol.session(), openURL: { _ in })
        await waitUntil { !app.isLoading && app.boards.count == 3 }
        return app
    }

    /// A window on `boardId` with its lists loaded, as its board view loads them.
    private func openWindow(on boardId: Int, in app: AppState) async -> BoardWindow {
        let window = BoardWindow(app: app, boardId: boardId)
        await app.loadStacks(boardId: boardId)
        return window
    }

    private var listRequests: [String] {
        StubURLProtocol.requests.filter { $0.path.hasSuffix("/stacks") }.map(\.path)
    }

    // MARK: - Boards and lists

    func testWindowsOnTheSameBoardShareItsLists() async {
        let app = await makeApp()
        let first = await openWindow(on: 1, in: app)
        let second = await openWindow(on: 1, in: app)
        XCTAssertEqual(first.stacks.map(\.id), [10, 11])
        XCTAssertEqual(second.stacks.map(\.id), [10, 11])

        boardOneChanged.withLock { $0 = true }
        let before = listRequests.count
        await app.refreshIfChanged()

        XCTAssertEqual(first.stacks.map(\.id), [10, 11, 12])
        XCTAssertEqual(second.stacks.map(\.id), [10, 11, 12], "a change shows in every window on the board")
        XCTAssertEqual(listRequests.count - before, 1, "the board's lists are fetched once, not once per window")
    }

    func testRefreshingCoversTheBoardOfEveryWindow() async {
        let app = await makeApp()
        let first = await openWindow(on: 1, in: app)
        let second = await openWindow(on: 2, in: app)
        let before = listRequests.count

        await app.refreshIfChanged()

        XCTAssertEqual(Set(listRequests.dropFirst(before)), [
            "/index.php/apps/deck/api/v1.0/boards/1/stacks",
            "/index.php/apps/deck/api/v1.0/boards/2/stacks",
        ])
        XCTAssertEqual(first.stacks.map(\.id), [10, 11])
        XCTAssertEqual(second.stacks.map(\.id), [20, 21])
    }

    func testEachWindowHasItsOwnSelectionAndFilter() async {
        let app = await makeApp()
        let first = await openWindow(on: 1, in: app)
        let second = await openWindow(on: 2, in: app)

        first.selectedCardId = 100
        first.cardFilter.text = "C100"
        first.cardSearchText = "C2"

        XCTAssertEqual(first.selectedCard?.id, 100)
        XCTAssertNil(second.selectedCardId)
        XCTAssertFalse(second.cardFilter.isActive)
        XCTAssertEqual(second.cardSearchText, "")
        XCTAssertEqual(second.shownCards(in: second.stacks[0]).map(\.id), [200, 201])
        XCTAssertEqual(first.shownCards(in: first.stacks[0]).map(\.id), [100])

        second.selectCard(.down)
        XCTAssertEqual(second.selectedCardId, 200, "the keyboard moves the selection of the window it's in")
        XCTAssertEqual(first.selectedCardId, 100)
    }

    func testListsAreLetGoOnceNoWindowShowsTheirBoard() async {
        let app = await makeApp()
        let first = await openWindow(on: 1, in: app)
        let second = await openWindow(on: 1, in: app)

        second.selectedBoardId = 2
        XCTAssertEqual(Set(app.lists.keys), [1, 2], "the first window still shows board 1")
        XCTAssertEqual(first.stacks.map(\.id), [10, 11])

        first.selectedBoardId = 3
        XCTAssertEqual(Set(app.lists.keys), [2, 3])
    }

    func testClosingAWindowLetsGoOfItsBoardsLists() async {
        let app = await makeApp()
        let first = await openWindow(on: 1, in: app)
        let second = await openWindow(on: 2, in: app)

        app.windowClosed(second)

        XCTAssertEqual(app.windows.map(ObjectIdentifier.init), [ObjectIdentifier(first)])
        XCTAssertEqual(Set(app.lists.keys), [1])
        let before = listRequests.count
        await app.refreshIfChanged()
        XCTAssertEqual(listRequests.dropFirst(before), ["/index.php/apps/deck/api/v1.0/boards/1/stacks"])
    }

    func testDeletingABoardMovesOnlyTheWindowsShowingIt() async {
        let app = await makeApp()
        let first = await openWindow(on: 3, in: app)
        let second = await openWindow(on: 2, in: app)

        await app.deleteBoard(id: 2)

        XCTAssertEqual(second.selectedBoardId, 1, "the window on the deleted board opens the first board")
        XCTAssertEqual(first.selectedBoardId, 3)
    }

    func testANewWindowOpensTheBoardOpenedLast() async {
        let app = await makeApp()
        let first = await openWindow(on: 1, in: app)
        first.selectedBoardId = 2

        let second = BoardWindow(app: app)
        XCTAssertEqual(second.selectedBoardId, 2)
        XCTAssertEqual(BoardWindow(app: app, boardId: 3).selectedBoardId, 3, "or the board it's opened on")
        XCTAssertEqual(
            BoardWindow(app: app, boardId: 99).selectedBoardId,
            3,
            "on one that isn't there: the board opened last, now 3"
        )
    }

    // MARK: - Moving a card to another board (#204)

    /// Card 100 dragged from board 1's first list to the top of board 2's: once `moved`, the server has it there. A
    /// `reorder` that fails leaves the card where it was, and the lists can't be loaded after it.
    private func stubMoveToBoardTwo(moved: Locked<Bool>, reorder: StubResponse) {
        let failed = Locked(false)
        StubURLProtocol.handler = { request in
            if request.path.hasSuffix("/boards") {
                return .json("[" + [1, 2, 3].map(Self.boardJSON).joined(separator: ",") + "]")
            }
            if request.path.hasSuffix("/reorder") {
                if reorder.status == 200 {
                    moved.withLock { $0 = true }
                } else {
                    failed.withLock { $0 = true }
                }
                return reorder
            }
            if failed.withLock({ $0 }) {
                return .status(500)
            }
            let isMoved = moved.withLock { $0 }
            if request.path.hasSuffix("/boards/1/stacks") {
                return .json(Self.stacksJSON(board: 1, cards: isMoved ? [101] : nil))
            }
            if request.path.hasSuffix("/boards/2/stacks") {
                return .json(Self.stacksJSON(board: 2, cards: isMoved ? [100, 200, 201] : nil))
            }
            return .json("{}")
        }
    }

    func testACardMovedToAnotherBoardLeavesItsOldBoardStraightAway() async {
        let moved = Locked(false)
        stubMoveToBoardTwo(moved: moved, reorder: .json("[]", delay: 0.3))
        let app = await makeApp()
        let from = await openWindow(on: 1, in: app)
        let to = await openWindow(on: 2, in: app)

        // Dropped on board 2's window, as a card dragged in from board 1's window is.
        let move = Task { await app.moveCard(boardId: 2, cardId: 100, fromStackId: 10, toStackId: 20, order: 0) }
        await waitUntil { moved.withLock { $0 } }

        XCTAssertEqual(from.stacks[0].activeCards.map(\.id), [101], "gone from the board it was dragged from")
        XCTAssertEqual(to.stacks[0].activeCards.map(\.id), [100, 200, 201], "and on the one it was dropped on")
        XCTAssertEqual(to.stacks[0].activeCards.first?.stackId, 20)
        await move.value

        XCTAssertEqual(from.stacks[0].activeCards.map(\.id), [101], "both boards reloaded from the server")
        XCTAssertEqual(to.stacks[0].activeCards.map(\.id), [100, 200, 201])
        XCTAssertEqual(app.cachedLists(of: 1)?.first?.activeCards.map(\.id), [101], "the copy on the Mac too")
        XCTAssertNil(app.actionError)
        let lines = StubURLProtocol.requests.map(\.line)
        XCTAssertTrue(lines.contains("PUT /index.php/apps/deck/api/v1.0/boards/2/stacks/20/cards/100/reorder"))
    }

    func testAFailedMoveToAnotherBoardPutsTheCardBack() async {
        stubMoveToBoardTwo(moved: Locked(false), reorder: .status(500))
        let app = await makeApp()
        let from = await openWindow(on: 1, in: app)
        let to = await openWindow(on: 2, in: app)

        await app.moveCard(boardId: 2, cardId: 100, fromStackId: 10, toStackId: 20, order: 0)

        XCTAssertEqual(from.stacks[0].activeCards.map(\.id), [100, 101], "back, though the lists couldn't reload")
        XCTAssertEqual(to.stacks[0].activeCards.map(\.id), [200, 201])
        XCTAssertEqual(app.cachedLists(of: 1)?.first?.activeCards.map(\.id), [100, 101])
        XCTAssertNotNil(app.actionError)
    }

    // MARK: - Things every window follows

    func testRefreshWaitsWhileAListIsDraggedInAnyWindow() async {
        let app = await makeApp()
        _ = await openWindow(on: 1, in: app)
        let second = await openWindow(on: 2, in: app)
        second.isDraggingStack = true
        let before = StubURLProtocol.requests.count

        await app.refreshIfChanged()

        XCTAssertEqual(StubURLProtocol.requests.count, before)
    }

    func testDeletingALabelTakesItOutOfEveryWindowsFilter() async throws {
        let app = await makeApp()
        let first = await openWindow(on: 1, in: app)
        let second = await openWindow(on: 2, in: app)
        first.cardFilter.labelIds = [5]
        second.cardFilter.labelIds = [5, 6]

        let label = try XCTUnwrap(app.boards.first?.labels.first)
        let deleted = await app.deleteLabel(label, boardId: 1)

        XCTAssertTrue(deleted)
        XCTAssertEqual(first.cardFilter.labelIds, [])
        XCTAssertEqual(second.cardFilter.labelIds, [6])
    }

    func testSwitchingAccountsResetsEveryWindow() async throws {
        let store = InMemoryCredentialStore.signedIn("rob", "alice")
        let app = await makeApp(store)
        let first = await openWindow(on: 2, in: app)
        let second = await openWindow(on: 3, in: app)
        first.cardFilter.text = "x"
        second.cardFilter.hideDone = true
        let alice = try XCTUnwrap(app.accounts.last)

        await app.switchAccount(to: alice)

        XCTAssertFalse(first.cardFilter.isActive)
        XCTAssertFalse(second.cardFilter.isActive)
        XCTAssertEqual(first.selectedBoardId, 1, "the new account's boards: each window opens the first")
        XCTAssertEqual(second.selectedBoardId, 1)
    }
}
