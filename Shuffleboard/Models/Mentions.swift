import Foundation

// MARK: - CommentMention

/// Someone a comment mentions, as the server parsed it from the message (`mentions` in Deck's comment responses).
struct CommentMention: Decodable, Hashable, Sendable {
    let mentionId: String
    /// "user" for a person; Nextcloud also knows groups, guests and others, which are shown as written.
    let mentionType: String
    let mentionDisplayName: String

    init(mentionId: String, mentionType: String = "user", mentionDisplayName: String) {
        self.mentionId = mentionId
        self.mentionType = mentionType
        self.mentionDisplayName = mentionDisplayName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mentionId = try c.decode(String.self, forKey: .mentionId)
        self.mentionType = try c.decodeIfPresent(String.self, forKey: .mentionType) ?? "user"
        let name = try c.decodeIfPresent(String.self, forKey: .mentionDisplayName) ?? ""
        self.mentionDisplayName = name.isEmpty ? mentionId : name
    }

    private enum CodingKeys: String, CodingKey {
        case mentionId, mentionType, mentionDisplayName
    }
}

// MARK: - Mentions

/// @mentions in comments (#163). The server finds them in the message text, the way Nextcloud's comments do:
/// `@alice`, or `@"name with spaces"` for a user id with characters a bare mention can't hold. The person mentioned
/// gets a Nextcloud notification.
enum Mentions {
    /// Characters a bare `@id` mention may hold; any other id is quoted.
    private static let bareCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-@.'")

    private static func isBare(_ id: String) -> Bool {
        !id.isEmpty && id.lowercased().unicodeScalars.allSatisfy(bareCharacters.contains)
    }

    /// How a mention of `userId` is written in a message.
    static func token(for userId: String) -> String {
        isBare(userId) ? "@\(userId)" : "@\"\(userId)\""
    }

    /// The mention being typed at the end of `text`: an `@` at the start or after a space, and what follows it.
    static func query(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        let typed = text[text.index(after: at)...]
        guard !typed.contains(where: { $0.isWhitespace || $0 == "\"" }) else { return nil }
        if at > text.startIndex {
            guard text[text.index(before: at)].isWhitespace else { return nil }
        }
        return String(typed)
    }

    /// The people to offer for `query`: those whose user id or name starts a word with it, at most `limit`.
    static func suggestions(for query: String, from users: [DeckUser], limit: Int = 6) -> [DeckUser] {
        let query = query.lowercased()
        func matches(_ user: DeckUser) -> Bool {
            guard !query.isEmpty else { return true }
            let words = [user.uid] + user.displayName.split(whereSeparator: \.isWhitespace).map(String.init)
            return words.contains { $0.lowercased().hasPrefix(query) }
                || user.displayName.lowercased().hasPrefix(query)
        }
        return Array(users.filter(matches).prefix(limit))
    }

    /// `text` with the mention being typed at its end replaced by `user`'s, and a space to carry on typing.
    static func completing(_ text: String, with user: DeckUser) -> String {
        guard query(in: text) != nil, let at = text.lastIndex(of: "@") else { return text }
        return String(text[..<at]) + token(for: user.uid) + " "
    }

    /// A piece of a comment's message: plain text, or a mention shown by name.
    enum Segment: Equatable {
        case text(String)
        case mention(CommentMention)
    }

    /// `message` split into text and the `mentions` the server found in it; a mention is matched as written
    /// (`@id` or `@"id"`, ignoring case), not inside a longer word.
    static func segments(of message: String, mentions: [CommentMention]) -> [Segment] {
        // Longer ids first, so "@bob.smith" isn't read as "@bob".
        let sorted = mentions.sorted { $0.mentionId.count > $1.mentionId.count }
        var segments: [Segment] = []
        var plain = ""
        var index = message.startIndex
        while index < message.endIndex {
            if message[index] == "@", isMentionStart(message, at: index),
               let (mention, end) = mention(in: message, at: index, from: sorted) {
                if !plain.isEmpty {
                    segments.append(.text(plain))
                    plain = ""
                }
                segments.append(.mention(mention))
                index = end
            } else {
                plain.append(message[index])
                index = message.index(after: index)
            }
        }
        if !plain.isEmpty {
            segments.append(.text(plain))
        }
        return segments
    }

    /// An `@` starts a mention at the start of the message or after something that isn't part of a word.
    private static func isMentionStart(_ message: String, at index: String.Index) -> Bool {
        guard index > message.startIndex else { return true }
        let before = message[message.index(before: index)]
        return !(before.isLetter || before.isNumber || before == "_")
    }

    private static func mention(
        in message: String,
        at index: String.Index,
        from mentions: [CommentMention]
    )
        -> (CommentMention, String.Index)? {
        let rest = message[message.index(after: index)...]
        func starts(with written: String) -> Bool {
            rest.prefix(written.count).lowercased() == written.lowercased()
        }
        for mention in mentions {
            let quoted = "\"\(mention.mentionId)\""
            if starts(with: quoted) {
                return (mention, rest.index(rest.startIndex, offsetBy: quoted.count))
            }
            guard isBare(mention.mentionId), starts(with: mention.mentionId) else { continue }
            let end = rest.index(rest.startIndex, offsetBy: mention.mentionId.count)
            if end == message.endIndex || !continuesBareMention(message[end]) {
                return (mention, end)
            }
        }
        return nil
    }

    /// Whether `character` would make a bare mention longer, as the server reads it, so the id doesn't end there.
    private static func continuesBareMention(_ character: Character) -> Bool {
        character.lowercased().unicodeScalars.allSatisfy(bareCharacters.contains)
    }
}
