import Foundation
import os

private let reminderLogger = Logger(subsystem: "ie.unicornops.shuffleboard", category: "Reminders")

/// The system's notifications, as `CardReminderSync` uses them, so it can be tested without them.
@MainActor
protocol ReminderNotifications: AnyObject {
    /// Asks for permission the first time; afterwards answers with what the user chose.
    func requestPermission() async -> Bool
    /// The ids of the card reminders waiting to be shown.
    func pendingIds() async -> Set<String>
    /// Shows `reminder` at `date`, or straight away if nil.
    func add(_ reminder: CardReminder, at date: Date?) async
    func remove(ids: Set<String>)
}

/// What is remembered per account between launches.
struct ReminderState: Codable, Equatable {
    /// Reminders already shown, or handed to macOS to show at their time, so they aren't shown again.
    var handled: Set<String> = []
    /// The cards assigned to the user when the app last looked, to spot new assignments.
    var assigned: Set<Int> = []
}

/// Keeps macOS's notifications in step with the cards (#157): schedules reminders for due dates, shows the ones
/// whose time has come, cancels those no longer needed (done, archived, unassigned, due date changed) and says when
/// a card is newly assigned to the user. When the app starts, one notification sums up the cards already overdue;
/// otherwise nothing old is shown the first time an account is seen, and nothing is shown twice. Each kind can be
/// turned off in Settings.
@MainActor
final class CardReminderSync {
    /// UserDefaults keys for the two settings; both default to on.
    static let dueRemindersKey = "remindDueCards"
    static let assignedRemindersKey = "notifyAssignedCards"
    /// How many reminders are scheduled ahead at most, the soonest first; macOS limits pending notifications.
    static let maxScheduled = 50

    private let notifications: ReminderNotifications
    private let defaults: UserDefaults
    /// Cards the user assigned to themselves in the app, which don't need a notification.
    private var selfAssigned: Set<Int> = []
    /// Accounts whose overdue cards have been summed up since the app started.
    private var summarized: Set<String> = []
    /// Each account's user id on its server, once known (see `DeckAPI.currentUserId`).
    private var userIds: [String: String] = [:]

    init(notifications: ReminderNotifications, defaults: UserDefaults = .standard) {
        self.notifications = notifications
        self.defaults = defaults
    }

    private func isOn(_ key: String) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    /// Brings the reminders for `accountId`'s cards up to date. `cards` are every card the user can see that could
    /// have one; reminders for other accounts are cancelled.
    func update(cards: [RemindableCard], userId: String, accountId: String, now: Date) async {
        let previous = state(for: accountId)
        let state = previous ?? ReminderState()
        let isFirstLook = previous == nil

        let due = CardReminders.dueReminders(for: cards, userId: userId, accountId: accountId, now: now)
        let assignedNow = Set(cards.filter { CardReminders.isAssigned($0.card, to: userId) }.map(\.card.id))
        let showDue = isOn(Self.dueRemindersKey)
        let scheduled = showDue
            ? Array(due.filter { $0.date > now }.sorted { $0.date < $1.date }.prefix(Self.maxScheduled))
            : []
        var immediate = showDue ? due.filter { $0.date <= now && !state.handled.contains($0.id) } : []
        if isOn(Self.assignedRemindersKey) {
            immediate += cards
                .filter { assignedNow.contains($0.card.id) && !state.assigned.contains($0.card.id) }
                .filter { !selfAssigned.contains($0.card.id) }
                .map { CardReminders.assignedReminder(for: $0, accountId: accountId, now: now) }
        }
        if isFirstLook {
            immediate = []
        }
        // The first time since the app started: one notification for everything already overdue, instead of one
        // per card.
        if showDue, !summarized.contains(accountId) {
            summarized.insert(accountId)
            immediate.removeAll { $0.kind == .overdue }
            if let summary = CardReminders.overdueSummary(for: cards, userId: userId, accountId: accountId, now: now) {
                immediate.append(summary)
            }
        }

        let pending = await notifications.pendingIds()
        let wanted = Set(scheduled.map(\.id))
        notifications.remove(ids: pending.subtracting(wanted))
        let toAdd = scheduled.filter { !pending.contains($0.id) }
        reminderLogger.notice(
            "\(cards.count) cards, \(assignedNow.count) assigned to \(userId, privacy: .private), \(Set(due.map(\.cardId)).count) with due reminders: \(toAdd.count) to schedule, \(immediate.count) to show"
        )
        var allowed = false
        if !toAdd.isEmpty || !immediate.isEmpty {
            allowed = await notifications.requestPermission()
            reminderLogger.notice("Notifications allowed: \(allowed)")
        }
        if allowed {
            for reminder in toAdd {
                await notifications.add(reminder, at: reminder.date)
            }
            for reminder in immediate {
                await notifications.add(reminder, at: nil)
            }
        }
        finish(state, accountId: accountId, due: due, wanted: wanted, assignedNow: assignedNow, now: now)
    }

    /// Saves what this update handled.
    private func finish(
        _ state: ReminderState,
        accountId: String,
        due: [CardReminder],
        wanted: Set<String>,
        assignedNow: Set<Int>,
        now: Date
    ) {
        var state = state
        // Past reminders count as handled whether shown or not (turned off, first look, no permission), so turning
        // reminders on later doesn't bring old ones back. Only reminders that still apply are kept.
        let past = due.filter { $0.date <= now }.map(\.id)
        state.handled = state.handled.union(past).union(wanted).intersection(due.map(\.id))
        state.assigned = assignedNow
        selfAssigned.subtract(assignedNow)
        save(state, for: accountId)
    }

    /// The user id Deck's assignments use for `accountId`, once `setUserId` has recorded it.
    func userId(for accountId: String) -> String? {
        userIds[accountId]
    }

    func setUserId(_ userId: String, for accountId: String) {
        userIds[accountId] = userId
    }

    /// The user assigned themselves to `cardId` in the app; no need to tell them.
    func noteSelfAssigned(cardId: Int) {
        selfAssigned.insert(cardId)
    }

    /// Cancels `accountId`'s reminders and forgets it, when it signs out.
    func forget(accountId: String) async {
        let pending = await notifications.pendingIds()
        notifications.remove(ids: pending.filter { $0.contains("|\(accountId)|") })
        defaults.removeObject(forKey: Self.stateKey(accountId))
    }

    // MARK: - Saved state

    private static func stateKey(_ accountId: String) -> String {
        "cardReminders.\(accountId)"
    }

    func state(for accountId: String) -> ReminderState? {
        defaults.data(forKey: Self.stateKey(accountId))
            .flatMap { try? JSONDecoder().decode(ReminderState.self, from: $0) }
    }

    private func save(_ state: ReminderState, for accountId: String) {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Self.stateKey(accountId))
        }
    }
}
