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

        // After submitting, the field shows the loaded URL (which percent-encodes the markup),
        // not the raw text that was typed.
        let address = app.textFields["addressField"]
        expectation(for: NSPredicate(format: "value CONTAINS '%3Ctitle%3E'"), evaluatedWith: address)
        waitForExpectations(timeout: 5)

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

        // With no tab open, ⌘W closes the window.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: 5))
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

    /// A link with a `download` attribute saves the file, and the Downloads button and list
    /// appear. Downloads go to a temporary folder in UI testing mode.
    @MainActor
    func testDownloadingAFileShowsItInTheDownloadsList() throws {
        let app = launchApp()
        XCTAssertTrue(app.descendants(matching: .any)["sidebar"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["downloadsButton"].exists, "No Downloads button before any download")

        app.typeKey("t", modifierFlags: .command)
        app.typeText("data:text/html,<title>Files</title><a href='data:text/plain,hello' download='hello.txt'>Get hello</a>\n")
        let link = app.links["Get hello"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.click()

        let downloadsButton = app.buttons["downloadsButton"]
        XCTAssertTrue(downloadsButton.waitForExistence(timeout: 10))
        downloadsButton.click()
        // Each row is one accessibility element, so VoiceOver reads the name and status together.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'downloadRow' AND label CONTAINS 'hello.txt'"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        // ⌥⌘L toggles the list.
        app.typeKey("l", modifierFlags: [.command, .option])
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
    }

    /// macOS window tabbing is off, so the View menu has no "Show Tab Bar".
    @MainActor
    func testWindowTabbingMenuItemsAreHidden() throws {
        let app = launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.menuBars.menuItems["Show Tab Bar"].exists)
    }

    /// ⌘F opens the find bar, a missing word says so, and Esc closes it.
    @MainActor
    func testFindInPage() throws {
        let app = launchApp()
        XCTAssertTrue(app.descendants(matching: .any)["sidebar"].waitForExistence(timeout: 5))
        app.typeKey("t", modifierFlags: .command)
        app.typeText("data:text/html,<title>Pond</title><p>Axolotls live in lakes.</p>\n")
        XCTAssertTrue(app.descendants(matching: .any)["sidebar"].staticTexts["Pond"].waitForExistence(timeout: 10))

        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["findField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.typeText("lakes")
        XCTAssertFalse(app.staticTexts["findNoMatches"].waitForExistence(timeout: 2))

        app.typeKey("a", modifierFlags: .command)
        app.typeText("ocean")
        XCTAssertTrue(app.staticTexts["findNoMatches"].waitForExistence(timeout: 5))

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            Self.makeApp().launch()
        }
    }
}
