import XCTest

/// UI tests for Axo on iPhone and iPad. They run in UI testing mode (in-memory database,
/// non-persistent website data), and pages come from `data:` URLs.
final class AxoiOSUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        // A system alert (such as a freshly booted simulator's own location prompts) must never
        // be granted by a test. XCTest's default handler taps "Allow"; decline instead.
        addUIInterruptionMonitor(withDescription: "System alerts") { alert in
            // XCTest calls interruption monitors on the main thread, while it drives the app.
            MainActor.assumeIsolated {
                for title in ["Don’t Allow", "Don't Allow", "Not Now", "Cancel"] where alert.buttons[title].exists {
                    alert.buttons[title].tap()
                    return true
                }
                return false
            }
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

    /// The iPhone's address (#181), whose value is the shown page's full address.
    @MainActor
    private func address(in app: XCUIApplication) -> XCUIElement {
        app.buttons["mobileAddressBar"]
    }

    /// Waits for the page to finish loading: the bar's loading line goes.
    @MainActor
    private func waitUntilLoaded(_ app: XCUIApplication) {
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.progressIndicators["Loading"])
        waitForExpectations(timeout: 15)
    }

    /// Picks an item from the ••• menu.
    @MainActor
    private func chooseFromMenu(_ title: String, in app: XCUIApplication) {
        app.buttons["pageMenuButton"].tap()
        let item = app.buttons[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "No \(title) in the menu")
        item.tap()
    }

    @MainActor
    func testOpeningAPageShowsItAndListsItsTab() throws {
        let app = launchApp()
        openPage("data:text/html,<title>Pond</title><p>Axolotls</p>", in: app)

        XCTAssertTrue(app.descendants(matching: .any)["webContent"].waitForExistence(timeout: 10))
        let address = address(in: app)
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        XCTAssertTrue((address.value as? String)?.hasPrefix("data:text/html") == true, "\(address.value ?? "none")")

        let sidebar = showSidebar(in: app)
        XCTAssertTrue(sidebar.staticTexts["Pond"].waitForExistence(timeout: 10))
    }

    /// The iPhone's bar (#181): the address edits in the command bar, the ••• menu goes back
    /// and forward nearest the thumb, and moves the bar to the top and back.
    @MainActor
    func testTheMenuGoesBackAndMovesTheAddressBar() throws {
        let app = launchApp()
        openPage("data:text/html,<title>First</title>", in: app)
        let address = address(in: app)
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        // Let the first page finish, or the second replaces it and there's nothing to go back to.
        waitUntilLoaded(app)

        address.tap()
        let field = app.textFields["commandField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "The address edits in the command bar")
        field.typeText("data:text/html,<title>Second</title>\n")
        expectation(for: NSPredicate(format: "value CONTAINS 'Second'"), evaluatedWith: address)
        waitForExpectations(timeout: 10)
        waitUntilLoaded(app)

        chooseFromMenu("Back", in: app)
        expectation(for: NSPredicate(format: "value CONTAINS 'First'"), evaluatedWith: address)
        waitForExpectations(timeout: 10)
        app.buttons["pageMenuButton"].tap()
        XCTAssertTrue(app.buttons["Forward"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Forward"].firstMatch.isEnabled, "Forward goes to Second again")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "iPhone menu"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["Forward"].firstMatch.tap()
        expectation(for: NSPredicate(format: "value CONTAINS 'Second'"), evaluatedWith: address)
        waitForExpectations(timeout: 10)

        // The address bar moves to the top, and back.
        let bottomY = address.frame.midY
        chooseFromMenu("Address Bar at Top", in: app)
        expectation(for: NSPredicate { _, _ in address.frame.midY < bottomY - 200 }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        chooseFromMenu("Address Bar at Bottom", in: app)
        expectation(for: NSPredicate { _, _ in abs(address.frame.midY - bottomY) < 2 }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
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
