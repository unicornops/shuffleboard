import Foundation

struct Card: Identifiable, Codable {
    let id: Int
    var title: String
    var description: String?
    var stackId: Int
    var type: String?
    var lastModified: Int?
    var createdAt: Int?
    var labels: [DeckLabel]?
    var assignedUsers: [CardAssignment]?
    var attachments: [Attachment]?
    var attachmentCount: Int?
    var owner: String?
    var order: Int
    var archived: Bool
    var duedate: String?
    var startdate: String?
    /// ISO-8601 date the card was marked done, or nil when not done.
    var done: String?
    var deletedAt: Int?
    var commentsUnread: Int?
    var commentsCount: Int?
    var overdue: Int?
    var etag: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decodeIntOrString(forKey: .id)) ?? 0
        self.title = (try? c.decode(String.self, forKey: .title)) ?? ""
        self.description = (try? c.decodeIfPresent(String.self, forKey: .description))
        self.stackId = (try? c.decodeIntOrString(forKey: .stackId)) ?? 0
        self.type = (try? c.decodeIfPresent(String.self, forKey: .type))
        self.lastModified = (try? c.decodeIntOrStringIfPresent(forKey: .lastModified))
        self.createdAt = (try? c.decodeIntOrStringIfPresent(forKey: .createdAt))
        self.labels = (try? c.decodeIfPresent([DeckLabel].self, forKey: .labels))
        self.assignedUsers = (try? c.decodeIfPresent([CardAssignment].self, forKey: .assignedUsers))
        self.attachments = (try? c.decodeIfPresent([Attachment].self, forKey: .attachments))
        self.attachmentCount = (try? c.decodeIntOrStringIfPresent(forKey: .attachmentCount))
        // Deck serialises the owner as a user object; older responses used the plain user id.
        self.owner = (try? c.decodeIfPresent(String.self, forKey: .owner))
            ?? (try? c.decodeIfPresent(DeckUser.self, forKey: .owner))?.uid
        self.order = (try? c.decodeIntOrStringIfPresent(forKey: .order)) ?? 999
        self.archived = (try? c.decodeIfPresent(Bool.self, forKey: .archived)) ?? false
        self.duedate = (try? c.decodeIfPresent(String.self, forKey: .duedate))
        self.startdate = (try? c.decodeIfPresent(String.self, forKey: .startdate))
        self.done = (try? c.decodeIfPresent(String.self, forKey: .done))
        self.deletedAt = (try? c.decodeIntOrStringIfPresent(forKey: .deletedAt))
        self.commentsUnread = (try? c.decodeIntOrStringIfPresent(forKey: .commentsUnread))
        self.commentsCount = (try? c.decodeIntOrStringIfPresent(forKey: .commentsCount))
        self.overdue = (try? c.decodeIntOrStringIfPresent(forKey: .overdue))
        self.etag = (try? c.decodeIfPresent(String.self, forKey: .etag))
    }

    enum CodingKeys: String, CodingKey {
        case id, title, description, stackId, type, lastModified, createdAt
        case labels, assignedUsers, attachments, attachmentCount, owner, order
        case archived, duedate, startdate, done, deletedAt, commentsUnread, commentsCount, overdue
        case etag = "ETag"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(description ?? "", forKey: .description)
        try c.encode(stackId, forKey: .stackId)
        try c.encode(type ?? "plain", forKey: .type)
        try c.encodeIfPresent(lastModified, forKey: .lastModified)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encode(labels ?? [], forKey: .labels)
        try c.encode(assignedUsers ?? [], forKey: .assignedUsers)
        try c.encodeIfPresent(attachments, forKey: .attachments)
        try c.encode(attachmentCount ?? 0, forKey: .attachmentCount)
        try c.encodeIfPresent(owner, forKey: .owner)
        try c.encode(order, forKey: .order)
        try c.encode(archived, forKey: .archived)
        try c.encodeIfPresent(duedate, forKey: .duedate)
        try c.encodeIfPresent(startdate, forKey: .startdate)
        try c.encodeIfPresent(done, forKey: .done)
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try c.encode(commentsUnread ?? 0, forKey: .commentsUnread)
        try c.encodeIfPresent(commentsCount, forKey: .commentsCount)
        try c.encodeIfPresent(overdue, forKey: .overdue)
        try c.encodeIfPresent(etag, forKey: .etag)
    }
}

struct Attachment: Codable, Identifiable {
    let id: Int
    var cardId: Int?
    var type: String?
    var data: String?
    var lastModified: Int?
    var createdAt: Int?
    var createdBy: String?
    var deletedAt: Int?
    var extendedData: AttachmentExtendedData?

    enum CodingKeys: String, CodingKey {
        case id, cardId, type, data, lastModified, createdAt, createdBy, deletedAt, extendedData
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decodeIntOrString(forKey: .id)) ?? 0
        self.cardId = try? c.decodeIntOrStringIfPresent(forKey: .cardId)
        self.type = (try? c.decodeIfPresent(String.self, forKey: .type))
        self.data = (try? c.decodeIfPresent(String.self, forKey: .data))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .data)).map { String($0) }
        self.lastModified = try? c.decodeIntOrStringIfPresent(forKey: .lastModified)
        self.createdAt = try? c.decodeIntOrStringIfPresent(forKey: .createdAt)
        self.createdBy = (try? c.decodeIfPresent(String.self, forKey: .createdBy))
        self.deletedAt = try? c.decodeIntOrStringIfPresent(forKey: .deletedAt)
        self.extendedData = try? c.decodeIfPresent(AttachmentExtendedData.self, forKey: .extendedData)
    }

    /// Display name for the attachment (filename).
    var displayName: String {
        extendedData?.info?.basename ?? extendedData?.info?.filename ?? data ?? String(localized: "Attachment \(id)")
    }

    /// Deleted but still listed: Deck keeps deleted `deck_file` attachments until it cleans up.
    var isDeleted: Bool {
        (deletedAt ?? 0) > 0
    }

    /// Whether deleting it can be undone. Deck restores only `deck_file` attachments (stored by Deck itself);
    /// deleting a `file` attachment unshares the file from the card, leaving it in its owner's Files.
    var canBeRestored: Bool {
        type == "deck_file"
    }

    /// Human-readable file size.
    var formattedSize: String? {
        guard let bytes = extendedData?.filesize else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

struct AttachmentExtendedData: Codable {
    var filesize: Int?
    var mimetype: String?
    var info: AttachmentInfo?
}

struct AttachmentInfo: Codable {
    var dirname: String?
    var basename: String?
    var fileExtension: String?
    var filename: String?

    enum CodingKeys: String, CodingKey {
        case dirname, basename, filename
        case fileExtension = "extension"
    }
}

// MARK: - Dates

/// Dates as the Deck API sends and accepts them: ISO-8601, e.g. `2026-10-10T12:00:00+00:00`.
enum DeckDate {
    /// Parses a Deck date, with or without fractional seconds. Returns nil for nil, empty or unparseable values.
    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    /// Formats a date for the Deck API, in UTC.
    static func string(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

extension Card {
    /// The due date, if the card has one.
    var dueDate: Date? {
        DeckDate.parse(duedate)
    }

    /// The start date, if the card has one.
    var startDate: Date? {
        DeckDate.parse(startdate)
    }

    /// Whether the card is marked done.
    var isDone: Bool {
        DeckDate.parse(done) != nil
    }

    /// A card is overdue when its due date has passed and it isn't done.
    func isOverdue(at now: Date = Date()) -> Bool {
        guard let dueDate, !isDone else { return false }
        return dueDate < now
    }

    /// A copy with the start and due dates set (or cleared with nil) and the done state set. Marking an
    /// already-done card done keeps its original done date; marking a card done stamps it with `now`.
    func withSchedule(startDate: Date?, dueDate: Date?, isDone: Bool, now: Date = Date()) -> Card {
        var card = self
        card.startdate = startDate.map(DeckDate.string(from:))
        card.duedate = dueDate.map(DeckDate.string(from:))
        if !isDone {
            card.done = nil
        } else if !self.isDone {
            card.done = DeckDate.string(from: now)
        }
        return card
    }
}

// MARK: - Assignments

/// A user (or group) assigned to a card. Deck wraps the user in `participant`.
struct CardAssignment: Codable, Hashable, Identifiable {
    let id: Int
    let participant: DeckUser
    /// 0 for a user; other values are groups, circles or federated users.
    let type: Int

    init(id: Int, participant: DeckUser, type: Int = Self.userType) {
        self.id = id
        self.participant = participant
        self.type = type
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIntOrString(forKey: .id)
        self.participant = try c.decode(DeckUser.self, forKey: .participant)
        self.type = (try? c.decodeIntOrStringIfPresent(forKey: .type)) ?? Self.userType
    }

    enum CodingKeys: String, CodingKey {
        case id, participant, type
    }

    static let userType = 0
}

extension Card {
    /// Who the card is assigned to.
    var assignments: [CardAssignment] {
        assignedUsers ?? []
    }
}
