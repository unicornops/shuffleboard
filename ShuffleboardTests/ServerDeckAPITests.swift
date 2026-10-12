import Foundation
import XCTest
@testable import Shuffleboard

/// `DeckAPI` against a real Nextcloud server with Deck (#119): every endpoint the app uses, so a server release
/// that changes them fails here rather than in the app. Skipped without a test server (see `TestServer`).
final class ServerDeckAPITests: XCTestCase {
    private var server: TestServer!
    private var api: DeckAPI!

    override func setUp() async throws {
        server = try TestServer.require()
        api = try await server.api(for: TestServer.alice)
    }

    // MARK: - Boards

    func testBoardLifecycle() async throws {
        let title = uniqueTitle("E2E lifecycle")
        let created = try await api.createBoard(title: title, color: "31CC7C")
        XCTAssertEqual(created.title, title)
        XCTAssertEqual(created.owner?.uid, TestServer.alice)
        var boards = try await api.getBoards()
        XCTAssertTrue(boards.contains { $0.id == created.id }, "New board missing from the board list")

        let renamed = title + " renamed"
        let archived = try await api.updateBoard(id: created.id, title: renamed, color: "E9322D", archived: true)
        XCTAssertEqual(archived.title, renamed)
        XCTAssertTrue(archived.archived)
        // Deck has no partial update: leaving `archived` out unarchives the board, so the app always sends it (#133).
        let edited = try await api.updateBoard(id: created.id, title: renamed, color: "9C59B6", archived: true)
        XCTAssertTrue(edited.archived, "Editing an archived board unarchived it")
        let color = try await api.getBoard(id: created.id).color
        XCTAssertEqual(color?.lowercased(), "9c59b6")
        let unarchived = try await api.updateBoard(id: created.id, title: renamed, color: "E9322D", archived: false)
        XCTAssertFalse(unarchived.archived)

        try await api.deleteBoard(id: created.id)
        boards = try await api.getBoards()
        let deleted = boards.first { $0.id == created.id }
        XCTAssertGreaterThan(deleted?.deletedAt ?? 0, 0, "Deleted board should be soft-deleted, not gone")

        guard server.deck(atLeast: "1.17") else {
            // Deck 1.16 refuses to restore a deleted board (fixed in 1.17.0), so the app's "Restore" fails there.
            do {
                try await api.undoDeleteBoard(id: created.id)
                XCTFail("Deck \(server.deckVersion) restored a deleted board: drop this exception")
            } catch DeckAPIError.permissionDenied {
                // Expected.
            }
            return
        }
        try await api.undoDeleteBoard(id: created.id)
        let restored = try await api.getBoard(id: created.id)
        XCTAssertEqual(restored.deletedAt ?? 0, 0)
        try await api.deleteBoard(id: created.id)
    }

    /// The app reads Deck's version to explain a refused restore on Deck 1.16 (#136).
    func testDeckVersion() async throws {
        let version = try await api.deckVersion()
        XCTAssertEqual(version, server.deckVersion)
    }

    /// Reminders match assignments against the user id the server reports (#157).
    func testCurrentUserId() async throws {
        let userId = try await api.currentUserId()
        XCTAssertEqual(userId, TestServer.alice)
    }

    // MARK: - Duplicating boards (#137)

    /// The copy matches the source: colour, labels (Deck's defaults replaced), lists in order, and active cards with
    /// their descriptions, dates, done state and labels. Archived cards aren't copied.
    func testCopyingABoard() async throws {
        try await withTemporaryBoard(api) { source in
            var labels = try await api.getBoard(id: source.id).labels
            let urgent = try await api.createLabel(boardId: source.id, title: "Urgent", color: "E9322D")
            if let finished = labels.first(where: { $0.title == "Finished" }) {
                try await api.deleteLabel(boardId: source.id, labelId: finished.id)
            }
            if let later = labels.first(where: { $0.title == "Later" }) {
                _ = try await api.updateLabel(boardId: source.id, labelId: later.id, title: "Later", color: "9C59B6")
            }
            labels = try await api.getBoard(id: source.id).labels

            let todo = try await api.createStack(boardId: source.id, title: "To do", order: 0)
            _ = try await api.createStack(boardId: source.id, title: "Done", order: 1)
            let first = try await api.createCard(
                boardId: source.id,
                stackId: todo.id,
                title: "Write it",
                description: "With **notes**",
                order: 0,
                duedate: "2030-03-04T09:00:00+00:00"
            )
            try await api.assignLabel(boardId: source.id, stackId: todo.id, cardId: first.id, labelId: urgent.id)
            var second = try await api.createCard(boardId: source.id, stackId: todo.id, title: "Ship it", order: 1)
            second.done = "2030-01-02T09:00:00+00:00"
            _ = try await api.updateCard(boardId: source.id, stackId: todo.id, card: second)
            let old = try await api.createCard(boardId: source.id, stackId: todo.id, title: "Old", order: 2)
            try await api.archiveCard(boardId: source.id, stackId: todo.id, cardId: old.id)

            let sourceBoard = try await api.getBoard(id: source.id)
            let copy = try await api.copyBoard(sourceBoard, options: BoardCopyOptions(title: "Copy", withCards: true))

            XCTAssertNotEqual(copy.id, source.id)
            XCTAssertEqual(copy.title, "Copy")
            XCTAssertEqual(copy.color?.lowercased(), sourceBoard.color?.lowercased())
            func summary(_ labels: [DeckLabel]) -> [String] {
                labels.map { "\($0.title) \($0.color?.lowercased() ?? "")" }.sorted()
            }
            XCTAssertEqual(summary(copy.labels), summary(labels), "Labels differ from the source's")

            let lists = try await AppState.sorted(api.getStacks(boardId: copy.id))
            XCTAssertEqual(lists.map(\.title), ["To do", "Done"])
            let cards = lists[0].activeCards
            XCTAssertEqual(cards.map(\.title), ["Write it", "Ship it"], "Archived card copied, or order lost")
            XCTAssertEqual(cards[0].description, "With **notes**")
            XCTAssertEqual(cards[0].dueDate, DeckDate.parse("2030-03-04T09:00:00+00:00"))
            XCTAssertEqual(cards[0].labels?.map(\.title), ["Urgent"])
            XCTAssertTrue(cards[1].isDone, "Done state not copied")
            XCTAssertTrue(lists[1].activeCards.isEmpty)

            let bare = try await api.copyBoard(sourceBoard, options: BoardCopyOptions(title: "Lists", withCards: false))
            let bareLists = try await AppState.sorted(api.getStacks(boardId: bare.id))
            XCTAssertEqual(bareLists.map(\.title), ["To do", "Done"])
            XCTAssertTrue(bareLists.allSatisfy { $0.activeCards.isEmpty }, "Cards copied without Copy cards")
            try? await api.deleteBoard(id: copy.id)
            try? await api.deleteBoard(id: bare.id)
        }
    }

    // MARK: - Stacks and cards

    func testStacksAndCardEditing() async throws {
        try await withTemporaryBoard(api) { board in
            let first = try await api.createStack(boardId: board.id, title: "To do", order: 0)
            let second = try await api.createStack(boardId: board.id, title: "Done", order: 1)
            let renamed = try await api.updateStack(boardId: board.id, stackId: second.id, title: "Finished", order: 5)
            XCTAssertEqual(renamed.title, "Finished")
            XCTAssertEqual(renamed.order, 5)

            let card = try await api.createCard(
                boardId: board.id,
                stackId: first.id,
                title: "Write tests",
                description: "Against a **real** server"
            )
            XCTAssertEqual(card.stackId, first.id)

            var edited = try await api.getCard(boardId: board.id, stackId: first.id, cardId: card.id)
            XCTAssertEqual(edited.description, "Against a **real** server")
            let due = Date(timeIntervalSince1970: 1_900_000_000)
            let start = Date(timeIntervalSince1970: 1_899_000_000)
            edited = edited.withSchedule(startDate: start, dueDate: due, isDone: true)
            edited.title = "Write more tests"
            _ = try await api.updateCard(boardId: board.id, stackId: first.id, card: edited)

            let saved = try await api.getCard(boardId: board.id, stackId: first.id, cardId: card.id)
            XCTAssertEqual(saved.title, "Write more tests")
            XCTAssertEqual(saved.description, "Against a **real** server", "Saving the title must keep the description")
            XCTAssertEqual(saved.dueDate.map { Int($0.timeIntervalSince1970) }, 1_900_000_000)
            if server.deck(atLeast: "1.18") {
                XCTAssertEqual(
                    saved.startDate.map { Int($0.timeIntervalSince1970) },
                    1_899_000_000,
                    "Start date not saved"
                )
            } else {
                // Deck 1.18 added start dates; older versions drop them, so the app doesn't offer them (#138).
                XCTAssertNil(saved.startDate, "Deck \(server.deckVersion) saves start dates: offer them there too")
            }
            XCTAssertTrue(saved.isDone)

            let undone = try await api.updateCard(
                boardId: board.id,
                stackId: first.id,
                card: saved.withSchedule(startDate: nil, dueDate: nil, isDone: false)
            )
            XCTAssertFalse(undone.isDone)
            XCTAssertNil(undone.dueDate)
            XCTAssertNil(undone.startDate, "Start date not cleared")

            try await api.deleteCard(boardId: board.id, stackId: first.id, cardId: card.id)
            let stacks = try await api.getStacks(boardId: board.id)
            XCTAssertNil(stacks.stack(holding: card.id), "Deleted card still on the board")

            try await api.deleteStack(boardId: board.id, stackId: second.id)
            let remaining = try await api.getStacks(boardId: board.id)
            XCTAssertEqual(remaining.map(\.id), [first.id])
        }
    }

    /// The #117 regression at the API level: a card moved to another list stays there.
    func testMovingCardsBetweenAndWithinLists() async throws {
        try await withTemporaryBoard(api) { board in
            let todo = try await api.createStack(boardId: board.id, title: "To do", order: 0)
            let doing = try await api.createStack(boardId: board.id, title: "Doing", order: 1)
            var cards: [Card] = []
            for title in ["One", "Two", "Three"] {
                try await cards.append(api.createCard(boardId: board.id, stackId: todo.id, title: title))
            }

            try await api.reorderCard(
                boardId: board.id,
                cardId: cards[0].id,
                order: 0,
                newStackId: doing.id
            )
            var stacks = try await api.getStacks(boardId: board.id)
            XCTAssertEqual(stacks.stack(holding: cards[0].id)?.id, doing.id, "Moved card went back to its old list")

            // Within a list: "Three" to the top.
            try await api.reorderCard(
                boardId: board.id,
                cardId: cards[2].id,
                order: 0,
                newStackId: todo.id
            )
            stacks = try await api.getStacks(boardId: board.id)
            let todoTitles = stacks.first { $0.id == todo.id }?.activeCards.map(\.title)
            XCTAssertEqual(todoTitles, ["Three", "Two"])
        }
    }

    func testArchivingCards() async throws {
        try await withTemporaryBoard(api) { board in
            let stack = try await api.createStack(boardId: board.id, title: "To do")
            let card = try await api.createCard(boardId: board.id, stackId: stack.id, title: "Old news")

            try await api.archiveCard(boardId: board.id, stackId: stack.id, cardId: card.id)
            var stacks = try await api.getStacks(boardId: board.id)
            XCTAssertNil(stacks.stack(holding: card.id), "Archived card still in the board's lists")
            let archived = try await api.getArchivedStacks(boardId: board.id)
            XCTAssertTrue(archived.contains { $0.cards?.contains { $0.id == card.id } == true })

            try await api.unarchiveCard(boardId: board.id, stackId: stack.id, cardId: card.id)
            stacks = try await api.getStacks(boardId: board.id)
            XCTAssertEqual(stacks.stack(holding: card.id)?.id, stack.id)
        }
    }

    // MARK: - Labels and assignees

    func testLabelsAndAssignees() async throws {
        try await withTemporaryBoard(api) { board in
            let stack = try await api.createStack(boardId: board.id, title: "To do")
            let card = try await api.createCard(boardId: board.id, stackId: stack.id, title: "Label me")
            let label = try await api.createLabel(boardId: board.id, title: "Urgent", color: "E9322D")
            XCTAssertEqual(label.title, "Urgent")
            let boardLabels = try await api.getBoard(id: board.id).labels
            XCTAssertTrue(boardLabels.contains { $0.id == label.id })

            try await api.assignLabel(boardId: board.id, stackId: stack.id, cardId: card.id, labelId: label.id)
            var saved = try await api.getCard(boardId: board.id, stackId: stack.id, cardId: card.id)
            XCTAssertEqual(saved.labels?.map(\.id), [label.id])
            try await api.removeLabel(boardId: board.id, stackId: stack.id, cardId: card.id, labelId: label.id)
            saved = try await api.getCard(boardId: board.id, stackId: stack.id, cardId: card.id)
            XCTAssertEqual(saved.labels?.count ?? 0, 0)

            // Editing and deleting labels (#135): cards that have the label follow.
            try await api.assignLabel(boardId: board.id, stackId: stack.id, cardId: card.id, labelId: label.id)
            let renamed = try await api.updateLabel(
                boardId: board.id,
                labelId: label.id,
                title: "Critical",
                color: "9C59B6"
            )
            XCTAssertEqual(renamed.title, "Critical")
            saved = try await api.getCard(boardId: board.id, stackId: stack.id, cardId: card.id)
            XCTAssertEqual(saved.labels?.map(\.title), ["Critical"])
            XCTAssertEqual(saved.labels?.first?.color?.lowercased(), "9c59b6")
            try await api.deleteLabel(boardId: board.id, labelId: label.id)
            let remaining = try await api.getBoard(id: board.id).labels
            XCTAssertFalse(remaining.contains { $0.id == label.id }, "Deleted label still on the board")
            saved = try await api.getCard(boardId: board.id, stackId: stack.id, cardId: card.id)
            XCTAssertEqual(saved.labels?.count ?? 0, 0, "Deleted label still on the card")

            // Bob can only be assigned once the board is shared with him.
            try await api.addShare(
                boardId: board.id,
                type: .user,
                participant: TestServer.bob,
                permissions: SharePermissions()
            )
            try await api.assignUser(boardId: board.id, stackId: stack.id, cardId: card.id, userId: TestServer.bob)
            try await api.assignUser(boardId: board.id, stackId: stack.id, cardId: card.id, userId: TestServer.alice)
            saved = try await api.getCard(boardId: board.id, stackId: stack.id, cardId: card.id)
            XCTAssertEqual(Set(saved.assignedUsers?.map(\.participant.uid) ?? []), [TestServer.alice, TestServer.bob])

            try await api.unassignUser(boardId: board.id, stackId: stack.id, cardId: card.id, userId: TestServer.bob)
            saved = try await api.getCard(boardId: board.id, stackId: stack.id, cardId: card.id)
            XCTAssertEqual(saved.assignedUsers?.map(\.participant.uid), [TestServer.alice])
        }
    }

    // MARK: - Attachments

    func testAttachments() async throws {
        try await withTemporaryBoard(api) { board in
            let stack = try await api.createStack(boardId: board.id, title: "To do")
            let card = try await api.createCard(boardId: board.id, stackId: stack.id, title: "With a file")
            let contents = Data("Shuffleboard end-to-end attachment \(UUID())\n".utf8)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-\(UUID().uuidString).txt")
            try contents.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }

            try await api.uploadAttachment(
                boardId: board.id,
                stackId: stack.id,
                cardId: card.id,
                fileURL: file,
                filename: file.lastPathComponent
            )
            let attachments = try await api.getAttachments(boardId: board.id, stackId: stack.id, cardId: card.id)
            let attachment = try XCTUnwrap(attachments.first, "Uploaded attachment not listed")
            XCTAssertEqual(attachments.count, 1)
            XCTAssertEqual(attachment.type, "file")

            let downloaded = try await api.downloadAttachment(
                boardId: board.id,
                stackId: stack.id,
                cardId: card.id,
                attachmentId: attachment.id,
                type: attachment.type
            )
            XCTAssertEqual(downloaded, contents)

            try await api.deleteAttachment(
                boardId: board.id,
                stackId: stack.id,
                cardId: card.id,
                attachmentId: attachment.id,
                type: attachment.type
            )
            let remaining = try await api.getAttachments(boardId: board.id, stackId: stack.id, cardId: card.id)
            XCTAssertTrue(remaining.allSatisfy { ($0.deletedAt ?? 0) > 0 }, "Deleted attachment still listed")

            // Deleting a `file` attachment only unshares it: it can't be restored (#139).
            do {
                try await api.restoreAttachment(
                    boardId: board.id,
                    stackId: stack.id,
                    cardId: card.id,
                    attachmentId: attachment.id,
                    type: attachment.type
                )
                XCTFail("Deck \(server.deckVersion) restored a file attachment: offer Restore for those too")
            } catch DeckAPIError.permissionDenied {
                // Expected.
            }
        }
    }

    /// `deck_file` attachments (stored by Deck itself, as older clients uploaded them) stay listed when deleted, with
    /// `deletedAt`, and can be restored (#139).
    func testRestoringADeckFileAttachment() async throws {
        try await withTemporaryBoard(api) { board in
            let stack = try await api.createStack(boardId: board.id, title: "To do")
            let card = try await api.createCard(boardId: board.id, stackId: stack.id, title: "With an old file")
            let id = try await uploadDeckFile(board: board.id, stack: stack.id, card: card.id)

            try await api.deleteAttachment(
                boardId: board.id,
                stackId: stack.id,
                cardId: card.id,
                attachmentId: id,
                type: "deck_file"
            )
            var listed = try await api.getAttachments(boardId: board.id, stackId: stack.id, cardId: card.id)
            let deleted = try XCTUnwrap(listed.first { $0.id == id }, "Deleted deck_file attachment not listed")
            XCTAssertTrue(deleted.isDeleted)
            XCTAssertTrue(deleted.canBeRestored)

            try await api.restoreAttachment(
                boardId: board.id,
                stackId: stack.id,
                cardId: card.id,
                attachmentId: id,
                type: "deck_file"
            )
            listed = try await api.getAttachments(boardId: board.id, stackId: stack.id, cardId: card.id)
            XCTAssertEqual(listed.first { $0.id == id }?.isDeleted, false, "Attachment not restored")
        }
    }

    /// Uploads a `deck_file` attachment, which the app itself no longer creates; returns its id.
    private func uploadDeckFile(board: Int, stack: Int, card: Int) async throws -> Int {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-\(UUID().uuidString).txt")
        try Data("An old-style attachment\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let boundary = "Boundary-\(UUID().uuidString)"
        let body = try DeckAPI.writeMultipartBody(
            fileURL: file,
            filename: file.lastPathComponent,
            fields: ["type": "deck_file", "data": file.lastPathComponent],
            boundary: boundary
        )
        defer { try? FileManager.default.removeItem(at: body) }
        let url = server.url.appendingPathComponent(
            "index.php/apps/deck/api/v1.1/boards/\(board)/stacks/\(stack)/cards/\(card)/attachments"
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let appPassword = try await server.appPassword(for: TestServer.alice)
        request.setValue(TestServer.basicAuth(TestServer.alice, appPassword), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession(configuration: .ephemeral).upload(for: request, fromFile: body)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, String(decoding: data, as: UTF8.self))
        let attachment = try JSONDecoder().decode(Attachment.self, from: data)
        XCTAssertEqual(attachment.type, "deck_file")
        return attachment.id
    }

    // MARK: - Comments

    func testComments() async throws {
        try await withTemporaryBoard(api) { board in
            let stack = try await api.createStack(boardId: board.id, title: "To do")
            let card = try await api.createCard(boardId: board.id, stackId: stack.id, title: "Discuss")

            let first = try await api.addComment(cardId: card.id, message: "First!")
            XCTAssertEqual(first.actorId, TestServer.alice)
            _ = try await api.addComment(cardId: card.id, message: "Second")
            var comments = try await api.getComments(cardId: card.id)
            XCTAssertEqual(comments.map(\.message), ["Second", "First!"], "Comments should come newest first")

            let updated = try await api.updateComment(cardId: card.id, commentId: first.id, message: "First, edited")
            XCTAssertEqual(updated.message, "First, edited")
            try await api.deleteComment(cardId: card.id, commentId: first.id)
            comments = try await api.getComments(cardId: card.id)
            XCTAssertEqual(comments.map(\.message), ["Second"])
        }
    }

    func testCommentMentioningBob() async throws {
        try await withTemporaryBoard(api) { board in
            try await api.addShare(
                boardId: board.id,
                type: .user,
                participant: TestServer.bob,
                permissions: SharePermissions()
            )
            let stack = try await api.createStack(boardId: board.id, title: "To do")
            let card = try await api.createCard(boardId: board.id, stackId: stack.id, title: "Ask Bob")

            let message = "Can you look, \(Mentions.token(for: TestServer.bob))?"
            let posted = try await api.addComment(cardId: card.id, message: message)
            XCTAssertEqual(posted.mentions.map(\.mentionId), [TestServer.bob], "Mention not recorded: \(posted)")
            XCTAssertEqual(posted.segments.count, 3, "Mention not found in the message: \(posted.segments)")
            let listed = try await api.getComments(cardId: card.id)
            XCTAssertEqual(listed.first?.mentions.map(\.mentionId), [TestServer.bob])
        }
    }

    // MARK: - Sharing

    func testSharingWithAPersonAndAGroup() async throws {
        let bobAPI = try await server.api(for: TestServer.bob)
        try await withTemporaryBoard(api) { board in
            let sharees = try await api.searchSharees("bob")
            let bob = try XCTUnwrap(sharees.first { $0.participantId == TestServer.bob }, "Bob not found: \(sharees)")
            XCTAssertEqual(bob.shareType, .user)
            let groups = try await api.searchSharees("famil")
            XCTAssertTrue(groups.contains { $0.participantId == "family" && $0.shareType == .group }, "\(groups)")

            try await api.addShare(
                boardId: board.id,
                type: .user,
                participant: TestServer.bob,
                permissions: SharePermissions()
            )
            var shared = try await api.getBoard(id: board.id)
            let entry = try XCTUnwrap(shared.acl.first { $0.participant?.uid == TestServer.bob })
            XCTAssertFalse(entry.permissionEdit)
            var bobsBoards = try await bobAPI.getBoards()
            XCTAssertTrue(bobsBoards.contains { $0.id == board.id }, "Bob can't see the board shared with him")

            let aclId = try XCTUnwrap(entry.id)
            try await api.updateShare(boardId: board.id, aclId: aclId, permissions: SharePermissions(edit: true))
            shared = try await api.getBoard(id: board.id)
            XCTAssertEqual(shared.acl.first { $0.id == aclId }?.permissionEdit, true)
            let asBob = try await bobAPI.getBoard(id: board.id)
            XCTAssertEqual(asBob.permissions?.permissionEdit, true)
            XCTAssertEqual(asBob.permissions?.permissionManage, false)

            try await api.addShare(
                boardId: board.id,
                type: .group,
                participant: "family",
                permissions: SharePermissions()
            )
            shared = try await api.getBoard(id: board.id)
            XCTAssertTrue(shared.acl
                .contains { $0.type == ShareType.group.rawValue && $0.participant?.uid == "family" })

            try await api.removeShare(boardId: board.id, aclId: aclId)
            shared = try await api.getBoard(id: board.id)
            XCTAssertFalse(shared.acl.contains { $0.id == aclId })
            for group in shared.acl.filter({ $0.type == ShareType.group.rawValue }) {
                if let id = group.id {
                    try await api.removeShare(boardId: board.id, aclId: id)
                }
            }
            bobsBoards = try await bobAPI.getBoards()
            XCTAssertFalse(
                bobsBoards.contains { $0.id == board.id && ($0.deletedAt ?? 0) == 0 },
                "Bob still sees the board"
            )
        }
    }

    // MARK: - ETags

    /// `refreshIfChanged()` relies on the board list's ETag: Deck changes it when anything on any board changes.
    func testBoardListETagAnswersNotModifiedUntilSomethingChanges() async throws {
        try await withTemporaryBoard(api) { board in
            let stack = try await api.createStack(boardId: board.id, title: "To do")
            let boards = try await api.fetchBoards(ifNoneMatch: nil)
            let etag = try XCTUnwrap(boards?.etag, "Board list has no ETag")

            let unchanged = try await api.fetchBoards(ifNoneMatch: etag)
            XCTAssertNil(unchanged, "Expected 304 for an unchanged board list")

            // Deck's ETags come from modification times in whole seconds: a change within the same second
            // as the last fetch keeps the old ETag.
            await sleep(seconds: 1.1)
            _ = try await api.createCard(boardId: board.id, stackId: stack.id, title: "Something changed")
            let changed = try await api.fetchBoards(ifNoneMatch: etag)
            XCTAssertNotNil(changed, "A new card should change the board list's ETag")
            XCTAssertNotEqual(changed?.etag, etag)
        }
    }

    /// Deck's list endpoint (`GET /boards/{id}/stacks`) sends no ETag, so the lists are always fetched in full.
    /// If a release adds one, it must still answer 304 only while nothing changed.
    func testListsETagIfTheServerSendsOne() async throws {
        try await withTemporaryBoard(api) { board in
            let stack = try await api.createStack(boardId: board.id, title: "To do")
            guard let etag = try await api.fetchStacks(boardId: board.id, ifNoneMatch: nil)?.etag else { return }
            let unchanged = try await api.fetchStacks(boardId: board.id, ifNoneMatch: etag)
            XCTAssertNil(unchanged, "Expected 304 for unchanged lists")
            await sleep(seconds: 1.1)
            _ = try await api.createCard(boardId: board.id, stackId: stack.id, title: "Something changed")
            let changed = try await api.fetchStacks(boardId: board.id, ifNoneMatch: etag)
            XCTAssertNotNil(changed, "A new card should change the lists' ETag")
        }
    }

    // MARK: - App passwords

    func testRevokedAppPasswordIsUnauthorized() async throws {
        // One session for both requests, as in the app: a session cookie must not outlive the app password.
        let revoked = try await server.api(for: TestServer.alice, session: URLSession(configuration: .ephemeral))
        _ = try await revoked.getBoards()
        try await revoked.revokeAppPassword()
        do {
            _ = try await revoked.getBoards()
            XCTFail("A revoked app password still works")
        } catch DeckAPIError.unauthorized {
            // Expected.
        }
    }
}
