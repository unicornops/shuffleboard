import Foundation
import XCTest

// MARK: - Test server

/// The test server from `scripts/e2e/start-server.sh`, as `TestServer` in the unit tests (UI tests can't import
/// the app, so this is a small copy). The tests are skipped without it.
struct UITestServer: Sendable {
    let url: URL
    /// The server's Deck version, e.g. "1.18.5".
    let deckVersion: String
    private let passwords: [String: String]

    static let alice = "alice"
    static let bob = "bob"

    static func require() throws -> UITestServer {
        let env = ProcessInfo.processInfo.environment
        guard let value = env["E2E_SERVER_URL"], let url = URL(string: value),
              let alice = env["E2E_ALICE_PASSWORD"], let bob = env["E2E_BOB_PASSWORD"] else {
            throw XCTSkip("No test server: run scripts/e2e/start-server.sh and pass E2E_SERVER_URL (see README)")
        }
        return UITestServer(
            url: url,
            deckVersion: env["E2E_DECK_VERSION"] ?? "",
            passwords: [Self.alice: alice, Self.bob: bob]
        )
    }

    /// Whether the server's Deck is `version` or newer, for behaviour that changed between Deck releases.
    func deck(atLeast version: String) -> Bool {
        let have = deckVersion.split(separator: ".").map { Int($0) ?? 0 }
        let want = version.split(separator: ".").map { Int($0) ?? 0 }
        return !have.lexicographicallyPrecedes(want)
    }

    /// The account id the app shows, e.g. `alice@localhost:8443`, or `alice@localhost:8443/nextcloud` for a server
    /// at a sub-path.
    func accountId(_ user: String) -> String {
        let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        return "\(user)@\(url.host ?? "")" + (url.port.map { ":\($0)" } ?? "") + path
    }

    /// A new app password for `user`, as a client gets one after signing in.
    func appPassword(for user: String) async throws -> String {
        let json = try await request(
            "GET",
            "ocs/v2.php/core/getapppassword?format=json",
            user: user,
            secret: passwords[user] ?? ""
        )
        guard let password = ((json as? [String: Any])?["ocs"] as? [String: Any])
            .flatMap({ $0["data"] as? [String: Any] })?["apppassword"] as? String else {
            throw UITestError("No app password for \(user)")
        }
        return password
    }

    /// A Deck API client for `user` with its own app password, for setting up and checking what the UI did.
    func client(for user: String) async throws -> DeckClient {
        try await DeckClient(server: self, user: user, appPassword: appPassword(for: user))
    }

    /// Sends a request and returns the decoded JSON (nil for an empty body); throws for any status but 2xx.
    func request(
        _ method: String,
        _ path: String,
        user: String,
        secret: String,
        body: Any? = nil
    ) async throws
        -> Any? {
        guard let requestURL = URL(string: path, relativeTo: url.appendingPathComponent("/")) else {
            throw UITestError("Bad path \(path)")
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Basic " + Data("\(user):\(secret)".utf8).base64EncodedString(),
            forHTTPHeaderField: "Authorization"
        )
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw UITestError("\(method) \(path): HTTP \(status)", status: status)
        }
        return data.isEmpty ? nil : try JSONSerialization.jsonObject(with: data)
    }
}

struct UITestError: Error, CustomStringConvertible {
    let description: String
    var status = 0

    init(_ description: String, status: Int = 0) {
        self.description = description
        self.status = status
    }
}

/// The few Deck API calls the UI tests need to set up boards and check the server afterwards.
struct DeckClient: Sendable {
    let server: UITestServer
    let user: String
    let appPassword: String

    private func call(_ method: String, _ path: String, _ body: Any? = nil) async throws -> Any? {
        try await server.request(
            method,
            "index.php/apps/deck/api/v1.0/" + path,
            user: user,
            secret: appPassword,
            body: body
        )
    }

    func createBoard(_ title: String) async throws -> Int {
        try await Self.id(call("POST", "boards", ["title": title, "color": "2E8B57"]))
    }

    func createStack(board: Int, _ title: String, order: Int) async throws -> Int {
        try await Self.id(call("POST", "boards/\(board)/stacks", ["title": title, "order": order]))
    }

    func createCard(board: Int, stack: Int, _ title: String, order: Int = 0) async throws -> Int {
        try await Self.id(call(
            "POST",
            "boards/\(board)/stacks/\(stack)/cards",
            ["title": title, "type": "plain", "order": order]
        ))
    }

    /// Shares `board` with the user `participant`, who may then be assigned and mentioned.
    func share(board: Int, with participant: String) async throws {
        _ = try await call("POST", "boards/\(board)/acl", [
            "type": 0, "participant": participant,
            "permissionEdit": true, "permissionShare": false, "permissionManage": false,
        ])
    }

    func createLabel(board: Int, _ title: String, color: String = "FF7A66") async throws -> Int {
        try await Self.id(call("POST", "boards/\(board)/labels", ["title": title, "color": color]))
    }

    /// The titles of the board's labels.
    func labels(board: Int) async throws -> [String] {
        try await (self.board(board)["labels"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
    }

    /// The id of the (not deleted) board titled `title`, if any.
    func boardId(titled title: String) async throws -> Int? {
        let boards = try await call("GET", "boards") as? [[String: Any]] ?? []
        return boards.first { $0["title"] as? String == title && $0["deletedAt"] as? Int ?? 0 == 0 }?["id"] as? Int
    }

    /// Attaches a small text file as a `deck_file` attachment (stored by Deck, as older clients did); returns its id.
    func attachDeckFile(board: Int, stack: Int, card: Int, name: String) async throws -> Int {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = ""
        for (field, value) in [("data", name), ("type", "deck_file")] {
            body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"\r\n\r\n\(value)\r\n"
        }
        body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n"
            + "Content-Type: text/plain\r\n\r\nA UI test attachment\r\n--\(boundary)--\r\n"
        var request = URLRequest(url: server.url.appendingPathComponent(attachmentsPath(board, stack, card)))
        request.httpMethod = "POST"
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Basic " + Data("\(user):\(appPassword)".utf8).base64EncodedString(),
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = Data(body.utf8)
        let (data, _) = try await URLSession(configuration: .ephemeral).data(for: request)
        return try Self.id(JSONSerialization.jsonObject(with: data))
    }

    /// The card's attachments (API v1.1), deleted `deck_file` ones included.
    func attachments(board: Int, stack: Int, card: Int) async throws -> [[String: Any]] {
        try await server.request(
            "GET",
            attachmentsPath(board, stack, card),
            user: user,
            secret: appPassword
        ) as? [[String: Any]] ?? []
    }

    private func attachmentsPath(_ board: Int, _ stack: Int, _ card: Int) -> String {
        "index.php/apps/deck/api/v1.1/boards/\(board)/stacks/\(stack)/cards/\(card)/attachments"
    }

    func deleteBoard(_ id: Int) async {
        _ = try? await call("DELETE", "boards/\(id)")
    }

    func board(_ id: Int) async throws -> [String: Any] {
        try await call("GET", "boards/\(id)") as? [String: Any] ?? [:]
    }

    /// Whether the board is soft-deleted. Reads the board list: a deleted board itself answers 403.
    func isDeleted(_ id: Int) async throws -> Bool {
        let boards = try await call("GET", "boards") as? [[String: Any]] ?? []
        guard let board = boards.first(where: { $0["id"] as? Int == id }) else { throw UITestError("No board \(id)") }
        return board["deletedAt"] as? Int ?? 0 > 0
    }

    /// The board's lists, each with its cards.
    func stacks(board: Int) async throws -> [[String: Any]] {
        try await call("GET", "boards/\(board)/stacks") as? [[String: Any]] ?? []
    }

    /// The card titled `title` as the server has it, if any.
    func card(titled title: String, board: Int) async throws -> [String: Any]? {
        try await stacks(board: board).flatMap { $0["cards"] as? [[String: Any]] ?? [] }
            .first { $0["title"] as? String == title }
    }

    /// The title of the list holding the card titled `card`, if any.
    func list(holding card: String, board: Int) async throws -> String? {
        try await stacks(board: board).first { stack in
            (stack["cards"] as? [[String: Any]] ?? []).contains { $0["title"] as? String == card }
        }?["title"] as? String
    }

    /// The titles of the active cards in the list titled `list`, in board order.
    func titles(inList list: String, board: Int) async throws -> [String] {
        let stack = try await stacks(board: board).first { $0["title"] as? String == list }
        let cards = (stack?["cards"] as? [[String: Any]] ?? []).filter { ($0["archived"] as? Bool) != true }
        return cards
            .sorted { ($0["order"] as? Int ?? 0, $0["id"] as? Int ?? 0) < (
                $1["order"] as? Int ?? 0,
                $1["id"] as? Int ?? 0
            ) }
            .compactMap { $0["title"] as? String }
    }

    /// True if the app password still works, false once it has been revoked.
    func isValid() async throws -> Bool {
        do {
            _ = try await call("GET", "boards")
            return true
        } catch let error as UITestError where error.status == 401 {
            return false
        }
    }

    private static func id(_ json: Any?) throws -> Int {
        guard let id = (json as? [String: Any])?["id"] as? Int else { throw UITestError("No id in \(String(describing: json))") }
        return id
    }
}

func uniqueTitle(_ prefix: String) -> String {
    "\(prefix) \(UUID().uuidString.prefix(6))"
}

// MARK: - Launching the app

/// What a UI test signed the app in with, to check on the server afterwards.
struct LaunchedAccount {
    let user: String
    let appPassword: String
}

@MainActor
extension XCUIApplication {
    /// Launches the app signed in to `server` as `users` (the first is active), with credentials kept in memory
    /// (see `UITestLaunch` in the app). No users shows the sign-in screen.
    @discardableResult
    func launch(
        on server: UITestServer,
        as users: [String],
        appearance: String? = nil
    ) async throws
        -> [LaunchedAccount] {
        var accounts: [LaunchedAccount] = []
        for user in users {
            try await accounts.append(LaunchedAccount(user: user, appPassword: server.appPassword(for: user)))
        }
        let credentials = accounts.map {
            ["serverURL": server.url.absoluteString, "username": $0.user, "appPassword": $0.appPassword]
        }
        let json = try JSONSerialization.data(withJSONObject: credentials)
        launchEnvironment["SHUFFLEBOARD_UITEST_ACCOUNTS"] = String(decoding: json, as: UTF8.self)
        if let appearance {
            launchEnvironment["SHUFFLEBOARD_UITEST_APPEARANCE"] = appearance
        }
        launch()
        XCTAssertTrue(windows.firstMatch.waitForExistence(timeout: 20), "The app's window did not open")
        return accounts
    }

    /// Any element with this accessibility identifier or label.
    func element(_ name: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: name).firstMatch
    }

    /// The first element of `type` whose identifier, label, title or placeholder is `name`.
    func find(_ type: XCUIElement.ElementType, _ name: String) -> XCUIElement {
        descendants(matching: type).matching(
            NSPredicate(
                format: "identifier == %@ OR label == %@ OR title == %@ OR placeholderValue == %@",
                name,
                name,
                name,
                name
            )
        ).firstMatch
    }

    /// Opens a board from the sidebar.
    func openBoard(_ title: String) {
        element("board: \(title)").waitToAppear("Board \(title) not in the sidebar", timeout: 20).click()
    }

    func card(_ title: String) -> XCUIElement {
        element("card: \(title)")
    }

    func list(_ title: String) -> XCUIElement {
        element("list: \(title)")
    }
}

extension XCUIElement {
    /// Waits for the element and fails the test if it doesn't appear.
    @MainActor
    @discardableResult
    func waitToAppear(
        _ message: String = "",
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    )
        -> XCUIElement {
        XCTAssertTrue(
            waitForExistence(timeout: timeout),
            message.isEmpty ? "\(self) did not appear" : message,
            file: file,
            line: line
        )
        return self
    }

    /// Replaces a text field's contents.
    @MainActor
    func replaceText(with text: String) {
        click()
        typeKey("a", modifierFlags: .command)
        typeText(text)
    }
}

/// Polls `condition` until it holds or `timeout` passes; for checking the server after a UI action.
func eventually(
    timeout: TimeInterval = 15,
    _ message: String,
    isolation _: isolated (any Actor)? = #isolation,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async throws -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await condition() {
            return
        }
        try await Task.sleep(nanoseconds: 500_000_000)
    }
    XCTFail(message, file: file, line: line)
}

// MARK: - Taking the server away

/// Takes the test server off the network and brings it back (#156), through the admin API of the Caddy in front of
/// it (see `scripts/e2e/start-server.sh`): while it's away, connections to the server are refused, as when it's down.
/// Tests that need it are skipped without `E2E_CADDY_ADMIN`.
struct ServerSwitch: Sendable {
    let admin: URL

    static func require() throws -> ServerSwitch {
        guard let value = ProcessInfo.processInfo.environment["E2E_CADDY_ADMIN"], let admin = URL(string: value) else {
            throw XCTSkip("No E2E_CADDY_ADMIN: restart the server with scripts/e2e/start-server.sh")
        }
        return ServerSwitch(admin: admin)
    }

    /// Stops serving the server, keeping the rest of Caddy's configuration (the admin API among it); returns the
    /// configuration to pass to `bringBack(_:)`.
    func takeAway() async throws -> Data {
        let (config, _) = try await URLSession.shared.data(from: admin.appendingPathComponent("config/"))
        guard var json = try JSONSerialization.jsonObject(with: config) as? [String: Any],
              var apps = json["apps"] as? [String: Any] else {
            throw UITestError("Unexpected Caddy configuration")
        }
        apps["http"] = nil
        json["apps"] = apps
        try await load(JSONSerialization.data(withJSONObject: json))
        return config
    }

    func bringBack(_ config: Data) async throws {
        try await load(config)
    }

    private func load(_ config: Data) async throws {
        var request = URLRequest(url: admin.appendingPathComponent("load"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = config
        let (body, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UITestError("Caddy didn't load the configuration: \(String(decoding: body, as: UTF8.self))")
        }
    }
}
