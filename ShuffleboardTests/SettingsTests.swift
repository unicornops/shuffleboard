import Foundation
import XCTest
@testable import Shuffleboard

/// The settings in Shuffleboard > Settings… (#165) and what they change.
@MainActor
final class SettingsTests: XCTestCase {
    private let suiteName = "SettingsTests"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { request in
            request.path.hasSuffix("/boards") ? .json(#"[{"id": 1, "title": "One", "archived": false}]"#) : .json("[]")
        }
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        StubURLProtocol.reset()
    }

    private func makeApp() async -> AppState {
        let app = AppState(
            credentialStore: InMemoryCredentialStore.signedIn(),
            session: StubURLProtocol.session(),
            openURL: { _ in }
        )
        await waitUntil { !app.isLoading && !app.boards.isEmpty }
        return app
    }

    private var boardListRequests: Int {
        StubURLProtocol.requests.count { $0.method == "GET" && $0.path.hasSuffix("/boards") }
    }

    // MARK: - Stored values

    func testDefaultsAndStoredValues() {
        XCTAssertEqual(AppSettings.refreshInterval(in: defaults), 60, "every minute by default")
        XCTAssertTrue(AppSettings.refreshesWhenActivated(in: defaults))
        XCTAssertNil(AppSettings.launchAccountId(in: defaults), "the account used last by default")

        defaults.set(300, forKey: AppSettings.refreshIntervalKey)
        defaults.set(false, forKey: AppSettings.refreshWhenActivatedKey)
        defaults.set("alice@cloud.example", forKey: AppSettings.launchAccountKey)
        XCTAssertEqual(AppSettings.refreshInterval(in: defaults), 300)
        XCTAssertFalse(AppSettings.refreshesWhenActivated(in: defaults))
        XCTAssertEqual(AppSettings.launchAccountId(in: defaults), "alice@cloud.example")

        defaults.set(0, forKey: AppSettings.refreshIntervalKey)
        XCTAssertNil(AppSettings.refreshInterval(in: defaults), "never")
        defaults.set(7, forKey: AppSettings.refreshIntervalKey)
        XCTAssertEqual(AppSettings.refreshInterval(in: defaults), 60, "a value not offered counts as the default")
        defaults.set("", forKey: AppSettings.launchAccountKey)
        XCTAssertNil(AppSettings.launchAccountId(in: defaults))
    }

    func testRefreshIntervalTitles() {
        XCTAssertEqual(
            AppSettings.refreshIntervals.map(AppSettings.refreshIntervalTitle),
            ["Every 30 seconds", "Every minute", "Every 5 minutes", "Every 15 minutes", "Never"]
        )
    }

    // MARK: - Behaviour

    func testRefreshesAtTheChosenInterval() async {
        defaults.set(300, forKey: AppSettings.refreshIntervalKey)
        let app = await makeApp()
        let before = boardListRequests
        var waits: [TimeInterval] = []
        await app.refreshPeriodically(defaults: defaults) { seconds in
            waits.append(seconds)
            if waits.count == 3 {
                throw CancellationError()
            }
        }
        XCTAssertEqual(waits, [300, 300, 300])
        XCTAssertEqual(boardListRequests - before, 2, "one check after each wait until cancelled")
    }

    func testAChangedIntervalAppliesFromTheNextWait() async {
        let app = await makeApp()
        var waits: [TimeInterval] = []
        await app.refreshPeriodically(defaults: defaults) { [defaults] seconds in
            waits.append(seconds)
            defaults?.set(waits.count == 1 ? 30 : 0, forKey: AppSettings.refreshIntervalKey)
        }
        XCTAssertEqual(waits, [60, 30], "then never, which ends the loop")
    }

    func testNeverRefreshesInTheBackground() async {
        defaults.set(0, forKey: AppSettings.refreshIntervalKey)
        let app = await makeApp()
        let before = boardListRequests
        var waited = false
        await app.refreshPeriodically(defaults: defaults) { _ in waited = true }
        XCTAssertFalse(waited)
        XCTAssertEqual(boardListRequests, before)
    }

    func testComingToTheFrontChecksForChangesUnlessTurnedOff() async {
        let app = await makeApp()
        var before = boardListRequests
        await app.appDidBecomeActive(defaults: defaults)
        XCTAssertEqual(boardListRequests - before, 1)

        defaults.set(false, forKey: AppSettings.refreshWhenActivatedKey)
        before = boardListRequests
        await app.appDidBecomeActive(defaults: defaults)
        XCTAssertEqual(boardListRequests, before)
    }
}
