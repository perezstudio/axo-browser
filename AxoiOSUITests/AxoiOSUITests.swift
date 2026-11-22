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
        // Wait until the window has loaded its Space; a tap during launch can be lost. The tabs
        // view's New Tab card on iPhone, the sidebar's New Tab on iPad.
        let loaded = NSPredicate { _, _ in
            app.buttons["newTabCard"].exists || app.descendants(matching: .any)["sidebarNewTabButton"].exists
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: loaded, object: nil)], timeout: 10), .completed)
        let field = app.textFields["commandField"]
        newTab.tap()
        if !field.waitForExistence(timeout: 5) { newTab.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(address + "\n")
    }

    /// The Space's tabs: on iPhone the tabs view (#182), which the bar's tabs button goes back
    /// to; on iPad the sidebar beside the page.
    @MainActor
    private func showSidebar(in app: XCUIApplication) -> XCUIElement {
        let sidebar = app.descendants(matching: .any)["sidebar"]
        if sidebar.waitForExistence(timeout: 2) { return sidebar }
        let tabsView = app.descendants(matching: .any)["tabsView"]
        if !tabsView.exists { app.buttons["showTabsButton"].tap() }
        XCTAssertTrue(tabsView.waitForExistence(timeout: 5))
        return tabsView
    }

    /// The iPhone's address (#181), whose value is the shown page's full address.
    @MainActor
    private func address(in app: XCUIApplication) -> XCUIElement {
        app.buttons["mobileAddressBar"]
    }

    /// Waits for the page to finish loading: the bar's loading line shows (a page can finish
    /// before it's seen, so that wait is short and may end without it), then goes.
    @MainActor
    private func waitUntilLoaded(_ app: XCUIApplication) {
        let line = app.progressIndicators["Loading"]
        _ = line.waitForExistence(timeout: 2)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: line)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(app.descendants(matching: .any)["webContent"].exists)
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

    /// The iPhone's tabs view (#182): the tabs button goes back to it, a card opens its page,
    /// and a card's × closes its tab while the others stay.
    @MainActor
    func testTheTabsViewOpensAndClosesCards() throws {
        let app = launchApp()
        openPage("data:text/html,<title>One</title>", in: app)
        XCTAssertTrue(address(in: app).waitForExistence(timeout: 10))
        waitUntilLoaded(app)
        app.buttons["showTabsButton"].tap()
        openPage("data:text/html,<title>Two</title>", in: app)
        expectation(for: NSPredicate(format: "value CONTAINS 'Two'"), evaluatedWith: address(in: app))
        waitForExpectations(timeout: 10)
        waitUntilLoaded(app)

        app.buttons["showTabsButton"].tap()
        let tabs = app.descendants(matching: .any)["tabsView"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5), "The page zooms back into the tabs view")
        let cards = tabs.descendants(matching: .any).matching(identifier: "tabCard")
        XCTAssertEqual(cards.count, 2)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Tabs view"
        shot.lifetime = .keepAlways
        add(shot)

        cards.matching(NSPredicate(format: "label == 'One'")).firstMatch.tap()
        expectation(for: NSPredicate(format: "value CONTAINS 'One'"), evaluatedWith: address(in: app))
        waitForExpectations(timeout: 10)

        app.buttons["showTabsButton"].tap()
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        app.buttons["Close Two"].tap()
        expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: cards)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(cards.matching(NSPredicate(format: "label == 'One'")).firstMatch.exists, "The other stays")
    }

    @MainActor
    func testClosingATabRemovesItFromTheList() throws {
        let app = launchApp()
        openPage("data:text/html,<title>Brief</title>", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["webContent"].waitForExistence(timeout: 10))

        let tabs = showSidebar(in: app)
        if tabs.identifier == "sidebar" {
            // iPad: swipe the row to close it.
            let row = tabs.staticTexts["Brief"]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.swipeLeft()
            app.buttons["Close"].tap()
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row)
        } else {
            // iPhone: the card's ×.
            let card = tabs.descendants(matching: .any).matching(identifier: "tabCard").matching(NSPredicate(format: "label == 'Brief'")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 10))
            app.buttons["Close Brief"].tap()
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: card)
        }
        waitForExpectations(timeout: 5)
    }
}
