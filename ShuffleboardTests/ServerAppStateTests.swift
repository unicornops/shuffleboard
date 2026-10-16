import Foundation
import XCTest
@testable import Shuffleboard

/// `AppState` against a real Nextcloud server with Deck (#119): signing in, the flows the UI drives, several
/// accounts and the session ending. Credentials stay in memory. Skipped without a test server (see `TestServer`).
@MainActor
final class ServerAppStateTests: XCTestCase {
    private var server: TestServer!
    private var store: InMemoryCredentialStore!
    /// One session for every account, like the app's `URLSession.shared`, but with its own cookies.
    private var session: URLSession!

    override func setUp() async throws {
        server = try TestServer.require()
        store = InMemoryCredentialStore()
        session = URLSession(configuration: .ephemeral)
    }

    private func makeApp() -> AppState {
        AppState(credentialStore: store, session: session, openURL: { _ in })
    }

    private func signedInApp(as user: String = TestServer.alice) async throws -> AppState {
        let app = makeApp()
        try await app.finishSignIn(server.credentials(for: user))
        XCTAssertTrue(app.isLoggedIn)
        XCTAssertNil(app.errorMessage)
        return app
    }

    // MARK: - Sign-in

    /// Login Flow v2 end to end: the app starts the flow, a scripted browser signs in and grants access on the
    /// server's web pages, and the app's polling picks up the app password.
    func testBrowserSignIn() async throws {
        let server = try XCTUnwrap(server)
        let browserError = Locked<Error?>(nil)
        let app = AppState(credentialStore: store, session: session, openURL: { url in
            Task {
                do {
                    try await LoginFlowBrowser.approve(loginURL: url, on: server, as: TestServer.alice)
                } catch {
                    browserError.withLock { $0 = error }
                }
            }
        })
        XCTAssertTrue(app.showingLogin)

        app.startBrowserLogin(serverURL: server.url)
        await waitUntil(timeout: 60) {
            app.isLoggedIn || app.errorMessage != nil || browserError.withLock { $0 } != nil
        }
        if let error = browserError.withLock({ $0 }) {
            XCTFail("Browser sign-in failed on \(server.version): \(error)")
        }
        XCTAssertNil(app.errorMessage)
        XCTAssertTrue(app.isLoggedIn)
        XCTAssertFalse(app.showingLogin)
        XCTAssertEqual(app.activeAccount?.username, TestServer.alice)
        XCTAssertEqual(store.credentials?.username, TestServer.alice, "Credentials not saved")
        XCTAssertNotEqual(
            store.credentials?.appPassword,
            server.password(of: TestServer.alice),
            "Saved the login password"
        )

        await waitUntil(timeout: 10) { !app.isLoading }
        XCTAssertNil(app.errorMessage)
        try await app.signOutAndCheckRevoked(on: server, store: store)
    }

    // MARK: - Boards, lists and cards

    func testCreatingAndMovingCardsThroughAppState() async throws {
        let app = try await signedInApp()
        let title = uniqueTitle("E2E app")
        let created = await app.createBoard(title: title, color: "31CC7C")
        XCTAssertTrue(created, app.errorMessage ?? "")
        let board = try XCTUnwrap(app.boards.first { $0.title == title })
        XCTAssertEqual(app.serverDeckVersion, server.deckVersion)
        XCTAssertEqual(app.supportsStartDates, server.deck(atLeast: "1.18"))

        app.window.selectBoard(board)
        await app.loadStacks(boardId: board.id)
        let addedTodo = await app.createStack(boardId: board.id, title: "To do")
        let addedDone = await app.createStack(boardId: board.id, title: "Done")
        XCTAssertTrue(addedTodo && addedDone, app.errorMessage ?? "")
        XCTAssertEqual(app.window.stacks.map(\.title), ["To do", "Done"])
        let todo = app.window.stacks[0]
        let done = app.window.stacks[1]

        await app.window.createCard(boardId: board.id, stackId: todo.id, title: "Ship it")
        XCTAssertNil(app.actionError)
        let card = try XCTUnwrap(app.window.stacks.first?.activeCards.first)
        XCTAssertEqual(card.title, "Ship it")

        // The #117 regression: after a move, the reload from the server must still show the card in "Done".
        await app.moveCard(boardId: board.id, cardId: card.id, fromStackId: todo.id, toStackId: done.id, order: 0)
        XCTAssertNil(app.actionError)
        XCTAssertEqual(app.window.stacks.stack(holding: card.id)?.id, done.id)
        await app.refresh()
        await waitUntil(timeout: 10) { !app.isLoading && !app.window.isLoadingStacks }
        XCTAssertEqual(app.window.stacks.stack(holding: card.id)?.id, done.id, "Card snapped back after a refresh")

        let moved = try XCTUnwrap(app.window.stacks.stack(holding: card.id)?.activeCards.first { $0.id == card.id })
        let saved = await app.updateCard(
            boardId: board.id,
            stackId: done.id,
            card: moved,
            edits: CardEdits(title: "Shipped", description: "Release notes", startDate: nil, dueDate: nil, isDone: true)
        )
        XCTAssertTrue(saved, app.errorMessage ?? "")
        let edited = try XCTUnwrap(app.window.stacks.stack(holding: card.id)?.activeCards.first { $0.id == card.id })
        XCTAssertEqual(edited.title, "Shipped")
        XCTAssertEqual(edited.description, "Release notes")
        XCTAssertTrue(edited.isDone)

        let comment = await app.addComment("Done and dusted", to: edited)
        XCTAssertEqual(comment?.message, "Done and dusted")
        let comments = await app.comments(for: edited, offset: 0)
        XCTAssertEqual(comments?.map(\.message), ["Done and dusted"])
        XCTAssertNil(app.actionError)

        await app.deleteBoard(id: board.id)
        XCTAssertFalse(app.activeBoards.contains { $0.id == board.id })
        XCTAssertEqual(app.deletedBoards.first?.id, board.id, "Deleted board not under Recently Deleted")
    }

    /// Deleting moves a board to Recently Deleted; restoring brings it back, except on Deck 1.16, which can't (#136).
    func testDeletingAndRestoringABoard() async throws {
        let app = try await signedInApp()
        let title = uniqueTitle("E2E restore")
        let created = await app.createBoard(title: title, color: "31CC7C")
        XCTAssertTrue(created, app.errorMessage ?? "")
        let board = try XCTUnwrap(app.boards.first { $0.title == title })

        await app.deleteBoard(id: board.id)
        XCTAssertNil(app.actionError)
        XCTAssertFalse(app.activeBoards.contains { $0.id == board.id })
        await app.refresh()
        let deleted = try XCTUnwrap(app.deletedBoards.first { $0.id == board.id }, "Not under Recently Deleted")
        XCTAssertTrue(deleted.canManage, "The owner can restore it")

        await app.window.restoreBoard(id: board.id)

        guard server.deck(atLeast: "1.17") else {
            XCTAssertEqual(app.actionError, AppState.restoreUnsupportedMessage(deckVersion: server.deckVersion))
            XCTAssertTrue(app.deletedBoards.contains { $0.id == board.id })
            return
        }
        XCTAssertNil(app.actionError)
        XCTAssertTrue(app.activeBoards.contains { $0.id == board.id }, "Restored board not back with the others")
        XCTAssertEqual(app.window.selectedBoardId, board.id)
        let onServer = try await server.api(for: TestServer.alice).getBoard(id: board.id)
        XCTAssertFalse(onServer.isDeleted)
        await app.deleteBoard(id: board.id)
    }

    func testEditingABoard() async throws {
        let app = try await signedInApp()
        let title = uniqueTitle("E2E edit")
        let created = await app.createBoard(title: title, color: "31CC7C")
        XCTAssertTrue(created, app.errorMessage ?? "")
        let board = try XCTUnwrap(app.boards.first { $0.title == title })
        XCTAssertTrue(board.canManage, "The owner can manage the board")

        let saved = await app.updateBoard(id: board.id, title: title + " renamed", color: "9C59B6")

        XCTAssertTrue(saved, app.errorMessage ?? "")
        XCTAssertEqual(app.boards.first { $0.id == board.id }?.title, title + " renamed")
        let onServer = try await server.api(for: TestServer.alice).getBoard(id: board.id)
        XCTAssertEqual(onServer.title, title + " renamed")
        XCTAssertEqual(onServer.color?.lowercased(), "9c59b6")
        XCTAssertFalse(onServer.archived)

        // An archived board stays archived when it is edited.
        await app.archiveBoard(id: board.id)
        let renamedAgain = await app.updateBoard(id: board.id, title: title + " archived", color: "31CC7C")
        XCTAssertTrue(renamedAgain, app.errorMessage ?? "")
        let archived = try await server.api(for: TestServer.alice).getBoard(id: board.id)
        XCTAssertTrue(archived.archived, "Editing an archived board unarchived it")
        XCTAssertEqual(app.archivedBoards.map(\.id), [board.id])
        await app.deleteBoard(id: board.id)
    }

    func testRenamingAList() async throws {
        let app = try await signedInApp()
        let title = uniqueTitle("E2E rename list")
        let created = await app.createBoard(title: title, color: "31CC7C")
        XCTAssertTrue(created, app.errorMessage ?? "")
        let board = try XCTUnwrap(app.boards.first { $0.title == title })
        XCTAssertTrue(board.canEdit, "The owner can edit the board")
        app.window.selectBoard(board)
        await app.loadStacks(boardId: board.id)
        for list in ["To do", "Doing", "Done"] {
            let added = await app.createStack(boardId: board.id, title: list)
            XCTAssertTrue(added, app.errorMessage ?? "")
        }
        let doing = try XCTUnwrap(app.window.stacks.first { $0.title == "Doing" })

        await app.renameStack(boardId: board.id, stackId: doing.id, title: "In progress")

        XCTAssertNil(app.actionError)
        XCTAssertEqual(app.window.stacks.map(\.title), ["To do", "In progress", "Done"])
        let onServer = try await server.api(for: TestServer.alice).getStacks(boardId: board.id)
        XCTAssertEqual(AppState.sorted(onServer).map(\.title), ["To do", "In progress", "Done"], "Renamed list moved")
        await app.deleteBoard(id: board.id)
    }

    /// The realistic test server's board of 300 cards (#142) loads whole: every list and card, in order, with labels.
    func testOpeningALargeBoard() async throws {
        guard ProcessInfo.processInfo.environment["E2E_PROFILE"] == "realistic" else {
            throw XCTSkip("Only the realistic test server has the large board")
        }
        let app = try await signedInApp()
        await app.loadBoards()
        let board = try XCTUnwrap(app.boards.first { $0.title == "Big backlog" }, "No large board: run seed.sh")
        app.window.selectBoard(board)
        await app.loadStacks(boardId: board.id)

        XCTAssertNil(app.window.stacksError)
        XCTAssertEqual(app.window.stacks.map(\.title), (1 ... 12).map { "List \($0)" })
        XCTAssertEqual(app.window.stacks.reduce(0) { $0 + $1.activeCards.count }, 300)
        let first = try XCTUnwrap(app.window.stacks.first)
        XCTAssertEqual(first.activeCards.map(\.title), (1 ... 25).map { "Card 1.\($0)" })
        XCTAssertEqual(first.activeCards.count { !($0.labels ?? []).isEmpty }, 8, "Labels missing")
        XCTAssertEqual(first.activeCards.count { $0.duedate != nil }, 6, "Due dates missing")
    }

    /// Picks up a change made elsewhere (here: another client) with the ETag refresh.
    func testRefreshIfChangedPicksUpChangesFromAnotherClient() async throws {
        let app = try await signedInApp()
        let other = try await server.api(for: TestServer.alice)
        try await withTemporaryBoard(other) { board in
            await app.loadBoards()
            app.window.selectBoard(board)
            await app.loadStacks(boardId: board.id)
            XCTAssertTrue(app.window.stacks.isEmpty)

            let stack = try await other.createStack(boardId: board.id, title: "Added elsewhere")
            await app.refreshIfChanged()
            XCTAssertEqual(app.window.stacks.map(\.id), [stack.id])

            // Once the lists are settled, an unchanged board list skips them (#141); a card added elsewhere
            // changes the board list's ETag, so the lists are downloaded again. Deck's ETags have 1-second steps.
            await sleep(seconds: 1.6)
            await app.refreshIfChanged()
            await sleep(seconds: 1.1)
            let card = try await other.createCard(boardId: board.id, stackId: stack.id, title: "Card from elsewhere")
            await app.refreshIfChanged()
            XCTAssertEqual(
                app.window.stacks.first?.activeCards.map(\.id),
                [card.id],
                "Card added elsewhere not picked up"
            )
        }
    }

    /// Searching all boards finds cards on every board, archived ones too, and picks up cards added since (#158).
    func testSearchingAllBoards() async throws {
        let app = try await signedInApp()
        let other = try await server.api(for: TestServer.alice)
        let word = uniqueTitle("Needle").replacingOccurrences(of: " ", with: "")
        try await withTemporaryBoard(other) { first in
            try await withTemporaryBoard(other) { second in
                let firstList = try await other.createStack(boardId: first.id, title: "To do")
                let secondList = try await other.createStack(boardId: second.id, title: "Doing")
                _ = try await other.createCard(boardId: first.id, stackId: firstList.id, title: "\(word) one")
                let archived = try await other.createCard(
                    boardId: second.id,
                    stackId: secondList.id,
                    title: "\(word) two"
                )
                try await other.archiveCard(boardId: second.id, stackId: secondList.id, cardId: archived.id)
                _ = try await other.createCard(boardId: second.id, stackId: secondList.id, title: "Haystack")
                await app.loadBoards()

                app.window.cardSearchText = word
                await app.loadCardsForSearch()
                let found = app.window.cardSearchResults.filter { [first.id, second.id].contains($0.board.id) }
                XCTAssertEqual(Set(found.map(\.board.id)), [first.id, second.id])
                let titles = found.flatMap(\.results).map { "\($0.card.title) in \($0.listTitle)" }
                XCTAssertEqual(Set(titles), ["\(word) one in To do", "\(word) two in Doing"])
                XCTAssertEqual(found.flatMap(\.results).first { $0.card.id == archived.id }?.card.archived, true)

                // A card added elsewhere: the board list reports the change, so the board is fetched again.
                await sleep(seconds: 1.6)
                _ = try await other.createCard(boardId: first.id, stackId: firstList.id, title: "\(word) three")
                await app.loadCardsForSearch()
                let again = app.window.cardSearchResults.flatMap(\.results).map(\.card.title)
                XCTAssertTrue(again.contains("\(word) three"), "New card not found: \(again)")
            }
        }
    }

    // MARK: - Accounts

    func testSwitchingBetweenTwoAccounts() async throws {
        let app = try await signedInApp(as: TestServer.alice)
        let aliceBoard = uniqueTitle("E2E Alice's")
        _ = await app.createBoard(title: aliceBoard, color: "31CC7C")
        let aliceBoardId = try XCTUnwrap(app.boards.first { $0.title == aliceBoard }?.id)

        try await app.finishSignIn(server.credentials(for: TestServer.bob))
        XCTAssertEqual(app.accounts.map(\.username), [TestServer.alice, TestServer.bob])
        XCTAssertEqual(app.activeAccount?.username, TestServer.bob)
        // Same URLSession, so also the same cookies: the server must answer as Bob, not Alice.
        XCTAssertFalse(app.boards.contains { $0.id == aliceBoardId }, "Bob's account shows Alice's board")

        let alice = try XCTUnwrap(app.accounts.first { $0.username == TestServer.alice })
        await app.switchAccount(to: alice)
        XCTAssertEqual(app.activeAccount?.username, TestServer.alice)
        XCTAssertTrue(app.boards.contains { $0.id == aliceBoardId }, "Alice's board missing after switching back")
        await app.deleteBoard(id: aliceBoardId)

        // Signing out of one account goes to the other.
        await app.signOut()
        XCTAssertTrue(app.isLoggedIn)
        XCTAssertEqual(app.activeAccount?.username, TestServer.bob)
        XCTAssertEqual(store.saved.accounts.map(\.username), [TestServer.bob])
        try await app.signOutAndCheckRevoked(on: server, store: store)
    }

    // MARK: - Session ending

    func testRevokedAppPasswordSignsOut() async throws {
        let creds = try await server.credentials(for: TestServer.alice)
        let app = makeApp()
        try await app.finishSignIn(creds)
        XCTAssertTrue(app.isLoggedIn)

        // Revoked elsewhere, e.g. in the web UI's security settings.
        let elsewhere = DeckAPI(serverURL: creds.serverURL, username: creds.username, appPassword: creds.appPassword)
        try await elsewhere.revokeAppPassword()

        await app.refresh()
        XCTAssertFalse(app.isLoggedIn, "Still signed in with a revoked app password")
        XCTAssertTrue(app.showingLogin)
        XCTAssertEqual(app.errorMessage, DeckAPIError.unauthorized.localizedDescription)
        XCTAssertTrue(store.saved.all.isEmpty, "Revoked credentials kept")
    }
}

// MARK: - Helpers

@MainActor
private extension AppState {
    /// Signs out the last account and checks that its app password no longer works on the server.
    func signOutAndCheckRevoked(on server: TestServer, store: InMemoryCredentialStore) async throws {
        let creds = try XCTUnwrap(store.credentials)
        await signOut()
        XCTAssertFalse(isLoggedIn)
        XCTAssertTrue(showingLogin)
        XCTAssertTrue(store.saved.all.isEmpty)
        let old = DeckAPI(
            serverURL: creds.serverURL,
            username: creds.username,
            appPassword: creds.appPassword,
            session: URLSession(configuration: .ephemeral)
        )
        do {
            _ = try await old.getBoards()
            XCTFail("Signing out did not revoke the app password")
        } catch DeckAPIError.unauthorized {
            // Expected.
        }
    }
}
