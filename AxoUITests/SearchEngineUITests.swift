import AppKit
import XCTest

/// Search engines (#132): adding a custom engine in Settings › Search, making it a profile's
/// engine in Profiles, and searching with it from the command bar, by default and by keyword.
/// The engine searches a port on this Mac that nothing listens on, so no search leaves the Mac.
final class SearchEngineUITests: XCTestCase {
    override class func setUp() {
        super.setUp()
        AxoUITests.connectRunnerToWindowServer()
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        await MainActor.run { XCUIApplication().terminate() }
        try await super.tearDown()
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = AxoUITests.makeApp()
        app.launch()
        AxoUITests.bringToFront(app)
        XCTAssertTrue(app.descendants(matching: .any)["sidebar"].waitForExistence(timeout: 5))
        return app
    }

    /// The address the shown tab loaded, from the sidebar's address bar.
    @MainActor
    private func shownAddress(in app: XCUIApplication) -> String {
        app.descendants(matching: .any)["sidebarAddressBar"].value as? String ?? ""
    }

    /// Adds "Local Search" (keyword `ls`) searching `http://127.0.0.1:<port>/find?q=%s`.
    @MainActor
    private func addLocalEngine(in app: XCUIApplication, port: UInt16) {
        app.typeKey(",", modifierFlags: .command)
        AxoUITests.selectSettingsPane("search", in: app)
        let new = app.buttons["newSearchEngineButton"]
        XCTAssertTrue(new.waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "searchEngineRow").count, 3, "Google, Bing, and DuckDuckGo")
        new.click()

        let name = app.textFields["searchEngineNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("Local Search")
        app.textFields["searchEngineKeywordField"].click()
        app.textFields["searchEngineKeywordField"].typeText("ls")
        let url = app.textFields["searchEngineURLField"]
        url.click()
        url.typeText("http://127.0.0.1:\(port)/find")
        app.buttons["saveSearchEngineButton"].click()
        XCTAssertTrue(app.descendants(matching: .any)["searchEngineProblem"].waitForExistence(timeout: 5),
                      "A search URL without %s is refused, and says why")
        url.typeText("?q=%s")
        app.buttons["saveSearchEngineButton"].click()
        let row = app.descendants(matching: .any).matching(identifier: "searchEngineRow").matching(NSPredicate(format: "label == 'Local Search'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The new engine is listed")
    }

    @MainActor
    func testACustomEngineSearchesByKeywordAndAsAProfilesEngine() throws {
        let app = launchApp()
        let port = try AxoUITests.closedPort()
        addLocalEngine(in: app, port: port)
        app.typeKey("w", modifierFlags: .command)

        // By keyword, whatever the profile's engine.
        AxoUITests.openPage("ls axolotls", in: app)
        let keyword = NSPredicate { _, _ in self.shownAddress(in: app).contains("127.0.0.1:\(port)/find?q=axolotls") }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: keyword, object: nil)], timeout: 15), .completed,
                       "The keyword searched with Local Search: \(shownAddress(in: app))")

        // As the profile's engine.
        app.typeKey(",", modifierFlags: .command)
        AxoUITests.selectSettingsPane("profiles", in: app)
        let google = app.radioButtons["Google"]
        XCTAssertTrue(google.waitForExistence(timeout: 5))
        XCTAssertEqual(google.value as? Int, 1, "Profiles search with Google until they pick another")
        app.radioButtons["Local Search"].click()
        let chosen = NSPredicate(format: "value == 1")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: chosen, object: app.radioButtons["Local Search"])], timeout: 5), .completed)
        app.typeKey("w", modifierFlags: .command)

        AxoUITests.openPage("pond life", in: app)
        let plain = NSPredicate { _, _ in self.shownAddress(in: app).contains("127.0.0.1:\(port)/find?q=pond%20life") }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: plain, object: nil)], timeout: 15), .completed,
                       "A plain search used the profile's engine: \(shownAddress(in: app))")
    }

    /// Removing the profile's engine asks first, naming the profile, and the profile searches
    /// with Google again.
    @MainActor
    func testRemovingAProfilesEngineGoesBackToGoogle() throws {
        let app = launchApp()
        addLocalEngine(in: app, port: try AxoUITests.closedPort())
        AxoUITests.selectSettingsPane("profiles", in: app)
        XCTAssertTrue(app.radioButtons["Local Search"].waitForExistence(timeout: 5))
        app.radioButtons["Local Search"].click()

        AxoUITests.selectSettingsPane("search", in: app)
        let edit = app.buttons.matching(identifier: "editSearchEngineButton").matching(NSPredicate(format: "label == 'Edit Local Search'")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.click()
        app.buttons["removeSearchEngineButton"].click()
        let confirm = app.buttons["confirmRemoveSearchEngineButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS 'will search with Google instead'")).firstMatch.exists
                      || app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'will search with Google instead'")).firstMatch.exists,
                      "The confirmation names what happens to the profile")
        confirm.click()
        let row = app.descendants(matching: .any).matching(identifier: "searchEngineRow").matching(NSPredicate(format: "label == 'Local Search'")).firstMatch
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))

        AxoUITests.selectSettingsPane("profiles", in: app)
        let google = app.radioButtons["Google"]
        XCTAssertTrue(google.waitForExistence(timeout: 5))
        let backToGoogle = NSPredicate(format: "value == 1")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: backToGoogle, object: google)], timeout: 5), .completed)
    }
}
