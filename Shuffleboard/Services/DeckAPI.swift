import Foundation

/// Client for Nextcloud Deck REST API
/// https://deck.readthedocs.io/en/latest/API/
///
/// Uses only the documented REST API: v1.0 for boards, stacks, cards and labels, and v1.1 for attachments.
///
/// `Sendable`: every stored property is an immutable, `Sendable` value, so `AppState` (on the main actor) can
/// call its `async` methods without data races.
final class DeckAPI: Sendable {
    private let baseURL: URL
    /// API v1.1 (Deck 1.3+), used for attachments: v1.0 only lists and addresses `deck_file` attachments,
    /// while files attached since Deck 1.3 have the type `file`.
    private let attachmentsBaseURL: URL
    /// The OCS API, used for comments.
    private let ocsBaseURL: URL
    /// Nextcloud's core OCS API, used to search for people and groups to share with.
    private let coreOCSBaseURL: URL
    private let appPasswordURL: URL
    /// Nextcloud's capabilities, which include the server's Deck version.
    private let capabilitiesURL: URL
    /// The Activity app's OCS API filtered to one object, for cards' history (#164).
    private let activityURL: URL
    private let username: String
    private let appPassword: String
    private let session: URLSession
    /// A new decoder per use keeps `DeckAPI` `Sendable` without relying on `JSONDecoder`'s thread-safety.
    private var decoder: JSONDecoder {
        JSONDecoder()
    }

    private var encoder: JSONEncoder {
        JSONEncoder()
    }

    init(serverURL: URL, username: String, appPassword: String, session: URLSession = .shared) {
        self.baseURL = serverURL
            .appendingPathComponent("index.php")
            .appendingPathComponent("apps")
            .appendingPathComponent("deck")
            .appendingPathComponent("api")
            .appendingPathComponent("v1.0")
        self.coreOCSBaseURL = serverURL
            .appendingPathComponent("ocs")
            .appendingPathComponent("v2.php")
            .appendingPathComponent("core")
        self.ocsBaseURL = serverURL
            .appendingPathComponent("ocs")
            .appendingPathComponent("v2.php")
            .appendingPathComponent("apps")
            .appendingPathComponent("deck")
            .appendingPathComponent("api")
            .appendingPathComponent("v1.0")
        self.attachmentsBaseURL = serverURL
            .appendingPathComponent("index.php")
            .appendingPathComponent("apps")
            .appendingPathComponent("deck")
            .appendingPathComponent("api")
            .appendingPathComponent("v1.1")
        self.capabilitiesURL = serverURL
            .appendingPathComponent("ocs")
            .appendingPathComponent("v2.php")
            .appendingPathComponent("cloud")
            .appendingPathComponent("capabilities")
        self.appPasswordURL = serverURL
            .appendingPathComponent("ocs")
            .appendingPathComponent("v2.php")
            .appendingPathComponent("core")
            .appendingPathComponent("apppassword")
        self.activityURL = serverURL
            .appendingPathComponent("ocs")
            .appendingPathComponent("v2.php")
            .appendingPathComponent("apps")
            .appendingPathComponent("activity")
            .appendingPathComponent("api")
            .appendingPathComponent("v2")
            .appendingPathComponent("activity")
            .appendingPathComponent("filter")
        self.username = username
        self.appPassword = appPassword
        self.session = session
    }

    private var authHeader: String {
        let credentials = "\(username):\(appPassword)"
        guard let data = credentials.data(using: .utf8) else { return "" }
        return "Basic \(data.base64EncodedString())"
    }

    /// A request signed in as this account. It neither sends nor stores cookies: Nextcloud answers a request
    /// that carries a session cookie as that session's user, whatever its `Authorization` header says. With the
    /// app's one URLSession, a second account on the same server would otherwise read and change the first
    /// account's boards.
    private func authorizedRequest(url: URL, method: String, timeout: TimeInterval = 60) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.httpShouldHandleCookies = false
        req.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        return req
    }

    /// Builds a full URL by appending the relative path to the base URL (avoids `URL(string:relativeTo:)` replacing the
    /// last path component and dropping `/v1.0`).
    private func url(for path: String) -> URL? {
        Self.url(base: baseURL, path: path)
    }

    /// Like `url(for:)`, for the v1.1 attachment endpoints.
    private func attachmentsURL(for path: String) -> URL? {
        Self.url(base: attachmentsBaseURL, path: path)
    }

    private static func url(base: URL, path: String) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let basePath = base.path
        components.path = (basePath.hasSuffix("/") ? basePath : basePath + "/") + path
        return components.url
    }

    private func request<T: Decodable>(
        _ path: String,
        method: String = "GET",
        body: (any Encodable)? = nil
    ) async throws
        -> T {
        guard let requestURL = url(for: path) else { throw DeckAPIError.invalidURL }
        let encodedBody = try body.map { try encoder.encode($0) }
        let (data, _) = try await performRequest(url: requestURL, method: method, body: encodedBody)
        return try decoder.decode(T.self, from: data)
    }

    private func requestNoContent(
        _ path: String,
        method: String = "GET",
        body: (any Encodable)? = nil
    ) async throws {
        guard let requestURL = url(for: path) else { throw DeckAPIError.invalidURL }
        let encodedBody = try body.map { try encoder.encode($0) }
        _ = try await performRequest(url: requestURL, method: method, body: encodedBody)
    }

    // MARK: - Session

    /// Revokes the app password this client signs in with, so it stops working and disappears from the
    /// user's devices in Nextcloud's security settings (`DELETE /ocs/v2.php/core/apppassword`).
    /// The server answers 403 if the credential is not an app password.
    func revokeAppPassword(timeout: TimeInterval = 10) async throws {
        let req = authorizedRequest(url: appPasswordURL, method: "DELETE", timeout: timeout)
        let (data, response) = try await session.data(for: req)
        try validate(response: response, data: data)
    }

    // MARK: - Boards

    func getBoards(details: Bool = true) async throws -> [Board] {
        guard let boards = try await fetchBoards(details: details, ifNoneMatch: nil) else {
            throw DeckAPIError.invalidResponse
        }
        return boards.value
    }

    /// Fetches the boards with their ETag. With `ifNoneMatch` (a previous ETag), returns `nil` when nothing on
    /// any board has changed: Deck propagates changes to cards, labels and stacks up to the board list's ETag.
    func fetchBoards(details: Bool = true, ifNoneMatch etag: String?) async throws -> Tagged<[Board]>? {
        guard let base = url(for: "boards"),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw DeckAPIError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "details", value: details ? "true" : "false")]
        guard let url = components.url else { throw DeckAPIError.invalidURL }
        guard let (data, response) = try await performConditionalGet(url: url, ifNoneMatch: etag) else {
            return nil
        }
        let etag = Self.etag(of: response)
        if let boards = try? decoder.decode([Board].self, from: data) {
            return Tagged(value: boards, etag: etag)
        }
        if let wrapper = try? decoder.decode(OCSBoardsWrapper.self, from: data) {
            return Tagged(value: wrapper.data, etag: etag)
        }
        if let ocs = try? decoder.decode(OCSEnvelope.self, from: data) {
            return Tagged(value: ocs.ocs.data, etag: etag)
        }
        throw DeckAPIError.badRequest("Could not decode boards response")
    }

    private struct OCSBoardsWrapper: Decodable {
        let data: [Board]
    }

    private struct OCSEnvelope: Decodable {
        let ocs: OCSBoardsWrapper
    }

    /// A GET that returns `nil` for 304 Not Modified. With an ETag it bypasses URLSession's cache, so the
    /// server's 304 reaches us instead of being answered from a cached copy.
    private func performConditionalGet(url: URL, ifNoneMatch etag: String?) async throws -> (Data, URLResponse)? {
        do {
            return try await performRequest(url: url, method: "GET", ifNoneMatch: etag)
        } catch DeckAPIError.notModified {
            return nil
        }
    }

    private static func etag(of response: URLResponse) -> String? {
        (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
    }

    private func performRequest(
        url: URL,
        method: String,
        body: Data? = nil,
        ifNoneMatch etag: String? = nil
    ) async throws
        -> (Data, URLResponse) {
        var req = authorizedRequest(url: url, method: method)
        if let etag {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
            req.cachePolicy = .reloadIgnoringLocalCacheData
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, response) = try await session.data(for: req)
        try validate(response: response, data: data)
        return (data, response)
    }

    /// Maps a non-2xx response to a `DeckAPIError`.
    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw DeckAPIError.invalidResponse }
        if http.statusCode == 304 {
            throw DeckAPIError.notModified
        }
        if http.statusCode == 400, let err = try? decoder.decode(APIErrorResponse.self, from: data) {
            throw DeckAPIError.badRequest(err.message)
        }
        // OCS endpoints put the reason in ocs.meta.message.
        if !(200 ... 299).contains(http.statusCode), http.statusCode != 401, http.statusCode != 403,
           let err = try? decoder.decode(OCSErrorResponse.self, from: data),
           let message = err.ocs.meta.message, !message.isEmpty {
            throw DeckAPIError.badRequest(message)
        }
        if http.statusCode == 401 {
            throw DeckAPIError.unauthorized
        }
        if http.statusCode == 403 {
            throw DeckAPIError.permissionDenied
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw DeckAPIError.httpStatus(http.statusCode)
        }
    }

    private struct OCSBoardsResponse: Decodable {
        let data: [Board]
    }

    func getBoard(id: Int) async throws -> Board {
        try await request("boards/\(id)")
    }

    func createBoard(title: String, color: String = "0082c9") async throws -> Board {
        guard let url = url(for: "boards") else { throw DeckAPIError.invalidURL }
        let body = try encoder.encode(CreateBoardRequest(title: title, color: color))
        let (data, _) = try await performRequest(url: url, method: "POST", body: body)
        return try decoder.decode(Board.self, from: data)
    }

    /// Sets the board's title, colour and archived state. Deck has no partial update: a missing `archived` means
    /// `false`, so renaming an archived board must send `archived: true` to keep it archived.
    func updateBoard(id: Int, title: String, color: String?, archived: Bool) async throws -> Board {
        try await request(
            "boards/\(id)",
            method: "PUT",
            body: UpdateBoardRequest(title: title, color: color, archived: archived)
        )
    }

    func deleteBoard(id: Int) async throws {
        try await requestNoContent("boards/\(id)", method: "DELETE")
    }

    func undoDeleteBoard(id: Int) async throws {
        try await requestNoContent("boards/\(id)/undo_delete", method: "POST")
    }

    // MARK: - Stacks

    func getStacks(boardId: Int) async throws -> [Stack] {
        guard let stacks = try await fetchStacks(boardId: boardId, ifNoneMatch: nil) else {
            throw DeckAPIError.invalidResponse
        }
        return stacks.value
    }

    /// Fetches a board's stacks (with their cards) and the ETag; `nil` when unchanged since `ifNoneMatch`.
    func fetchStacks(boardId: Int, ifNoneMatch etag: String?) async throws -> Tagged<[Stack]>? {
        guard let url = url(for: "boards/\(boardId)/stacks") else { throw DeckAPIError.invalidURL }
        guard let (data, response) = try await performConditionalGet(url: url, ifNoneMatch: etag) else {
            return nil
        }
        return try Tagged(value: decodeStacks(from: data, context: "stacks"), etag: Self.etag(of: response))
    }

    private func decodingErrorDescription(_ error: DecodingError) -> String {
        switch error {
        case let .keyNotFound(key, context):
            return "missing key '\(key.stringValue)' at \(context.codingPath.map(\.stringValue).joined(separator: "."))"

        case let .typeMismatch(type, context):
            return "type mismatch for \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"

        case let .valueNotFound(type, context):
            return "nil value for \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"

        case let .dataCorrupted(context):
            return "data corrupted at \(context.codingPath.map(\.stringValue).joined(separator: "."))"

        @unknown default:
            return error.localizedDescription
        }
    }

    private struct OCSStacksWrapper: Decodable {
        let data: [Stack]
    }

    private struct OCSStacksEnvelope: Decodable {
        let ocs: OCSStacksWrapper
    }

    private struct OCSCardWrapper: Decodable {
        let data: Card
    }

    private struct OCSCardEnvelope: Decodable {
        let ocs: OCSCardWrapper
    }

    func getStack(boardId: Int, stackId: Int) async throws -> Stack {
        try await request("boards/\(boardId)/stacks/\(stackId)")
    }

    /// The board's stacks, each holding its *archived* cards.
    func getArchivedStacks(boardId: Int) async throws -> [Stack] {
        guard let url = url(for: "boards/\(boardId)/stacks/archived") else { throw DeckAPIError.invalidURL }
        let (data, _) = try await performRequest(url: url, method: "GET")
        return try decodeStacks(from: data, context: "archived stacks")
    }

    /// Decodes a `[Stack]` from raw response data, trying direct decode first then
    /// OCS wrapper formats. `context` is used only in error messages.
    private func decodeStacks(from data: Data, context: String) throws -> [Stack] {
        do {
            return try decoder.decode([Stack].self, from: data)
        } catch let arrayError as DecodingError {
            if let wrapper = try? decoder.decode(OCSStacksWrapper.self, from: data) {
                return wrapper.data
            }
            if let ocs = try? decoder.decode(OCSStacksEnvelope.self, from: data) {
                return ocs.ocs.data
            }
            let detail = decodingErrorDescription(arrayError)
            throw DeckAPIError.badRequest("Could not decode \(context): \(detail)")
        } catch {
            throw DeckAPIError.badRequest("Could not decode \(context): \(error.localizedDescription)")
        }
    }

    func createStack(boardId: Int, title: String, order: Int = 999) async throws -> Stack {
        try await request(
            "boards/\(boardId)/stacks",
            method: "POST",
            body: CreateStackRequest(title: title, order: order)
        )
    }

    func updateStack(boardId: Int, stackId: Int, title: String?, order: Int?) async throws -> Stack {
        try await request(
            "boards/\(boardId)/stacks/\(stackId)",
            method: "PUT",
            body: UpdateStackRequest(title: title, order: order)
        )
    }

    func deleteStack(boardId: Int, stackId: Int) async throws {
        try await requestNoContent("boards/\(boardId)/stacks/\(stackId)", method: "DELETE")
    }

    // MARK: - Cards

    func getCard(boardId: Int, stackId: Int, cardId: Int) async throws -> Card {
        let path = "boards/\(boardId)/stacks/\(stackId)/cards/\(cardId)"
        guard let requestURL = url(for: path) else { throw DeckAPIError.invalidURL }
        let (data, _) = try await performRequest(url: requestURL, method: "GET")
        return try decodeCard(from: data, context: "card response")
    }

    /// Decodes a `Card` from raw response data, trying direct decode first then
    /// OCS wrapper formats. `context` is used only in the error message.
    private func decodeCard(from data: Data, context: String) throws -> Card {
        if let card = try? decoder.decode(Card.self, from: data) {
            return card
        }
        if let wrapper = try? decoder.decode(OCSCardWrapper.self, from: data) {
            return wrapper.data
        }
        if let envelope = try? decoder.decode(OCSCardEnvelope.self, from: data) {
            return envelope.ocs.data
        }
        throw DeckAPIError.badRequest("Could not decode \(context)")
    }

    func createCard(
        boardId: Int,
        stackId: Int,
        title: String,
        description: String? = nil,
        order: Int = 999,
        duedate: String? = nil
    ) async throws
        -> Card {
        try await request(
            "boards/\(boardId)/stacks/\(stackId)/cards",
            method: "POST",
            body: CreateCardRequest(
                title: title,
                type: "plain",
                order: order,
                description: description,
                duedate: duedate
            )
        )
    }

    /// Saves `card`'s current state. Deck's update endpoint requires `owner` and overwrites every field
    /// it is given or defaults (a missing `duedate`/`done` clears them, a missing `order` becomes 0),
    /// so the whole card is always sent rather than just the edited fields.
    func updateCard(boardId: Int, stackId: Int, card: Card) async throws -> Card {
        try await request(
            "boards/\(boardId)/stacks/\(stackId)/cards/\(card.id)",
            method: "PUT",
            body: UpdateCardRequest(card: card, fallbackOwner: username)
        )
    }

    func deleteCard(boardId: Int, stackId: Int, cardId: Int) async throws {
        try await requestNoContent("boards/\(boardId)/stacks/\(stackId)/cards/\(cardId)", method: "DELETE")
    }

    /// Moves a card to position `order` in the stack `newStackId`, which may be the stack it is already in.
    /// The server renumbers the other cards.
    ///
    /// The URL names the destination stack too, not the card's current one. Deck reads the destination from
    /// `stackId`, which the URL and the body both set, and which one wins depends on the server: when anything
    /// reads the request's parameters before routing (some installed apps do), the URL's value wins. With the
    /// card's current stack there, the server answered 200 and left the card where it was.
    func reorderCard(boardId: Int, cardId: Int, order: Int, newStackId: Int) async throws {
        try await requestNoContent(
            "boards/\(boardId)/stacks/\(newStackId)/cards/\(cardId)/reorder",
            method: "PUT",
            body: ReorderCardRequest(order: order, stackId: newStackId)
        )
    }

    /// Archives a card: it leaves the board's lists and appears in `getArchivedStacks`.
    func archiveCard(boardId: Int, stackId: Int, cardId: Int) async throws {
        try await requestNoContent("boards/\(boardId)/stacks/\(stackId)/cards/\(cardId)/archive", method: "PUT")
    }

    func unarchiveCard(boardId: Int, stackId: Int, cardId: Int) async throws {
        try await requestNoContent("boards/\(boardId)/stacks/\(stackId)/cards/\(cardId)/unarchive", method: "PUT")
    }

    /// Assigns a user (type 0) or another participant type to a card.
    func assignUser(boardId: Int, stackId: Int, cardId: Int, userId: String, type: Int = 0) async throws {
        try await requestNoContent(
            "boards/\(boardId)/stacks/\(stackId)/cards/\(cardId)/assignUser",
            method: "PUT",
            body: AssignUserRequest(userId: userId, type: type)
        )
    }

    func unassignUser(boardId: Int, stackId: Int, cardId: Int, userId: String, type: Int = 0) async throws {
        try await requestNoContent(
            "boards/\(boardId)/stacks/\(stackId)/cards/\(cardId)/unassignUser",
            method: "PUT",
            body: AssignUserRequest(userId: userId, type: type)
        )
    }

    func assignLabel(boardId: Int, stackId: Int, cardId: Int, labelId: Int) async throws {
        try await requestNoContent(
            "boards/\(boardId)/stacks/\(stackId)/cards/\(cardId)/assignLabel",
            method: "PUT",
            body: LabelIdRequest(labelId: labelId)
        )
    }

    func removeLabel(boardId: Int, stackId: Int, cardId: Int, labelId: Int) async throws {
        try await requestNoContent(
            "boards/\(boardId)/stacks/\(stackId)/cards/\(cardId)/removeLabel",
            method: "PUT",
            body: LabelIdRequest(labelId: labelId)
        )
    }
}

// MARK: - Labels

extension DeckAPI {
    /// Creates a new label on the board. Returns the created label (or reload board to get it).
    func createLabel(boardId: Int, title: String, color: String = "31CC7C") async throws -> DeckLabel {
        try await request(
            "boards/\(boardId)/labels",
            method: "POST",
            body: LabelRequest(title: title, color: color)
        )
    }

    /// Renames and recolours a label; cards that have it show the change.
    func updateLabel(boardId: Int, labelId: Int, title: String, color: String) async throws -> DeckLabel {
        try await request(
            "boards/\(boardId)/labels/\(labelId)",
            method: "PUT",
            body: LabelRequest(title: title, color: color)
        )
    }

    /// Deletes a label from the board and from every card that has it. Unlike boards, lists and cards, a deleted
    /// label can't be restored.
    func deleteLabel(boardId: Int, labelId: Int) async throws {
        try await requestNoContent("boards/\(boardId)/labels/\(labelId)", method: "DELETE")
    }
}

// MARK: - Server

extension DeckAPI {
    /// The server's Deck version, e.g. "1.18.5", from Nextcloud's capabilities; nil if it doesn't say.
    func deckVersion() async throws -> String? {
        let (data, _) = try await performRequest(url: capabilitiesURL, method: "GET")
        return try decoder.decode(OCSResponse<Capabilities>.self, from: data).ocs.data.capabilities.deck?.version
    }

    /// The signed-in user's id, which Deck's assignments use. It can differ from the name they signed in with (an
    /// email address, or different capitals). From Nextcloud's user API (`GET /ocs/v2.php/cloud/user`).
    func currentUserId() async throws -> String {
        let url = capabilitiesURL.deletingLastPathComponent().appendingPathComponent("user")
        let (data, _) = try await performRequest(url: url, method: "GET")
        return try decoder.decode(OCSResponse<CurrentUser>.self, from: data).ocs.data.id
    }

    private struct CurrentUser: Decodable {
        let id: String
    }

    /// Whether `version` ("1.16.8") is `minimum` ("1.17") or newer; missing parts count as 0.
    static func version(_ version: String, isAtLeast minimum: String) -> Bool {
        let have = version.split(separator: ".").map { Int($0) ?? 0 }
        let need = minimum.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0 ..< max(have.count, need.count) {
            let part = index < have.count ? have[index] : 0
            let wanted = index < need.count ? need[index] : 0
            if part != wanted {
                return part > wanted
            }
        }
        return true
    }

    private struct Capabilities: Decodable {
        struct List: Decodable {
            let deck: Deck?
        }

        struct Deck: Decodable {
            let version: String?
        }

        let capabilities: List
    }
}

// MARK: - Sharing

extension DeckAPI {
    /// Shares the board; the new share starts read-only unless `permissions` say otherwise.
    func addShare(boardId: Int, type: ShareType, participant: String, permissions: SharePermissions) async throws {
        try await requestNoContent(
            "boards/\(boardId)/acl",
            method: "POST",
            body: AddShareRequest(
                type: type.rawValue,
                participant: participant,
                permissionEdit: permissions.edit,
                permissionShare: permissions.share,
                permissionManage: permissions.manage
            )
        )
    }

    func updateShare(boardId: Int, aclId: Int, permissions: SharePermissions) async throws {
        try await requestNoContent(
            "boards/\(boardId)/acl/\(aclId)",
            method: "PUT",
            body: UpdateShareRequest(
                permissionEdit: permissions.edit,
                permissionShare: permissions.share,
                permissionManage: permissions.manage
            )
        )
    }

    func removeShare(boardId: Int, aclId: Int) async throws {
        try await requestNoContent("boards/\(boardId)/acl/\(aclId)", method: "DELETE")
    }

    /// People, groups, federated users and Teams matching `query`, as Deck's web UI searches.
    func searchSharees(_ query: String, limit: Int = 20) async throws -> [Sharee] {
        guard let base = Self.url(base: coreOCSBaseURL, path: "autocomplete/get"),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw DeckAPIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "itemType", value: "deck"),
            URLQueryItem(name: "limit", value: String(limit)),
        ] + ShareType.allCases.map { URLQueryItem(name: "shareTypes[]", value: String($0.rawValue)) }
        guard let url = components.url else { throw DeckAPIError.invalidURL }
        let (data, _) = try await performRequest(url: url, method: "GET")
        return try decoder.decode(OCSResponse<[Sharee]>.self, from: data).ocs.data
    }
}

// MARK: - Comments

extension DeckAPI {
    /// A page of a card's comments, newest first.
    func getComments(cardId: Int, limit: Int = 20, offset: Int = 0) async throws -> [CardComment] {
        guard var components = commentsURL(cardId: cardId)
            .flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            throw DeckAPIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        guard let url = components.url else { throw DeckAPIError.invalidURL }
        let (data, _) = try await performRequest(url: url, method: "GET")
        return try decoder.decode(OCSResponse<[CardComment]>.self, from: data).ocs.data
    }

    func addComment(cardId: Int, message: String) async throws -> CardComment {
        guard let url = commentsURL(cardId: cardId) else { throw DeckAPIError.invalidURL }
        let body = try encoder.encode(CommentRequest(message: message))
        let (data, _) = try await performRequest(url: url, method: "POST", body: body)
        return try decoder.decode(OCSResponse<CardComment>.self, from: data).ocs.data
    }

    /// Only the comment's author may update it.
    func updateComment(cardId: Int, commentId: Int, message: String) async throws -> CardComment {
        guard let url = commentsURL(cardId: cardId, commentId: commentId) else { throw DeckAPIError.invalidURL }
        let body = try encoder.encode(CommentRequest(message: message))
        let (data, _) = try await performRequest(url: url, method: "PUT", body: body)
        return try decoder.decode(OCSResponse<CardComment>.self, from: data).ocs.data
    }

    /// Only the comment's author may delete it.
    func deleteComment(cardId: Int, commentId: Int) async throws {
        guard let url = commentsURL(cardId: cardId, commentId: commentId) else { throw DeckAPIError.invalidURL }
        _ = try await performRequest(url: url, method: "DELETE")
    }

    private func commentsURL(cardId: Int, commentId: Int? = nil) -> URL? {
        let path = "cards/\(cardId)/comments" + (commentId.map { "/\($0)" } ?? "")
        return Self.url(base: ocsBaseURL, path: path)
    }
}

// MARK: - Activity

extension DeckAPI {
    /// A page of the card's history (#164), newest first: up to `limit` events older than the event `since`, or
    /// the newest without it. From the Activity app, which Deck records cards' events in; `.unavailable` if the
    /// server doesn't have it.
    func getCardActivity(cardId: Int, since: Int? = nil, limit: Int = 20) async throws -> CardActivityPage {
        guard var components = URLComponents(url: activityURL, resolvingAgainstBaseURL: false) else {
            throw DeckAPIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "object_type", value: "deck_card"),
            URLQueryItem(name: "object_id", value: String(cardId)),
            URLQueryItem(name: "limit", value: String(limit)),
        ] + (since.map { [URLQueryItem(name: "since", value: String($0))] } ?? [])
        guard let url = components.url else { throw DeckAPIError.invalidURL }
        var request = authorizedRequest(url: url, method: "GET")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 404:
            // What Nextcloud answers for an app's API when the app isn't enabled.
            return .unavailable

        case 204, 304:
            // 204: the user doesn't list Deck's events in their activity stream; 304: no older events.
            return .events([])

        default:
            try validate(response: response, data: data)
            return try .events(decoder.decode(OCSResponse<[CardActivity]>.self, from: data).ocs.data)
        }
    }
}

// MARK: - Attachments

extension DeckAPI {

    // Attachments use REST API v1.1, which handles every attachment type: `file` (Deck 1.3+, stored in the
    // user's Files) as well as the older `deck_file`. Single attachments are addressed as `{type}/{id}`.

    private struct OCSAttachmentsWrapper: Decodable {
        let data: [Attachment]
    }

    private struct OCSAttachmentsEnvelope: Decodable {
        let ocs: OCSAttachmentsWrapper
    }

    private static let defaultAttachmentType = "file"

    /// Form fields sent with an upload. Deck 1.17 and 1.18 answer 400 without `data`, though uploads don't use
    /// it (fixed in Deck 1.19).
    static let uploadFields = ["type": defaultAttachmentType, "data": ""]

    /// Fetches the list of attachments for a card.
    func getAttachments(boardId: Int, stackId: Int, cardId: Int) async throws -> [Attachment] {
        guard let url = attachmentsURL(for: "boards/\(boardId)/stacks/\(stackId)/cards/\(cardId)/attachments") else {
            throw DeckAPIError.invalidURL
        }
        let (data, _) = try await performRequest(url: url, method: "GET")
        guard let attachments = decodeAttachments(from: data) else {
            throw DeckAPIError.badRequest("Could not decode attachments response")
        }
        return attachments
    }

    /// Decodes an attachment list from the response envelopes Deck uses, or returns `nil` if the
    /// response is not an attachment list (as opposed to an empty one).
    private func decodeAttachments(from data: Data) -> [Attachment]? {
        if let attachments = try? decoder.decode([Attachment].self, from: data) {
            return attachments
        }
        if let wrapper = try? decoder.decode(OCSAttachmentsWrapper.self, from: data) {
            return wrapper.data
        }
        if let envelope = try? decoder.decode(OCSAttachmentsEnvelope.self, from: data) {
            return envelope.ocs.data
        }
        // Lenient fallback: decode the entries that parse and skip any that don't.
        let parsed = try? JSONSerialization.jsonObject(with: data)
        let entries: [[String: Any]]? = if let array = parsed as? [[String: Any]] {
            array
        } else if let object = parsed as? [String: Any] {
            (object["data"] as? [[String: Any]])
                ?? ((object["ocs"] as? [String: Any])?["data"] as? [[String: Any]])
        } else {
            nil
        }
        return entries?.compactMap { dict -> Attachment? in
            guard let jsonData = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return try? decoder.decode(Attachment.self, from: jsonData)
        }
    }

    /// Downloads the file content of an attachment. Returns raw binary data.
    func downloadAttachment(
        boardId: Int,
        stackId: Int,
        cardId: Int,
        attachmentId: Int,
        type: String? = nil
    ) async throws
        -> Data {
        guard let url = attachmentURL(
            boardId: boardId,
            stackId: stackId,
            cardId: cardId,
            id: attachmentId,
            type: type
        ) else {
            throw DeckAPIError.invalidURL
        }
        return try await performRequest(url: url, method: "GET").0
    }

    /// Uploads a file as an attachment to a card.
    ///
    /// Returns the created attachment, or `nil` if the server accepted the upload but its response
    /// could not be decoded (the upload is not retried in that case, which would duplicate it).
    @discardableResult
    func uploadAttachment(
        boardId: Int,
        stackId: Int,
        cardId: Int,
        fileURL: URL,
        filename: String
    ) async throws
        -> Attachment? {
        guard let url = attachmentsURL(for: "boards/\(boardId)/stacks/\(stackId)/cards/\(cardId)/attachments") else {
            throw DeckAPIError.invalidURL
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        let bodyFile = try Self.writeMultipartBody(
            fileURL: fileURL,
            filename: filename,
            fields: Self.uploadFields,
            boundary: boundary
        )
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        let data = try await performMultipartUpload(url: url, bodyFile: bodyFile, boundary: boundary)
        return try? decoder.decode(Attachment.self, from: data)
    }

    /// URL of a single attachment: `.../attachments/{type}/{id}`.
    private func attachmentURL(boardId: Int, stackId: Int, cardId: Int, id: Int, type: String?) -> URL? {
        let type = type.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultAttachmentType
        return attachmentsURL(for: "boards/\(boardId)/stacks/\(stackId)/cards/\(cardId)/attachments/\(type)/\(id)")
    }

    /// Writes a `multipart/form-data` body holding `fileURL` to a temporary file, streaming the file
    /// in chunks so large attachments are not loaded into memory.
    static func writeMultipartBody(
        fileURL: URL,
        filename: String,
        fields: [String: String] = [:],
        boundary: String
    ) throws
        -> URL {
        let bodyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-upload-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: bodyFile.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let output = try FileHandle(forWritingTo: bodyFile)
            defer { try? output.close() }
            let input = try FileHandle(forReadingFrom: fileURL)
            defer { try? input.close() }

            var header = ""
            for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
                header += "--\(boundary)\r\n"
                    + "Content-Disposition: form-data; name=\"\(multipartQuoted(name))\"\r\n\r\n"
                    + "\(value)\r\n"
            }
            header += "--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"file\"; filename=\"\(multipartQuoted(filename))\"\r\n"
                + "Content-Type: application/octet-stream\r\n\r\n"
            try output.write(contentsOf: Data(header.utf8))
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        } catch {
            try? FileManager.default.removeItem(at: bodyFile)
            throw error
        }
        return bodyFile
    }

    /// Escapes a value for a quoted `Content-Disposition` parameter (RFC 7578 §4.2 / WHATWG form encoding):
    /// `"`, CR and LF are percent-encoded so a filename cannot break out of the header.
    static func multipartQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    /// Uploads a prepared multipart body file to `url` with the standard Deck headers and returns the
    /// response body on success.
    private func performMultipartUpload(url: URL, bodyFile: URL, boundary: String) async throws -> Data {
        var req = authorizedRequest(url: url, method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.upload(for: req, fromFile: bodyFile)
        try validate(response: response, data: data)
        return data
    }

    /// Deletes an attachment from a card.
    func deleteAttachment(
        boardId: Int,
        stackId: Int,
        cardId: Int,
        attachmentId: Int,
        type: String? = nil
    ) async throws {
        guard let url = attachmentURL(
            boardId: boardId,
            stackId: stackId,
            cardId: cardId,
            id: attachmentId,
            type: type
        ) else {
            throw DeckAPIError.invalidURL
        }
        _ = try await performRequest(url: url, method: "DELETE")
    }

    /// Restores a deleted attachment. Only `deck_file` attachments can be restored; Deck refuses (403) for `file`
    /// ones, whose deletion only unshares the file from the card.
    func restoreAttachment(boardId: Int, stackId: Int, cardId: Int, attachmentId: Int, type: String?) async throws {
        guard let url = attachmentURL(
            boardId: boardId,
            stackId: stackId,
            cardId: cardId,
            id: attachmentId,
            type: type
        )?.appendingPathComponent("restore") else {
            throw DeckAPIError.invalidURL
        }
        _ = try await performRequest(url: url, method: "PUT")
    }
}

// MARK: - Tagged

/// A value fetched from Deck with the ETag the server sent for it.
struct Tagged<Value: Sendable>: Sendable {
    let value: Value
    let etag: String?
}

// MARK: - Request DTOs

private struct APIErrorResponse: Codable {
    let status: Int?
    let message: String
}

private struct CreateBoardRequest: Encodable {
    let title: String
    let color: String
}

private struct UpdateBoardRequest: Encodable {
    let title: String
    let color: String?
    let archived: Bool
}

private struct CreateStackRequest: Encodable {
    let title: String
    let order: Int
}

private struct UpdateStackRequest: Encodable {
    let title: String?
    let order: Int?
}

private struct CreateCardRequest: Encodable {
    let title: String
    let type: String
    let order: Int
    let description: String?
    let duedate: String?
}

/// Body for `PUT /boards/{boardId}/stacks/{stackId}/cards/{cardId}`.
/// See https://github.com/nextcloud/deck/blob/main/docs/API.md (Update card details).
struct UpdateCardRequest: Encodable {
    let title: String
    let description: String
    let type: String
    let owner: String
    let order: Int
    let duedate: String?
    let startdate: String?
    let done: String?

    /// `fallbackOwner` (the signed-in user) is used when the card was decoded without an owner,
    /// because the server rejects an update with an empty one.
    init(card: Card, fallbackOwner: String) {
        self.title = card.title
        self.description = card.description ?? ""
        self.type = card.type ?? "plain"
        self.owner = card.owner.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackOwner
        self.order = card.order
        self.duedate = card.duedate
        self.startdate = card.startdate
        self.done = card.done
    }

    enum CodingKeys: String, CodingKey {
        case title, description, type, owner, order, duedate, startdate, done
    }

    /// Dates are always encoded, as `null` when unset, so the body states exactly what the card should be.
    /// `archived` is deliberately omitted: the server leaves it unchanged, but rejects `true` for an
    /// already-archived card.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(description, forKey: .description)
        try c.encode(type, forKey: .type)
        try c.encode(owner, forKey: .owner)
        try c.encode(order, forKey: .order)
        try c.encode(duedate, forKey: .duedate)
        try c.encode(startdate, forKey: .startdate)
        try c.encode(done, forKey: .done)
    }
}

private struct ReorderCardRequest: Encodable {
    let order: Int
    let stackId: Int
}

private struct AddShareRequest: Encodable {
    let type: Int
    let participant: String
    let permissionEdit: Bool
    let permissionShare: Bool
    let permissionManage: Bool
}

private struct UpdateShareRequest: Encodable {
    let permissionEdit: Bool
    let permissionShare: Bool
    let permissionManage: Bool
}

private struct CommentRequest: Encodable {
    let message: String
}

private struct AssignUserRequest: Encodable {
    let userId: String
    let type: Int
}

private struct LabelIdRequest: Encodable {
    let labelId: Int
}

/// Body for creating and updating a label.
private struct LabelRequest: Encodable {
    let title: String
    let color: String
}

enum DeckAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case notModified
    case badRequest(String)
    /// The app password was rejected: revoked from Nextcloud's security settings, or expired.
    case unauthorized
    case permissionDenied
    case httpStatus(Int)

    private static let sessionEndedMessage =
        "Your Nextcloud session has ended — the app password may have been revoked. Please sign in again."

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid URL"
        case .invalidResponse: "Invalid response"
        case .notModified: "Not modified"
        case let .badRequest(msg): msg
        case .unauthorized: Self.sessionEndedMessage
        case .permissionDenied: "Permission denied"
        case let .httpStatus(code): "HTTP \(code)"
        }
    }
}
