import Foundation

// MARK: - ShareType

/// Who a board is shared with (Deck's ACL `type`).
enum ShareType: Int, CaseIterable, Sendable {
    case user = 0
    case group = 1
    case federated = 6
    case team = 7

    /// Nextcloud autocomplete's `source` for this type.
    init?(source: String) {
        switch source {
        case "users": self = .user
        case "groups": self = .group
        case "remotes": self = .federated
        case "circles": self = .team
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .user: String(localized: "User")
        case .group: String(localized: "Group")
        case .federated: String(localized: "Federated user")
        case .team: String(localized: "Team")
        }
    }

    var symbol: String {
        switch self {
        case .user: "person.fill"
        case .group: "person.3.fill"
        case .federated: "globe"
        case .team: "person.2.circle.fill"
        }
    }
}

// MARK: - Sharee

/// Someone a board can be shared with, from Nextcloud's autocomplete
/// (`/ocs/v2.php/core/autocomplete/get?itemType=deck`), as Deck's web UI searches.
struct Sharee: Decodable, Identifiable, Hashable, Sendable {
    /// The participant id to share with: a user id, group id, cloud id or team id.
    let participantId: String
    let label: String
    let source: String
    /// Disambiguates people with the same name (often their email or id).
    let detail: String?

    var id: String {
        "\(source):\(participantId)"
    }

    var shareType: ShareType? {
        ShareType(source: source)
    }

    init(participantId: String, label: String, source: String, detail: String? = nil) {
        self.participantId = participantId
        self.label = label
        self.source = source
        self.detail = detail
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.participantId = try c.decode(String.self, forKey: .id)
        self.source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        let label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        self.label = label.isEmpty ? participantId : label
        self.detail = try c.decodeIfPresent(String.self, forKey: .shareWithDisplayNameUnique)
            ?? c.decodeIfPresent(String.self, forKey: .subline)
    }

    enum CodingKeys: String, CodingKey {
        case id, label, source, subline, shareWithDisplayNameUnique
    }
}

// MARK: - Permissions

/// The rights a share grants on top of read access.
struct SharePermissions: Equatable, Sendable {
    var edit = false
    var share = false
    var manage = false

    init(edit: Bool = false, share: Bool = false, manage: Bool = false) {
        self.edit = edit
        self.share = share
        self.manage = manage
    }

    init(_ entry: ACLEntry) {
        self.init(edit: entry.permissionEdit, share: entry.permissionShare, manage: entry.permissionManage)
    }

    enum Right: CaseIterable, Sendable {
        case edit, share, manage

        var title: String {
            switch self {
            case .edit: String(localized: "Can edit")
            case .share: String(localized: "Can share")
            case .manage: String(localized: "Can manage")
            }
        }
    }

    subscript(right: Right) -> Bool {
        get {
            switch right {
            case .edit: edit
            case .share: share
            case .manage: manage
            }
        }
        set {
            switch right {
            case .edit: edit = newValue
            case .share: share = newValue
            case .manage: manage = newValue
            }
        }
    }
}

// MARK: - Board sharing rules

extension Board {
    /// Whether the signed-in user may add shares and change their rights (Deck: PERMISSION_SHARE).
    var canShare: Bool {
        permissions?.permissionShare ?? false
    }

    /// Whether the signed-in user may change the board's lists and cards (Deck: PERMISSION_EDIT).
    var canEdit: Bool {
        permissions?.permissionEdit ?? false
    }

    /// Whether the signed-in user may remove shares and grant any right (Deck: PERMISSION_MANAGE).
    var canManage: Bool {
        permissions?.permissionManage ?? false
    }

    /// Whether the signed-in user may grant `right`. Without manage rights, Deck only lets you pass on rights you
    /// hold yourself and silently drops the rest, so the app doesn't offer them.
    func canGrant(_ right: SharePermissions.Right) -> Bool {
        guard canShare else { return false }
        if canManage {
            return true
        }
        switch right {
        case .edit: return permissions?.permissionEdit ?? false
        case .share: return true
        case .manage: return false
        }
    }

    /// Whether the board is already shared with `sharee`, or `sharee` owns it.
    func isShared(with sharee: Sharee) -> Bool {
        if sharee.shareType == .user, owner?.uid == sharee.participantId {
            return true
        }
        return acl.contains { $0.type == sharee.shareType?.rawValue && $0.participant?.uid == sharee.participantId }
    }
}
