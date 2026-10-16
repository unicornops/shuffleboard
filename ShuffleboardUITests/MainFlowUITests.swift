import XCTest

/// The app's main flows, driven through its UI against a real Nextcloud server with Deck (#119). Each test works
/// on a board of its own and checks the result on the server, not just on screen. Skipped without a test server.
@MainActor
final class MainFlowUITests: XCTestCase {
    private var server: UITestServer!
    private var alice: DeckClient!
    private var app: XCUIApplication!
    private var boards: [Int] = []

    override func setUp() async throws {
        continueAfterFailure = false
        server = try UITestServer.require()
        alice = try await server.client(for: UITestServer.alice)
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app?.terminate()
        for board in boards {
            await alice?.deleteBoard(board)
        }
    }

    private func makeBoard() async throws -> (id: Int, title: String) {
        let title = uniqueTitle("UI board")
        let id = try await alice.createBoard(title)
        boards.append(id)
        return (id, title)
    }

    // MARK: - Boards, lists and cards

    func testRenamingAndRecolouringABoard() async throws {
        let board = try await makeBoard()
        try await app.launch(on: server, as: [UITestServer.alice])
        app.openBoard(board.title)

        // From the sidebar's context menu.
        app.element("board: \(board.title)").rightClick()
        app.menuItems["Edit Board\u{2026}"].waitToAppear("No Edit Board item in the board's context menu").click()
        app.find(.textField, "Enter board name").waitToAppear("Edit sheet did not open")
            .replaceText(with: board.title + " renamed")
        app.find(.button, "Purple").click()
        app.find(.button, "Save").click()
        app.element("board: \(board.title) renamed").waitToAppear("Renamed board not shown in the sidebar")
        try await eventually("Board not renamed and recoloured on the server") {
            let saved = try await alice.board(board.id)
            return saved["title"] as? String == board.title + " renamed"
                && (saved["color"] as? String)?.lowercased() == "9c59b6"
        }

        // From the board's header.
        app.find(.button, "Edit board").waitToAppear().click()
        app.find(.textField, "Enter board name").waitToAppear().replaceText(with: board.title + " again")
        app.find(.button, "Save").click()
        app.element("board: \(board.title) again").waitToAppear("Board renamed from its header not shown")
        try await eventually("Board renamed from its header not saved on the server") {
            try await alice.board(board.id)["title"] as? String == board.title + " again"
        }
    }

    /// A deleted board goes to "Recently Deleted" and can be restored from there, except on Deck 1.16, which
    /// refuses; the app then says why.
    func testDeletingAndRestoringABoard() async throws {
        let board = try await makeBoard()
        try await app.launch(on: server, as: [UITestServer.alice])
        app.openBoard(board.title)

        app.element("board: \(board.title)").rightClick()
        app.menuItems["Archive"].waitToAppear("The board's context menu did not open")
        // Edit > Delete in the menu bar has the same title; the open context menu's item is the hittable one.
        let delete = app.menuItems.matching(NSPredicate(format: "title == %@", "Delete")).allElementsBoundByIndex
            .first { $0.isHittable }
        try XCTUnwrap(delete, "No Delete item in the board's context menu").click()
        // The dialog's button, not its Touch Bar copy, which can't be clicked.
        app.windows.descendants(matching: .button).matching(NSPredicate(format: "label == %@", "Delete")).firstMatch
            .waitToAppear("No confirmation before deleting the board").click()
        XCTAssertTrue(
            app.element("board: \(board.title)").waitForNonExistence(timeout: 10),
            "Deleted board still with the others"
        )
        try await eventually("Board not deleted on the server") {
            try await alice.isDeleted(board.id)
        }

        app.find(.button, "Recently Deleted").waitToAppear("No Recently Deleted section").click()
        app.element("deleted board: \(board.title)").waitToAppear("Deleted board not under Recently Deleted")
        app.find(.button, "Restore \(board.title)").click()

        guard server.deck(atLeast: "1.17") else {
            let explanation = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "can't restore deleted boards")).firstMatch
            explanation.waitToAppear("No explanation why Deck \(server.deckVersion) can't restore the board")
            return
        }
        app.element("board: \(board.title)").waitToAppear("Restored board not back with the others")
        try await eventually("Board not restored on the server") {
            try await !alice.isDeleted(board.id)
        }
    }

    /// Duplicating a board copies its lists and cards and opens the copy (#137).
    func testDuplicatingABoard() async throws {
        let board = try await makeBoard()
        let todo = try await alice.createStack(board: board.id, "To do", order: 0)
        _ = try await alice.createStack(board: board.id, "Done", order: 1)
        _ = try await alice.createCard(board: board.id, stack: todo, "Copy me")
        try await app.launch(on: server, as: [UITestServer.alice])
        app.openBoard(board.title)

        app.element("board: \(board.title)").rightClick()
        app.menuItems["Duplicate\u{2026}"].waitToAppear("No Duplicate item in the board's context menu").click()
        let copyTitle = board.title + " (copy)"
        let field = app.find(.textField, "Enter board name").waitToAppear("Duplicate sheet did not open")
        XCTAssertEqual(field.value as? String, copyTitle)
        app.find(.button, "Duplicate").click()

        app.element("board: \(copyTitle)").waitToAppear("Copy not in the sidebar", timeout: 30)
        let found = try await alice.boardId(titled: copyTitle)
        let copy = try XCTUnwrap(found, "Copy not on the server")
        boards.append(copy)
        let titles = try await alice.stacks(board: copy).compactMap { $0["title"] as? String }.sorted()
        XCTAssertEqual(titles, ["Done", "To do"])
        let copiedList = try await alice.list(holding: "Copy me", board: copy)
        XCTAssertEqual(copiedList, "To do", "Card not copied")
        app.list("To do").descendants(matching: .any)["card: Copy me"].waitToAppear("The copy isn't the open board")
    }

    func testCreatingListsAndACardThenDraggingItToAnotherList() async throws {
        let board = try await makeBoard()
        try await app.launch(on: server, as: [UITestServer.alice])
        app.openBoard(board.title)

        for list in ["To do", "Done"] {
            app.find(.button, "Add list").waitToAppear().click()
            app.find(.textField, "Enter list name").waitToAppear().typeText(list)
            app.find(.button, "Create").click()
            app.list(list).waitToAppear("List \(list) not shown after creating it")
        }

        app.list("To do").buttons["Add card"].click()
        // The field takes focus by itself (#140): type straight away, without clicking it.
        app.find(.textField, "Card title").waitToAppear()
        app.typeText("Write UI tests\r")
        let card = app.card("Write UI tests").waitToAppear("New card not shown")
        try await eventually("Card not created in To do on the server") {
            try await alice.list(holding: "Write UI tests", board: board.id) == "To do"
        }

        // The #117 regression: the card stays in "Done" after the drop and after a refresh.
        card.click(forDuration: 0.6, thenDragTo: app.list("Done"), withVelocity: .slow, thenHoldForDuration: 0.6)
        try await eventually("Dragged card is not in Done on the server") {
            try await alice.list(holding: "Write UI tests", board: board.id) == "Done"
        }
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(
            app.list("Done").descendants(matching: .any)["card: Write UI tests"].waitForExistence(timeout: 10),
            "Card snapped back out of Done after a refresh"
        )
    }

    func testRenamingLists() async throws {
        let board = try await makeBoard()
        _ = try await alice.createStack(board: board.id, "To do", order: 0)
        _ = try await alice.createStack(board: board.id, "Doing", order: 1)
        try await app.launch(on: server, as: [UITestServer.alice])
        app.openBoard(board.title)

        // From the list's menu.
        app.list("To do").waitToAppear().descendants(matching: .any)["List actions"].click()
        app.menuItems["Rename list"].waitToAppear("No Rename list item in the list's menu").click()
        app.find(.textField, "List name").waitToAppear("No field to rename the list").replaceText(with: "Backlog\r")
        app.list("Backlog").waitToAppear("Renamed list not shown")
        try await eventually("List not renamed on the server") {
            let titles = try await alice.stacks(board: board.id).compactMap { $0["title"] as? String }
            return titles.sorted() == ["Backlog", "Doing"]
        }

        // By double-clicking its title; Escape cancels.
        app.list("Doing").staticTexts["Doing"].doubleClick()
        let field = app.find(.textField, "List name").waitToAppear("Double-click did not start renaming")
        field.typeKey(.escape, modifierFlags: [])
        app.list("Doing").staticTexts["Doing"].waitToAppear("Escape did not cancel renaming").doubleClick()
        app.find(.textField, "List name").waitToAppear().replaceText(with: "In progress\r")
        app.list("In progress").waitToAppear("List renamed by double-click not shown")
        try await eventually("List renamed by double-click not saved on the server") {
            try await alice.stacks(board: board.id).contains { $0["title"] as? String == "In progress" }
        }
    }

    /// Moving cards into a list that already has cards (#117): dropped onto a card, and dropped between two cards.
    func testDraggingCardsIntoAListThatHasCards() async throws {
        let board = try await makeBoard()
        let todo = try await alice.createStack(board: board.id, "To do", order: 0)
        let doing = try await alice.createStack(board: board.id, "Doing", order: 1)
        for (order, title) in ["One", "Two", "Three"].enumerated() {
            _ = try await alice.createCard(board: board.id, stack: todo, title, order: order)
        }
        for (order, title) in ["Alpha", "Beta"].enumerated() {
            _ = try await alice.createCard(board: board.id, stack: doing, title, order: order)
        }
        try await app.launch(on: server, as: [UITestServer.alice])
        app.openBoard(board.title)
        app.card("Beta").waitToAppear()

        // Onto a card: the card goes to the end of that card's list.
        app.card("One").click(
            forDuration: 0.6,
            thenDragTo: app.card("Beta"),
            withVelocity: .slow,
            thenHoldForDuration: 0.6
        )
        try await eventually("Card dropped onto a card in Doing is not in Doing on the server") {
            try await alice.list(holding: "One", board: board.id) == "Doing"
        }

        // Between two cards: onto the gap just above Beta.
        let gap = app.card("Beta").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(
            dx: 0,
            dy: -5
        ))
        app.card("Two").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.6, thenDragTo: gap, withVelocity: .slow, thenHoldForDuration: 0.6)
        try await eventually("Card dropped between two cards in Doing is not in Doing on the server") {
            try await alice.list(holding: "Two", board: board.id) == "Doing"
        }
        let doingTitles = try await alice.titles(inList: "Doing", board: board.id)
        XCTAssertEqual(doingTitles, ["Alpha", "Two", "Beta", "One"])

        // Just inside the list's left edge, next to the gap between lists: that gap must not take the card.
        let edge = app.list("Doing").coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5))
        app.card("Three").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.6, thenDragTo: edge, withVelocity: .slow, thenHoldForDuration: 0.6)
        try await eventually("Card dropped at the edge of Doing is not in Doing on the server") {
            try await alice.list(holding: "Three", board: board.id) == "Doing"
        }

        app.typeKey("r", modifierFlags: .command)
        for title in ["One", "Two", "Three"] {
            XCTAssertTrue(
                app.list("Doing").descendants(matching: .any)["card: \(title)"].waitForExistence(timeout: 10),
                "\(title) snapped back out of Doing after a refresh"
            )
        }
    }

    /// Card moves made the way a person drags: a short press, a quick move and an immediate drop, with no pause
    /// over the target.
    func testQuickDragsToOtherLists() async throws {
        let board = try await makeBoard()
        let todo = try await alice.createStack(board: board.id, "To do", order: 0)
        let doing = try await alice.createStack(board: board.id, "Doing", order: 1)
        _ = try await alice.createStack(board: board.id, "Done", order: 2)
        for (order, title) in ["Quick one", "Quick two", "Quick three"].enumerated() {
            _ = try await alice.createCard(board: board.id, stack: todo, title, order: order)
        }
        _ = try await alice.createCard(board: board.id, stack: doing, "Already here")
        try await app.launch(on: server, as: [UITestServer.alice])
        app.openBoard(board.title)
        app.card("Already here").waitToAppear()

        let moves: [(card: String, list: String, velocity: XCUIGestureVelocity)] = [
            ("Quick one", "Doing", .default),
            ("Quick two", "Done", .fast),
            ("Quick three", "Doing", .fast),
        ]
        for move in moves {
            let target = app.list(move.list).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            app.card(move.card).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .click(forDuration: 0.2, thenDragTo: target, withVelocity: move.velocity, thenHoldForDuration: 0)
            try await eventually("\(move.card), dragged quickly, is not in \(move.list) on the server") {
                try await alice.list(holding: move.card, board: board.id) == move.list
            }
        }
    }

    /// Creating, moving, opening, finishing and archiving a card with only the keyboard (#159).
    /// Settings (#165): ⌘, opens it, and a change sticks when it's opened again. The toggle is flipped back, as
    /// the app's settings outlive the test.
    func testChangingASetting() async throws {
        try await app.launch(on: server, as: [UITestServer.alice])
        app.typeKey(",", modifierFlags: .command)
        let toggle = app.element("refresh when activated").waitToAppear("Settings did not open")
        let original = toggle.value as? Int
        toggle.click()
        XCTAssertNotEqual(toggle.value as? Int, original, "The setting did not change")

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(toggle.waitForNonExistence(timeout: 10), "Settings did not close")
        app.typeKey(",", modifierFlags: .command)
        let reopened = app.element("refresh when activated").waitToAppear("Settings did not open again")
        XCTAssertNotEqual(reopened.value as? Int, original, "The change was not kept")

        app.toolbars.buttons["Notifications"].click()
        app.element("due date notifications").waitToAppear("No notification settings")
        app.toolbars.buttons["General"].click()
        app.element("refresh when activated").waitToAppear().click()
        XCTAssertEqual(app.element("refresh when activated").value as? Int, original)
        app.typeKey("w", modifierFlags: .command)
    }

    func testWorkingWithCardsFromTheKeyboard() async throws {
        let board = try await makeBoard()
        let todo = try await alice.createStack(board: board.id, "To do", order: 0)
        _ = try await alice.createStack(board: board.id, "Done", order: 1)
        _ = try await alice.createCard(board: board.id, stack: todo, "Existing")
        try await app.launch(on: server, as: [UITestServer.alice])
        app.openBoard(board.title)
        app.card("Existing").waitToAppear()

        // File > New Card opens the field in the first list; the new card is then selected.
        app.typeKey("n", modifierFlags: .command)
        app.find(.textField, "Card title").waitToAppear("New Card did not open the card field")
        app.typeText("Keyboard card\r")
        app.card("Keyboard card").waitToAppear("New card not shown")
        try await eventually("Card not created in To do on the server") {
            try await alice.list(holding: "Keyboard card", board: board.id) == "To do"
        }

        // Card > Move to Next List.
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        try await eventually("Card not moved to Done on the server") {
            try await alice.list(holding: "Keyboard card", board: board.id) == "Done"
        }

        // Card > Open Card, then Escape closes it.
        app.typeKey("o", modifierFlags: .command)
        app.find(.textField, "card title").waitToAppear("Open Card did not open the card")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            app.find(.textField, "card title").waitForNonExistence(timeout: 10),
            "Escape did not close the card"
        )

        // Card > Mark as Done.
        app.typeKey("c", modifierFlags: [.command, .shift])
        try await eventually("Card not marked done on the server") {
            try await alice.card(titled: "Keyboard card", board: board.id)?["done"] is String
        }

        // The left arrow selects the card in To do; Card > Archive Card archives it.
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey("a", modifierFlags: [.command, .control])
        try await eventually("The card selected with the arrow keys was not archived on the server") {
            try await alice.card(titled: "Existing", board: board.id) == nil
        }
        let kept = try await alice.card(titled: "Keyboard card", board: board.id)
        XCTAssertNotNil(kept, "Archived the wrong card")
    }

    /// Edit > Search All Boards finds a card on another board; opening the result opens its board and the card (#158).
    func testSearchingAllBoardsAndOpeningACard() async throws {
        let open = try await makeBoard()
        let other = try await makeBoard()
        let list = try await alice.createStack(board: other.id, "Ideas", order: 0)
        let title = uniqueTitle("Findable")
        _ = try await alice.createCard(board: other.id, stack: list, title)
        try await app.launch(on: server, as: [UITestServer.alice])
        app.openBoard(open.title)

        app.typeKey("f", modifierFlags: [.command, .shift])
        let field = app.find(.textField, "Search all boards").waitToAppear("No search field in the sidebar")
        app.typeText(title)
        let result = app.element("search result: \(title)")
            .waitToAppear("Card on another board not found", timeout: 30)
        XCTAssertEqual(field.value as? String, title, "Search All Boards did not put the cursor in the field")

        result.click()
        let cardTitle = app.find(.textField, "card title").waitToAppear("The card did not open")
        XCTAssertEqual(cardTitle.value as? String, title)
        app.typeKey(.escape, modifierFlags: [])
        app.list("Ideas").waitToAppear("The card's board is not the open board")
    }

    func testEditingACardAndCommenting() async throws {
        let board = try await makeBoard()
        let stack = try await alice.createStack(board: board.id, "To do", order: 0)
        _ = try await alice.createCard(board: board.id, stack: stack, "Draft title")
        try await app.launch(on: server, as: [UITestServer.alice])
        app.openBoard(board.title)

        app.card("Draft title").waitToAppear().click()
        let title = app.find(.textField, "card title").waitToAppear("Card sheet did not open")
        title.replaceText(with: "Final title")
        app.find(.button, "Save").click()
        app.card("Final title").waitToAppear("Edited title not shown on the board")
        try await eventually("Edited title not saved on the server") {
            try await alice.list(holding: "Final title", board: board.id) == "To do"
        }

        app.card("Final title").click()
        let composer = app.find(.textField, "new comment").waitToAppear("No comment field on the card")
        composer.click()
        composer.typeText("Looks good to me")
        app.find(.button, "Comment").click()
        app.staticTexts["Looks good to me"].waitToAppear("Posted comment not shown")

        // The card's history (#164), below the comments: the rename names the old title.
        let activity = app.element("card activity")
        if server.hasActivity {
            if !activity.waitForExistence(timeout: 5) {
                app.sheets.firstMatch.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -2000)
            }
            activity.waitToAppear("No Activity section on the card")
            activity.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "Draft title")).firstMatch
                .waitToAppear("The card's activity doesn't show the rename")
        } else {
            XCTAssertFalse(activity.waitForExistence(timeout: 5), "An Activity section without the Activity app")
        }
        app.find(.button, "Cancel").click()
    }

    // MARK: - Windows (#160)

    /// A board opens in a new window from its context menu, or with ⌘-click; each window keeps its own board, and
    /// windows on the same board show the same lists, so a card added in one shows in the other.
    func testOpeningBoardsInNewWindows() async throws {
        let first = try await makeBoard()
        let second = try await makeBoard()
        _ = try await alice.createStack(board: first.id, "To do", order: 0)
        _ = try await alice.createStack(board: second.id, "Doing", order: 0)
        try await app.launch(on: server, as: [UITestServer.alice])
        app.openBoard(first.title)
        app.list("To do").waitToAppear("The first board's list isn't shown")

        app.element("board: \(second.title)").rightClick()
        app.menuItems["Open in New Window"].waitToAppear("No Open in New Window in the board's context menu").click()
        let secondWindow = app.windows.containing(.any, identifier: "list: Doing").firstMatch
        secondWindow.waitToAppear("The board did not open in a new window")
        XCTAssertEqual(app.windows.count, 2)
        let firstWindow = app.windows.containing(.any, identifier: "list: To do").firstMatch
        XCTAssertTrue(firstWindow.exists, "The first window no longer shows its board")

        secondWindow.list("Doing").buttons["Add card"].click()
        secondWindow.find(.textField, "Card title").waitToAppear()
        app.typeText("Added in a second window\r")
        try await eventually("Card not created on the server") {
            try await alice.list(holding: "Added in a second window", board: second.id) == "Doing"
        }

        // The first window opens the same board: the card is there too, from the same lists.
        firstWindow.element("board: \(second.title)").click()
        try await eventually("Both windows on the second board don't show the card") {
            app.windows.containing(.any, identifier: "card: Added in a second window").count == 2
        }

        // ⌘-click opens a board in another window.
        XCUIElement.perform(withKeyModifiers: .command) {
            app.windows.firstMatch.element("board: \(first.title)").click()
        }
        try await eventually("⌘-click did not open the board in a new window") {
            app.windows.count == 3
        }
        app.windows.containing(.any, identifier: "list: To do").firstMatch
            .waitToAppear("The ⌘-clicked board isn't shown in the new window")
    }

    /// @mentions (#163): typing "@" in a comment suggests the board's members; picking one writes the mention, which
    /// is shown by name once posted.
    func testMentioningSomeoneInAComment() async throws {
        let board = try await makeBoard()
        try await alice.share(board: board.id, with: UITestServer.bob)
        let stack = try await alice.createStack(board: board.id, "To do", order: 0)
        _ = try await alice.createCard(board: board.id, stack: stack, "Needs Bob")
        try await app.launch(on: server, as: [UITestServer.alice])
        app.openBoard(board.title)

        app.card("Needs Bob").waitToAppear().click()
        let composer = app.find(.textField, "new comment").waitToAppear("No comment field on the card")
        composer.click()
        composer.typeText("Over to @bo")
        app.element("mention \(UITestServer.bob)").waitToAppear("Bob not suggested").click()
        XCTAssertEqual(composer.value as? String, "Over to @\(UITestServer.bob) ")
        composer.typeText("now")
        app.find(.button, "Comment").click()
        app.staticTexts["Over to @Bob Example now"].waitToAppear("The mention is not shown by name")
        app.find(.button, "Cancel").click()
    }

    // MARK: - Offline (#156)

    func testKeepsShowingTheBoardReadOnlyWhileTheServerIsAway() async throws {
        let serverSwitch = try ServerSwitch.require()
        let board = try await makeBoard()
        let stack = try await alice.createStack(board: board.id, "To do", order: 0)
        _ = try await alice.createCard(board: board.id, stack: stack, "Still here offline")
        app.launchEnvironment["SHUFFLEBOARD_UITEST_BOARD_CACHE"] = "fresh"
        try await app.launch(on: server, as: [UITestServer.alice])
        app.openBoard(board.title)
        app.card("Still here offline").waitToAppear()
        app.find(.button, "Add card").waitToAppear("No Add card button while online")
        // The copy is saved a second after the last change.
        try await Task.sleep(for: .seconds(2))

        let windowFrame = app.windows.firstMatch.frame
        let config = try await serverSwitch.takeAway()
        addTeardownBlock { try? await serverSwitch.bringBack(config) }
        app.typeKey("r", modifierFlags: .command)
        app.element("offline banner").waitToAppear("No offline banner once the server went away")
        XCTAssertEqual(app.windows.firstMatch.frame, windowFrame, "The window changed size when the banner appeared")
        XCTAssertTrue(app.card("Still here offline").exists, "The board is no longer shown")
        XCTAssertFalse(app.find(.button, "Add card").exists, "Cards can still be added")
        XCTAssertFalse(app.find(.button, "Add list").isEnabled, "Lists can still be added")
        app.card("Still here offline").click()
        app.element("card read-only notice").waitToAppear("The card's sheet doesn't say it's read-only")
        XCTAssertFalse(app.find(.textField, "card title").isEnabled, "The card's title can still be edited")
        app.find(.button, "Close").click()

        // Opened again with the server still away: the board from the Mac, straight away.
        app.terminate()
        app.launchEnvironment["SHUFFLEBOARD_UITEST_BOARD_CACHE"] = "keep"
        app.launch()
        app.card("Still here offline").waitToAppear("The saved board isn't shown at launch")
        app.element("offline banner").waitToAppear("No offline banner at launch")

        try await serverSwitch.bringBack(config)
        app.find(.button, "Try Again").click()
        XCTAssertTrue(
            app.element("offline banner").waitForNonExistence(timeout: 15),
            "The offline banner stayed once the server was back"
        )
        app.find(.button, "Add card").waitToAppear("Editing didn't come back with the server")
    }

    // MARK: - Labels

    func testEditingAndDeletingLabels() async throws {
        let board = try await makeBoard()
        _ = try await alice.createLabel(board: board.id, "UI urgent")
        _ = try await alice.createLabel(board: board.id, "UI someday")
        try await app.launch(on: server, as: [UITestServer.alice])
        app.openBoard(board.title)

        app.find(.button, "Labels").waitToAppear().click()
        app.find(.button, "Edit UI urgent").waitToAppear("Label not listed in the Labels sheet").click()
        app.find(.textField, "Label name").waitToAppear("Label editor did not open").replaceText(with: "UI critical")
        app.find(.button, "Save").click()
        app.staticTexts["UI critical"].waitToAppear("Renamed label not shown")
        try await eventually("Label not renamed on the server") {
            let labels = try await alice.labels(board: board.id)
            return labels.contains("UI critical") && !labels.contains("UI urgent")
        }

        app.find(.button, "Delete UI someday").click()
        // The dialog's button, not its Touch Bar copy, which can't be clicked.
        app.windows.descendants(matching: .button).matching(NSPredicate(format: "label == %@", "Delete")).firstMatch
            .waitToAppear("No confirmation before deleting a label").click()
        try await eventually("Label not deleted on the server") {
            try await !alice.labels(board: board.id).contains("UI someday")
        }
        XCTAssertTrue(
            app.staticTexts["UI someday"].waitForNonExistence(timeout: 10),
            "Deleted label still listed"
        )
        app.find(.button, "Done").click()
    }

    /// Removing an attachment asks first; a `deck_file` one stays listed and can be restored (#139).
    func testRemovingAndRestoringAnAttachment() async throws {
        let board = try await makeBoard()
        let stack = try await alice.createStack(board: board.id, "To do", order: 0)
        let card = try await alice.createCard(board: board.id, stack: stack, "With a file")
        let attachment = try await alice.attachDeckFile(board: board.id, stack: stack, card: card, name: "notes.txt")
        let deletedAt = {
            try await self.alice.attachments(board: board.id, stack: stack, card: card)
                .first { $0["id"] as? Int == attachment }?["deletedAt"] as? Int ?? 0
        }
        try await app.launch(on: server, as: [UITestServer.alice])
        app.openBoard(board.title)

        app.card("With a file").waitToAppear().click()
        app.find(.button, "Remove notes.txt").waitToAppear("Attachment not shown on the card").click()
        // The dialog's button, not its Touch Bar copy, which can't be clicked.
        app.windows.descendants(matching: .button).matching(NSPredicate(format: "label == %@", "Remove")).firstMatch
            .waitToAppear("No confirmation before removing an attachment").click()
        try await eventually("Attachment not removed on the server") { try await deletedAt() > 0 }

        // A link-style button: not necessarily of type button.
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Restore notes.txt")).firstMatch
            .waitToAppear("Removed attachment can't be restored").click()
        try await eventually("Attachment not restored on the server") { try await deletedAt() == 0 }
        app.find(.button, "Remove notes.txt").waitToAppear("Restored attachment not shown as attached")
        app.find(.button, "Cancel").click()
    }

    /// Start dates (#138), on Deck 1.18 and later; older versions have none, so the sheet doesn't offer them.
    func testSettingAndClearingAStartDate() async throws {
        let board = try await makeBoard()
        let stack = try await alice.createStack(board: board.id, "To do", order: 0)
        _ = try await alice.createCard(board: board.id, stack: stack, "Plan the trip")
        try await app.launch(on: server, as: [UITestServer.alice])
        app.openBoard(board.title)

        app.card("Plan the trip").waitToAppear().click()
        app.find(.textField, "card title").waitToAppear("Card sheet did not open")
        app.element("has due date").waitToAppear()
        guard server.deck(atLeast: "1.18") else {
            XCTAssertFalse(app.element("has start date").exists, "Start date offered on Deck \(server.deckVersion)")
            app.find(.button, "Cancel").click()
            return
        }
        // Starts today at 9:00, due tomorrow at 9:00: the defaults.
        app.element("has start date").click()
        app.element("has due date").click()
        app.find(.button, "Save").click()
        try await eventually("Start date not saved on the server") {
            let card = try await alice.card(titled: "Plan the trip", board: board.id)
            guard let start = card?["startdate"] as? String, let due = card?["duedate"] as? String else { return false }
            return start < due
        }

        app.card("Plan the trip").waitToAppear().click()
        app.element("has start date").waitToAppear("Start date not shown when reopening the card").click()
        app.find(.button, "Save").click()
        try await eventually("Start date not cleared on the server") {
            let card = try await alice.card(titled: "Plan the trip", board: board.id)
            return card?["startdate"] as? String == nil && card?["duedate"] as? String != nil
        }
    }

    // MARK: - Sharing

    func testSharingABoard() async throws {
        let board = try await makeBoard()
        try await app.launch(on: server, as: [UITestServer.alice])
        app.openBoard(board.title)

        app.find(.button, "Sharing").waitToAppear().click()
        let search = app.find(.textField, "Search people, groups and teams").waitToAppear("Sharing sheet did not open")
        search.click()
        search.typeText("bob")
        app.find(.button, "Share with Bob Example").waitToAppear("Bob not found in the share search").click()
        try await eventually("Board not shared with Bob on the server") {
            let acl = try await alice.board(board.id)["acl"] as? [[String: Any]] ?? []
            return acl.contains { ($0["participant"] as? [String: Any])?["uid"] as? String == UITestServer.bob }
        }
        app.staticTexts["Bob Example"].waitToAppear("Bob not listed as having access")
        app.find(.button, "Done").click()
    }

    // MARK: - Accounts

    func testSwitchingAccountsAndSigningOut() async throws {
        let board = try await makeBoard()
        let bob = try await server.client(for: UITestServer.bob)
        let bobsTitle = uniqueTitle("UI Bob's board")
        let bobsBoard = try await bob.createBoard(bobsTitle)
        defer { Task { await bob.deleteBoard(bobsBoard) } }

        let accounts = try await app.launch(on: server, as: [UITestServer.alice, UITestServer.bob])
        app.element("board: \(board.title)").waitToAppear("Alice's board not shown")

        accountMenu().click()
        app.menuItems[server.accountId(UITestServer.bob)].waitToAppear("Bob's account not in the account menu").click()
        app.element("board: \(bobsTitle)").waitToAppear("Bob's board not shown after switching")
        XCTAssertFalse(app.element("board: \(board.title)").exists, "Alice's board still shown for Bob")

        // Signing out of Bob goes back to Alice; signing out of her too shows the sign-in screen.
        accountMenu().click()
        app.menuItems["Sign Out of \(server.accountId(UITestServer.bob))"].waitToAppear().click()
        app.element("board: \(board.title)").waitToAppear("Not back on Alice's account after signing Bob out")
        accountMenu().click()
        app.menuItems["Sign Out of \(server.accountId(UITestServer.alice))"].waitToAppear().click()
        app.find(.button, "Sign in with browser").waitToAppear("Sign-in screen not shown after signing out")

        for account in accounts {
            let client = DeckClient(server: server, user: account.user, appPassword: account.appPassword)
            try await eventually("Signing out did not revoke \(account.user)'s app password") {
                try await !client.isValid()
            }
        }
    }

    private func accountMenu() -> XCUIElement {
        let menu = app.find(.menuButton, "Account menu")
        return menu.waitForExistence(timeout: 5) ? menu : app.find(.popUpButton, "Account menu").waitToAppear()
    }
}
