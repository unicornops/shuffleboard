import Foundation
import XCTest
@testable import Shuffleboard

/// The app's String Catalog (#162): it's built into the app, and counts take their plural form. The keys are the
/// ones the app's code uses (`\(count)` of an Int is `%lld`), so a key that changes in the code without its catalog
/// entry fails here as well as in CI's catalog check.
final class LocalizationTests: XCTestCase {
    func testTheCatalogIsBuiltIntoTheApp() {
        XCTAssertEqual(Bundle.main.developmentLocalization, "en")
        XCTAssertTrue(Bundle.main.localizations.contains("en"), "no English localization in \(Bundle.main.bundleURL)")
        XCTAssertNotNil(
            Bundle.main.url(
                forResource: "Localizable",
                withExtension: "stringsdict",
                subdirectory: nil,
                localization: "en"
            ),
            "the plural forms aren't in the app"
        )
    }

    func testCountsTakeTheirPluralForm() {
        XCTAssertEqual(String(localized: "\(1) comments"), "1 comment")
        XCTAssertEqual(String(localized: "\(2) comments"), "2 comments")
        XCTAssertEqual(String(localized: "\(1) attachments"), "1 attachment")
        XCTAssertEqual(String(localized: "\(0) attachments"), "0 attachments")
        XCTAssertEqual(String(localized: "Could not load \(1) attachments."), "Could not load 1 attachment.")
        XCTAssertEqual(String(localized: "\(1) cards are overdue"), "1 card is overdue")
        XCTAssertEqual(String(localized: "\(4) cards are overdue"), "4 cards are overdue")
    }

    func testACountInTheMiddleOfASentenceTakesItsPluralForm() {
        XCTAssertEqual(
            String(localized: "Showing \(1) of \(1) cards. Drag and drop is paused while filtering."),
            "Showing 1 of 1 card. Drag and drop is paused while filtering."
        )
        XCTAssertEqual(
            String(localized: "Showing \(2) of \(12) cards. Drag and drop is paused while filtering."),
            "Showing 2 of 12 cards. Drag and drop is paused while filtering."
        )
    }

    func testRefreshIntervalsSpellOutOne() {
        XCTAssertEqual(AppSettings.refreshIntervalTitle(1), "Every second")
        XCTAssertEqual(AppSettings.refreshIntervalTitle(45), "Every 45 seconds")
        XCTAssertEqual(AppSettings.refreshIntervalTitle(120), "Every 2 minutes")
    }

    func testDeleteConfirmationsAreWholeSentences() {
        XCTAssertEqual(
            DeleteConfirmation.card("Paint"),
            "\u{201c}Paint\u{201d} will be deleted. You can restore it from Deck in your browser until the server "
                + "clears deleted items (after 5 hours by default)."
        )
        XCTAssertTrue(DeleteConfirmation.board("Home").hasPrefix("\u{201c}Home\u{201d} and all its lists and cards"))
    }
}
