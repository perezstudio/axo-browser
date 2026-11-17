//
//  AxoUITests.swift
//  AxoUITests
//
//  Created by Kevin Perez on 10/2/26.
//

import AppKit
import XCTest

final class AxoUITests: XCTestCase {

    override class func setUp() {
        super.setUp()
        connectRunnerToWindowServer()
    }

    /// Connects the test runner to the window server before its first event. The runner has no
    /// `NSApplication`, and XCTest's event synthesis asserts (`CGS_REQUIRE_INIT`) when nothing in
    /// the runner has connected yet: a fresh runner whose first test starts with a key press
    /// crashes (seen on GitHub's Mac runners when running one test alone).
    static func connectRunnerToWindowServer() {
        MainActor.assumeIsolated { _ = NSApplication.shared }
    }

    /// Whether the tests run on a GitHub-hosted Mac (`.github/workflows/ui-tests.yml` sets
    /// `TEST_RUNNER_AXO_HOSTED_RUNNER`). A few tests can't pass on that virtual Mac and skip
    /// there; they still run in full everywhere else.
    static var isOnHostedRunner: Bool {
        ProcessInfo.processInfo.environment["AXO_HOSTED_RUNNER"] == "1"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Quits Axo after each test. Otherwise the next launch quits it first, and macOS moving
    /// focus after that quit can take focus away from the new Axo ("not foreground").
    override func tearDown() async throws {
        await MainActor.run { XCUIApplication().terminate() }
        try await super.tearDown()
    }

    /// Launches Axo with an in-memory database, non-persistent website data, and no restored
    /// window state, so every test starts from a clean launch.
    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = Self.makeApp()
        app.launch()
        Self.bringToFront(app)
        return app
    }

    @MainActor
    static func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AXO_UI_TESTING"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        // UI tests share user defaults with the person's own Axo. WebKit remembers whether they
        // last docked the Web Inspector, so start it docked for this run (an argument-domain
        // override, which doesn't change their saved choice).
        app.launchArguments += ["-__WebInspectorPageGroupLevel1__.WebKit2InspectorStartsAttached", "YES"]
        return app
    }

    /// Opens `address` in a new tab through the command bar (⌘T). It types into the command
    /// field itself, once it's there: typed at the app as the bar opens, the first letters could
    /// be lost or go elsewhere, turning an address into a search.
    @MainActor
    static func openPage(_ address: String, in app: XCUIApplication) {
        app.typeKey("t", modifierFlags: .command)
        let field = app.textFields["commandField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "The command bar opens")
        // The field can appear a moment before it takes keyboard focus (typing then fails with
        // "Neither element nor any descendant has keyboard focus"), so wait for focus, and click
        // the field if it doesn't come.
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: focused, object: field)], timeout: 3) != .completed {
            field.click()
        }
        field.typeText(address + "\n")
    }

    /// Selects a pane in the Settings window's sidebar (#85) by its raw value, such as `general`
    /// or `linkRouting`, once Settings is open. Settings reopens on the last pane used, so tests
    /// select the pane they need first.
    @MainActor
    static func selectSettingsPane(_ pane: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.descendants(matching: .any)["settingsPane.\(pane)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Settings shows the \(pane) pane's row", file: file, line: line)
        row.click()
    }

    /// Waits for Axo to be the frontmost app, activating it if another app took focus during
    /// launch. Keystrokes fail with "not foreground" otherwise.
    @MainActor
    static func bringToFront(_ app: XCUIApplication) {
        if !app.wait(for: .runningForeground, timeout: 5) {
            app.activate()
            _ = app.wait(for: .runningForeground, timeout: 5)
        }
    }

    /// Launches Axo set up to receive `url` as a link from another app (sent by `sourceApp`).
    @MainActor
    private func launchApp(externalLink url: String, sourceApp: String? = nil) -> XCUIApplication {
        let app = Self.makeApp()
        app.launchEnvironment["AXO_UI_TESTING_EXTERNAL_URL"] = url
        if let sourceApp { app.launchEnvironment["AXO_UI_TESTING_SOURCE_APP"] = sourceApp }
        app.launch()
        Self.bringToFront(app)
        return app
    }

    /// Sends the link set up in `launchApp(externalLink:)`, as another app would. Never use
    /// `XCUIApplication.open` for this: it launches a new Axo outside testing mode, which would
    /// use the person's real database.
    @MainActor
    static func sendExternalLink(in app: XCUIApplication) {
        app.menuBars.menuBarItems["Testing"].click()
        app.menuBars.menuItems["Open Link from Another App"].click()
    }

    /// The fraction of sampled pixels in `region` (screen points) of a window screenshot that
    /// differ clearly from the region's most common color: 0 for a blank area.
    static func fractionOfDistinctPixels(in image: NSImage, region: CGRect, window: CGRect) throws -> Double {
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let scale = Double(bitmap.pixelsWide) / window.width
        // Screen points are top-down here, as are bitmap rows.
        let left = Int((region.minX - window.minX) * scale), top = Int((region.minY - window.minY) * scale)
        let width = Int(region.width * scale), height = Int(region.height * scale)
        var samples: [Double] = []
        for x in stride(from: max(left, 0), to: min(left + width, bitmap.pixelsWide), by: 6) {
            for y in stride(from: max(top, 0), to: min(top + height, bitmap.pixelsHigh), by: 6) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    samples.append((color.redComponent + color.greenComponent + color.blueComponent) / 3)
                }
            }
        }
        guard !samples.isEmpty else { return 0 }
        let common = Dictionary(grouping: samples) { ($0 * 20).rounded() }.max { $0.value.count < $1.value.count }!.key / 20
        return Double(samples.filter { abs($0 - common) > 0.08 }.count) / Double(samples.count)
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
        AxoUITests.openPage(page("First"), in: app)
        XCTAssertTrue(sidebar.staticTexts["First"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["No Tab Open"].exists)

        // After submitting, the address bar holds the loaded URL (which percent-encodes the
        // markup), not the raw text that was typed.
        let address = app.descendants(matching: .any)["sidebarAddressBar"]
        expectation(for: NSPredicate(format: "value CONTAINS '%3Ctitle%3E'"), evaluatedWith: address)
        waitForExpectations(timeout: 5)

        // ⌘L edits the selected tab's address in the command bar; the tab navigates in place.
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

    /// New Tab (⌘T; the sidebar's top row has no button for it, as on the board, #67) and a
    /// second tab: the sidebar lists both, and selecting one shows it.
    @MainActor
    func testNewTabAddsTabsToTheSidebar() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))

        app.typeKey("t", modifierFlags: .command)
        app.typeText(page("Alpha") + "\n")
        XCTAssertTrue(sidebar.staticTexts["Alpha"].waitForExistence(timeout: 10))

        app.typeKey("t", modifierFlags: .command)
        app.typeText(page("Beta") + "\n")
        XCTAssertTrue(sidebar.staticTexts["Beta"].waitForExistence(timeout: 10))
        XCTAssertTrue(sidebar.staticTexts["Alpha"].exists, "A new tab must not replace the previous one")

        sidebar.staticTexts["Alpha"].click()
        let address = app.descendants(matching: .any)["sidebarAddressBar"]
        let showsAlpha = NSPredicate(format: "value CONTAINS 'Alpha'")
        expectation(for: showsAlpha, evaluatedWith: address)
        waitForExpectations(timeout: 5)
    }

    /// A link with a `download` attribute saves the file, and it shows in the list that opens from
    /// Downloads at the left of the sidebar's footer (#67). Downloads go to a temporary folder in
    /// UI testing mode.
    @MainActor
    func testDownloadingAFileShowsItInTheDownloadsList() throws {
        let app = launchApp()
        XCTAssertTrue(app.descendants(matching: .any)["sidebar"].waitForExistence(timeout: 5))
        let footer = app.descendants(matching: .any)["spaceSwitcher"]
        XCTAssertTrue(footer.buttons["downloadsButton"].waitForExistence(timeout: 5), "Downloads is in the footer from the start")
        XCTAssertEqual(footer.buttons["downloadsButton"].value as? String, "None")

        AxoUITests.openPage("data:text/html,<title>Files</title><a href='data:text/plain,hello' download='hello.txt'>Get hello</a>", in: app)
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

    /// A page's `confirm()` shows as a dialog naming the page, and the page gets the answer.
    @MainActor
    func testJavaScriptConfirmShowsAndReturnsTheAnswer() throws {
        // While the page waits on confirm(), WebKit blocks its web process. On GitHub's virtual
        // Mac every query into the page's web view then takes over a minute, so the dialog can't
        // be checked in time there (it does appear).
        try XCTSkipIf(Self.isOnHostedRunner, "A blocked web process stalls accessibility queries on GitHub's hosted Mac.")
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))

        // Ask after a moment, so the dialog doesn't open while the typed Return is still being delivered.
        AxoUITests.openPage("data:text/html,<title>Ask</title><script>setTimeout(() => document.title = confirm('Delete everything?') ? 'Yes' : 'No', 300)</script>", in: app)

        XCTAssertTrue(app.staticTexts["This page says"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Delete everything?"].exists)
        let dialog = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch
        dialog.buttons["Cancel"].firstMatch.click()

        XCTAssertTrue(sidebar.staticTexts["No"].waitForExistence(timeout: 10))
    }

    /// The sidebar's address bar shows the site, and clicking it (or ⌘L) edits the full address in
    /// the command bar: selected, so typing replaces it, loading in the same tab; Esc closes it.
    /// Copy Link copies the address, the full-address setting can be turned on, and the bar can be
    /// hidden.
    @MainActor
    func testSidebarAddressBarEditsInTheCommandBar() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        let bar = app.descendants(matching: .any)["sidebarAddressBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        // As tall as a favorite's tile (`FavoritesLayout.tileHeight`), as in Arc.
        XCTAssertEqual(bar.frame.height, 40, accuracy: 1)
        let commandField = app.textFields["commandField"]

        AxoUITests.openPage("data:text/html,<title>First</title>", in: app)
        XCTAssertTrue(sidebar.staticTexts["First"].waitForExistence(timeout: 10))
        XCTAssertEqual(bar.label, "Address")
        expectation(for: NSPredicate(format: "value BEGINSWITH 'data:text/html,'"), evaluatedWith: bar)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.textFields["addressField"].exists, "No editable field in the sidebar")
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Sidebar address bar"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        // Clicking it opens the command bar with the full address, selected.
        bar.click()
        XCTAssertTrue(commandField.waitForExistence(timeout: 5))
        XCTAssertTrue((commandField.value as? String ?? "").hasPrefix("data:text/html,"), "The full address to edit")
        // Esc closes it, leaving the page as it was.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(commandField.waitForNonExistence(timeout: 5))

        // ⌘L opens it too; typing replaces the selected address and Return loads in this tab.
        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(commandField.waitForExistence(timeout: 5))
        app.typeText("data:text/html,<title>Second</title>\n")
        XCTAssertTrue(sidebar.staticTexts["Second"].waitForExistence(timeout: 10))
        XCTAssertFalse(sidebar.staticTexts["First"].exists, "Loaded in place, not in a new tab")

        // Copy Link (⇧⌘C) copies the address (to the test run's own pasteboard).
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.perezstudio.Axo.testing"))
        pasteboard.clearContents()
        app.typeKey("c", modifierFlags: [.command, .shift])
        let copied = expectation(description: "the link is copied")
        Task { @MainActor in
            for _ in 0..<50 where pasteboard.string(forType: .string) == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if pasteboard.string(forType: .string)?.contains("Second") == true { copied.fulfill() }
        }
        wait(for: [copied], timeout: 10)

        // View › Hide Address Bar in Sidebar hides it; ⌘L still edits the address.
        app.menuBarItems["View"].click()
        app.menuItems["Hide Address Bar in Sidebar"].click()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5))
        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(commandField.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(commandField.waitForNonExistence(timeout: 5))
        app.menuBarItems["View"].click()
        app.menuItems["Show Address Bar in Sidebar"].click()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))

        // Settings › General › Show full website address.
        app.typeKey(",", modifierFlags: .command)
        AxoUITests.selectSettingsPane("general", in: app)
        let fullAddress = app.checkBoxes["showsFullAddressToggle"]
        XCTAssertTrue(fullAddress.waitForExistence(timeout: 5))
        XCTAssertEqual(fullAddress.value as? Int, 0, "Off by default")
        fullAddress.click()
        XCTAssertEqual(fullAddress.value as? Int, 1)
        app.typeKey("w", modifierFlags: .command)
        // What the pill then shows (the whole address) is covered by AddressDisplayTests.
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
    }

    /// Clicks `element` where it is. XCUITest's own click first scrolls the list "to make it
    /// visible", which moves the pointer off a row, so a button shown only on hover goes before
    /// the click lands.
    @MainActor
    private func clickWithoutScrolling(_ element: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        let frame = element.frame
        XCTAssertTrue(frame.width.isFinite && frame.width > 0, "The element is on screen: \(frame)")
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - window.frame.minX, dy: frame.midY - window.frame.minY))
            .click()
    }

    /// Hovering a tab row shows a close button (#69): it closes a tab, and unloads a pinned one,
    /// which stays in the sidebar.
    @MainActor
    func testTabRowCloseButtonClosesOrUnloads() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        for title in ["Keep", "Gone", "Docs"] {
            AxoUITests.openPage("data:text/html,<title>\(title)</title>", in: app)
            XCTAssertTrue(sidebar.staticTexts[title].waitForExistence(timeout: 10))
        }
        app.typeKey("p", modifierFlags: [.command, .control]) // Pin Tab, on "Docs"
        let closeButton = sidebar.buttons["tabRowCloseButton"]

        sidebar.staticTexts["Gone"].hover()
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        clickWithoutScrolling(closeButton, in: app)
        XCTAssertTrue(sidebar.staticTexts["Gone"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(sidebar.staticTexts["Keep"].exists)

        // A pinned tab's button unloads it: it stays in the sidebar. (In the Pinned section, the
        // section's identifier replaces its rows' and their buttons', so they're found by label.)
        XCTAssertTrue(sidebar.staticTexts["Pinned"].waitForExistence(timeout: 5), "Docs is pinned")
        let pinned = sidebar.staticTexts["Docs"]
        XCTAssertTrue(pinned.waitForExistence(timeout: 5))
        pinned.hover()
        let unload = sidebar.buttons["Unload Tab"]
        XCTAssertTrue(unload.waitForExistence(timeout: 5))
        clickWithoutScrolling(unload, in: app)
        XCTAssertTrue(pinned.exists, "Unloaded, not closed")
    }

    /// Actions with no other visible result show a brief notice (#103): Copy Link shows "Link
    /// copied" over the page while the sidebar's address bar is hidden, and closing a tab offers
    /// Undo, which brings it back.
    @MainActor
    func testNoticesShowAndUndoCloses() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        AxoUITests.openPage("data:text/html,<title>Keep</title>", in: app)
        XCTAssertTrue(sidebar.staticTexts["Keep"].waitForExistence(timeout: 10))
        AxoUITests.openPage("data:text/html,<title>Gone</title>", in: app)
        XCTAssertTrue(sidebar.staticTexts["Gone"].waitForExistence(timeout: 10))

        // With the address bar hidden, "Link copied" shows over the page.
        app.menuBarItems["View"].click()
        app.menuItems["Hide Address Bar in Sidebar"].click()
        app.typeKey("c", modifierFlags: [.command, .shift])
        let notice = app.descendants(matching: .any)["notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertEqual(notice.label, "Link copied")
        app.menuBarItems["View"].click()
        app.menuItems["Show Address Bar in Sidebar"].click()

        // ⌘W shows "Closed Gone" with Undo, which brings the tab back.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(sidebar.staticTexts["Gone"].waitForNonExistence(timeout: 5))
        let undo = app.buttons["noticeUndoButton"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertEqual(notice.label, "Closed Gone")
        undo.click()
        XCTAssertTrue(sidebar.staticTexts["Gone"].waitForExistence(timeout: 5))
        XCTAssertTrue(undo.waitForNonExistence(timeout: 5))
    }

    /// With Settings › General › Edit the address in › Sidebar, the sidebar's address bar becomes
    /// the field, with suggestions below it and no command bar; Return loads in the same tab and
    /// Esc stops editing.
    @MainActor
    func testAddressEditsInTheSidebar() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        AxoUITests.openPage("data:text/html,<title>First</title>", in: app)
        XCTAssertTrue(sidebar.staticTexts["First"].waitForExistence(timeout: 10))

        app.typeKey(",", modifierFlags: .command)
        AxoUITests.selectSettingsPane("general", in: app)
        let inSidebar = app.radioButtons["Sidebar"]
        XCTAssertTrue(inSidebar.waitForExistence(timeout: 5))
        inSidebar.click()
        app.typeKey("w", modifierFlags: .command)

        let bar = app.descendants(matching: .any)["sidebarAddressBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        bar.click()
        let field = app.textFields["sidebarAddressField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["addressSuggestions"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["commandField"].exists, "No command bar over the page")

        // Typing replaces the selected address; Return loads in this tab.
        app.typeText("data:text/html,<title>Second</title>\n")
        XCTAssertTrue(sidebar.staticTexts["Second"].waitForExistence(timeout: 10))
        XCTAssertFalse(sidebar.staticTexts["First"].exists, "Loaded in place, not in a new tab")
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))

        // Clicking a suggestion runs it: the field keeps focus until the row's click lands.
        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.typeText("data:text/html,<title>Third</title>")
        let suggestion = app.descendants(matching: .any)["addressSuggestions"]
            .descendants(matching: .any).matching(identifier: "commandResult").firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5))
        suggestion.click()
        XCTAssertTrue(sidebar.staticTexts["Third"].waitForExistence(timeout: 10))
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))

        // ⌘L edits there too, and Esc stops.
        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
    }

    /// Return in the prompt cancels: a page can ask while the person is typing, and their next
    /// Return mustn't open an app. Allow does open it, which proves the test can tell. (UI test
    /// runs never open an app: `UITestingExternalApps` opens a tab titled "Opened in another app"
    /// instead.)
    @MainActor
    func testReturnCancelsALinkToAnotherApp() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        let question = app.staticTexts["Allow this page to open “Mail”?"]
        let opened = sidebar.staticTexts["Opened in another app"]

        AxoUITests.openPage("data:text/html,<title>Contact</title><a id=m href='mailto:someone@example.com'>Write</a><script>setTimeout(() => document.getElementById('m').click(), 300)</script>", in: app)
        XCTAssertTrue(question.waitForExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(question.waitForNonExistence(timeout: 5), "Return answered the prompt")
        XCTAssertFalse(opened.waitForExistence(timeout: 2), "Return cancelled: nothing opened")

        // Loading the page again asks again; Allow opens the link.
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(question.waitForExistence(timeout: 10))
        let dialog = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch
        dialog.buttons["Allow"].firstMatch.click()
        XCTAssertTrue(opened.waitForExistence(timeout: 10), "Allow opened the link")
    }

    /// A page's link to another app asks first; cancelling opens nothing (UI test runs never open
    /// an app: `UITestingExternalApps`).
    @MainActor
    func testLinksToOtherAppsAskFirst() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))

        // Follow the link after a moment, so the prompt doesn't open while the typed Return is
        // still being delivered.
        AxoUITests.openPage("data:text/html,<title>Contact</title><a id=m href='mailto:someone@example.com'>Write</a><script>setTimeout(() => document.getElementById('m').click(), 300)</script>", in: app)

        XCTAssertTrue(app.staticTexts["Allow this page to open “Mail”?"].waitForExistence(timeout: 10))
        let dialog = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch
        XCTAssertFalse(dialog.buttons["Always Allow"].exists, "A data: page has no site to remember")
        dialog.buttons["Cancel"].firstMatch.click()

        XCTAssertTrue(app.staticTexts["Allow this page to open “Mail”?"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(sidebar.staticTexts["Contact"].waitForExistence(timeout: 5), "The page stays")
        XCTAssertFalse(sidebar.staticTexts["Opened in another app"].exists, "Cancel opened nothing")
    }

    /// Create a Space from the switcher, see its tabs separately, and switch back with ⌃1.
    @MainActor
    func testCreatingAndSwitchingSpaces() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        AxoUITests.openPage("data:text/html,<title>Home tab</title>", in: app)
        XCTAssertTrue(sidebar.staticTexts["Home tab"].waitForExistence(timeout: 10))

        app.buttons["newSpaceButton"].click()
        let nameField = app.textFields["spaceNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click()
        nameField.typeText("Work")
        app.buttons["createSpaceButton"].click()

        XCTAssertTrue(sidebar.staticTexts["Work"].waitForExistence(timeout: 5), "The sidebar shows the new Space")
        XCTAssertFalse(sidebar.staticTexts["Home tab"].exists, "Each Space has its own tabs")
        XCTAssertEqual(app.buttons.matching(identifier: "spaceButton").count, 2)

        app.typeKey("1", modifierFlags: .control)
        XCTAssertTrue(sidebar.staticTexts["Home tab"].waitForExistence(timeout: 5))
    }

    /// Clicking a tab in the sidebar hands keyboard focus to its page, as in Arc: keys go to the
    /// page, not the sidebar.
    @MainActor
    func testClickingATabGivesItsPageTheKeyboard() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        // The page names the last key it got in its title.
        AxoUITests.openPage("data:text/html,<title>Keys</title><script>addEventListener('keydown', e => document.title = 'Got ' + e.key)</script>", in: app)
        XCTAssertTrue(sidebar.staticTexts["Keys"].waitForExistence(timeout: 10))
        AxoUITests.openPage("data:text/html,<title>Other</title>", in: app)
        XCTAssertTrue(sidebar.staticTexts["Other"].waitForExistence(timeout: 10))

        sidebar.staticTexts["Keys"].click()
        app.typeKey("x", modifierFlags: [])
        XCTAssertTrue(sidebar.staticTexts["Got x"].waitForExistence(timeout: 5), "The page got the key")
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(sidebar.staticTexts["Got ArrowDown"].waitForExistence(timeout: 5), "Arrow keys go to the page too")
    }

    /// Settings › General moves the navigation bar from the sidebar to the page's control bar at
    /// the top of the page's area (#170), where ⌘L still focuses the address field, and which
    /// takes the window's controls and Show Sidebar while the sidebar is hidden. (UI testing keeps
    /// settings in its own store.)
    @MainActor
    func testNavigationBarPlacement() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        let sidebarBar = app.descendants(matching: .any)["sidebarAddressBar"]
        XCTAssertTrue(sidebarBar.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(sidebarBar.frame.maxX, sidebar.frame.maxX + 1, "The sidebar holds the address bar by default")
        XCTAssertFalse(app.textFields["addressField"].exists, "There it's the pill, not a field")
        XCTAssertTrue(app.buttons["backButton"].exists)

        app.typeKey(",", modifierFlags: .command)
        AxoUITests.selectSettingsPane("general", in: app)
        let abovePage = app.radioButtons["Above the page"]
        XCTAssertTrue(abovePage.waitForExistence(timeout: 5))
        abovePage.click()
        app.typeKey("w", modifierFlags: .command)

        let pageBar = app.descendants(matching: .any)["pageAddressBar"]
        XCTAssertTrue(pageBar.waitForExistence(timeout: 5))
        let address = pageBar.textFields["addressField"]
        XCTAssertTrue(address.exists, "Above the page, it's an editable field, as in Safari")
        XCTAssertFalse(sidebarBar.exists, "The sidebar no longer has one")
        XCTAssertGreaterThan(address.frame.minX, sidebar.frame.maxX - 1, "It sits in the page's control bar")
        XCTAssertTrue(app.buttons["backButton"].exists && app.buttons["reloadButton"].exists)
        XCTAssertLessThan(app.buttons["reloadButton"].frame.maxX, pageBar.frame.minX,
                          "Reload stays with back and forward, before the address field")
        XCTAssertGreaterThan(app.buttons["summarizeButton"].frame.minX, pageBar.frame.maxX,
                             "The page's tools sit after the address field, at the trailing edge")

        app.typeKey("l", modifierFlags: .command)
        app.typeText("data:text/html,<title>Above</title>\n")
        XCTAssertTrue(sidebar.staticTexts["Above"].waitForExistence(timeout: 10), "⌘L focuses the address field above the page")

        // The control bar sits at the top of the page's area, not in a toolbar across the
        // window (#170); with the sidebar hidden it takes the window's controls and Show Sidebar.
        let window = app.windows.firstMatch
        let controlBar = app.descendants(matching: .any)["controlBar"]
        XCTAssertTrue(controlBar.exists)
        XCTAssertFalse(window.toolbars.firstMatch.exists, "No toolbar across the window")
        XCTAssertEqual(controlBar.frame.minY, window.frame.minY, accuracy: 1, "At the window's top edge")
        XCTAssertFalse(controlBar.buttons["showSidebarButton"].exists, "No Show Sidebar while it shows")
        app.buttons["hideSidebarButton"].click()
        XCTAssertTrue(sidebar.waitForNonExistence(timeout: 5))
        XCTAssertTrue(controlBar.buttons["showSidebarButton"].waitForExistence(timeout: 5), "The control bar takes Show Sidebar")
        XCTAssertTrue(window.buttons[XCUIIdentifierCloseWindow].exists, "And the window's controls")
        XCTAssertLessThan(window.buttons[XCUIIdentifierCloseWindow].frame.maxX, controlBar.buttons["showSidebarButton"].frame.minX)
        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = "Control bar with the sidebar hidden"
        shot.lifetime = .keepAlways
        add(shot)
        controlBar.buttons["showSidebarButton"].click()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        XCTAssertTrue(controlBar.buttons["showSidebarButton"].waitForNonExistence(timeout: 5))
    }

    /// Above the page, the control bar takes the page's `theme-color`, as in Safari (#107), the
    /// sidebar's top keeps its own color (#170), and turning "Tint the toolbar to match the page"
    /// off in Settings clears it. Checked on pixels of the control bar between the address field
    /// and the page's tools, and of the sidebar's top row, in window screenshots.
    @MainActor
    func testToolbarTakesThePagesThemeColor() throws {
        let raspberry = (red: 155.0 / 255, green: 42.0 / 255, blue: 92.0 / 255)
        let app = Self.makeApp()
        // The tint setting is left to its default (on): an argument would override the switch.
        app.launchArguments += ["-navigationBarPlacement", "page"]
        app.launch()
        Self.bringToFront(app)
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        AxoUITests.openPage("data:text/html,<meta name=theme-color content=rgb(155,42,92)><title>Tinted</title>", in: app)
        XCTAssertTrue(sidebar.staticTexts["Tinted"].waitForExistence(timeout: 10))

        let window = app.windows.firstMatch
        // The open toolbar between the address field and the page's tools: Reload's own glass
        // circle sits close to the field, so the gap before it is too narrow to sample.
        let address = app.descendants(matching: .any)["pageAddressBar"].frame
        let tools = app.buttons["summarizeButton"].frame
        let point = CGPoint(x: (address.maxX + tools.minX) / 2 - window.frame.minX, y: address.midY - window.frame.minY)
        func waitForToolbar(tinted: Bool, _ name: String) {
            var color = Self.color(at: point, in: window)
            let deadline = Date.now.addingTimeInterval(5)
            while Self.isClose(color, to: raspberry) != tinted, Date.now < deadline {
                RunLoop.current.run(until: .now.addingTimeInterval(0.25))
                color = Self.color(at: point, in: window)
            }
            let shot = XCTAttachment(screenshot: window.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
            XCTAssertEqual(Self.isClose(color, to: raspberry), tinted, "\(name): toolbar pixel \(color)")
        }
        waitForToolbar(tinted: true, "Toolbar tinted to the page")
        // The tint colors only the page's control bar (#170): the sidebar keeps its own color up
        // to the window's top, beside its top row's buttons.
        let row = app.descendants(matching: .any)["sidebarTopRow"]
        XCTAssertTrue(row.exists, "The sidebar's top row, not a toolbar, is above the sidebar")
        XCTAssertFalse(window.toolbars.firstMatch.exists, "No toolbar across the window")
        let hide = app.buttons["hideSidebarButton"].frame
        let sidebarTop = CGPoint(x: hide.minX - 30 - window.frame.minX, y: 8)
        let sidebarColor = Self.color(at: sidebarTop, in: window)
        XCTAssertFalse(Self.isClose(sidebarColor, to: raspberry), "The sidebar's top isn't tinted: \(sidebarColor)")
        XCTAssertGreaterThan(app.descendants(matching: .any)["controlBar"].frame.minX, sidebar.frame.maxX - 1,
                             "The control bar sits over the page, not the sidebar")

        app.typeKey(",", modifierFlags: .command)
        AxoUITests.selectSettingsPane("general", in: app)
        let toggle = app.checkBoxes["tintsToolbarToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(toggle.isEnabled, "Above the page, the setting can be changed")
        toggle.click()
        app.typeKey("w", modifierFlags: .command)
        waitForToolbar(tinted: false, "Toolbar with tinting turned off")
    }

    /// The page meets the sidebar along one straight edge with a soft shadow on the sidebar's
    /// side (#67): the sidebar is darker right beside the edge than farther in. Back and forward
    /// share one glass capsule and reload is its own circle (checked in the screenshot).
    /// Checked in light and dark mode, with window screenshots.
    @MainActor
    func testThePageCastsAShadowOnTheSidebar() throws {
        for appearance in ["Light", "Dark"] {
            let app = Self.makeApp()
            app.launchEnvironment["AXO_UI_TESTING_APPEARANCE"] = appearance
            app.launch()
            Self.bringToFront(app)
            let sidebar = app.descendants(matching: .any)["sidebar"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
            let window = app.windows.firstMatch
            let edge = sidebar.frame.maxX - window.frame.minX
            // An empty part of the sidebar, below its rows and above the footer, so neither point
            // lands on a row or its highlight.
            let footerTop = app.descendants(matching: .any)["spaceSwitcher"].frame.minY
            let y = footerTop - window.frame.minY - 40
            func luminance(_ color: (red: Double, green: Double, blue: Double)) -> Double {
                0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
            }
            let nearEdge = luminance(Self.color(at: CGPoint(x: edge - 2, y: y), in: window))
            let fartherIn = luminance(Self.color(at: CGPoint(x: edge - 40, y: y), in: window))
            let shot = XCTAttachment(screenshot: window.screenshot())
            shot.name = "Page edge, \(appearance): \(nearEdge) beside the edge, \(fartherIn) farther in"
            shot.lifetime = .keepAlways
            add(shot)
            XCTAssertLessThan(nearEdge, fartherIn - 0.015,
                              "\(appearance): the sidebar beside the page's edge (\(nearEdge)) is darker than farther in (\(fartherIn))")

            // Reload's own glass circle, apart from back and forward's capsule, shows only in the
            // screenshot above: toolbar items report their whole slots, which touch either way.
            XCTAssertTrue(app.buttons["reloadButton"].exists && app.buttons["backButton"].exists)
            app.terminate()
        }
    }

    /// With the navigation bar in the sidebar, the sidebar's top row stands in for the window
    /// toolbar (#67): back, forward, reload, and Hide Sidebar sit beside the window's controls,
    /// the window has no toolbar, and the page reaches the window's top edge, where clicks reach
    /// it. With the sidebar hidden the page fills the window, the sidebar floats in from the left
    /// edge, and a bar along the top edge moves the window; with the sidebar's address bar
    /// hidden, the toolbar comes back.
    @MainActor
    func testTheSidebarReplacesTheToolbar() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        let row = app.descendants(matching: .any)["sidebarTopRow"]
        XCTAssertTrue(row.exists)
        for id in ["backButton", "forwardButton", "reloadButton", "hideSidebarButton"] {
            XCTAssertTrue(row.buttons[id].exists, "\(id) is in the sidebar's top row")
            XCTAssertLessThan(row.buttons[id].frame.maxX, sidebar.frame.maxX + 1, "\(id) sits over the sidebar")
        }
        XCTAssertFalse(window.toolbars.firstMatch.exists, "No window toolbar")
        // The window's controls, made for the row since they hide with the title bar.
        let close = window.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(close.exists, "The window can still be closed")
        XCTAssertEqual(close.frame.midY, row.buttons["reloadButton"].frame.midY, accuracy: 1.5, "In line with the row")
        XCTAssertTrue(window.buttons[XCUIIdentifierMinimizeWindow].exists, "The window can be minimized")
        // The green button reports itself as full screen or zoom, as macOS chooses.
        XCTAssertTrue(window.buttons[XCUIIdentifierFullScreenWindow].exists || window.buttons[XCUIIdentifierZoomWindow].exists,
                      "The window can go full screen")

        // A link along the page's very top: the title bar's area above the page takes no clicks.
        // The link renames the page rather than opening another: WebKit refuses a link's top-level
        // navigation to a data: address, which would hide whether the click arrived.
        AxoUITests.openPage("data:text/html,<title>Top</title><body style='margin:0'><a href='about:blank' onclick=\"document.title='Reached';return false\" style='display:block;height:20px'>Top link</a>", in: app)
        let link = app.links["Top link"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        // The page's own web view (its container's identifier doesn't reach the accessibility tree).
        let page = window.webViews.firstMatch
        XCTAssertEqual(page.frame.minY, window.frame.minY, accuracy: 1, "The page reaches the window's top edge")
        XCTAssertEqual(link.frame.minY, window.frame.minY, accuracy: 1)
        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = "Sidebar top row, page to the top"
        shot.lifetime = .keepAlways
        add(shot)
        link.click()
        XCTAssertTrue(sidebar.staticTexts["Reached"].waitForExistence(timeout: 10), "The click at the window's top reached the page")

        // The find bar sits at the page's top, with the page below it, not under it.
        app.typeKey("f", modifierFlags: .command)
        let findField = app.descendants(matching: .any)["findField"]
        XCTAssertTrue(findField.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(page.frame.minY, findField.frame.maxY - 1, "The page sits below the find bar")
        app.typeKey(.escape, modifierFlags: [])

        // Hidden from the button, the sidebar leaves the page filling the window, with no
        // toolbar (part 3 of #67; the page's place is checked in AxoTests' PageLayerTests, since
        // the hosted runner's accessibility doesn't follow a web view's frame).
        row.buttons["hideSidebarButton"].click()
        XCTAssertTrue(sidebar.waitForNonExistence(timeout: 5))
        XCTAssertFalse(window.toolbars.firstMatch.waitForExistence(timeout: 2), "No toolbar with the sidebar hidden")
        XCTAssertFalse(window.buttons[XCUIIdentifierCloseWindow].exists, "Nor the window's controls")

        // The pointer at the page's top edge shows a bar that moves the window, and leaving it
        // lets it go.
        let dragBar = app.descendants(matching: .any)["windowDragBar"]
        XCTAssertFalse(dragBar.exists, "No bar until the pointer reaches the top edge")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0)).withOffset(CGVector(dx: 0, dy: 2)).hover()
        XCTAssertTrue(dragBar.waitForExistence(timeout: 5), "The drag bar shows along the top edge")
        XCTAssertEqual(dragBar.frame.minY, window.frame.minY, accuracy: 1)
        let before = window.frame.origin
        let grab = dragBar.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        grab.press(forDuration: 0.3, thenDragTo: grab.withOffset(CGVector(dx: 40, dy: 30)))
        XCTAssertGreaterThan(abs(window.frame.origin.x - before.x) + abs(window.frame.origin.y - before.y), 20, "Dragging it moves the window")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)).hover()
        XCTAssertTrue(dragBar.waitForNonExistence(timeout: 5), "The pointer leaving lets it go")

        // The pointer at the window's left edge floats the sidebar in, with the window's
        // controls and Keep Sidebar Shown in its top row.
        let floating = app.descendants(matching: .any)["floatingSidebar"]
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 2, dy: 0))
        edge.hover()
        XCTAssertTrue(floating.waitForExistence(timeout: 5), "The sidebar floats in from the left edge")
        XCTAssertTrue(floating.buttons["keepSidebarShownButton"].exists)
        XCTAssertTrue(window.buttons[XCUIIdentifierCloseWindow].exists, "The window's controls are in its top row")
        XCTAssertEqual(floating.frame.minX - window.frame.minX, 8, accuracy: 1, "A card inset from the window's edge")
        let shot2 = XCTAttachment(screenshot: window.screenshot())
        shot2.name = "Floating sidebar"
        shot2.lifetime = .keepAlways
        add(shot2)
        // Its rows answer the pointer as the sidebar's do.
        floating.staticTexts["Reached"].hover()
        XCTAssertTrue(floating.buttons["tabRowCloseButton"].waitForExistence(timeout: 5), "Hovering a row shows its close button")

        // Leaving it lets it go.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).hover()
        XCTAssertTrue(floating.waitForNonExistence(timeout: 5), "The pointer leaving lets it go")

        // Keep Sidebar Shown puts it back in the window, where the top row takes over again.
        edge.hover()
        XCTAssertTrue(floating.waitForExistence(timeout: 5))
        floating.buttons["keepSidebarShownButton"].click()
        XCTAssertTrue(floating.waitForNonExistence(timeout: 5))
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(window.toolbars.firstMatch.exists, "No toolbar with the sidebar shown")

        // Hidden from the menu (AppKit's own Toggle Sidebar, not the row's button), the page
        // fills the window too, and ⌃⌘S shows the sidebar again.
        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(sidebar.waitForNonExistence(timeout: 5))
        XCTAssertFalse(window.toolbars.firstMatch.waitForExistence(timeout: 2), "No toolbar however the sidebar hides")
        // View › Show Downloads while it's hidden brings the card in, with the list open.
        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuItems["Show Downloads"].click()
        XCTAssertTrue(floating.waitForExistence(timeout: 5), "The card comes in for the list")
        XCTAssertTrue(app.buttons["clearDownloadsButton"].waitForExistence(timeout: 5))
        // The pointer away from the card: the open list still holds it.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).hover()
        XCTAssertTrue(floating.exists, "The open list holds the card")
        app.typeKey("l", modifierFlags: [.command, .option])
        XCTAssertTrue(app.buttons["clearDownloadsButton"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(floating.waitForNonExistence(timeout: 5), "And goes once it's closed, with the pointer elsewhere")
        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))

        // With the sidebar's address bar hidden (View menu), the toolbar holds the page's tools.
        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuItems["Hide Address Bar in Sidebar"].click()
        XCTAssertTrue(window.toolbars.firstMatch.waitForExistence(timeout: 5), "The toolbar comes back without the address bar")
        XCTAssertFalse(row.exists)
    }

    /// The sRGB color of the pixel at `point` (in points from the window's top left) in a
    /// screenshot of `window`.
    @MainActor
    static func color(at point: CGPoint, in window: XCUIElement) -> (red: Double, green: Double, blue: Double) {
        let image = window.screenshot().image
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return (0, 0, 0) }
        let scale = Double(cgImage.width) / image.size.width
        var pixel = [UInt8](repeating: 0, count: 4)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // Draw the image so the wanted pixel lands on the context's only one (y counts up).
            let x = -(point.x * scale).rounded(.down)
            let y = -(Double(cgImage.height) - (point.y * scale).rounded(.down) - 1)
            context.draw(cgImage, in: CGRect(x: x, y: y, width: Double(cgImage.width), height: Double(cgImage.height)))
        }
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    static func isClose(_ color: (red: Double, green: Double, blue: Double), to other: (red: Double, green: Double, blue: Double)) -> Bool {
        abs(color.red - other.red) < 0.08 && abs(color.green - other.green) < 0.08 && abs(color.blue - other.blue) < 0.08
    }

    /// The sidebar's footer matches the top of the window (#135): its buttons and the Space dots'
    /// capsule are as tall as the buttons at the top, round, and as far from the window's edges.
    /// With the navigation bar in the sidebar, the top is the sidebar's top row (#67), lined up
    /// with the window's controls; above the page, the window toolbar. Checked in light and
    /// dark mode, with window screenshots.
    @MainActor
    func testSidebarFooterMatchesTheToolbar() throws {
        for appearance in ["Light", "Dark"] {
            let app = Self.makeApp()
            app.launchEnvironment["AXO_UI_TESTING_APPEARANCE"] = appearance
            app.launch()
            Self.bringToFront(app)
            let window = app.windows.firstMatch
            XCTAssertTrue(app.buttons["downloadsButton"].waitForExistence(timeout: 5))
            checkFooterMatchesToolbar(in: app, appearance: appearance, placement: "sidebar")

            app.typeKey(",", modifierFlags: .command)
            AxoUITests.selectSettingsPane("general", in: app)
            app.radioButtons["Above the page"].click()
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(app.descendants(matching: .any)["pageAddressBar"].waitForExistence(timeout: 5))
            XCTAssertTrue(window.exists)
            checkFooterMatchesToolbar(in: app, appearance: appearance, placement: "above the page")
            app.terminate()
        }
    }

    /// With many Spaces the dots scroll inside their capsule, which stays between the buttons,
    /// lined up with them. Accessibility reports the scroll area inside the capsule (a dot's
    /// height), not the capsule, so the capsule's own height is checked in the attached
    /// screenshot.
    @MainActor
    func testSidebarFooterFitsManySpaces() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        for index in 1...10 {
            app.buttons["newSpaceButton"].click()
            let nameField = app.textFields["spaceNameField"]
            XCTAssertTrue(nameField.waitForExistence(timeout: 5))
            nameField.click()
            nameField.typeText("Space\(index)")
            app.buttons["createSpaceButton"].click()
            XCTAssertTrue(sidebar.staticTexts["Space\(index)"].waitForExistence(timeout: 5))
        }
        XCTAssertEqual(app.buttons.matching(identifier: "spaceButton").count, 11)
        let window = app.windows.firstMatch

        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = "Footer with eleven Spaces"
        shot.lifetime = .keepAlways
        add(shot)
        let downloads = app.buttons["downloadsButton"].frame
        let newSpace = app.buttons["newSpaceButton"].frame
        let dots = app.descendants(matching: .any)["spaceDots"].frame
        XCTAssertLessThanOrEqual(dots.height, 36 + 1, "The dots fit in a capsule the buttons' height")
        XCTAssertEqual(dots.midY, downloads.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(dots.minX, downloads.maxX, "The dots don't run under Downloads")
        XCTAssertLessThanOrEqual(dots.maxX, newSpace.minX, "Or under New Space")
        XCTAssertEqual(downloads.height, 36, accuracy: 1)
        XCTAssertEqual(newSpace.height, 36, accuracy: 1)
    }

    @MainActor
    private func checkFooterMatchesToolbar(in app: XCUIApplication, appearance: String, placement: String) {
        let window = app.windows.firstMatch.frame
        let inSidebar = placement == "sidebar"
        // The buttons at the top: reload (the sidebar's top row's, or above the page the control
        // bar's, #170) and Hide Sidebar, both 36 pt glass in line with the window's controls.
        let top = app.buttons["reloadButton"].frame
        let trailing = app.buttons["hideSidebarButton"].frame
        let leading = app.buttons[inSidebar ? "downloadsButton" : "settingsButton"].frame
        let newSpace = app.buttons["newSpaceButton"].frame
        let dots = app.descendants(matching: .any)["spaceDots"].frame
        let context = "\(appearance), navigation bar \(placement)"
        XCTAssertEqual(top.height, 36, accuracy: 1, "Reload's glass, \(context)")
        XCTAssertEqual(trailing.height, 36, accuracy: 1, "Hide Sidebar's glass, \(context)")
        let close = app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].frame
        XCTAssertEqual(close.midY, top.midY, accuracy: 1.5, "The top lines up with the window's controls, \(context)")
        for (name, frame) in [("The footer's leading button", leading), ("New Space", newSpace)] {
            XCTAssertEqual(frame.height, 36, accuracy: 1, "\(name) is the toolbar's glass size, \(context)")
            XCTAssertEqual(frame.width, frame.height, accuracy: 1, "\(name) is round, \(context)")
            XCTAssertEqual(frame.midY, leading.midY, accuracy: 1, "\(name) lines up, \(context)")
        }
        XCTAssertEqual(dots.height, 36, accuracy: 1, "The dots' capsule, \(context)")
        XCTAssertEqual(dots.midY, leading.midY, accuracy: 1, "The dots line up, \(context)")
        // The footer's buttons sit as far from the window's bottom and leading edges as the
        // top's buttons from its top, center to edge.
        let toolbarInset = top.midY - window.minY
        XCTAssertEqual(toolbarInset, 26, accuracy: 1, "The top's buttons are centered 26 pt down, \(context)")
        XCTAssertEqual(trailing.midY - window.minY, toolbarInset, accuracy: 1, "The top's buttons line up, \(context)")
        XCTAssertEqual(window.maxY - leading.midY, toolbarInset, accuracy: 1, "Bottom inset, \(context)")
        XCTAssertEqual(leading.midX - window.minX, toolbarInset, accuracy: 1, "Leading inset, \(context)")

        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "Toolbar and footer, \(context)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// With the navigation bar above the page, its address field and buttons work like the
    /// sidebar's: the field shows the page's address, clicking it and typing navigates the tab,
    /// and back and forward follow the history. Everything sits over the page, not the sidebar.
    @MainActor
    func testAddressBarAbovePage() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        AxoUITests.selectSettingsPane("general", in: app)
        app.radioButtons["Above the page"].click()
        app.typeKey("w", modifierFlags: .command)

        let address = app.descendants(matching: .any)["pageAddressBar"].textFields["addressField"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        for id in ["backButton", "forwardButton", "reloadButton", "siteSettingsButton"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.exists, "\(id) is in the page's control bar")
            XCTAssertGreaterThan(button.frame.minX, sidebar.frame.maxX - 1, "\(id) sits over the page")
        }

        AxoUITests.openPage(page("First"), in: app)
        XCTAssertTrue(sidebar.staticTexts["First"].waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "value CONTAINS '%3Ctitle%3EFirst'"), evaluatedWith: address)
        waitForExpectations(timeout: 5)

        // Clicking the field selects the address, so typing replaces it and the tab navigates.
        address.click()
        address.typeKey("a", modifierFlags: .command)
        address.typeText(page("Second") + "\n")
        XCTAssertTrue(sidebar.staticTexts["Second"].waitForExistence(timeout: 10))
        XCTAssertFalse(sidebar.staticTexts["First"].exists, "It navigates the tab instead of opening another")
        expectation(for: NSPredicate(format: "value CONTAINS '%3Ctitle%3ESecond'"), evaluatedWith: address)
        waitForExpectations(timeout: 5)

        let back = app.buttons["backButton"], forward = app.buttons["forwardButton"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: back)
        waitForExpectations(timeout: 10)
        back.click()
        XCTAssertTrue(sidebar.staticTexts["First"].waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: forward)
        waitForExpectations(timeout: 10)
        forward.click()
        XCTAssertTrue(sidebar.staticTexts["Second"].waitForExistence(timeout: 10))
    }

    /// Settings lists its panes in a sidebar like System Settings (#85): search filters them by
    /// their settings, Return opens the first match, the sidebar can't be hidden, the window is
    /// at least its minimum size, and it reopens on the last pane used. (That the window can be
    /// resized is a unit test: XCUITest's drags don't resize windows on the hosted runner.)
    @MainActor
    func testSettingsSidebarSearchesAndRemembersThePane() throws {
        let app = launchApp()
        XCTAssertTrue(app.descendants(matching: .any)["sidebar"].waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        AxoUITests.selectSettingsPane("linkRouting", in: app)
        XCTAssertTrue(app.buttons["addDomainRouteButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["addDomainRouteButton"].isHittable, "The window opens on screen, not taller than it")
        let general = app.descendants(matching: .any)["settingsPane.general"]
        let profiles = app.descendants(matching: .any)["settingsPane.profiles"]
        XCTAssertTrue(profiles.exists, "Every pane is listed before searching")

        // ⌘F searches; the panes whose settings match stay.
        app.typeKey("f", modifierFlags: .command)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("navigation bar")
        XCTAssertTrue(profiles.waitForNonExistence(timeout: 5), "Profiles has no navigation bar setting")
        XCTAssertTrue(general.exists, "General holds the navigation bar setting")
        XCTAssertTrue(app.radioButtons["Above the page"].waitForExistence(timeout: 5),
                      "The first match shows once the pane showing no longer matches")
        search.typeText("\n")
        XCTAssertTrue(app.radioButtons["Above the page"].exists, "Return keeps the first match")

        let window = app.windows.containing(.any, identifier: "settingsPaneList").firstMatch
        XCTAssertTrue(window.exists)
        XCTAssertGreaterThanOrEqual(window.frame.width, 719)
        XCTAssertGreaterThanOrEqual(window.frame.height, 479)

        // The sidebar can't be hidden: View › Toggle Sidebar leaves it.
        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(app.descendants(matching: .any)["settingsPaneList"].waitForExistence(timeout: 2))
        XCTAssertTrue(general.isHittable, "The panes stay on screen")

        // Closed and opened again, it shows the last pane used.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(window.waitForNonExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.radioButtons["Above the page"].waitForExistence(timeout: 5), "Settings reopens on General")
        XCTAssertTrue(app.descendants(matching: .any)["settingsPane.profiles"].exists, "The search is cleared")
    }

    /// Settings › Profiles adds a profile, then deletes the default one, moving the Home Space to
    /// the new profile.
    @MainActor
    func testProfilesInSettings() throws {
        let app = launchApp()
        XCTAssertTrue(app.descendants(matching: .any)["sidebar"].waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        AxoUITests.selectSettingsPane("profiles", in: app)

        let list = app.outlines["profileList"].exists ? app.outlines["profileList"] : app.tables["profileList"]
        XCTAssertTrue(app.textFields["profileNameField"].waitForExistence(timeout: 5), "The current profile is selected")
        XCTAssertEqual(app.textFields["profileNameField"].value as? String, "Default")
        XCTAssertTrue(app.staticTexts["Home"].exists, "It lists the Spaces that use it")
        XCTAssertFalse(app.buttons["deleteProfileButton"].isEnabled, "The only profile can't be deleted")

        // A new profile comes with its first Space (#176).
        app.buttons["addProfileButton"].click()
        let nameField = app.textFields["settingsNewProfileName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.typeText("Work")
        let firstSpace = app.textFields["profileFirstSpaceField"]
        firstSpace.click()
        firstSpace.typeText("Office")
        app.buttons["createProfileButton"].click()
        XCTAssertTrue(list.staticTexts["Work"].waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value == 'Work'"), evaluatedWith: app.textFields["profileNameField"])
        waitForExpectations(timeout: 5)
        // The Settings window: the one holding the profile list, not the browser window's sidebar.
        let settings = app.windows.containing(.any, identifier: "profileList").firstMatch
        XCTAssertTrue(settings.staticTexts["Office"].waitForExistence(timeout: 5), "Its first Space uses it, in Settings")

        list.staticTexts["Default"].click()
        app.buttons["deleteProfileButton"].click()
        let confirm = app.buttons["confirmDeleteProfileButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.popUpButtons["replacementProfilePicker"].exists, "It asks where Home goes")
        confirm.click()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: list.staticTexts["Default"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(list.staticTexts["Work"].exists)
    }

    /// Settings › Spaces gives a Space a color and icon, adds a Space, renames it, and deletes it.
    @MainActor
    func testSpacesInSettings() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        AxoUITests.selectSettingsPane("spaces", in: app)

        let name = app.textFields["spaceNameSettingsField"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "The current Space is selected")
        XCTAssertEqual(name.value as? String, "Home")
        XCTAssertTrue(app.descendants(matching: .any)["spaceProfilePicker"].exists, "It shows the profile (a picker once there are two)")
        XCTAssertFalse(app.buttons["deleteSpaceButton"].isEnabled, "The only Space can't be deleted")

        let teal = app.descendants(matching: .any)["spaceColorSwatches"].buttons["Teal"]
        teal.click()
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: teal)
        waitForExpectations(timeout: 5)
        let leaf = app.descendants(matching: .any)["spaceIconGrid"].buttons["Leaf"]
        leaf.click()
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: leaf)
        waitForExpectations(timeout: 5)

        app.buttons["addSpaceButton"].click()
        let newName = app.textFields["spaceNameField"]
        XCTAssertTrue(newName.waitForExistence(timeout: 5))
        newName.typeText("Work")
        app.buttons["createSpaceButton"].click()
        expectation(for: NSPredicate(format: "value == 'Work'"), evaluatedWith: name)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["deleteSpaceButton"].isEnabled)

        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Projects\n")
        let list = app.outlines["spaceList"].exists ? app.outlines["spaceList"] : app.tables["spaceList"]
        XCTAssertTrue(list.staticTexts["Projects"].waitForExistence(timeout: 5))

        app.buttons["deleteSpaceButton"].click()
        // The − button is also called Delete Space, so look in the confirmation sheet.
        let confirm = app.sheets.buttons["Delete Space"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: list.staticTexts["Projects"])
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.buttons.matching(identifier: "spaceButton").count, 1)
    }

    /// A tab becomes a favorite from its context menu: it moves to the grid above the pinned
    /// tabs, ⌘1 shows it, it stays in another Space of the same profile, and its own menu
    /// removes it.
    @MainActor
    func testFavorites() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        AxoUITests.openPage(page("Mail"), in: app)
        XCTAssertTrue(sidebar.staticTexts["Mail"].waitForExistence(timeout: 10))
        AxoUITests.openPage(page("News"), in: app)
        XCTAssertTrue(sidebar.staticTexts["News"].waitForExistence(timeout: 10))

        sidebar.staticTexts["Mail"].rightClick()
        app.windows.firstMatch.menuItems["Add to Favorites"].click()
        let tile = app.buttons["favoriteTile"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        XCTAssertEqual(tile.label, "Mail")
        XCTAssertFalse(sidebar.staticTexts["Mail"].exists, "It leaves the tab list")
        XCTAssertTrue(app.descendants(matching: .any)["favoritesGrid"].exists)

        sidebar.staticTexts["News"].click()
        app.typeKey("1", modifierFlags: .command)
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: tile)
        waitForExpectations(timeout: 5)
        expectation(for: NSPredicate(format: "value CONTAINS 'Mail'"), evaluatedWith: app.descendants(matching: .any)["sidebarAddressBar"])
        waitForExpectations(timeout: 5)

        app.buttons["newSpaceButton"].click()
        let nameField = app.textFields["spaceNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.typeText("Work")
        app.buttons["createSpaceButton"].click()
        XCTAssertTrue(sidebar.staticTexts["Work"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["favoriteTile"].exists, "Every Space of the profile shows it")

        app.buttons["favoriteTile"].rightClick()
        app.windows.firstMatch.menuItems["Remove from Favorites"].click()
        XCTAssertTrue(app.buttons["favoriteTile"].waitForNonExistence(timeout: 5))
    }

    /// The sidebar's footer: Downloads on the left (#67), a dot per Space (the current one
    /// selected) in the middle, and New Space on the right.
    @MainActor
    func testSidebarFooter() throws {
        let app = launchApp()
        let footer = app.descendants(matching: .any)["spaceSwitcher"]
        XCTAssertTrue(footer.waitForExistence(timeout: 5))
        let downloads = footer.buttons["downloadsButton"], newSpace = footer.buttons["newSpaceButton"]
        let dot = footer.buttons["spaceButton"]
        XCTAssertTrue(downloads.exists && newSpace.exists && dot.exists)
        XCTAssertFalse(footer.buttons["settingsButton"].exists, "Settings is in the Axo menu (⌘,)")
        XCTAssertLessThan(downloads.frame.midX, dot.frame.midX)
        XCTAssertLessThan(dot.frame.midX, newSpace.frame.midX)
        XCTAssertEqual(dot.label, "Home")
        XCTAssertTrue(dot.isSelected)

        downloads.click()
        XCTAssertTrue(app.buttons["clearDownloadsButton"].waitForExistence(timeout: 5), "The list opens")
        XCTAssertLessThan(app.buttons["clearDownloadsButton"].frame.maxY, downloads.frame.minY, "Above the footer")
    }

    /// Pin a tab from its context menu, close and reopen an unpinned tab, and see that closing
    /// the pinned tab keeps it in the sidebar.
    @MainActor
    func testPinCloseAndReopenTabs() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        for title in ["Mail", "Article"] {
            AxoUITests.openPage("data:text/html,<title>\(title)</title>", in: app)
            XCTAssertTrue(sidebar.staticTexts[title].waitForExistence(timeout: 10))
        }

        sidebar.staticTexts["Mail"].rightClick()
        // Scoped to the window: the Tabs menu in the menu bar also has "Pin Tab".
        app.windows.firstMatch.menuItems["Pin Tab"].click()
        XCTAssertTrue(sidebar.staticTexts["Pinned"].waitForExistence(timeout: 5))

        // ⌘W on the unpinned tab archives it; ⇧⌘T brings it back.
        sidebar.staticTexts["Article"].click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(sidebar.staticTexts["Article"].waitForNonExistence(timeout: 5))
        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertTrue(sidebar.staticTexts["Article"].waitForExistence(timeout: 5))

        // ⌘W on the pinned tab unloads it but keeps it pinned.
        sidebar.staticTexts["Mail"].click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(sidebar.staticTexts["Pinned"].exists)
        XCTAssertTrue(sidebar.staticTexts["Mail"].waitForExistence(timeout: 5))
    }

    /// Create a folder with ⌃⌘N, move a tab into it from the context menu, and collapse it.
    @MainActor
    func testFoldersHoldPinnedTabs() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        AxoUITests.openPage("data:text/html,<title>Docs</title>", in: app)
        XCTAssertTrue(sidebar.staticTexts["Docs"].waitForExistence(timeout: 10))

        app.typeKey("n", modifierFlags: [.command, .control])
        let nameField = app.textFields["nameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.typeText("Work\n")
        XCTAssertTrue(sidebar.staticTexts["Work"].waitForExistence(timeout: 5))

        sidebar.staticTexts["Docs"].rightClick()
        // The context menu is in the window; the Tabs menu in the menu bar has the same items.
        let contextMenu = app.windows.firstMatch
        contextMenu.menuItems["Move to Folder"].hover()
        contextMenu.menuItems["Work"].click()
        XCTAssertTrue(sidebar.staticTexts["Pinned"].waitForExistence(timeout: 5), "Moving into a folder pins the tab")
        XCTAssertTrue(sidebar.staticTexts["Docs"].waitForExistence(timeout: 5))

        // Collapsing the folder hides the tab inside it.
        sidebar.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(sidebar.staticTexts["Docs"].waitForNonExistence(timeout: 5))
    }

    /// ⌘T opens the command bar: typed addresses open in a new tab, and matching tabs can be
    /// picked with the arrow keys and Return.
    @MainActor
    func testCommandBarOpensPagesAndSwitchesTabs() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        for title in ["Garden notes", "Recipes"] {
            app.typeKey("t", modifierFlags: .command)
            let field = app.textFields["commandField"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            // Into the field itself: typed at the app as the bar opens, the first letter can be
            // lost ("ata:…" is a search, not a page).
            field.typeText("data:text/html,<title>\(title)</title>\n")
            XCTAssertTrue(sidebar.staticTexts[title].waitForExistence(timeout: 10))
            XCTAssertFalse(app.textFields["commandField"].exists, "The command bar closes after opening a page")
        }

        app.typeKey("t", modifierFlags: .command)
        let field = app.textFields["commandField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("garden")
        let tabRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'commandResult' AND label CONTAINS 'Garden notes'"))
            .firstMatch
        XCTAssertTrue(tabRow.waitForExistence(timeout: 5))
        // The first row searches for "garden"; the matching tab is next.
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])

        XCTAssertFalse(app.textFields["commandField"].waitForExistence(timeout: 2))
        let address = app.descendants(matching: .any)["sidebarAddressBar"]
        expectation(for: NSPredicate(format: "value CONTAINS 'Garden'"), evaluatedWith: address)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(sidebar.staticTexts.matching(identifier: "tabRow").count, 2, "Switching doesn't open a tab")

        // Esc closes the command bar without doing anything.
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.textFields["commandField"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.textFields["commandField"].waitForNonExistence(timeout: 5))
    }

    /// Settings › Site Customizations adds a site's CSS, turns it off, and deletes it.
    /// The iCloud pane explains that a test build can't sync, with the switch unavailable.
    /// (Syncing itself needs a signed Release build; AxoSync's tests cover it with a fake cloud.)
    @MainActor
    func testICloudPaneInSettings() throws {
        let app = launchApp()
        XCTAssertTrue(app.descendants(matching: .any)["sidebar"].waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        AxoUITests.selectSettingsPane("iCloud", in: app)

        let toggle = app.descendants(matching: .any)["syncToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertFalse(toggle.isEnabled)
        XCTAssertEqual(app.staticTexts["syncStatus"].value as? String, "This copy of Axo can't use iCloud. Official releases can.")
        XCTAssertFalse(app.buttons["syncNowButton"].exists)
    }

    @MainActor
    func testSiteCustomizationsInSettings() throws {
        let app = launchApp()
        XCTAssertTrue(app.descendants(matching: .any)["sidebar"].waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        AxoUITests.selectSettingsPane("siteCustomizations", in: app)

        app.buttons["addSiteCustomizationButton"].click()
        let domain = app.textFields["customizationDomainField"]
        XCTAssertTrue(domain.waitForExistence(timeout: 5))
        domain.click()
        domain.typeText("www.Example.com")
        let css = app.textViews["customizationCSSEditor"]
        css.click()
        css.typeText("p { color: red }")
        app.buttons["saveCustomizationButton"].click()

        let row = app.descendants(matching: .any).matching(identifier: "siteCustomization").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let toggle = row.checkBoxes.firstMatch
        XCTAssertEqual(toggle.label, "example.com", "The domain is tidied")
        XCTAssertEqual(toggle.value as? Int, 1)
        toggle.click()
        expectation(for: NSPredicate(format: "value == 0"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)

        row.buttons["Delete example.com"].click()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
    }

    /// Settings › Link Routing adds a domain rule, and a link to that domain from another app
    /// opens as a tab in the rule's Space instead of a mini window.
    @MainActor
    func testLinkRoutingRulesSendLinksToASpace() throws {
        // Port 9 on the loopback address refuses connections, so nothing leaves the machine.
        let app = launchApp(externalLink: "http://127.0.0.1:9/routed")
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        app.buttons["newSpaceButton"].click()
        let spaceName = app.textFields["spaceNameField"]
        XCTAssertTrue(spaceName.waitForExistence(timeout: 5))
        spaceName.typeText("Work")
        app.buttons["createSpaceButton"].click()
        XCTAssertTrue(sidebar.staticTexts["Work"].waitForExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .control)

        app.typeKey(",", modifierFlags: .command)
        // Settings reopens on the last pane used, so choose one.
        AxoUITests.selectSettingsPane("linkRouting", in: app)
        let addDomain = app.buttons["addDomainRouteButton"]
        XCTAssertTrue(addDomain.waitForExistence(timeout: 5))
        addDomain.click()
        let domain = app.textFields["routeDomainField"]
        XCTAssertTrue(domain.waitForExistence(timeout: 5))
        domain.typeText("127.0.0.1")
        app.popUpButtons["routeSpacePicker"].click()
        app.menuItems["Work"].click()
        app.buttons["addRouteConfirmButton"].click()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "linkRoute").firstMatch.waitForExistence(timeout: 5))
        // Close Settings, then the browser window too (⌘W with no tab open closes it): a routed
        // link brings the window back.
        app.windows.matching(NSPredicate(format: "title == 'Link Routing'")).firstMatch.buttons[XCUIIdentifierCloseWindow].click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(sidebar.waitForNonExistence(timeout: 5))

        Self.sendExternalLink(in: app)
        XCTAssertTrue(sidebar.staticTexts["127.0.0.1"].waitForExistence(timeout: 10), "The link opens as a tab, in a window")
        XCTAssertTrue(sidebar.staticTexts["Work"].exists, "in the Work Space")
        XCTAssertFalse(app.buttons["miniOpenInAxoButton"].exists, "not in a mini window")
    }

    /// A link sent from another app opens in a mini window, and Open in Axo makes it a tab.
    @MainActor
    func testLinksFromOtherAppsOpenInAMiniWindow() throws {
        // Port 9 on the loopback address refuses connections, so nothing leaves the machine.
        let app = launchApp(externalLink: "http://127.0.0.1:9/from-another-app")
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))

        Self.sendExternalLink(in: app)

        let openInAxo = app.buttons["miniOpenInAxoButton"]
        XCTAssertTrue(openInAxo.waitForExistence(timeout: 10), "The link opens in a mini window")
        XCTAssertEqual(app.windows.count, 2)
        XCTAssertFalse(sidebar.staticTexts["127.0.0.1"].exists, "It isn't a tab yet")

        openInAxo.click()
        XCTAssertTrue(sidebar.staticTexts["127.0.0.1"].waitForExistence(timeout: 10), "Open in Axo makes it a tab")
        XCTAssertEqual(app.windows.count, 1, "The mini window closes")
    }

    /// In a pinned tab, a link to another site opens in Peek instead of leaving the pinned page.
    /// Esc closes Peek, and Open as Tab moves its page into the sidebar.
    @MainActor
    func testLinksFromPinnedTabsOpenInPeek() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        // The link points at a closed loopback port, so nothing leaves the machine.
        // Not titled after the Space ("Home"), whose name row would match instead.
        AxoUITests.openPage("data:text/html,<title>Harbor</title><a href='http://127.0.0.1:9/far'>Far away</a>", in: app)
        XCTAssertTrue(sidebar.staticTexts["Harbor"].waitForExistence(timeout: 10))
        app.typeKey("p", modifierFlags: [.command, .control])
        XCTAssertTrue(sidebar.staticTexts["Pinned"].waitForExistence(timeout: 5))

        let link = app.webViews.firstMatch.links["Far away"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.click()
        let peek = app.descendants(matching: .any)["peek"]
        XCTAssertTrue(peek.waitForExistence(timeout: 5))

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(peek.waitForNonExistence(timeout: 5), "Esc closes Peek")
        // (While Peek is open it's modal, so the sidebar isn't in the accessibility tree.)
        XCTAssertTrue(sidebar.staticTexts["Harbor"].waitForExistence(timeout: 5))
        XCTAssertFalse(sidebar.staticTexts["127.0.0.1"].exists, "Peek never joined the sidebar")

        link.click()
        XCTAssertTrue(peek.waitForExistence(timeout: 5))
        app.buttons["peekOpenAsTabButton"].click()
        XCTAssertTrue(peek.waitForNonExistence(timeout: 5))
        XCTAssertTrue(sidebar.staticTexts["127.0.0.1"].waitForExistence(timeout: 5), "The page is now a tab")
    }

    /// Hovering a link shows where it goes at the bottom of the page, and moving away hides it.
    @MainActor
    func testHoveringALinkShowsItsAddress() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        // The link points at a closed loopback port, and isn't clicked.
        AxoUITests.openPage("data:text/html,<title>Pond</title><a href='http://127.0.0.1:9/axolotl'>An axolotl</a>", in: app)
        XCTAssertTrue(sidebar.staticTexts["Pond"].waitForExistence(timeout: 10))

        let link = app.webViews.firstMatch.links["An axolotl"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.hover()
        let status = app.descendants(matching: .any)["linkStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.value as? String, "http://127.0.0.1:9/axolotl")

        // Off the link, onto the page's empty space below it. (Off the page altogether, onto
        // the sidebar, WebKit doesn't always report the pointer leaving the link in UI tests;
        // the Mac runs pages on Chromium, which reports it through its own hook, checked by the
        // engine's test_hovered_links.sh.)
        app.webViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).hover()
        XCTAssertTrue(status.waitForNonExistence(timeout: 5), "Leaving the link hides it")
    }

    /// Add Split View (⌃⇧=) shows a chosen tab next to the current one as one sidebar row, and
    /// the split can be stacked and separated from the Tabs menu.
    @MainActor
    func testSplitView() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        for title in ["Notes", "Docs"] {
            AxoUITests.openPage("data:text/html,<title>\(title)</title>", in: app)
            XCTAssertTrue(sidebar.staticTexts[title].waitForExistence(timeout: 10))
        }

        app.typeKey("=", modifierFlags: [.control, .shift])
        XCTAssertTrue(app.textFields["commandField"].waitForExistence(timeout: 5))
        app.typeText("notes")
        let notes = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'commandResult' AND label CONTAINS 'Notes'")).firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        notes.click()

        let splitView = app.descendants(matching: .any)["splitView"]
        XCTAssertTrue(splitView.waitForExistence(timeout: 10))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "splitPane").count, 2)
        let row = sidebar.descendants(matching: .any).matching(identifier: "splitRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        // A static text exposes its spoken text as its value.
        let spoken = (row.value as? String) ?? row.label
        XCTAssertTrue(spoken.contains("Split view") && spoken.contains("Docs") && spoken.contains("Notes"), spoken)
        XCTAssertEqual(sidebar.staticTexts.matching(identifier: "tabRow").count, 0, "The two tabs are one row")

        app.menuBars.menuBarItems["Tabs"].click()
        app.menuBars.menuItems["Stack Panes"].click()
        app.menuBars.menuBarItems["Tabs"].click()
        XCTAssertTrue(app.menuBars.menuItems["Show Panes Side by Side"].waitForExistence(timeout: 5))
        app.menuBars.menuItems["Separate Split View"].click()

        XCTAssertTrue(splitView.waitForNonExistence(timeout: 5))
        XCTAssertEqual(sidebar.staticTexts.matching(identifier: "tabRow").count, 2)
    }

    /// The sidebar works from the keyboard: switching tabs, pinning, reordering, and moving a
    /// tab into a folder, all through menu commands and shortcuts.
    @MainActor
    func testSidebarWorksFromTheKeyboard() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        for title in ["Alpha", "Beta", "Gamma"] {
            AxoUITests.openPage("data:text/html,<title>\(title)</title>", in: app)
            XCTAssertTrue(sidebar.staticTexts[title].waitForExistence(timeout: 10))
        }
        let address = app.descendants(matching: .any)["sidebarAddressBar"]
        func expectSelected(_ title: String) {
            expectation(for: NSPredicate(format: "value CONTAINS %@", title), evaluatedWith: address)
            waitForExpectations(timeout: 5)
        }
        func rowOrder() -> [String] {
            sidebar.staticTexts.matching(identifier: "tabRow").allElementsBoundByIndex.map(\.label)
        }

        // ⌥⌘↑ and ⌥⌘↓ switch tabs, wrapping around.
        app.typeKey(.upArrow, modifierFlags: [.command, .option])
        expectSelected("Beta")
        app.typeKey(.downArrow, modifierFlags: [.command, .option])
        app.typeKey(.downArrow, modifierFlags: [.command, .option])
        expectSelected("Alpha")

        // ⌥⇧⌘↓ moves the selected tab down.
        app.typeKey(.downArrow, modifierFlags: [.command, .option, .shift])
        // Queries can't run inside an expectation's predicate, so poll.
        let deadline = Date().addingTimeInterval(5)
        while rowOrder() != ["Beta", "Alpha", "Gamma"], Date() < deadline { usleep(100_000) }
        XCTAssertEqual(rowOrder(), ["Beta", "Alpha", "Gamma"])

        // ⌃⌘P pins it.
        app.typeKey("p", modifierFlags: [.command, .control])
        XCTAssertTrue(sidebar.staticTexts["Pinned"].waitForExistence(timeout: 5))

        // Tabs › Move to Folder › New Folder… moves it into a new folder.
        app.menuBars.menuBarItems["Tabs"].click()
        app.menuBars.menuItems["Move to Folder"].hover()
        app.menuBars.menuItems["New Folder…"].click()
        let nameField = app.textFields["nameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.typeText("Work\n")
        XCTAssertTrue(sidebar.staticTexts["Work"].waitForExistence(timeout: 5))
        XCTAssertTrue(sidebar.staticTexts["Alpha"].exists)

        // Folder rows can be selected, so folder commands work from the menu bar.
        sidebar.staticTexts["Work"].click()
        app.menuBars.menuBarItems["Tabs"].click()
        let rename = app.menuBars.menuItems["Rename Folder…"]
        XCTAssertTrue(rename.isEnabled, "A selected folder enables its commands")
        rename.click()
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText("Projects\n")
        XCTAssertTrue(sidebar.staticTexts["Projects"].waitForExistence(timeout: 5))
    }

    /// Site Settings shows the current site's camera, microphone, and location answers, which
    /// can be changed and reset.
    @MainActor
    func testSiteSettingsChangeAndResetASitesPermissions() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        // The address bar's Site Settings button shows only on hover, so this goes through the
        // menu bar, as the keyboard does.
        let siteSettings = app.menuBars.menuItems["Site Settings…"]
        app.menuBars.menuBarItems["View"].click()
        XCTAssertFalse(siteSettings.isEnabled, "No site without a web page")
        app.typeKey(.escape, modifierFlags: [])

        // A closed loopback port: nothing loads, but the tab has a web address.
        // Typed into the field itself: typed at the app just after the View menu closed, the
        // first letter could be lost ("ttp://…", not a web address).
        app.typeKey("t", modifierFlags: .command)
        let field = app.textFields["commandField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("http://127.0.0.1:9/room")
        expectation(for: NSPredicate(format: "value == %@", "http://127.0.0.1:9/room"), evaluatedWith: field)
        waitForExpectations(timeout: 5)
        field.typeText("\n")
        XCTAssertTrue(sidebar.staticTexts["127.0.0.1"].waitForExistence(timeout: 10))
        // The row can appear a moment before the tab is selected; Site Settings is for the page
        // showing, which the address bar names once it's shown.
        let address = app.descendants(matching: .any)["sidebarAddressBar"]
        expectation(for: NSPredicate(format: "value CONTAINS %@", "127.0.0.1"), evaluatedWith: address)
        waitForExpectations(timeout: 10)

        app.menuBars.menuBarItems["View"].click()
        let toggle = app.menuBars.menuItems["Hide Address Bar in Sidebar"]
        XCTAssertTrue(siteSettings.isEnabled, """
            The shown page's site has settings (window's model in the menu: \(toggle.exists && toggle.isEnabled), \
            Copy Link: \(app.menuBars.menuItems["Copy Link"].isEnabled), address: \(address.value ?? "none"))
            """)
        siteSettings.click()
        let camera = app.popUpButtons["sitePermission-camera"]
        XCTAssertTrue(camera.waitForExistence(timeout: 5))
        XCTAssertEqual(camera.value as? String, "Ask")
        XCTAssertTrue(app.popUpButtons["sitePermission-microphone"].exists)
        XCTAssertTrue(app.popUpButtons["sitePermission-location"].exists)
        // UI tests run on WebKit, which never asks about notifications or the clipboard, so Site
        // Settings doesn't offer them (Chromium's rows are covered by the model's tests).
        XCTAssertFalse(app.popUpButtons["sitePermission-notifications"].exists)
        XCTAssertFalse(app.popUpButtons["sitePermission-clipboard"].exists)

        camera.click()
        app.menuItems["Don't Allow"].click()
        expectation(for: NSPredicate(format: "value == %@", "Don't Allow"), evaluatedWith: camera)
        waitForExpectations(timeout: 5)

        app.buttons["resetSiteSettings"].click()
        expectation(for: NSPredicate(format: "value == %@", "Ask"), evaluatedWith: camera)
        waitForExpectations(timeout: 5)
    }

    /// Summarize Page shows a summary of the page's text in a popover. UI tests use a
    /// predictable stand-in for the on-device model. Translation isn't run here, since it can
    /// show macOS's language download sheet; the model tests cover it with a fake session.
    @MainActor
    func testSummarizePageShowsASummary() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        // With the navigation bar in the sidebar it has no button (#67): View › Summarize Page
        // asks for it, and it hangs from the address bar.
        XCTAssertFalse(app.buttons["summarizeButton"].exists, "No button while the sidebar shows")
        app.menuBars.menuBarItems["View"].click()
        XCTAssertFalse(app.menuBars.menuItems["Summarize Page"].isEnabled, "Nothing to summarize without a tab")
        app.typeKey(.escape, modifierFlags: [])

        AxoUITests.openPage("data:text/html,<title>Story</title><p>Axolotls regrow limbs.</p>", in: app)
        XCTAssertTrue(sidebar.staticTexts["Story"].waitForExistence(timeout: 10))

        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuItems["Summarize Page"].click()
        let summary = app.staticTexts["summaryText"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertEqual(summary.value as? String, "• Story: Axolotls regrow limbs.")
        let address = app.descendants(matching: .any)["sidebarAddressBar"].frame
        XCTAssertGreaterThan(summary.frame.minY, address.maxY, "It hangs below the address bar")
        XCTAssertLessThan(summary.frame.minX, address.maxX, "beside the sidebar, not across the window")

        // Checked after the button: a click right after Esc closes the menu was sometimes lost.
        app.menuBars.menuBarItems["View"].click()
        XCTAssertTrue(app.menuBars.menuItems["Translate Page"].isEnabled)
        XCTAssertTrue(app.menuBars.menuItems["Summarize Page"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }

    /// The command bar finds and runs items from Axo's menus (#123): View › Hide Address Bar
    /// in Sidebar, found by typing part of it.
    @MainActor
    func testCommandBarRunsAMenuCommand() throws {
        let app = launchApp()
        let addressBar = app.descendants(matching: .any)["sidebarAddressBar"]
        XCTAssertTrue(addressBar.waitForExistence(timeout: 5))
        app.typeKey("t", modifierFlags: .command)
        let commandField = app.textFields["commandField"]
        XCTAssertTrue(commandField.waitForExistence(timeout: 5))
        commandField.typeText("hide address bar")
        let result = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'commandResult' AND label CONTAINS 'Hide Address Bar in Sidebar'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5), "The menu item is a result")
        XCTAssertTrue(result.label.contains("View menu"), "It names its menu: \(result.label)")
        result.click()
        XCTAssertTrue(addressBar.waitForNonExistence(timeout: 5), "Running it hid the address bar")
    }

    /// Import from Another Browser reads Arc's Spaces and Chrome's bookmarks from fixture files
    /// (never the real ones) and adds them to the sidebar.
    @MainActor
    func testImportingFromArcAndChrome() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AxoUITestImport-\(UUID().uuidString)")
        let arc = root.appending(path: "Arc")
        let chrome = root.appending(path: "Google/Chrome/Default")
        try FileManager.default.createDirectory(at: arc, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        // Pages point at a closed loopback port, so nothing leaves the machine even if one loads.
        try """
        {"sidebar": {"containers": [{"global": {}}, {
          "topAppsContainerIDs": [{"default": true}, "top"],
          "spaces": ["s", {"id": "s", "title": "Reading", "profile": {"default": true}, "containerIDs": ["pinned", "p", "unpinned", "u"]}],
          "items": [
            "top", {"id": "top", "childrenIds": ["fav"], "data": {"itemContainer": {}}},
            "fav", {"id": "fav", "childrenIds": [], "data": {"tab": {"savedURL": "http://127.0.0.1:9/mail", "savedTitle": "Mail"}}},
            "p", {"id": "p", "childrenIds": ["lib"], "data": {"itemContainer": {}}},
            "lib", {"id": "lib", "childrenIds": [], "data": {"tab": {"savedURL": "http://127.0.0.1:9/library", "savedTitle": "Library"}}},
            "u", {"id": "u", "childrenIds": [], "data": {"itemContainer": {}}}
          ]}]}}
        """.write(to: arc.appending(path: "StorableSidebar.json"), atomically: true, encoding: .utf8)
        try """
        {"roots": {"bookmark_bar": {"children": [{"type": "url", "name": "Docs", "url": "http://127.0.0.1:9/docs"}]}}}
        """.write(to: chrome.appending(path: "Bookmarks"), atomically: true, encoding: .utf8)

        let app = Self.makeApp()
        app.launchEnvironment["AXO_UI_TESTING_IMPORT_ROOT"] = root.path
        app.launch()
        Self.bringToFront(app)
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))

        app.menuBars.menuItems["Import from Another Browser…"].click()
        let spaces = app.checkBoxes["importPart-spaces"]
        XCTAssertTrue(spaces.waitForExistence(timeout: 10), "Arc is chosen first and read")
        XCTAssertTrue(app.checkBoxes["importPart-favorites"].exists)
        app.buttons["importButton"].click()
        let result = app.staticTexts["importResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertEqual(result.value as? String, "Imported 1 Space, 1 pinned tab, and 1 favorite.")
        app.buttons["importDoneButton"].click()

        XCTAssertEqual(app.buttons.matching(identifier: "spaceButton").count, 2, "The Arc Space is added")
        app.typeKey("2", modifierFlags: .control)
        // The Space's only tab is selected, so it starts loading (a closed port), which can
        // replace its imported title with an empty one; the row then shows the host.
        let library = sidebar.staticTexts.matching(NSPredicate(format: "label == 'Library' OR label == '127.0.0.1'")).firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 5), "The Arc Space's pinned tab is there")
        XCTAssertEqual(app.buttons.matching(identifier: "favoriteTile").count, 1, "Arc's favorite joins Favorites")

        // Chrome's bookmarks go into the current Space.
        app.typeKey("t", modifierFlags: .command)
        let commandField = app.textFields["commandField"]
        XCTAssertTrue(commandField.waitForExistence(timeout: 5))
        commandField.typeText("import")
        let action = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'commandResult' AND label CONTAINS 'Import from Another Browser'")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        // The first row searches for "import"; the action is next.
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        let picker = app.popUpButtons["importSourcePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.click()
        // The picker's own menu: the Apple menu's Recent Items can list Google Chrome too.
        picker.menuItems["Google Chrome"].click()
        XCTAssertTrue(app.checkBoxes["importPart-bookmarks"].waitForExistence(timeout: 10))
        app.buttons["importButton"].click()
        XCTAssertTrue(app.staticTexts["importResult"].waitForExistence(timeout: 10))
        app.buttons["importDoneButton"].click()
        XCTAssertTrue(sidebar.staticTexts["Imported from Chrome"].waitForExistence(timeout: 5))
    }

    /// An installed extension shows a toolbar button with its badge, and clicking it opens its
    /// popup.
    @MainActor
    func testExtensionToolbarButtonOpensItsPopup() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AxoUITestExtension-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {"name": "Axo Helper", "version": "1.0", "manifest_version": 3, "description": "UI test extension.",
         "action": {"default_title": "Axo Helper", "default_popup": "popup.html"},
         "background": {"service_worker": "bg.js"}}
        """.write(to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try "chrome.action.setBadgeText({ text: '3' });".write(to: folder.appending(path: "bg.js"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>Helper</title><body style='width:240px'><p>Hello from Axo Helper</p></body>"
            .write(to: folder.appending(path: "popup.html"), atomically: true, encoding: .utf8)

        let app = Self.makeApp()
        app.launchEnvironment["AXO_UI_TESTING_EXTENSION"] = folder.path
        app.launch()
        Self.bringToFront(app)

        let button = app.buttons.matching(NSPredicate(format: "identifier == 'extensionButton' AND label CONTAINS 'Axo Helper'")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label CONTAINS '3'"), evaluatedWith: button)
        waitForExpectations(timeout: 10)
        // Pinned at the right end of the sidebar's address bar (#67).
        let address = app.descendants(matching: .any)["sidebarAddressBar"].frame
        XCTAssertTrue(address.insetBy(dx: -1, dy: -1).contains(CGPoint(x: button.frame.midX, y: button.frame.midY)),
                      "In the address bar: \(button.frame) in \(address)")
        XCTAssertGreaterThan(button.frame.midX, address.midX, "At its right end")

        button.click()
        XCTAssertTrue(app.popovers.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.popovers.firstMatch.staticTexts["Hello from Axo Helper"].waitForExistence(timeout: 10))
    }

    /// Writes an unpacked test extension and returns its folder.
    private func writeTestExtension(name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AxoUITestExtension-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {"name": "\(name)", "version": "1.0", "manifest_version": 3, "description": "UI test extension.",
         "permissions": ["tabs"], "host_permissions": ["<all_urls>"],
         "action": {"default_title": "\(name)", "default_popup": "popup.html"}}
        """.write(to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>\(name)</title><p>\(name)</p>".write(to: folder.appending(path: "popup.html"), atomically: true, encoding: .utf8)
        return folder
    }

    /// Install Extension… shows a prompt with what the extension can do; adding it puts its
    /// button in the toolbar.
    @MainActor
    func testInstallingAnExtensionAsksFirst() throws {
        let folder = try writeTestExtension(name: "Reading List")
        let app = launchApp()
        XCTAssertTrue(app.descendants(matching: .any)["sidebar"].waitForExistence(timeout: 5))

        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuItems["Install Extension…"].click()
        let panel = app.sheets.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(folder.path + "\n")
        let install = panel.buttons["Install"]
        XCTAssertTrue(install.waitForExistence(timeout: 5))
        install.click()

        let prompt = app.descendants(matching: .any)["extensionInstallPrompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Add “Reading List”?"].exists)
        // The permission lines are one accessibility element, so VoiceOver reads them together.
        let lines = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                  "Read and change your data on all websites", "Read and change your data on all websites"))
        XCTAssertTrue(lines.firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(identifier: "extensionButton").firstMatch.exists, "Nothing runs before agreeing")

        app.buttons["confirmExtensionInstall"].click()
        let button = app.buttons.matching(NSPredicate(format: "identifier == 'extensionButton' AND label CONTAINS 'Reading List'")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
    }

    /// ⇧⌘E lists installed extensions; turning one off removes its toolbar button.
    @MainActor
    func testExtensionsWindowTurnsExtensionsOff() throws {
        let folder = try writeTestExtension(name: "Axo Helper")
        let app = Self.makeApp()
        app.launchEnvironment["AXO_UI_TESTING_EXTENSION"] = folder.path
        app.launch()
        Self.bringToFront(app)
        let button = app.buttons.matching(NSPredicate(format: "identifier == 'extensionButton' AND label CONTAINS 'Axo Helper'")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))

        app.typeKey("e", modifierFlags: [.command, .shift])
        let window = app.descendants(matching: .any)["extensionsWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["Axo Helper"].waitForExistence(timeout: 5))

        // A switch-style toggle is exposed as a checkbox on macOS.
        window.checkBoxes.firstMatch.click()
        XCTAssertTrue(button.waitForNonExistence(timeout: 10))
    }

    /// ⌥⌘I opens Axo's Web Inspector for the selected page, docked in the window.
    @MainActor
    func testWebInspectorOpens() throws {
        // WebKit pages never draw on GitHub's virtual Mac (the web process's sandbox can't create
        // IOSurfaces there), so the check that the inspector is drawn can't pass.
        try XCTSkipIf(Self.isOnHostedRunner, "WebKit pages don't draw on GitHub's hosted Mac.")
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        AxoUITests.openPage("data:text/html,<title>Inspect</title><h1>Inspect me</h1>", in: app)
        XCTAssertTrue(sidebar.staticTexts["Inspect"].waitForExistence(timeout: 10))

        app.typeKey("i", modifierFlags: [.command, .option])

        // The inspector's own interface is a web page with tabs like Elements and Console.
        let inspectorTab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Elements' OR title == 'Elements' OR value == 'Elements'"))
            .firstMatch
        XCTAssertTrue(inspectorTab.waitForExistence(timeout: 15))
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(inspectorTab.frame), "Docked inside the browser window")

        // The inspector must actually be drawn, not just present in the accessibility tree: its
        // area of the window has to show its interface (toolbars, tabs, the DOM tree) rather
        // than one flat color. (The page's content once drew over it in white.)
        let page = app.webViews.matching(NSPredicate(format: "label == 'Inspect'")).firstMatch
        let inspector = app.webViews.allElementsBoundByIndex.first { $0.frame != page.frame && $0.frame.height > 100 }
        let inspectorFrame = try XCTUnwrap(inspector?.frame, "The inspector has its own web view")
        XCTAssertFalse(page.frame.intersects(inspectorFrame.insetBy(dx: 1, dy: 1)), "The page makes room for the inspector. web views: \(app.webViews.allElementsBoundByIndex.map { "\($0.frame) \($0.label)" })")
        sleep(1)
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Docked Web Inspector"
        attachment.lifetime = .keepAlways
        add(attachment)
        let drawn = try Self.fractionOfDistinctPixels(in: screenshot.image, region: inspectorFrame, window: window)
        XCTAssertGreaterThan(drawn, 0.02, "The inspector's area shows its interface (\(drawn))")

        // And it works: the console runs code in the page and shows the result.
        let consoleTab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Console' OR title == 'Console'")).firstMatch
        XCTAssertTrue(consoleTab.waitForExistence(timeout: 5))
        consoleTab.click()
        sleep(1)
        app.typeText("document.title + ' from the console'\n")
        let output = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Inspect from the console' OR value CONTAINS 'Inspect from the console'"))
            .firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 10), "The console printed the page's title")
        let consoleShot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        consoleShot.name = "Web Inspector Console"
        consoleShot.lifetime = .keepAlways
        add(consoleShot)
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
        AxoUITests.openPage("data:text/html,<title>Pond</title><p>Axolotls live in lakes.</p>", in: app)
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
