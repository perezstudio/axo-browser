import XCTest

/// UI tests for Axo on iPhone and iPad. They run in UI testing mode (in-memory database,
/// non-persistent website data), and pages come from `data:` URLs.
final class AxoiOSUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        // A system alert (such as a freshly booted simulator's own location prompts) must never
        // be granted by a test. XCTest's default handler taps "Allow"; decline instead.
        addUIInterruptionMonitor(withDescription: "System alerts") { alert in
            for title in ["Don’t Allow", "Don't Allow", "Not Now", "Cancel"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AXO_UI_TESTING"] = "1"
        app.launch()
        return app
    }

    /// Opens a page from the command bar, the way New Tab works.
    @MainActor
    private func openPage(_ address: String, in app: XCUIApplication) {
        let newTab = app.buttons["newTabButton"].firstMatch
        XCTAssertTrue(newTab.waitForExistence(timeout: 10))
        // Wait until the window has loaded its Space; a tap during launch can be lost.
        XCTAssertTrue(app.descendants(matching: .any)["sidebarNewTabButton"].waitForExistence(timeout: 10))
        let field = app.textFields["commandField"]
        newTab.tap()
        if !field.waitForExistence(timeout: 5) { newTab.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(address + "\n")
    }

    /// The sidebar, which on iPhone is the first screen and on iPad sits beside the page.
    @MainActor
    private func showSidebar(in app: XCUIApplication) -> XCUIElement {
        let sidebar = app.descendants(matching: .any)["sidebar"]
        if !sidebar.waitForExistence(timeout: 2) {
            // iPhone: the list and the page take turns.
            app.buttons["showTabsButton"].tap()
        }
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        return sidebar
    }

    /// Waits for the page to finish loading: the reload button stops being Stop.
    @MainActor
    private func waitUntilLoaded(_ app: XCUIApplication) {
        expectation(for: NSPredicate(format: "label == 'Reload'"), evaluatedWith: app.buttons["reloadButton"])
        waitForExpectations(timeout: 15)
    }

    @MainActor
    func testOpeningAPageShowsItAndListsItsTab() throws {
        let app = launchApp()
        openPage("data:text/html,<title>Pond</title><p>Axolotls</p>", in: app)

        XCTAssertTrue(app.descendants(matching: .any)["webContent"].waitForExistence(timeout: 10))
        let address = app.textFields["addressField"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        XCTAssertTrue((address.value as? String)?.hasPrefix("data:text/html") == true)
        XCTAssertFalse(app.buttons["backButton"].isEnabled)

        let sidebar = showSidebar(in: app)
        XCTAssertTrue(sidebar.staticTexts["Pond"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testBackAndForwardFollowTheTabsHistory() throws {
        let app = launchApp()
        openPage("data:text/html,<title>First</title>", in: app)
        let address = app.textFields["addressField"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        // Let the first page finish, or the second replaces it and there's nothing to go back to.
        waitUntilLoaded(app)

        address.tap()
        address.typeText("data:text/html,<title>Second</title>\n")
        let back = app.buttons["backButton"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: back)
        waitForExpectations(timeout: 10)

        back.tap()
        expectation(for: NSPredicate(format: "value CONTAINS 'First'"), evaluatedWith: address)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["forwardButton"].isEnabled)
    }

    @MainActor
    func testClosingATabRemovesItFromTheList() throws {
        let app = launchApp()
        openPage("data:text/html,<title>Brief</title>", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["webContent"].waitForExistence(timeout: 10))

        let sidebar = showSidebar(in: app)
        let row = sidebar.staticTexts["Brief"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeLeft()
        app.buttons["Close"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row)
        waitForExpectations(timeout: 5)
    }
}
