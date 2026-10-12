import Foundation

// MARK: - CardComment

/// A comment on a card, from Deck's OCS comments API (`/ocs/v2.php/apps/deck/api/v1.0/cards/{id}/comments`).
struct CardComment: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let message: String
    /// The author's user id; only the author may edit or delete a comment.
    let actorId: String
    let actorDisplayName: String
    /// ISO-8601, e.g. `2020-03-10T10:23:07+00:00`.
    let creationDateTime: String
    /// The people the message mentions (#163), as the server found them.
    let mentions: [CommentMention]

    init(
        id: Int,
        message: String,
        actorId: String,
        actorDisplayName: String,
        creationDateTime: String,
        mentions: [CommentMention] = []
    ) {
        self.id = id
        self.message = message
        self.actorId = actorId
        self.actorDisplayName = actorDisplayName
        self.creationDateTime = creationDateTime
        self.mentions = mentions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIntOrString(forKey: .id)
        self.message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        self.actorId = try c.decodeIfPresent(String.self, forKey: .actorId) ?? ""
        self.actorDisplayName = try c.decodeIfPresent(String.self, forKey: .actorDisplayName) ?? ""
        self.creationDateTime = try c.decodeIfPresent(String.self, forKey: .creationDateTime) ?? ""
        self.mentions = try c.decodeIfPresent([CommentMention].self, forKey: .mentions) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case id, message, actorId, actorDisplayName, creationDateTime, mentions
    }

    /// The message split into text and mentions, to show mentions by name.
    var segments: [Mentions.Segment] {
        Mentions.segments(of: message, mentions: mentions)
    }

    /// The most characters Deck accepts in a comment.
    static let maximumLength = 1000

    /// Whether `text` can be posted: not blank, and within `maximumLength` once trimmed.
    static func isPostable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maximumLength
    }

    var createdAt: Date? {
        DeckDate.parse(creationDateTime)
    }

    var author: DeckUser {
        DeckUser(uid: actorId, displayname: actorDisplayName)
    }
}

// MARK: - OCS envelope

/// Deck's OCS endpoints wrap every response as `{"ocs": {"meta": {...}, "data": ...}}`.
struct OCSResponse<Payload: Decodable>: Decodable {
    struct OCS: Decodable {
        let data: Payload
    }

    let ocs: OCS
}

/// An OCS error body: `{"ocs": {"meta": {"message": "..."}}}`.
struct OCSErrorResponse: Decodable {
    struct OCS: Decodable {
        struct Meta: Decodable {
            let message: String?
        }

        let meta: Meta
    }

    let ocs: OCS
}
