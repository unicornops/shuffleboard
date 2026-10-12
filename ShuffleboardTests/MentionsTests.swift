import Foundation
import XCTest
@testable import Shuffleboard

/// @mentions in comments (#163): writing them, suggesting people, and finding them in a message.
final class MentionsTests: XCTestCase {
    private let bob = DeckUser(uid: "bob", displayname: "Bob Builder")
    private let bobby = DeckUser(uid: "bobby.tables", displayname: "Robert Tables")
    private let spaced = DeckUser(uid: "Jane Doe", displayname: "Jane")

    func testTokens() {
        XCTAssertEqual(Mentions.token(for: "bob"), "@bob")
        XCTAssertEqual(Mentions.token(for: "bobby.tables"), "@bobby.tables")
        XCTAssertEqual(Mentions.token(for: "o'neil@example.com"), "@o'neil@example.com")
        XCTAssertEqual(Mentions.token(for: "Jane Doe"), "@\"Jane Doe\"", "ids a bare mention can't hold are quoted")
        XCTAssertEqual(Mentions.token(for: "zoë"), "@\"zoë\"")
    }

    func testTheMentionBeingTyped() {
        XCTAssertEqual(Mentions.query(in: "@"), "")
        XCTAssertEqual(Mentions.query(in: "Thanks @bo"), "bo")
        XCTAssertEqual(Mentions.query(in: "Line one\n@b"), "b")
        XCTAssertNil(Mentions.query(in: "Thanks @bob "), "a space ends it")
        XCTAssertNil(Mentions.query(in: "mail me@example"), "not after a word")
        XCTAssertNil(Mentions.query(in: "No mention"))
    }

    func testSuggestions() {
        let people = [bob, bobby, spaced]
        XCTAssertEqual(Mentions.suggestions(for: "", from: people), people)
        XCTAssertEqual(Mentions.suggestions(for: "bo", from: people), [bob, bobby])
        XCTAssertEqual(Mentions.suggestions(for: "BUILD", from: people), [bob], "any word of the name")
        XCTAssertEqual(Mentions.suggestions(for: "rob", from: people), [bobby])
        XCTAssertEqual(Mentions.suggestions(for: "jane", from: people), [spaced])
        XCTAssertEqual(Mentions.suggestions(for: "x", from: people), [])
        XCTAssertEqual(Mentions.suggestions(for: "", from: people, limit: 2).count, 2)
    }

    func testCompleting() {
        XCTAssertEqual(Mentions.completing("Thanks @bo", with: bob), "Thanks @bob ")
        XCTAssertEqual(Mentions.completing("@", with: spaced), "@\"Jane Doe\" ")
        XCTAssertEqual(Mentions.completing("No mention", with: bob), "No mention")
    }

    func testFindingMentionsInAMessage() {
        let bobMention = CommentMention(mentionId: "bob", mentionDisplayName: "Bob Builder")
        let bobbyMention = CommentMention(mentionId: "bobby.tables", mentionDisplayName: "Robert Tables")
        let janeMention = CommentMention(mentionId: "Jane Doe", mentionDisplayName: "Jane")
        let mentions = [bobMention, bobbyMention, janeMention]
        XCTAssertEqual(
            Mentions.segments(of: "@bob and @bobby.tables, ask @\"Jane Doe\"", mentions: mentions),
            [.mention(bobMention), .text(" and "), .mention(bobbyMention), .text(", ask "), .mention(janeMention)]
        )
        XCTAssertEqual(
            Mentions.segments(of: "Hi @Bob!", mentions: mentions),
            [.text("Hi "), .mention(bobMention), .text("!")],
            "ids ignore case, as on the server"
        )
        XCTAssertEqual(
            Mentions.segments(of: "mail bob@bob or @bobcat", mentions: [bobMention]),
            [.text("mail bob@bob or @bobcat")],
            "not inside a word, and not the start of a longer id"
        )
        XCTAssertEqual(Mentions.segments(of: "@carol", mentions: mentions), [.text("@carol")], "not mentioned")
    }

    func testDecodingACommentWithMentions() throws {
        let json = #"""
        {"id": 3, "message": "Hi @bob", "actorId": "alice", "actorDisplayName": "Alice",
         "creationDateTime": "2026-10-12T10:00:00+00:00",
         "mentions": [{"mentionId": "bob", "mentionType": "user", "mentionDisplayName": "Bob Builder"},
                      {"mentionId": "carol", "mentionType": "user", "mentionDisplayName": ""}]}
        """#
        let comment = try JSONDecoder().decode(CardComment.self, from: Data(json.utf8))
        XCTAssertEqual(comment.mentions.map(\.mentionDisplayName), ["Bob Builder", "carol"], "no name: the id")
        XCTAssertEqual(comment.segments, [.text("Hi "), .mention(comment.mentions[0])])
        let plain = try JSONDecoder().decode(CardComment.self, from: Data(#"{"id": 4, "message": "x"}"#.utf8))
        XCTAssertEqual(plain.mentions, [], "older servers send none")
    }
}
