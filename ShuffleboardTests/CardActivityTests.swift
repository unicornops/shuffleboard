import Foundation
import XCTest
@testable import Shuffleboard

/// A card's history (#164): reading the Activity app's events, the requests for them, and a server without it.
final class CardActivityTests: XCTestCase {
    private var api: DeckAPI!

    override func setUp() {
        StubURLProtocol.reset()
        api = DeckAPI(serverURL: testServer, username: "rob", appPassword: "pw", session: StubURLProtocol.session())
    }

    override func tearDown() {
        StubURLProtocol.reset()
    }

    /// A move, as Deck sends it: the rich subject is a list, with the user, card and lists as parameters.
    private static let moved = """
    {"activity_id": 31, "app": "deck", "type": "deck", "user": "alice",
     "datetime": "2026-10-15T09:12:44+00:00",
     "subject": "Alice Example has moved the card Plan from list To do to Done",
     "subject_rich": ["{user} has moved the card {card} from list {stackBefore} to {stack}", {
        "user": {"type": "user", "id": "alice", "name": "Alice Example"},
        "card": {"type": "highlight", "id": "12", "name": "Plan"},
        "stackBefore": {"type": "highlight", "id": "3", "name": "To do"},
        "stack": {"type": "highlight", "id": 4, "name": "Done"}}],
     "object_type": "deck_card", "object_id": 12, "object_name": "Plan"}
    """

    private static func page(_ events: String...) -> String {
        #"{"ocs": {"meta": {"status": "ok", "statuscode": 200}, "data": ["# + events.joined(separator: ",") + "]}}"
    }

    // MARK: - Reading events

    func testReadsAnEventAsDeckSendsIt() throws {
        let event = try JSONDecoder().decode(CardActivity.self, from: Data(Self.moved.utf8))
        XCTAssertEqual(event.id, 31)
        XCTAssertEqual(event.userId, "alice")
        XCTAssertEqual(event.userName, "Alice Example")
        XCTAssertEqual(event.author, DeckUser(uid: "alice", displayname: "Alice Example"))
        XCTAssertEqual(event.createdAt, Date(timeIntervalSince1970: 1_792_055_564))
        XCTAssertEqual(event.segments, [
            .name("Alice Example"),
            .text(" has moved the card "),
            .name("Plan"),
            .text(" from list "),
            .name("To do"),
            .text(" to "),
            .name("Done"),
        ])
    }

    func testReadsARichSubjectSentAsAnObject() throws {
        let json = """
        {"activity_id": "7", "user": "rob", "subject": "You have created card Plan",
         "subject_rich": {"0": "You have created card {card}", "1": {"card": {"type": "highlight", "name": "Plan"}}}}
        """
        let event = try JSONDecoder().decode(CardActivity.self, from: Data(json.utf8))
        XCTAssertEqual(event.id, 7)
        XCTAssertNil(event.userName, "The subject doesn't name the user")
        XCTAssertEqual(event.segments, [.text("You have created card "), .name("Plan")])
    }

    func testFallsBackToThePlainSubject() throws {
        let noRich = try JSONDecoder().decode(
            CardActivity.self,
            from: Data(#"{"activity_id": 1, "subject": "Something happened", "user": ""}"#.utf8)
        )
        XCTAssertEqual(noRich.segments, [.text("Something happened")])
        XCTAssertNil(noRich.userId, "An empty user is no user")
        XCTAssertNil(noRich.author)

        // PHP sends an empty parameter list as [], not {}.
        let noParameters = try JSONDecoder().decode(
            CardActivity.self,
            from: Data(#"{"activity_id": 2, "subject": "Done", "subject_rich": ["Done", []]}"#.utf8)
        )
        XCTAssertEqual(noParameters.segments, [.text("Done")])
    }

    func testPlaceholdersWithoutANameShowAsNothing() {
        let event = CardActivity(
            id: 1,
            datetime: "",
            userId: nil,
            subject: "",
            richSubject: "{user} set the due date {after} {not a placeholder} and {",
            names: ["user": "Bob"]
        )
        XCTAssertEqual(event.segments, [.name("Bob"), .text(" set the due date  {not a placeholder} and {")])
    }

    // MARK: - Requests

    func testAsksForTheCardsEventsFromTheActivityApp() async throws {
        StubURLProtocol.handler = { _ in .json(Self.page(Self.moved)) }
        let first = try await api.getCardActivity(cardId: 12)
        _ = try await api.getCardActivity(cardId: 12, since: 31, limit: 5)

        let path = "/ocs/v2.php/apps/activity/api/v2/activity/filter"
        XCTAssertEqual(StubURLProtocol.requests.map(\.line), [
            "GET \(path)?object_type=deck_card&object_id=12&limit=20",
            "GET \(path)?object_type=deck_card&object_id=12&limit=5&since=31",
        ])
        XCTAssertEqual(StubURLProtocol.requests[0].header("OCS-APIRequest"), "true")
        guard case let .events(events) = first else { return XCTFail("got \(first)") }
        XCTAssertEqual(events.map(\.id), [31])
    }

    func testAServerWithoutTheActivityAppHasNoHistory() async throws {
        // Nextcloud's answer for the API of an app that isn't enabled.
        StubURLProtocol.handler = { _ in
            .json(
                #"{"ocs": {"meta": {"status": "failure", "statuscode": 998, "message": "Invalid query"}}}"#,
                status: 404
            )
        }
        let page = try await api.getCardActivity(cardId: 12)
        XCTAssertEqual(page, .unavailable)
    }

    func testNoMoreEventsIsAnEmptyPage() async throws {
        for status in [204, 304] {
            StubURLProtocol.handler = { _ in .status(status) }
            let page = try await api.getCardActivity(cardId: 12, since: 31)
            XCTAssertEqual(page, .events([]), "HTTP \(status)")
        }
    }

    func testOtherFailuresAreErrors() async {
        StubURLProtocol.handler = { _ in .status(500) }
        do {
            _ = try await api.getCardActivity(cardId: 12)
            XCTFail("expected an error")
        } catch {
            guard case DeckAPIError.httpStatus(500) = error else { return XCTFail("got \(error)") }
        }
    }

    // MARK: - The card sheet

    @MainActor
    func testTheSheetLeavesOutTheHistoryOnceTheServerHasNoActivityApp() async throws {
        StubURLProtocol.handler = { request in
            request.path.hasSuffix("/activity/filter") ? .status(404) : .json("[]")
        }
        let app = AppState(
            credentialStore: InMemoryCredentialStore.signedIn(),
            session: StubURLProtocol.session(),
            openURL: { _ in }
        )
        await waitUntil { !app.isLoading }
        let card = try JSONDecoder().decode(Card.self, from: Data(#"{"id": 12, "title": "Plan"}"#.utf8))
        XCTAssertFalse(app.activityIsUnavailable)

        let page = await app.activity(for: card, since: nil, limit: 20)

        XCTAssertEqual(page, .unavailable)
        XCTAssertTrue(app.activityIsUnavailable)
        XCTAssertNil(app.actionError, "A server without the app isn't an error")
    }
}
