import Foundation
import XCTest
@testable import Shuffleboard

/// Multiple accounts (#81): what is saved, and switching, adding and signing out of accounts.
@MainActor
final class AccountTests: XCTestCase {
    private nonisolated static let robBoards = #"[{"id": 1, "title": "Rob's", "archived": false}]"#
    private nonisolated static let aliceBoards = #"[{"id": 7, "title": "Alice's", "archived": false}]"#

    override func setUp() async throws {
        StubURLProtocol.reset()
        // Each user's boards, told apart by their Basic auth header; everything else is empty.
        StubURLProtocol.handler = { request in
            guard request.path.hasSuffix("/boards") else { return .json("[]") }
            let isAlice = request.header("Authorization") == Self.basic("alice")
            return .json(isAlice ? Self.aliceBoards : Self.robBoards)
        }
    }

    override func tearDown() async throws {
        StubURLProtocol.reset()
    }

    private nonisolated static func basic(_ username: String) -> String {
        "Basic " + Data("\(username):\(username)-app-password".utf8).base64EncodedString()
    }

    private func makeApp(_ store: InMemoryCredentialStore) async -> AppState {
        let app = AppState(credentialStore: store, session: StubURLProtocol.session(), openURL: { _ in })
        await waitUntil { !app.isLoading && !app.boards.isEmpty }
        return app
    }

    private func credentials(_ username: String, server: URL = testServer) -> Credentials {
        Credentials(serverURL: server, username: username, appPassword: "\(username)-app-password")
    }

    // MARK: - Saved accounts

    func testEarlierSingleAccountFormatStillSignsIn() throws {
        let legacy = #"{"serverURL": "https://cloud.example", "username": "rob", "appPassword": "pw"}"#
        let saved = try JSONDecoder().decode(SavedAccounts.self, from: Data(legacy.utf8))
        XCTAssertEqual(saved.accounts.map(\.id), ["rob@cloud.example"])
        XCTAssertEqual(saved.active?.appPassword, "pw")
    }

    func testSavedAccountsRoundTrip() throws {
        var saved = SavedAccounts()
        saved.add(credentials("rob"))
        saved.add(credentials("alice"))
        saved.activate("rob@cloud.example")
        let decoded = try JSONDecoder().decode(SavedAccounts.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded, saved)
        XCTAssertEqual(decoded.active?.username, "rob")
    }

    func testAccountIdentity() throws {
        let plain = try credentials("rob", server: XCTUnwrap(URL(string: "http://Cloud.Example/nextcloud/")))
        XCTAssertEqual(plain.serverURL.scheme, "https", "always stored as HTTPS")
        XCTAssertEqual(plain.account.id, "rob@cloud.example/nextcloud")
        let other = try credentials("rob", server: XCTUnwrap(URL(string: "https://other.example:8443")))
        XCTAssertEqual(other.account.id, "rob@other.example:8443")
    }

    func testSigningInAgainReplacesTheAccount() {
        var saved = SavedAccounts()
        saved.add(credentials("rob"))
        let replaced = saved.add(Credentials(serverURL: testServer, username: "rob", appPassword: "new"))
        XCTAssertEqual(replaced?.appPassword, "rob-app-password")
        XCTAssertEqual(saved.all.map(\.appPassword), ["new"])
    }

    func testRemovingTheActiveAccountActivatesTheNext() {
        var saved = SavedAccounts()
        saved.add(credentials("rob"))
        saved.add(credentials("alice"))
        saved.remove("alice@cloud.example")
        XCTAssertEqual(saved.active?.username, "rob")
        saved.remove("rob@cloud.example")
        XCTAssertNil(saved.active)
    }

    // MARK: - App

    func testSwitchingAccountsShowsTheirBoards() async throws {
        let store = InMemoryCredentialStore.signedIn("rob", "alice")
        let app = await makeApp(store)
        XCTAssertEqual(app.accounts.map(\.username), ["rob", "alice"])
        XCTAssertEqual(app.boards.map(\.id), [1])

        try await app.switchAccount(to: XCTUnwrap(app.accounts.last))

        XCTAssertEqual(app.activeAccount?.username, "alice")
        XCTAssertEqual(app.boards.map(\.id), [7])
        XCTAssertEqual(app.window.selectedBoardId, 7)
        XCTAssertEqual(store.saved.active?.username, "alice", "remembered for next launch")
    }

    func testOpensTheAccountChosenInSettingsAtLaunch() async throws {
        let store = InMemoryCredentialStore.signedIn("rob", "alice")
        let alice = try XCTUnwrap(store.saved.accounts.last)
        let app = AppState(
            credentialStore: store, session: StubURLProtocol.session(), openURL: { _ in }, launchAccountId: alice.id
        )
        await waitUntil { !app.isLoading && !app.boards.isEmpty }
        XCTAssertEqual(app.activeAccount?.username, "alice")
        XCTAssertEqual(app.boards.map(\.id), [7])

        let signedOut = AppState(
            credentialStore: store, session: StubURLProtocol.session(), openURL: { _ in }, launchAccountId: "gone"
        )
        XCTAssertEqual(signedOut.activeAccount?.username, "rob", "an account that signed out: the one used last")
    }

    func testAddingAnAccountKeepsTheOthers() async throws {
        let store = InMemoryCredentialStore.signedIn("rob")
        let app = await makeApp(store)

        app.addAccount()
        XCTAssertTrue(app.showingLogin)
        try await app.finishSignIn(credentials("alice"))

        XCTAssertFalse(app.showingLogin)
        XCTAssertEqual(app.accounts.map(\.username), ["rob", "alice"])
        XCTAssertEqual(app.activeAccount?.username, "alice")
        XCTAssertEqual(app.boards.map(\.id), [7])
        XCTAssertEqual(store.saved.accounts.count, 2)
    }

    func testCancellingAddAccountReturnsToBoards() async {
        let app = await makeApp(.signedIn("rob"))
        app.addAccount()
        app.cancelAddingAccount()
        XCTAssertFalse(app.showingLogin)
        XCTAssertEqual(app.activeAccount?.username, "rob")
    }

    func testSigningInAgainRevokesTheOldAppPassword() async throws {
        let app = await makeApp(.signedIn("rob"))

        try await app.finishSignIn(Credentials(serverURL: testServer, username: "rob", appPassword: "new"))

        XCTAssertEqual(app.accounts.count, 1)
        await waitUntil {
            StubURLProtocol.requests.contains {
                $0.line == "DELETE /ocs/v2.php/core/apppassword" && $0.header("Authorization") == Self.basic("rob")
            }
        }
    }

    func testSignOutSwitchesToTheNextAccount() async throws {
        let store = InMemoryCredentialStore.signedIn("rob", "alice")
        let app = await makeApp(store)

        await app.signOut()

        XCTAssertTrue(app.isLoggedIn)
        XCTAssertFalse(app.showingLogin)
        XCTAssertEqual(app.accounts.map(\.username), ["alice"])
        XCTAssertEqual(store.saved.accounts.map(\.username), ["alice"])
        await waitUntil { app.boards.map(\.id) == [7] }
        let revoke = try XCTUnwrap(StubURLProtocol.requests.first { $0.path == "/ocs/v2.php/core/apppassword" })
        XCTAssertEqual(revoke.header("Authorization"), Self.basic("rob"), "only the signed-out account is revoked")
    }

    func testRevokedAccountIsDroppedAndTheNextOneShown() async {
        let store = InMemoryCredentialStore.signedIn("rob", "alice")
        let app = await makeApp(store)

        app.endSessionIfUnauthorized(DeckAPIError.unauthorized)

        XCTAssertEqual(app.activeAccount?.username, "alice")
        XCTAssertFalse(app.showingLogin)
        XCTAssertEqual(app.actionError?.hasPrefix("Signed out of rob@cloud.example"), true)
        XCTAssertNil(app.errorMessage)
    }

    func testBoardsFromThePreviousAccountAreIgnored() async throws {
        let store = InMemoryCredentialStore.signedIn("rob", "alice")
        let app = await makeApp(store)
        StubURLProtocol.handler = { request in
            guard request.path.hasSuffix("/boards") else { return .json("[]") }
            let isAlice = request.header("Authorization") == Self.basic("alice")
            return .json(isAlice ? Self.aliceBoards : Self.robBoards, delay: isAlice ? 0 : 0.3)
        }

        let slow = Task { await app.refresh() }
        await sleep(seconds: 0.05)
        try await app.switchAccount(to: XCTUnwrap(app.accounts.last))
        await slow.value

        XCTAssertEqual(app.boards.map(\.id), [7])
    }
}

// MARK: - Keychain

/// Which keychain the credentials go to (#92): the data protection keychain when the build has the entitlement,
/// else the login keychain, and moving them from the login keychain without losing them.
final class KeychainStorageTests: XCTestCase {
    private var items: FakeKeychainItems!
    private var storage: KeychainStorage!

    override func setUp() {
        items = FakeKeychainItems()
        storage = KeychainStorage(items: items)
    }

    private func accounts(_ usernames: String...) -> SavedAccounts {
        var saved = SavedAccounts()
        for username in usernames {
            saved.add(Credentials(serverURL: testServer, username: username, appPassword: "\(username)-pw"))
        }
        return saved
    }

    private func data(_ accounts: SavedAccounts) throws -> Data {
        try JSONEncoder().encode(accounts)
    }

    func testSavesToTheDataProtectionKeychain() throws {
        try storage.save(accounts("rob", "alice"))
        XCTAssertEqual(storage.load(), accounts("rob", "alice"))
        XCTAssertNotNil(items.stored[.dataProtection])
        XCTAssertNil(items.stored[.file])
    }

    func testWithoutTheEntitlementUsesTheLoginKeychain() throws {
        items.hasEntitlement = false
        try storage.save(accounts("rob"))
        XCTAssertEqual(storage.load(), accounts("rob"))
        XCTAssertNotNil(items.stored[.file])
        XCTAssertNil(items.stored[.dataProtection])
    }

    func testMovesCredentialsFromTheLoginKeychain() throws {
        items.stored[.file] = try data(accounts("rob", "alice"))
        XCTAssertEqual(storage.load(), accounts("rob", "alice"), "Signed out by the upgrade")
        let moved = try XCTUnwrap(items.stored[.dataProtection], "Not moved to the data protection keychain")
        XCTAssertEqual(try JSONDecoder().decode(SavedAccounts.self, from: moved), accounts("rob", "alice"))
        XCTAssertNil(items.stored[.file], "Old copy left in the login keychain")
        XCTAssertEqual(storage.load(), accounts("rob", "alice"))
    }

    func testKeepsTheLoginKeychainItemWhenTheMoveFails() throws {
        items.stored[.file] = try data(accounts("rob"))
        items.writeStatus = errSecInteractionNotAllowed
        XCTAssertEqual(storage.load(), accounts("rob"))
        XCTAssertNotNil(items.stored[.file], "Deleted before the new copy was written")

        items.writeStatus = nil
        XCTAssertEqual(storage.load(), accounts("rob"))
        XCTAssertNotNil(items.stored[.dataProtection], "Not moved on the next launch")
        XCTAssertNil(items.stored[.file])
    }

    func testTheDataProtectionItemWinsOverAnOldCopy() throws {
        items.stored[.dataProtection] = try data(accounts("alice"))
        items.stored[.file] = try data(accounts("rob"))
        XCTAssertEqual(storage.load(), accounts("alice"))

        try storage.save(accounts("alice", "bob"))
        XCTAssertNil(items.stored[.file], "Old copy kept after saving")
    }

    func testSavingNoAccountsRemovesBothItems() throws {
        items.stored[.dataProtection] = try data(accounts("alice"))
        items.stored[.file] = try data(accounts("rob"))
        try storage.save(SavedAccounts())
        XCTAssertTrue(items.stored.isEmpty)
        XCTAssertEqual(storage.load(), SavedAccounts())

        items.hasEntitlement = false
        items.stored[.file] = try data(accounts("rob"))
        XCTAssertNoThrow(try storage.save(SavedAccounts()))
        XCTAssertTrue(items.stored.isEmpty)
    }

    func testStaysSignedInWhenDeletingTheOldCopyReachesBothKeychains() throws {
        items.fileDeleteReachesBoth = true
        items.stored[.file] = try data(accounts("rob"))
        XCTAssertEqual(storage.load(), accounts("rob"))
        XCTAssertNil(items.stored[.file])
        XCTAssertEqual(storage.load(), accounts("rob"), "Signed out at the next launch after the move")

        items.stored[.file] = try data(accounts("rob"))
        try storage.save(accounts("rob", "alice"))
        XCTAssertNil(items.stored[.file])
        XCTAssertEqual(storage.load(), accounts("rob", "alice"), "Signed out at the next launch after saving")
    }

    func testAFailedSaveThrows() {
        items.writeStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try storage.save(accounts("rob")))
    }
}

/// Both keychains' credentials item in memory. Without the entitlement, the data protection keychain answers
/// `errSecMissingEntitlement`, as it does for builds without a provisioning profile.
private final class FakeKeychainItems: KeychainItems {
    var stored: [Keychain: Data] = [:]
    var hasEntitlement = true
    /// Makes writes to the data protection keychain fail with this status.
    var writeStatus: OSStatus?
    /// Makes deleting the login keychain item also delete the data protection one, as macOS can.
    var fileDeleteReachesBoth = false

    func read(from keychain: Keychain) -> (OSStatus, Data?) {
        if keychain == .dataProtection, !hasEntitlement {
            return (errSecMissingEntitlement, nil)
        }
        return stored[keychain].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
    }

    func write(_ data: Data, to keychain: Keychain) -> OSStatus {
        if keychain == .dataProtection {
            guard hasEntitlement else { return errSecMissingEntitlement }
            if let writeStatus {
                return writeStatus
            }
        }
        stored[keychain] = data
        return errSecSuccess
    }

    func delete(from keychain: Keychain) -> OSStatus {
        if keychain == .dataProtection, !hasEntitlement {
            return errSecMissingEntitlement
        }
        var removed = stored.removeValue(forKey: keychain) != nil
        if keychain == .file, fileDeleteReachesBoth {
            removed = stored.removeValue(forKey: .dataProtection) != nil || removed
        }
        return removed ? errSecSuccess : errSecItemNotFound
    }
}
