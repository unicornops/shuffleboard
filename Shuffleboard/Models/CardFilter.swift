import Foundation

// MARK: - CardFilter

/// Which cards the board shows. Every active criterion must match; within labels or people, any selected one
/// matches. Filtering happens in the app, on the cards already loaded for the board.
struct CardFilter: Equatable, Sendable {
    enum Due: String, CaseIterable, Identifiable, Sendable {
        case any
        case overdue
        case dueSoon
        case noDueDate

        var id: Self {
            self
        }

        var title: String {
            switch self {
            case .any: String(localized: "Any due date")
            case .overdue: String(localized: "Overdue")
            case .dueSoon: String(localized: "Due in the next 7 days")
            case .noDueDate: String(localized: "No due date")
            }
        }
    }

    /// Matched against the title and description, ignoring case and accents.
    var text = ""
    var labelIds: Set<Int> = []
    /// User ids; a card matches if any of them is assigned.
    var assigneeIds: Set<String> = []
    var due = Due.any
    var hideDone = false

    static let dueSoonWindow: TimeInterval = 7 * 24 * 60 * 60

    /// Whether anything is filtered; text that is only whitespace doesn't count.
    var isActive: Bool {
        var trimmed = self
        trimmed.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed != Self()
    }

    func matches(_ card: Card, at now: Date = Date()) -> Bool {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty,
           !card.title.localizedStandardContains(query),
           !(card.description ?? "").localizedStandardContains(query) {
            return false
        }
        if !labelIds.isEmpty, !(card.labels ?? []).contains(where: { labelIds.contains($0.id) }) {
            return false
        }
        if !assigneeIds.isEmpty, !card.assignments.contains(where: { assigneeIds.contains($0.participant.uid) }) {
            return false
        }
        if hideDone, card.isDone {
            return false
        }
        return matchesDue(card, at: now)
    }

    private func matchesDue(_ card: Card, at now: Date) -> Bool {
        switch due {
        case .any:
            return true

        case .overdue:
            return card.isOverdue(at: now)

        case .dueSoon:
            guard let dueDate = card.dueDate, !card.isDone else { return false }
            return dueDate >= now && dueDate <= now.addingTimeInterval(Self.dueSoonWindow)

        case .noDueDate:
            return card.dueDate == nil
        }
    }
}
