import Foundation

// MARK: - CardActivity

/// An event in a card's history (#164): created, renamed, moved, given a due date, commented on… Deck records them
/// in the Activity app, and its OCS API (`/ocs/v2.php/apps/activity/api/v2/activity/filter`, with the card as the
/// object) sends them already written out in the user's language.
/// See https://github.com/nextcloud/activity/blob/master/docs/endpoint-v2.md
struct CardActivity: Decodable, Identifiable, Hashable, Sendable {
    /// A piece of the event's text: plain words, or a name (a person, list, label, date…) to show in bold.
    enum Segment: Hashable, Sendable {
        case text(String)
        case name(String)
    }

    let id: Int
    /// ISO-8601, e.g. `2026-10-15T09:12:44+00:00`.
    let datetime: String
    /// The id of the user who did it; nil when there isn't one (a public link, say).
    let userId: String?
    /// The event as plain text, e.g. "You have moved the card Plan from list To do to Done".
    let subject: String
    /// The subject with placeholders such as `{user}` and `{stack}`, and the names they stand for. Deck leaves a
    /// placeholder out of `names` when it has nothing to show for it.
    let richSubject: String?
    let names: [String: String]
    /// The display name of the user who did it, if the event names them.
    let userName: String?

    init(
        id: Int,
        datetime: String,
        userId: String?,
        subject: String,
        richSubject: String? = nil,
        names: [String: String] = [:],
        userName: String? = nil
    ) {
        self.id = id
        self.datetime = datetime
        self.userId = userId
        self.subject = subject
        self.richSubject = richSubject
        self.names = names
        self.userName = userName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIntOrString(forKey: .id)
        self.datetime = try c.decodeIfPresent(String.self, forKey: .datetime) ?? ""
        let userId = try? c.decodeIfPresent(String.self, forKey: .user)
        self.userId = userId?.isEmpty == false ? userId : nil
        self.subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
        let rich = try? c.decodeIfPresent(RichString.self, forKey: .richSubject)
        self.richSubject = rich?.template
        let parameters = rich?.parameters ?? [:]
        self.names = parameters.compactMapValues(\.name)
        self.userName = self.userId.flatMap { id in parameters.values.first { $0.type == "user" && $0.id == id }?.name }
    }

    enum CodingKeys: String, CodingKey {
        case id = "activity_id"
        case datetime, user, subject
        case richSubject = "subject_rich"
    }

    var createdAt: Date? {
        DeckDate.parse(datetime)
    }

    /// The user who did it, for their avatar; nil if the event doesn't say.
    var author: DeckUser? {
        userId.map { DeckUser(uid: $0, displayname: userName) }
    }

    /// The subject split into text and names, from the rich subject when there is one. As in the plain subject, a
    /// placeholder Deck has no name for shows as nothing.
    var segments: [Segment] {
        guard let richSubject, !richSubject.isEmpty else { return [.text(subject)] }
        var segments: [Segment] = []
        var text = ""
        var rest = Substring(richSubject)
        while let open = rest.firstIndex(of: "{") {
            text += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                rest = rest[open...]
                break
            }
            let key = String(rest[rest.index(after: open) ..< close])
            if key.isEmpty || key.contains(" ") {
                // Not a placeholder: keep it as it is.
                text += rest[open ... close]
            } else if let name = names[key], !name.isEmpty {
                if !text.isEmpty {
                    segments.append(.text(text))
                    text = ""
                }
                segments.append(.name(name))
            }
            rest = rest[rest.index(after: close)...]
        }
        text += rest
        if !text.isEmpty {
            segments.append(.text(text))
        }
        return segments
    }
}

// MARK: - Rich strings

/// A rich subject: `[template, {placeholder: parameter}]`. PHP sends it as a list, or as an object keyed "0" and
/// "1" in older servers; the parameters are an empty list when there are none.
private struct RichString: Decodable {
    struct Parameter: Decodable {
        let type: String?
        let id: String?
        let name: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.type = try? c.decodeIfPresent(String.self, forKey: .type)
            self.id = (try? c.decodeIfPresent(String.self, forKey: .id))
                ?? (try? c.decodeIfPresent(Int.self, forKey: .id)).map { String($0) }
            self.name = try? c.decodeIfPresent(String.self, forKey: .name)
        }

        enum CodingKeys: String, CodingKey {
            case type, id, name
        }
    }

    let template: String
    let parameters: [String: Parameter]

    private struct Index: CodingKey {
        let stringValue: String
        var intValue: Int? {
            Int(stringValue)
        }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
        }
    }

    init(from decoder: Decoder) throws {
        if var list = try? decoder.unkeyedContainer() {
            self.template = try list.decode(String.self)
            self.parameters = list.isAtEnd ? [:] : (try? list.decode([String: Parameter].self)) ?? [:]
        } else {
            let object = try decoder.container(keyedBy: Index.self)
            self.template = try object.decode(String.self, forKey: Index(stringValue: "0"))
            self.parameters = (try? object.decode([String: Parameter].self, forKey: Index(stringValue: "1"))) ?? [:]
        }
    }
}

// MARK: - CardActivityPage

/// What the server answered when asked for a card's history.
enum CardActivityPage: Equatable, Sendable {
    /// The server doesn't have the Activity app, so cards have no history to show.
    case unavailable
    /// Events, newest first; none once the oldest has been sent.
    case events([CardActivity])
}
