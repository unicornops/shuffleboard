import Foundation
import XCTest
@testable import Shuffleboard

/// The copy of the boards kept on the Mac, and working read-only while the server can't be reached (#156).
@MainActor
final class OfflineTests: XCTestCase {
    private static let rob = "rob@cloud.example"
    private static let alice = "alice@cloud.example"

    private nonisolated static let serverBoards = #"[{"id": 1, "title": "Server board", "archived": false}]"#
    private nonisolated static let serverStacks = #"""
    [{"id": 10, "title": "Doing", "boardId": 1, "order": 0, "cards": [{"id": 100, "title": "From the server",
      "stackId": 10, "order": 0}]}]
    """#

    /// Whether the stub server can be reached; when not, every request fails as with the server down.
    private let reachable = Locked(true)

    override func setUp() async throws {
        StubURLProtocol.reset()
        let reachable = reachable
        StubURLProtocol.handler = { request in
            guard reachable.withLock({ $0 }) else {
                return StubResponse(error: URLError(.cannotConnectToHost))
            }
            if request.path.hasSuffix("/boards") {
                return .json(Self.serverBoards)
            }
            if request.path.hasSuffix("/boards/1/stacks") {
                return .json(Self.serverStacks)
            }
            return .json("[]")
        }
    }

    override func tearDown() async throws {
        StubURLProtocol.reset()
    }

    private func setReachable(_ value: Bool) {
        reachable.withLock { $0 = value }
    }

    private func makeApp(
        _ cache: InMemoryBoardCacheStore,
        accounts: InMemoryCredentialStore = .signedIn()
    )
        -> AppState {
        AppState(credentialStore: accounts, session: StubURLProtocol.session(), openURL: { _ in }, boardCache: cache)
    }

    /// A copy of rob's boards: "Saved board" open, with one list and card.
    private static func savedSnapshot(syncedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws
        -> BoardCacheSnapshot {
        let boards = try JSONDecoder().decode(
            [Board].self,
            from: Data(#"[{"id": 1, "title": "Saved board", "archived": false}]"#.utf8)
        )
        let stacks = try JSONDecoder().decode([Stack].self, from: Data(#"""
        [{"id": 10, "title": "To do", "boardId": 1, "order": 0, "cards": [{"id": 100, "title": "Saved card",
          "stackId": 10, "order": 0}]}]
        """#.utf8))
        return BoardCacheSnapshot(
            boards: boards,
            boardsSyncedAt: syncedAt,
            selectedBoardId: 1,
            lists: [1: .init(stacks: stacks, syncedAt: syncedAt)]
        )
    }

    // MARK: - The file store

    private func temporaryStore() throws -> FileBoardCacheStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoardCacheTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return FileBoardCacheStore(directory: directory)
    }

    func testFileStoreKeepsEachAccountsCopy() throws {
        let store = try temporaryStore()
        XCTAssertNil(store.load(accountId: Self.rob), "nothing saved yet")

        let saved = try Self.savedSnapshot()
        store.save(saved, accountId: Self.rob)
        var alices = BoardCacheSnapshot()
        alices.boardsSyncedAt = Date(timeIntervalSince1970: 1_700_000_000)
        store.save(alices, accountId: Self.alice)

        let loaded = try XCTUnwrap(store.load(accountId: Self.rob))
        XCTAssertEqual(loaded.boards.map(\.title), ["Saved board"])
        XCTAssertEqual(loaded.selectedBoardId, 1)
        XCTAssertEqual(loaded.boardsSyncedAt, saved.boardsSyncedAt)
        XCTAssertEqual(loaded.lists[1]?.stacks.first?.cards?.map(\.title), ["Saved card"])
        XCTAssertEqual(store.load(accountId: Self.alice)?.boards.count, 0)

        store.remove(accountId: Self.rob)
        XCTAssertNil(store.load(accountId: Self.rob))
        XCTAssertNotNil(store.load(accountId: Self.alice), "only rob's copy is removed")
    }

    func testFileStoreFilesAreOnlyReadableByTheUser() throws {
        let store = try temporaryStore()
        try store.save(Self.savedSnapshot(), accountId: "rob@cloud.example/nextcloud")
        let url = store.fileURL(accountId: "rob@cloud.example/nextcloud")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, store.directory.standardizedFileURL)
        XCTAssertFalse(url.lastPathComponent.contains("@"), "the account id is encoded")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testFileStoreIgnoresUnreadableCopies() throws {
        let store = try temporaryStore()
        try store.save(Self.savedSnapshot(), accountId: Self.rob)
        let url = store.fileURL(accountId: Self.rob)

        try Data("not json".utf8).write(to: url)
        XCTAssertNil(store.load(accountId: Self.rob))

        var other = try Self.savedSnapshot()
        other.version = BoardCacheSnapshot.currentVersion + 1
        store.save(other, accountId: Self.rob)
        XCTAssertNil(store.load(accountId: Self.rob), "a copy in another format is ignored")
    }

    // MARK: - Connection problems

    func testWhichErrorsMeanTheServerCantBeReached() {
        XCTAssertEqual(ConnectionProblem(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(ConnectionProblem(URLError(.cannotConnectToHost)), .serverUnreachable)
        XCTAssertEqual(ConnectionProblem(URLError(.timedOut)), .serverUnreachable)
        XCTAssertEqual(ConnectionProblem(URLError(.cannotFindHost)), .serverUnreachable)
        XCTAssertEqual(ConnectionProblem(DeckAPIError.httpStatus(503)), .serverUnreachable, "maintenance mode")
        XCTAssertNil(ConnectionProblem(DeckAPIError.httpStatus(500)))
        XCTAssertNil(ConnectionProblem(DeckAPIError.permissionDenied))
        XCTAssertNil(ConnectionProblem(URLError(.cancelled)))
        XCTAssertNil(ConnectionProblem(URLError(.serverCertificateUntrusted)))
    }

    // MARK: - Launching

    func testLaunchShowsTheSavedBoardsBeforeTheServerAnswers() async throws {
        setReachable(false)
        let app = try makeApp(InMemoryBoardCacheStore([Self.rob: Self.savedSnapshot()]))

        // Straight away, before any request has finished.
        XCTAssertEqual(app.boards.map(\.title), ["Saved board"])
        XCTAssertEqual(app.selectedBoardId, 1, "the board that was open")
        XCTAssertEqual(app.stacks.first?.cards?.map(\.title), ["Saved card"])

        await waitUntil { app.connectionProblem != nil }
        XCTAssertEqual(app.connectionProblem, .serverUnreachable)
        XCTAssertTrue(app.isReadOnly)
        XCTAssertEqual(app.boards.map(\.title), ["Saved board"], "the copy stays on screen")
        XCTAssertNil(app.errorMessage)
        XCTAssertNil(app.actionError, "the offline banner says it, not an error")
        XCTAssertEqual(app.offlineDataDate, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testLaunchReplacesTheSavedBoardsWithTheServersAndSavesThem() async throws {
        let cache = try InMemoryBoardCacheStore([Self.rob: Self.savedSnapshot()])
        let app = makeApp(cache)
        await waitUntil { app.boards.first?.title == "Server board" && !app.isLoading }
        await app.loadStacks(boardId: 1)
        XCTAssertEqual(app.stacks.first?.cards?.map(\.title), ["From the server"])
        XCTAssertNil(app.connectionProblem)

        app.flushCache()
        let saved = try XCTUnwrap(cache.snapshots[Self.rob])
        XCTAssertEqual(saved.boards.map(\.title), ["Server board"])
        XCTAssertEqual(saved.lists[1]?.stacks.first?.cards?.map(\.title), ["From the server"])
        XCTAssertEqual(saved.selectedBoardId, 1)
        XCTAssertGreaterThan(try XCTUnwrap(saved.boardsSyncedAt), Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testFirstLaunchSavesWhatTheServerSent() async {
        let cache = InMemoryBoardCacheStore()
        let app = makeApp(cache)
        XCTAssertTrue(app.boards.isEmpty)
        await waitUntil { app.selectedBoardId == 1 && !app.isLoading }
        await app.loadStacks(boardId: 1)
        app.flushCache()
        XCTAssertEqual(cache.snapshots[Self.rob]?.boards.map(\.title), ["Server board"])
        XCTAssertEqual(cache.snapshots[Self.rob]?.lists[1]?.stacks.count, 1)
    }

    func testNothingIsSavedBeforeTheServerHasAnswered() async {
        setReachable(false)
        let cache = InMemoryBoardCacheStore()
        let app = makeApp(cache)
        await waitUntil { app.connectionProblem != nil && !app.isLoading }
        app.flushCache()
        XCTAssertNil(cache.snapshots[Self.rob])
        XCTAssertNotNil(app.errorMessage, "no copy to show: the sidebar says why it's empty")
    }

    // MARK: - Losing and regaining the connection

    func testLosingTheConnectionKeepsTheBoardOnScreenUntilItsBack() async {
        let app = makeApp(InMemoryBoardCacheStore())
        await waitUntil { app.selectedBoardId == 1 && !app.isLoading }
        await app.loadStacks(boardId: 1)

        setReachable(false)
        await app.refreshIfChanged()
        XCTAssertEqual(app.connectionProblem, .serverUnreachable)
        XCTAssertEqual(app.stacks.first?.cards?.map(\.title), ["From the server"])
        XCTAssertNil(app.stacksError)

        // A full reload fails the same way, without an error over the lists.
        await app.loadStacks(boardId: 1)
        XCTAssertEqual(app.stacks.first?.cards?.map(\.title), ["From the server"])
        XCTAssertNil(app.stacksError)
        XCTAssertNil(app.actionError)

        setReachable(true)
        await app.reconnect()
        XCTAssertNil(app.connectionProblem)
        XCTAssertFalse(app.isReadOnly)
    }

    func testABoardThatWasNeverOpenedSaysWhyItHasNoLists() async throws {
        var snapshot = try Self.savedSnapshot()
        snapshot.lists = [:]
        setReachable(false)
        let app = makeApp(InMemoryBoardCacheStore([Self.rob: snapshot]))
        await waitUntil { app.connectionProblem != nil && !app.isLoading }
        await app.loadStacks(boardId: 1)
        XCTAssertTrue(app.stacks.isEmpty)
        XCTAssertEqual(app.stacksError?.contains("haven't been saved on this Mac"), true)
    }

    func testEditingIsOffWhileOffline() async throws {
        setReachable(false)
        let app = try makeApp(InMemoryBoardCacheStore([Self.rob: Self.savedSnapshot()]))
        await waitUntil { app.connectionProblem != nil }
        app.selectedCardId = 100
        XCTAssertNotNil(app.selectedCard)
        XCTAssertFalse(app.canChangeSelectedCard)
        XCTAssertFalse(app.canMoveSelectedCard)
        app.startNewCard()
        XCTAssertNil(app.newCardListId)
        app.requestDeletingSelectedCard()
        XCTAssertNil(app.cardPendingDelete)
    }

    func testSearchFindsCardsOnSavedBoards() async throws {
        var snapshot = try Self.savedSnapshot()
        snapshot.selectedBoardId = nil
        setReachable(false)
        let app = makeApp(InMemoryBoardCacheStore([Self.rob: snapshot]))
        await waitUntil { app.connectionProblem != nil && !app.isLoading }
        app.selectedBoardId = nil
        app.cardSearchText = "saved"
        XCTAssertEqual(app.cardSearchResults.flatMap(\.results).map(\.card.title), ["Saved card"])
    }

    // MARK: - Accounts

    func testSigningOutDeletesThatAccountsCopy() async throws {
        let cache = try InMemoryBoardCacheStore([
            Self.rob: Self.savedSnapshot(),
            Self.alice: Self.savedSnapshot(),
        ])
        let app = makeApp(cache, accounts: .signedIn("rob", "alice"))
        await waitUntil { !app.isLoading }
        app.logout()
        XCTAssertNil(cache.snapshots[Self.rob])
        XCTAssertNotNil(cache.snapshots[Self.alice])
        XCTAssertEqual(app.activeAccount?.id, Self.alice)

        // Nothing still waiting to be saved brings rob's copy back.
        await sleep(seconds: 1.5)
        XCTAssertNil(cache.snapshots[Self.rob])
    }

    func testSwitchingAccountsShowsTheOtherAccountsCopy() async throws {
        var alices = try Self.savedSnapshot()
        alices.boards[0].title = "Alice's saved board"
        let cache = InMemoryBoardCacheStore([Self.alice: alices])
        let accounts = InMemoryCredentialStore.signedIn("rob", "alice")
        let app = makeApp(cache, accounts: accounts)
        await waitUntil { app.boards.first?.title == "Server board" && !app.isLoading }

        setReachable(false)
        let alice = try XCTUnwrap(app.accounts.first { $0.id == Self.alice })
        await app.switchAccount(to: alice)
        XCTAssertEqual(app.boards.map(\.title), ["Alice's saved board"])
        XCTAssertEqual(app.connectionProblem, .serverUnreachable)
        XCTAssertNotNil(cache.snapshots[Self.rob], "rob's boards were saved on switching")
    }
}
