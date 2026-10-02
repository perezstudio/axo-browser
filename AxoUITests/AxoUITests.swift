//
//  AxoUITests.swift
//  AxoUITests
//
//  Created by Kevin Perez on 10/2/26.
//

import XCTest

final class AxoUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches Axo with an in-memory database, non-persistent website data, and no restored
    /// window state, so every test starts from a clean launch.
    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = Self.makeApp()
        app.launch()
        return app
    }

    private static func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AXO_UI_TESTING"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        return app
    }

    /// A page with only a title, so tests never touch the network.
    private func page(_ title: String) -> String {
        "data:text/html,<title>\(title)</title>"
    }

    /// A fresh launch opens one window with the sidebar and the empty state.
    @MainActor
    func testLaunchShowsSidebarAndEmptyState() throws {
        let app = launchApp()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["sidebar"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No Tab Open"].waitForExistence(timeout: 5))
    }

    /// Open a tab, navigate, go back, and close it, using the keyboard and toolbar.
    @MainActor
    func testOpenNavigateGoBackAndCloseTab() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))

        // ⌘T focuses the address field for a new tab.
        app.typeKey("t", modifierFlags: .command)
        app.typeText(page("First") + "\n")
        XCTAssertTrue(sidebar.staticTexts["First"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["No Tab Open"].exists)

        // ⌘L edits the selected tab's address; the tab navigates in place.
        app.typeKey("l", modifierFlags: .command)
        app.typeText(page("Second") + "\n")
        XCTAssertTrue(sidebar.staticTexts["Second"].waitForExistence(timeout: 10))
        XCTAssertFalse(sidebar.staticTexts["First"].exists, "Navigating must not open another tab")

        // Back returns to the first page.
        let back = app.buttons["backButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: back)
        waitForExpectations(timeout: 10)
        back.click()
        XCTAssertTrue(sidebar.staticTexts["First"].waitForExistence(timeout: 10))

        // ⌘W closes the tab and shows the empty state again.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["No Tab Open"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.windows.firstMatch.exists, "Closing the last tab must not close the window")
    }

    /// The New Tab button and a second tab: the sidebar lists both, and selecting one shows it.
    @MainActor
    func testNewTabButtonAddsTabsToTheSidebar() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))

        app.buttons["newTabButton"].click()
        app.typeText(page("Alpha") + "\n")
        XCTAssertTrue(sidebar.staticTexts["Alpha"].waitForExistence(timeout: 10))

        app.buttons["newTabButton"].click()
        app.typeText(page("Beta") + "\n")
        XCTAssertTrue(sidebar.staticTexts["Beta"].waitForExistence(timeout: 10))
        XCTAssertTrue(sidebar.staticTexts["Alpha"].exists, "A new tab must not replace the previous one")

        sidebar.staticTexts["Alpha"].click()
        let address = app.textFields["addressField"]
        let showsAlpha = NSPredicate(format: "value CONTAINS 'Alpha'")
        expectation(for: showsAlpha, evaluatedWith: address)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            Self.makeApp().launch()
        }
    }
}
