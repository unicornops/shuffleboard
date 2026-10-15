import Foundation
import XCTest
@testable import Shuffleboard

// MARK: - Test server

/// The real Nextcloud server with Deck that `scripts/e2e/start-server.sh` starts, for the end-to-end tests.
///
/// Its address and its users' login passwords come from the environment (`E2E_SERVER_URL`,
/// `E2E_ALICE_PASSWORD`, …); `xcodebuild test` passes them on when they are prefixed with `TEST_RUNNER_`.
/// Without them the tests that need a server are skipped, so the normal unit test run doesn't need one.
struct TestServer: Sendable {
    let url: URL
    /// Nextcloud version, as the server reported it when it was set up (for test failure messages).
    let version: String
    /// The Deck release on the server, e.g. `1.19.0`.
    let deckVersion: String
    /// Whether the server has the Activity app, which cards' history comes from (#164). One test job turns it off.
    let hasActivity: Bool
    private let passwords: [String: String]

    static let alice = "alice"
    static let bob = "bob"

    /// The server from the environment, or `XCTSkip` when there is none.
    static func require() throws -> TestServer {
        let env = ProcessInfo.processInfo.environment
        guard let value = env["E2E_SERVER_URL"], let url = URL(string: value) else {
            throw XCTSkip("No test server: run scripts/e2e/start-server.sh and pass E2E_SERVER_URL (see README)")
        }
        var passwords: [String: String] = [:]
        for user in [alice, bob] {
            guard let password = env["E2E_\(user.uppercased())_PASSWORD"] else {
                throw XCTSkip("No password for \(user) on the test server")
            }
            passwords[user] = password
        }
        let version = "Nextcloud \(env["E2E_NEXTCLOUD_VERSION"] ?? "?"), Deck \(env["E2E_DECK_VERSION"] ?? "?")"
        return TestServer(
            url: url,
            version: version,
            deckVersion: env["E2E_DECK_VERSION"] ?? "",
            hasActivity: env["E2E_ACTIVITY"] != "0",
            passwords: passwords
        )
    }

    /// Whether the server's Deck is `version` or newer, for behaviour that changed between Deck releases.
    func deck(atLeast version: String) -> Bool {
        let have = deckVersion.split(separator: ".").map { Int($0) ?? 0 }
        let want = version.split(separator: ".").map { Int($0) ?? 0 }
        return !have.lexicographicallyPrecedes(want)
    }

    /// `user`'s login password: only for creating app passwords and the browser sign-in page.
    func password(of user: String) -> String {
        passwords[user] ?? ""
    }

    /// A new app password for `user`, as a client gets one after signing in
    /// (`GET /ocs/v2.php/core/getapppassword` with the login password).
    func appPassword(for user: String) async throws -> String {
        var components = URLComponents(
            url: url.appendingPathComponent("ocs/v2.php/core/getapppassword"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "format", value: "json")]
        guard let requestURL = components?.url else { throw DeckAPIError.invalidURL }
        var request = URLRequest(url: requestURL)
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.basicAuth(user, password(of: user)), forHTTPHeaderField: "Authorization")
        // Its own session: a cookie from this sign-in must not carry over to the client under test.
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DeckAPIError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(OCSResponse<AppPasswordPayload>.self, from: data).ocs.data.apppassword
    }

    /// Credentials with a new app password for `user`.
    func credentials(for user: String) async throws -> Credentials {
        try await Credentials(serverURL: url, username: user, appPassword: appPassword(for: user))
    }

    /// A Deck client signed in as `user` with a new app password, using its own session unless given one.
    func api(for user: String, session: URLSession = URLSession(configuration: .ephemeral)) async throws -> DeckAPI {
        let creds = try await credentials(for: user)
        return DeckAPI(
            serverURL: creds.serverURL,
            username: creds.username,
            appPassword: creds.appPassword,
            session: session
        )
    }

    static func basicAuth(_ user: String, _ password: String) -> String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    private struct AppPasswordPayload: Decodable {
        let apppassword: String
    }
}

// MARK: - Test data

/// A title no other test or run uses, so tests can share one server.
func uniqueTitle(_ prefix: String) -> String {
    "\(prefix) \(UUID().uuidString.prefix(8))"
}

/// Runs `body` with a new board, then deletes the board whether or not `body` succeeded.
func withTemporaryBoard<Result: Sendable>(
    _ api: DeckAPI,
    title: String = uniqueTitle("E2E board"),
    isolation _: isolated (any Actor)? = #isolation,
    _ body: (Board) async throws -> Result
) async throws
    -> Result {
    let board = try await api.createBoard(title: title, color: "31CC7C")
    do {
        let result = try await body(board)
        try? await api.deleteBoard(id: board.id)
        return result
    } catch {
        try? await api.deleteBoard(id: board.id)
        throw error
    }
}

extension [Stack] {
    /// The stack holding the active card `cardId`, if any.
    func stack(holding cardId: Int) -> Stack? {
        first { $0.cards?.contains { $0.id == cardId && !$0.archived } == true }
    }
}

// MARK: - Browser sign-in

/// Approves a Login Flow v2 sign-in the way a person does in the browser: signs in on the server's login page,
/// then grants the app access. Test-only: it reads the web pages, which are not an API and can change.
enum LoginFlowBrowser {
    enum Failure: Error, CustomStringConvertible {
        case missing(String, page: URL?)
        case notSignedIn(URL?)
        case status(Int, URL?)

        var description: String {
            switch self {
            case let .missing(what, page): "No \(what) on \(page?.absoluteString ?? "?")"
            case let .notSignedIn(page): "Signing in did not reach the grant page, ended at \(page?.absoluteString ?? "?")"
            case let .status(code, page): "HTTP \(code) from \(page?.absoluteString ?? "?")"
            }
        }
    }

    static func approve(loginURL: URL, on server: TestServer, as user: String) async throws {
        let browser = ScriptedBrowser(origin: server.url)

        // The flow's landing page redirects to the page that asks the user to sign in, with the flow's state.
        let flow = try await browser.get(loginURL)
        let state = try flowState(in: flow)

        // Sign in; the login form then redirects to the grant page.
        let login = try await browser.get(server.url.appendingPathComponent("index.php/login"))
        let redirect = URLComponents(string: state.loginRedirectUrl)
        let grant = try await browser.post(
            server.url.appendingPathComponent("index.php/login"),
            form: [
                "user": user,
                "password": server.password(of: user),
                "requesttoken": requestToken(in: login),
                "redirect_url": (redirect?.percentEncodedPath ?? "") +
                    (redirect?.percentEncodedQuery.map { "?\($0)" } ?? ""),
            ]
        )
        guard grant.url.path.hasSuffix("/login/v2/grant") else { throw Failure.notSignedIn(grant.url) }

        // Grant access: the flow's poll then returns the new app password.
        _ = try await browser.post(
            server.url.appendingPathComponent("index.php/login/v2/grant"),
            form: ["stateToken": state.stateToken, "requesttoken": requestToken(in: grant)]
        )
    }

    private struct LoginFlowAuth: Decodable {
        let stateToken: String
        let loginRedirectUrl: String
    }

    /// The flow's state token and where to go after signing in: page data in newer Nextcloud versions, a form on
    /// the page in older ones (32).
    private static func flowState(in page: ScriptedBrowser.Page) throws -> LoginFlowAuth {
        if let state = try? decodeInitialState(LoginFlowAuth.self, named: "core-loginFlowAuth", in: page) {
            return state
        }
        guard let token = page.html.firstMatch(of: #/name="stateToken" value="([^"]+)"/#),
              let grant = page.html.firstMatch(of: #/id="login-form" action="([^"]+)"/#) else {
            throw Failure.missing("login flow state", page: page.url)
        }
        return LoginFlowAuth(
            stateToken: String(token.1),
            loginRedirectUrl: String(grant.1).replacingOccurrences(of: "&amp;", with: "&")
        )
    }

    /// The CSRF token Nextcloud puts on every page's `<head>`.
    private static func requestToken(in page: ScriptedBrowser.Page) throws -> String {
        guard let match = page.html.firstMatch(of: #/data-requesttoken="([^"]+)"/#) else {
            throw Failure.missing("request token", page: page.url)
        }
        return String(match.1)
    }

    /// Nextcloud passes page data to its scripts as base64 JSON in hidden inputs.
    private static func decodeInitialState<Value: Decodable>(
        _: Value.Type,
        named name: String,
        in page: ScriptedBrowser.Page
    ) throws
        -> Value {
        let html = page.html
        guard let start = html.range(of: "id=\"initial-state-\(name)\" value=\""),
              let end = html[start.upperBound...].firstIndex(of: "\""),
              let data = Data(base64Encoded: String(html[start.upperBound ..< end])) else {
            throw Failure.missing(name, page: page.url)
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }
}

/// Just enough of a browser for Nextcloud's sign-in pages: keeps cookies and follows redirects itself, so it
/// behaves the same whatever URLSession does with cookies set on a redirect.
actor ScriptedBrowser {
    struct Page {
        let html: String
        let url: URL
    }

    private let origin: String
    private let session: URLSession
    private var cookies: [String: String] = [:]

    init(origin: URL) {
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        components?.path = ""
        self.origin = components?.string ?? origin.absoluteString
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        self.session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    func get(_ url: URL) async throws -> Page {
        try await load(URLRequest(url: url))
    }

    func post(_ url: URL, form: [String: String]) async throws -> Page {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Nextcloud only accepts the login form from its own origin.
        request.setValue(origin, forHTTPHeaderField: "Origin")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        // `URLComponents` leaves "+" alone, which a form body would read as a space.
        request.httpBody = Data((body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        return try await load(request)
    }

    private func load(_ first: URLRequest) async throws -> Page {
        var request = first
        for _ in 0 ..< 10 {
            guard let url = request.url else { break }
            if !cookies.isEmpty {
                request.setValue(
                    cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "),
                    forHTTPHeaderField: "Cookie"
                )
            }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LoginFlowBrowser.Failure.status(0, url) }
            remember(HTTPCookie.cookies(withResponseHeaderFields: headers(of: http), for: url))

            switch http.statusCode {
            case 200 ..< 300:
                return Page(html: String(decoding: data, as: UTF8.self), url: url)
            case 301 ... 303, 307, 308:
                guard let location = http.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: url)?.absoluteURL else {
                    throw LoginFlowBrowser.Failure.status(http.statusCode, url)
                }
                let keepsMethod = http.statusCode == 307 || http.statusCode == 308
                var redirected = URLRequest(url: next)
                if keepsMethod {
                    redirected.httpMethod = request.httpMethod
                    redirected.httpBody = request.httpBody
                }
                request = redirected
            default:
                throw LoginFlowBrowser.Failure.status(http.statusCode, url)
            }
        }
        throw LoginFlowBrowser.Failure.status(310, request.url)
    }

    private func remember(_ received: [HTTPCookie]) {
        for cookie in received {
            if let expires = cookie.expiresDate, expires < Date() {
                cookies[cookie.name] = nil
            } else {
                cookies[cookie.name] = cookie.value
            }
        }
    }

    private func headers(of response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for case let (name as String, value as String) in response.allHeaderFields {
            headers[name] = value
        }
        return headers
    }
}

/// Hands every redirect back to `ScriptedBrowser` instead of following it.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
