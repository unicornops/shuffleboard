import Foundation
import XCTest
@testable import Shuffleboard

// MARK: - Stub server

/// A canned response from `StubURLProtocol`.
struct StubResponse: Sendable {
    var status = 200
    var body = Data()
    /// Seconds to wait before answering.
    var delay: TimeInterval = 0
    /// Fail the request with this error instead of answering.
    var error: URLError?
    var headers: [String: String] = [:]

    static func json(_ string: String, status: Int = 200, delay: TimeInterval = 0) -> StubResponse {
        StubResponse(status: status, body: Data(string.utf8), delay: delay)
    }

    static func status(_ status: Int) -> StubResponse {
        StubResponse(status: status)
    }
}

/// A request seen by `StubURLProtocol`.
struct RecordedRequest: Sendable {
    let method: String
    let path: String
    let query: String?
    let headers: [String: String]
    let body: Data
    /// Whether the request lets URLSession send and store cookies.
    var handlesCookies = true

    /// The value of header `name`, matched case-insensitively as HTTP requires.
    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var line: String {
        "\(method) \(path)" + (query.map { "?\($0)" } ?? "")
    }

    var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

/// Answers every request from `handler` and records it. Tests run serially, so the shared state is
/// reset in `reset()` (called from `setUp`) rather than being per-test.
final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _handler: @Sendable (RecordedRequest) -> StubResponse = { _ in .status(404) }
    private nonisolated(unsafe) static var _requests: [RecordedRequest] = []

    /// Called on URLSession's threads, so it must be `@Sendable`: it can't touch main-actor test state.
    static var handler: @Sendable (RecordedRequest) -> StubResponse {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    static var requests: [RecordedRequest] {
        lock.withLock { _requests }
    }

    static func reset() {
        lock.withLock {
            _handler = { _ in .status(404) }
            _requests = []
        }
    }

    /// An ephemeral session whose requests all go to the stub.
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            path: request.url?.path ?? "",
            query: request.url?.query,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? Self.read(request.httpBodyStream),
            handlesCookies: request.httpShouldHandleCookies
        )
        let response = Self.lock.withLock { () -> StubResponse in
            Self._requests.append(recorded)
            return Self._handler(recorded)
        }
        // URLSession drives a protocol instance from its own threads and its `client` calls are thread-safe,
        // so answering later from another queue is fine; the box only tells the compiler so.
        let this = UncheckedSendable(value: self)
        DispatchQueue.global().asyncAfter(deadline: .now() + response.delay) {
            let stub = this.value
            if let error = response.error {
                stub.client?.urlProtocol(stub, didFailWithError: error)
                return
            }
            guard let url = stub.request.url,
                  let http = HTTPURLResponse(
                      url: url,
                      statusCode: response.status,
                      httpVersion: nil,
                      headerFields: response.headers
                  ) else { return }
            stub.client?.urlProtocol(stub, didReceive: http, cacheStoragePolicy: .notAllowed)
            stub.client?.urlProtocol(stub, didLoad: response.body)
            stub.client?.urlProtocolDidFinishLoading(stub)
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Mutable state shared between a test and its stub handler, guarded by a lock.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&value) }
    }
}

/// Carries a value the compiler can't prove `Sendable` into a `@Sendable` closure.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

// MARK: - Credentials

/// Keeps credentials in memory so tests never touch the real Keychain.
final class InMemoryCredentialStore: CredentialStore {
    var saved: SavedAccounts
    private(set) var saveCount = 0

    init(_ saved: SavedAccounts = SavedAccounts()) {
        self.saved = saved
    }

    /// The active account's credentials, if any.
    var credentials: Credentials? {
        saved.active
    }

    static func signedIn(_ usernames: String...) -> InMemoryCredentialStore {
        var saved = SavedAccounts()
        for username in usernames.isEmpty ? ["rob"] : usernames {
            saved.add(Credentials(serverURL: testServer, username: username, appPassword: "\(username)-app-password"))
        }
        if let first = saved.accounts.first {
            saved.activate(first.id)
        }
        return InMemoryCredentialStore(saved)
    }

    func load() -> SavedAccounts {
        saved
    }

    func save(_ accounts: SavedAccounts) throws {
        saveCount += 1
        saved = accounts
    }
}

// MARK: - Helpers

let testServer = URL(string: "https://cloud.example")!

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func waitUntil(
    timeout: TimeInterval = 3,
    _ condition: () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("Timed out waiting for condition", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

func sleep(seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

// MARK: - Board cache

/// Keeps the copy of the boards in memory (#156).
final class InMemoryBoardCacheStore: BoardCacheStore {
    var snapshots: [Account.ID: BoardCacheSnapshot] = [:]
    private(set) var saveCount = 0

    init(_ snapshots: [Account.ID: BoardCacheSnapshot] = [:]) {
        self.snapshots = snapshots
    }

    func load(accountId: Account.ID) -> BoardCacheSnapshot? {
        snapshots[accountId]
    }

    func save(_ snapshot: BoardCacheSnapshot, accountId: Account.ID) {
        saveCount += 1
        snapshots[accountId] = snapshot
    }

    func remove(accountId: Account.ID) {
        snapshots[accountId] = nil
    }
}
