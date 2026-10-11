import Foundation
import XCTest
@testable import Shuffleboard

/// Notifications about due and newly assigned cards (#157).
@MainActor
final class CardReminderTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var notifications: FakeReminderNotifications!
    private var defaults: UserDefaults!
    private var sync: CardReminderSync!
    private let suiteName = "CardReminderTests"

    override func setUp() async throws {
        clock = start
        notifications = FakeReminderNotifications()
        notifications.now = { [unowned self] in clock }
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        sync = CardReminderSync(notifications: notifications, defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private let board = Board(
        id: 1,
        title: "Home",
        color: nil,
        archived: false,
        owner: nil,
        labels: [],
        acl: [],
        permissions: nil,
        users: [],
        shared: nil,
        deletedAt: nil,
        lastModified: nil,
        settings: nil
    )

    /// A card due `dueIn` seconds from the start, assigned to `assignee` (a user, or a group with `type` 1).
    private func card(
        _ id: Int,
        dueIn: TimeInterval?,
        assignee: String? = "alice",
        type: Int = 0,
        done: Bool = false
    ) throws
        -> RemindableCard {
        var fields = #""id": \#(id), "title": "Card \#(id)", "stackId": 10, "order": 0"#
        if let dueIn {
            fields += #", "duedate": "\#(DeckDate.string(from: start.addingTimeInterval(dueIn)))""#
        }
        if let assignee {
            fields += #", "assignedUsers": [{"id": 1, "participant": {"uid": "\#(assignee)"}, "type": \#(type)}]"#
        }
        if done {
            fields += #", "done": "\#(DeckDate.string(from: start))""#
        }
        let card = try JSONDecoder().decode(Card.self, from: Data("{\(fields)}".utf8))
        return RemindableCard(card: card, board: board, listTitle: "To do")
    }

    private func update(_ cards: [RemindableCard]) async {
        await sync.update(cards: cards, userId: "alice", accountId: "alice@cloud.example", now: clock)
    }

    private let hour: TimeInterval = 60 * 60

    // MARK: - Which reminders

    func testOnlyUndoneCardsAssignedToTheUserWithADueDateGetReminders() throws {
        let cards = try [
            card(1, dueIn: 72 * hour),
            card(2, dueIn: 72 * hour, assignee: "bob"),
            card(3, dueIn: 72 * hour, type: 1),
            card(4, dueIn: nil),
            card(5, dueIn: 72 * hour, done: true),
        ]
        let reminders = try CardReminders.dueReminders(for: cards, userId: "alice", accountId: "a", now: start)
        XCTAssertEqual(reminders.map(\.cardId), [1, 1])
        XCTAssertEqual(reminders.map(\.kind), [.dueSoon, .overdue])
        XCTAssertEqual(reminders[0].date, start.addingTimeInterval(48 * hour), "a day before")
        XCTAssertEqual(reminders[1].date, start.addingTimeInterval(72 * hour), "when it's due")
        XCTAssertEqual(reminders[0].title, "Due soon: Card 1")
        XCTAssertTrue(reminders[0].body.hasPrefix("Home \u{203a} To do"))
    }

    /// Due dates follow Deck's own rule: the owner of an unshared board hears about every card on it, and a board
    /// set to "all" or "off" overrides being assigned.
    func testDueRemindersFollowTheBoardsDueDateNotificationSetting() throws {
        func on(_ item: RemindableCard, owner: String? = nil, shared: Bool = false, notifyDue: String? = nil)
            -> RemindableCard {
            var board = board
            board.owner = owner.map { DeckUser(uid: $0) }
            board.acl = shared
                ? [ACLEntry(
                    id: 1,
                    participant: DeckUser(uid: "bob"),
                    type: 0,
                    boardId: 1,
                    permissionEdit: true,
                    permissionShare: false,
                    permissionManage: false,
                    owner: false
                )]
                : []
            board.settings = notifyDue.map { BoardSettings(notifyDue: $0, calendar: nil) }
            return RemindableCard(card: item.card, board: board, listTitle: item.listTitle)
        }
        let unassigned = try card(1, dueIn: -hour, assignee: nil)
        let assigned = try card(2, dueIn: -hour)
        let cases: [(RemindableCard, Bool, String)] = [
            (on(unassigned, owner: "alice"), true, "own unshared board"),
            (on(unassigned, owner: "alice", shared: true), false, "own shared board, not assigned"),
            (on(unassigned, owner: "bob"), false, "someone else's board, not assigned"),
            (on(unassigned, owner: "bob", notifyDue: "all"), true, "set to all cards"),
            (on(assigned, owner: "bob", notifyDue: "assigned"), true, "assigned"),
            (on(assigned, owner: "alice", notifyDue: "off"), false, "turned off"),
        ]
        for (item, wanted, why) in cases {
            XCTAssertEqual(CardReminders.wantsDueReminders(item, userId: "alice"), wanted, why)
        }
        let summary = CardReminders.overdueSummary(
            for: [on(unassigned, owner: "alice")], userId: "alice", accountId: "a", now: start
        )
        XCTAssertEqual(summary?.cardId, 1, "the summary uses the same rule")
    }

    func testACardDueWithinADayIsDueSoonNowAndAnOverdueCardIsOnlyOverdue() throws {
        let soon = try CardReminders.dueReminders(
            for: [card(1, dueIn: 5 * hour)],
            userId: "alice",
            accountId: "a",
            now: start
        )
        XCTAssertEqual(soon.map(\.kind), [.dueSoon, .overdue])
        XCTAssertEqual(soon[0].date, start)
        let late = try CardReminders.dueReminders(
            for: [card(1, dueIn: -hour)],
            userId: "alice",
            accountId: "a",
            now: start
        )
        XCTAssertEqual(late.map(\.kind), [.overdue])
    }

    func testANewDueDateIsANewReminder() throws {
        let first = try CardReminders.dueReminders(
            for: [card(1, dueIn: 72 * hour)],
            userId: "alice",
            accountId: "a",
            now: start
        )
        let moved = try CardReminders.dueReminders(
            for: [card(1, dueIn: 96 * hour)],
            userId: "alice",
            accountId: "a",
            now: start
        )
        XCTAssertNotEqual(first[0].id, moved[0].id)
    }

    // MARK: - Scheduling and showing

    func testTheFirstLookSumsUpOverdueCardsAndSchedulesWhatsAhead() async throws {
        try await update([card(1, dueIn: -hour), card(2, dueIn: 72 * hour)])

        XCTAssertEqual(notifications.shown.map(\.kind), [.overdueSummary], "one summary, nothing else old")
        XCTAssertEqual(notifications.shown.first?.title, "Overdue: Card 1")
        XCTAssertEqual(notifications.pending.values.map(\.cardId).sorted(), [2, 2])
        XCTAssertEqual(notifications.permissionRequests, 1)
    }

    func testOverdueCardsAreSummedUpOnceEachTimeTheAppStarts() async throws {
        let cards = try [
            card(1, dueIn: -2 * hour),
            card(2, dueIn: -5 * hour),
            card(3, dueIn: -1 * hour),
            card(4, dueIn: -3 * hour),
            card(5, dueIn: -3 * hour, done: true),
        ]
        // A first launch that already knew these cards.
        await update(cards)
        notifications.clearShown()

        // The next launch: a new sync with what the last one saved.
        sync = CardReminderSync(notifications: notifications, defaults: defaults)
        await update(cards)
        XCTAssertEqual(notifications.shown.count, 1)
        let summary = try XCTUnwrap(notifications.shown.first)
        XCTAssertEqual(summary.kind, .overdueSummary)
        XCTAssertEqual(summary.title, "4 cards are overdue")
        XCTAssertEqual(summary.body, "Card 2, Card 4, Card 1 and 1 more", "longest overdue first")
        XCTAssertEqual(summary.cardId, 2, "opens the card overdue longest")

        await update(cards)
        XCTAssertEqual(notifications.shown.count, 1, "once per launch")
    }

    func testNoSummaryWithDueDateRemindersOff() async throws {
        defaults.set(false, forKey: CardReminderSync.dueRemindersKey)
        try await update([card(1, dueIn: -hour)])
        XCTAssertTrue(notifications.shown.isEmpty)
    }

    func testTheUserIdIsRememberedPerAccount() {
        XCTAssertNil(sync.userId(for: "a"))
        sync.setUserId("rob", for: "a")
        XCTAssertEqual(sync.userId(for: "a"), "rob")
        XCTAssertNil(sync.userId(for: "b"))
    }

    func testRemindersAreNotShownTwice() async throws {
        // Already assigned before it gets a due date, so the only notification is the reminder.
        try await update([card(1, dueIn: nil)])
        let cards = try [card(1, dueIn: 5 * hour)]

        await update(cards)
        XCTAssertEqual(notifications.shown.map(\.kind), [.dueSoon], "due within a day: straight away")
        await update(cards)
        XCTAssertEqual(notifications.shown.count, 1)

        // Its time comes: macOS shows the scheduled one; the app doesn't show it again.
        clock += 6 * hour
        await update(cards)
        XCTAssertEqual(notifications.shown.count, 1)
        XCTAssertTrue(notifications.pending.isEmpty)
    }

    func testDoneCardsAndChangedDueDatesCancelTheirReminders() async throws {
        await update([])
        try await update([card(1, dueIn: 72 * hour), card(2, dueIn: 72 * hour)])
        XCTAssertEqual(notifications.pending.count, 4)

        try await update([card(1, dueIn: 72 * hour, done: true), card(2, dueIn: 96 * hour)])

        XCTAssertEqual(notifications.pending.values.map(\.cardId), [2, 2])
        XCTAssertEqual(
            Set(notifications.pending.values.compactMap(\.dueDate)),
            [start.addingTimeInterval(96 * hour)]
        )
    }

    func testNewAssignmentsAreShownExceptOnesTheUserMade() async throws {
        try await update([card(1, dueIn: nil, assignee: "bob"), card(2, dueIn: nil, assignee: "bob")])

        sync.noteSelfAssigned(cardId: 2)
        try await update([card(1, dueIn: nil), card(2, dueIn: nil)])

        XCTAssertEqual(notifications.shown.map(\.kind), [.assigned])
        XCTAssertEqual(notifications.shown.map(\.cardId), [1])
        XCTAssertEqual(notifications.shown.first?.title, "Assigned to you: Card 1")
        try await update([card(1, dueIn: nil), card(2, dueIn: nil)])
        XCTAssertEqual(notifications.shown.count, 1, "not again")
    }

    func testTurningRemindersOffCancelsThemAndOnAgainDoesntBringBackOldOnes() async throws {
        await update([])
        let cards = try [card(1, dueIn: 2 * hour)]
        defaults.set(false, forKey: CardReminderSync.dueRemindersKey)
        defaults.set(false, forKey: CardReminderSync.assignedRemindersKey)

        await update(cards)
        XCTAssertTrue(notifications.shown.isEmpty)
        XCTAssertTrue(notifications.pending.isEmpty)

        clock += 3 * hour
        await update(cards)
        defaults.set(true, forKey: CardReminderSync.dueRemindersKey)
        await update(cards)
        XCTAssertTrue(notifications.shown.isEmpty, "reminders from while they were off")
    }

    func testWithoutPermissionNothingIsAddedOrSavedUpForLater() async throws {
        notifications.permission = false
        await update([])
        let cards = try [card(1, dueIn: 2 * hour)]

        await update(cards)
        XCTAssertTrue(notifications.shown.isEmpty)

        notifications.permission = true
        await update(cards)
        XCTAssertTrue(notifications.shown.isEmpty, "not shown late once allowed")
        XCTAssertEqual(notifications.pending.count, 1, "the overdue reminder is still ahead")
    }

    func testSigningOutCancelsTheAccountsReminders() async throws {
        try await update([card(1, dueIn: 72 * hour)])
        XCTAssertNotNil(sync.state(for: "alice@cloud.example"))

        await sync.forget(accountId: "alice@cloud.example")

        XCTAssertTrue(notifications.pending.isEmpty)
        XCTAssertNil(sync.state(for: "alice@cloud.example"))
    }
}

/// The notification centre in memory: scheduled reminders stay pending until their date passes on `now`.
@MainActor
final class FakeReminderNotifications: ReminderNotifications {
    var now: () -> Date = Date.init
    var permission = true
    private(set) var permissionRequests = 0
    private var scheduled: [String: (reminder: CardReminder, date: Date)] = [:]
    private(set) var shown: [CardReminder] = []

    /// The reminders still waiting to be shown.
    var pending: [String: CardReminder] {
        scheduled.filter { $0.value.date > now() }.mapValues(\.reminder)
    }

    func requestPermission() async -> Bool {
        permissionRequests += 1
        return permission
    }

    func pendingIds() async -> Set<String> {
        Set(pending.keys)
    }

    func add(_ reminder: CardReminder, at date: Date?) async {
        if let date {
            scheduled[reminder.id] = (reminder, date)
        } else {
            shown.append(reminder)
        }
    }

    func remove(ids: Set<String>) {
        for id in ids {
            scheduled[id] = nil
        }
    }

    func clearShown() {
        shown = []
    }
}
