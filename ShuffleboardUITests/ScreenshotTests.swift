import XCTest

/// Screenshots of the main screens for the README (#47), in light and dark mode, from the demo data that
/// `scripts/e2e/seed.sh` creates. Runs only when `E2E_SCREENSHOTS` is set; each screenshot is kept in the test
/// results as an attachment named `<screen>-<appearance>`, which `scripts/e2e/export-screenshots.sh` saves.
@MainActor
final class ScreenshotTests: XCTestCase {
    private var server: UITestServer!

    override func setUp() async throws {
        continueAfterFailure = false
        server = try UITestServer.require()
        guard ProcessInfo.processInfo.environment["E2E_SCREENSHOTS"] != nil else {
            throw XCTSkip("Set E2E_SCREENSHOTS to take the README screenshots")
        }
    }

    func testLightScreenshots() async throws {
        try await captureScreens(appearance: "light")
    }

    func testDarkScreenshots() async throws {
        try await captureScreens(appearance: "dark")
    }

    private func captureScreens(appearance: String) async throws {
        let signedOut = XCUIApplication()
        try await signedOut.launch(on: server, as: [], appearance: appearance)
        signedOut.find(.button, "Sign in with browser").waitToAppear()
        keep(signedOut, "sign-in", appearance)
        signedOut.terminate()

        let app = XCUIApplication()
        try await app.launch(on: server, as: [UITestServer.alice], appearance: appearance)
        app.openBoard("Home renovation")
        app.card("Choose paint colours").waitToAppear("Demo data missing: run scripts/e2e/seed.sh")
        // Let avatars, labels and the window settle.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        keep(app, "board", appearance)

        app.card("Choose paint colours").click()
        app.find(.textField, "card title").waitToAppear()
        app.staticTexts["Agreed. Let's order two tins on Friday."].waitToAppear("Comments did not load")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        keep(app, "card", appearance)
        app.find(.button, "Cancel").click()

        app.find(.button, "Sharing").waitToAppear().click()
        app.staticTexts["Bob Example"].waitToAppear()
        try await Task.sleep(nanoseconds: 500_000_000)
        keep(app, "sharing", appearance)
        app.find(.button, "Done").click()
        if PseudoLanguage.isOn {
            try await captureWindowsNotInTheREADME(app, appearance)
        }
        app.terminate()
    }

    /// In the pseudo-language (#162), Settings and About too, to look for text that is cut off.
    private func captureWindowsNotInTheREADME(_ app: XCUIApplication, _ appearance: String) async throws {
        app.typeKey(",", modifierFlags: .command)
        // Settings opens on the tab it was last on.
        app.toolbars.buttons.withText("General").firstMatch.waitToAppear("Settings did not open").click()
        app.element("refresh when activated").waitToAppear("No General settings")
        try await Task.sleep(nanoseconds: 500_000_000)
        keepScreen("settings-general-\(appearance)")
        app.toolbars.buttons.withText("Notifications").firstMatch.click()
        app.element("due date notifications").waitToAppear()
        keepScreen("settings-notifications-\(appearance)")
        app.toolbars.buttons.withText("Updates").firstMatch.click()
        try await Task.sleep(nanoseconds: 500_000_000)
        keepScreen("settings-updates-\(appearance)")
        // Leave Settings on its first tab, where the other tests expect it.
        app.toolbars.buttons.withText("General").firstMatch.click()
        app.typeKey("w", modifierFlags: .command)

        app.menuBars.menuBarItems["Shuffleboard"].click()
        app.menuItems.withText("About Shuffleboard").firstMatch.waitToAppear().click()
        app.find(.button, "Copy Build Info").waitToAppear("About did not open")
        try await Task.sleep(nanoseconds: 500_000_000)
        keepScreen("about-\(appearance)")
        app.typeKey("w", modifierFlags: .command)
    }

    /// Keeps a screenshot of the whole screen, for a window that may not be the first.
    private func keepScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Keeps a screenshot of the app's window in the test results.
    private func keep(_ app: XCUIApplication, _ screen: String, _ appearance: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "\(screen)-\(appearance)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
