//
//  AxoUITests.swift
//  AxoUITests
//
//  Created by Kevin Perez on 10/2/26.
//

import AppKit
import XCTest

/// Where `testTheSelectedRowIsHighlighted` reads a row's shade: past the highlight's 10 pt inset,
/// before the row's icon.
enum SidebarHighlightProbe {
    static let x: CGFloat = 14
}

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

    /// A port on this Mac nothing listens on, so a load there is refused without leaving the
    /// Mac. The UI test runner is sandboxed and can't listen on a port itself, so it tries random
    /// high ports until a connection to one is refused. Where the sandbox refuses the connection
    /// too, it can't check, and takes a random high port (a listener there is very unlikely).
    static func closedPort() throws -> UInt16 {
        for _ in 0..<50 {
            let port = UInt16.random(in: 49_152...65_000)
            let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard socket >= 0 else { continue }
            defer { close(socket) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = port.bigEndian
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if connected != 0, errno == ECONNREFUSED || errno == EPERM || errno == EACCES {
                return port
            }
        }
        throw XCTSkip("No closed port")
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

    /// Back's history menu (#112): after three pages in one tab, right-clicking Back lists the
    /// earlier pages, nearest first, and choosing the farthest goes two back at once; Forward's
    /// menu then lists the later pages and jumps to one. Holding a button (or VoiceOver's Show
    /// History action) for the same pages in a popover is checked by hand: XCUITest's press
    /// doesn't reach the button's hold, and it can't run named actions.
    @MainActor
    func testBackHistoryMenuJumpsTwoBack() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        AxoUITests.openPage(page("First"), in: app)
        XCTAssertTrue(sidebar.staticTexts["First"].waitForExistence(timeout: 10))
        for title in ["Second", "Third"] {
            // Typed into the field once it has focus: typed at the app as the bar opens, the
            // first letters can be lost, turning the address into a search.
            app.typeKey("l", modifierFlags: .command)
            let field = app.textFields["commandField"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            expectation(for: NSPredicate(format: "hasKeyboardFocus == true"), evaluatedWith: field)
            waitForExpectations(timeout: 5)
            field.typeKey("a", modifierFlags: .command)
            field.typeText(page(title) + "\n")
            XCTAssertTrue(sidebar.staticTexts[title].waitForExistence(timeout: 10))
        }

        let back = app.buttons["backButton"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: back)
        waitForExpectations(timeout: 10)
        back.rightClick()
        let window = app.windows.firstMatch
        let first = window.menuItems["First"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        // Without the menu's own items that have no title (separators).
        let titles = window.menus.firstMatch.menuItems.allElementsBoundByIndex.map(\.title).filter { !$0.isEmpty }
        XCTAssertEqual(titles, ["Second", "First"], "The nearest page first")
        first.click()
        XCTAssertTrue(sidebar.staticTexts["First"].waitForExistence(timeout: 10))

        let forward = app.buttons["forwardButton"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: forward)
        waitForExpectations(timeout: 10)
        forward.rightClick()
        XCTAssertTrue(window.menuItems["Second"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.menuItems["Third"].exists)
        app.typeKey(.escape, modifierFlags: [])

        // Forward's menu goes straight to a later page. (Holding the button for the same pages
        // in a popover is checked by hand: XCUITest's press doesn't reach the button's hold.)
        forward.rightClick()
        let third = window.menuItems["Third"]
        XCTAssertTrue(third.waitForExistence(timeout: 5))
        third.click()
        XCTAssertTrue(sidebar.staticTexts["Third"].waitForExistence(timeout: 10))

        // A plain click still goes one page, and the menu reads the history afresh.
        back.click()
        XCTAssertTrue(sidebar.staticTexts["Second"].waitForExistence(timeout: 10))
        back.rightClick()
        XCTAssertTrue(window.menuItems["First"].waitForExistence(timeout: 5))
        XCTAssertEqual(window.menus.firstMatch.menuItems.allElementsBoundByIndex.map(\.title).filter { !$0.isEmpty }, ["First"])
        app.typeKey(.escape, modifierFlags: [])
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

    /// A tab playing sound shows a speaker at its row's end, which mutes it, as the Tabs menu
    /// unmutes it (#71), and its row's value tells VoiceOver. The page plays a faint tone once clicked
    /// (pages need a click to play sound).
    @MainActor
    func testMutingATabFromItsSpeaker() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        AxoUITests.openPage("data:text/html,<title>Tone</title><body style='height:100vh'><script>addEventListener('click', () => { const c = new AudioContext(); const o = c.createOscillator(); const g = c.createGain(); g.gain.value = 0.001; o.connect(g).connect(c.destination); o.start(); document.title = 'Tone on' })</script>", in: app)
        XCTAssertTrue(sidebar.staticTexts["Tone"].waitForExistence(timeout: 10))
        let speaker = sidebar.buttons["tabMuteButton"]
        XCTAssertFalse(speaker.exists, "No speaker before the page plays sound")

        app.webViews.firstMatch.click()
        XCTAssertTrue(sidebar.staticTexts["Tone on"].waitForExistence(timeout: 10))
        XCTAssertTrue(speaker.waitForExistence(timeout: 10), "Playing sound shows the speaker")
        XCTAssertEqual(speaker.label, "Mute Tab")
        let row = sidebar.descendants(matching: .any).matching(identifier: "tabRow").element(boundBy: 0)
        XCTAssertTrue((row.value as? String)?.contains("Playing audio") == true)

        speaker.click()
        let muted = NSPredicate(format: "label == 'Unmute Tab'")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: muted, evaluatedWith: speaker)], timeout: 5), .completed)
        XCTAssertTrue((row.value as? String)?.contains("Muted") == true)

        // The Tabs menu unmutes the shown tab too.
        app.menuBars.menuBarItems["Tabs"].click()
        app.menuBars.menuItems["Unmute Tab"].click()
        let unmuted = NSPredicate(format: "label == 'Mute Tab'")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: unmuted, evaluatedWith: speaker)], timeout: 5), .completed)
    }

    /// Dragging a tab's row onto another Space's dot moves it there (#78): the notice says where
    /// it went, and Undo puts it back.
    @MainActor
    func testDraggingARowOntoAnotherSpace() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        app.buttons["newSpaceButton"].click()
        let nameField = app.textFields["spaceNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click()
        nameField.typeText("Work")
        app.buttons["createSpaceButton"].click()
        XCTAssertTrue(sidebar.staticTexts["Work"].waitForExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .control)
        AxoUITests.openPage(page("Alpha"), in: app)
        XCTAssertTrue(sidebar.staticTexts["Alpha"].waitForExistence(timeout: 10))
        AxoUITests.openPage(page("Beta"), in: app)
        XCTAssertTrue(sidebar.staticTexts["Beta"].waitForExistence(timeout: 10))

        let workDot = app.buttons.matching(identifier: "spaceButton").matching(NSPredicate(format: "label == 'Work'")).firstMatch
        XCTAssertTrue(workDot.exists)
        sidebar.staticTexts["Alpha"].click(forDuration: 0.6, thenDragTo: workDot)
        XCTAssertTrue(sidebar.staticTexts["Alpha"].waitForNonExistence(timeout: 5), "It left this Space")
        let notice = app.descendants(matching: .any)["notice"]
        let undo = app.buttons["noticeUndoButton"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "The notice offers Undo")
        XCTAssertEqual(notice.label, "Moved Alpha to Work")
        undo.click()
        XCTAssertTrue(sidebar.staticTexts["Alpha"].waitForExistence(timeout: 5), "Undo brings it back")

        // Dropped there again, it's in Work.
        sidebar.staticTexts["Alpha"].click(forDuration: 0.6, thenDragTo: workDot)
        XCTAssertTrue(sidebar.staticTexts["Alpha"].waitForNonExistence(timeout: 5))
        workDot.click()
        XCTAssertTrue(sidebar.staticTexts["Alpha"].waitForExistence(timeout: 5), "Shown in Work")
    }

    /// Dragging rows between sections (#77): a tab into Pinned and back out, into a folder, and
    /// a favorite out of Favorites into the tabs section and into Pinned.
    /// The selected row is highlighted, and the highlight follows a click: SwiftUI 27's
    /// reorderable rows (tried for #77) stopped the sidebar list drawing its selection.
    @MainActor
    func testTheSelectedRowIsHighlighted() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        AxoUITests.openPage(page("First"), in: app)
        XCTAssertTrue(sidebar.staticTexts["First"].waitForExistence(timeout: 10))
        AxoUITests.openPage(page("Second"), in: app)
        XCTAssertTrue(sidebar.staticTexts["Second"].waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        app.descendants(matching: .any)["sidebarAddressBar"].hover() // Away from the rows.

        // Just inside the highlight's leading edge, before the row's icon.
        func shade(of title: String) -> Double {
            let row = sidebar.staticTexts[title].frame
            let point = CGPoint(x: sidebar.frame.minX - window.frame.minX + SidebarHighlightProbe.x,
                                y: row.midY - window.frame.minY)
            let color = AxoUITests.color(at: point, in: window)
            return (color.red + color.green + color.blue) / 3
        }
        let deadline = Date().addingTimeInterval(5)
        while abs(shade(of: "Second") - shade(of: "First")) < 0.03, Date() < deadline { usleep(200_000) }
        XCTAssertGreaterThan(abs(shade(of: "Second") - shade(of: "First")), 0.03, "The selected row, Second, is highlighted")

        sidebar.staticTexts["First"].click()
        app.descendants(matching: .any)["sidebarAddressBar"].hover()
        let moved = Date().addingTimeInterval(5)
        while abs(shade(of: "First") - shade(of: "Second")) < 0.03, Date() < moved { usleep(200_000) }
        XCTAssertGreaterThan(abs(shade(of: "First") - shade(of: "Second")), 0.03, "The highlight follows the click")

        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = "Selected row"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testDraggingRowsBetweenSections() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        for name in ["Alpha", "Beta", "Gamma", "Delta"] {
            AxoUITests.openPage("data:text/html,<title>\(name)</title>", in: app)
            XCTAssertTrue(sidebar.staticTexts[name].waitForExistence(timeout: 10))
        }
        let pinned = sidebar.descendants(matching: .any)["pinnedSection"]
        // The Pinned section's identifier lands on each pinned row (replacing `tabRow`), not on a
        // container around them, so a row is pinned when it shows but isn't a `tabRow`.
        func isPinned(_ name: String) -> Bool {
            sidebar.staticTexts[name].exists
                && !sidebar.descendants(matching: .any).matching(identifier: "tabRow")
                    .matching(NSPredicate(format: "label == %@", name)).firstMatch.exists
        }
        func wait(_ what: String, until condition: @escaping () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition(), Date() < deadline { usleep(100_000) }
            XCTAssertTrue(condition(), what)
        }

        // Before each drag the pointer leaves the rows and the dragged row must take clicks: the
        // previous drag leaves the pointer on a row, whose hover card (#76) can show meanwhile.
        func drag(_ source: XCUIElement, to target: XCUIElement) {
            app.descendants(matching: .any)["sidebarAddressBar"].hover()
            let deadline = Date().addingTimeInterval(5)
            while !source.isHittable, Date() < deadline { usleep(100_000) }
            source.click(forDuration: 0.6, thenDragTo: target)
        }

        // Pin Alpha from the keyboard, then drag Beta onto it: it's pinned there.
        sidebar.staticTexts["Alpha"].click()
        app.typeKey("p", modifierFlags: [.command, .control])
        XCTAssertTrue(pinned.waitForExistence(timeout: 5))
        drag(sidebar.staticTexts["Beta"], to: sidebar.staticTexts["Alpha"])
        wait("Beta is pinned") { isPinned("Beta") }

        // And back out, onto Gamma in the tabs section.
        drag(sidebar.staticTexts["Beta"], to: sidebar.staticTexts["Gamma"])
        wait("Beta is unpinned") { !isPinned("Beta") && sidebar.staticTexts["Beta"].exists }

        // Into a folder: Alpha goes into a new folder, then Beta onto the folder.
        sidebar.staticTexts["Alpha"].click()
        app.menuBars.menuBarItems["Tabs"].click()
        app.menuBars.menuItems["Move to Folder"].hover()
        app.menuBars.menuItems["New Folder…"].click()
        let nameField = app.textFields["nameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.typeText("Work\n")
        // By its name and item count: the Pinned section's identifier replaces `folderRow` too.
        let folder = sidebar.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Work' AND value ENDSWITH 'item' OR label == 'Work' AND value ENDSWITH 'items'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        drag(sidebar.staticTexts["Beta"], to: folder)
        wait("Beta is in the folder") { (folder.value as? String) == "2 items" }

        // A favorite out of Favorites, into the tabs section and then into Pinned.
        sidebar.staticTexts["Gamma"].rightClick()
        app.windows.firstMatch.menuItems["Add to Favorites"].click()
        let tile = app.buttons["favoriteTile"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        drag(tile, to: sidebar.staticTexts["Delta"])
        wait("Gamma is a tab again") { !tile.exists && sidebar.staticTexts["Gamma"].exists && !isPinned("Gamma") }

        sidebar.staticTexts["Gamma"].rightClick()
        app.windows.firstMatch.menuItems["Add to Favorites"].click()
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        drag(tile, to: folder)
        wait("Gamma is pinned") { !tile.exists && isPinned("Gamma") }
    }

    /// A page that can't be reached shows Axo's Can't Connect page in its place, and Go Back
    /// returns to the page before (#178). The address is a port on this Mac nothing listens on, so
    /// nothing leaves the Mac.
    @MainActor
    func testCantConnectAndGoBack() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        AxoUITests.openPage("data:text/html,<title>Before</title><h1>Before</h1>", in: app)
        XCTAssertTrue(sidebar.staticTexts["Before"].waitForExistence(timeout: 10))

        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(app.textFields["commandField"].waitForExistence(timeout: 5))
        app.typeText("http://127.0.0.1:\(try AxoUITests.closedPort())/\n")
        let cantConnect = app.descendants(matching: .any)["pageLoadError"]
        XCTAssertTrue(cantConnect.waitForExistence(timeout: 15), "Axo's own page shows in place of the page")
        XCTAssertTrue(cantConnect.staticTexts["Axo Can’t Connect to This Site"].exists)
        XCTAssertTrue(cantConnect.buttons["pageErrorRetry"].exists)

        cantConnect.buttons["pageErrorGoBack"].click()
        XCTAssertTrue(cantConnect.waitForNonExistence(timeout: 10), "Go Back leaves it")
        XCTAssertTrue(sidebar.staticTexts["Before"].exists, "The page before shows again")
    }

    /// A page with nothing to say about its connection (a data: page) shows no lock and no
    /// "Not secure" in the address's value (#96); the states themselves are covered by model tests
    /// and the engine's script, since UI tests load no web pages.
    @MainActor
    func testADataPageShowsNoConnectionIndicator() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        AxoUITests.openPage("data:text/html,<title>Quiet</title>", in: app)
        XCTAssertTrue(sidebar.staticTexts["Quiet"].waitForExistence(timeout: 10))
        let pill = app.descendants(matching: .any)["sidebarAddressBar"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["connectionButton"].exists)
        XCTAssertFalse((pill.value as? String)?.hasPrefix("Not ") == true)
    }

    /// Resting the pointer on a tab's row shows its card beside the sidebar, with its title and
    /// address, never over the row; it goes once the pointer leaves (#76).
    @MainActor
    func testHoveringATabRowShowsItsCard() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        AxoUITests.openPage("data:text/html,<title>Card</title><h1>Card</h1>", in: app)
        XCTAssertTrue(sidebar.staticTexts["Card"].waitForExistence(timeout: 10))
        AxoUITests.openPage("data:text/html,<title>Other</title>", in: app)
        XCTAssertTrue(sidebar.staticTexts["Other"].waitForExistence(timeout: 10))

        let row = sidebar.descendants(matching: .any).matching(identifier: "tabRow").matching(NSPredicate(format: "label == 'Card'")).firstMatch
        row.hover()
        let card = app.descendants(matching: .any)["tabPreviewCard"]
        // The hosted Mac sometimes misses the first hover's move onto the row, so if no card
        // shows, the pointer leaves and comes back once.
        if !card.waitForExistence(timeout: 5) {
            app.descendants(matching: .any)["sidebarAddressBar"].hover()
            row.hover()
        }
        XCTAssertTrue(card.waitForExistence(timeout: 5), "Resting on the row shows its card")
        XCTAssertTrue(card.staticTexts["Card"].exists, "Its title")
        let address = card.descendants(matching: .any)["tabPreviewAddress"]
        XCTAssertTrue(address.exists, "Its address")
        let spoken = address.label.isEmpty ? (address.value as? String ?? "") : address.label
        XCTAssertTrue(spoken.hasPrefix("data:text/html"), "Got \(spoken)")
        XCTAssertGreaterThanOrEqual(card.frame.minX, row.frame.maxX - 1, "Beside the row, never over it")

        // Over the page by position: the hosted Mac's WebKit pages aren't in the tree.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).hover()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5), "It goes when the pointer leaves")

        // With tabs at the top, below the tab.
        app.typeKey(",", modifierFlags: .command)
        AxoUITests.selectSettingsPane("general", in: app)
        app.radioButtons["At the top"].click()
        app.typeKey("w", modifierFlags: .command)
        let tab = app.descendants(matching: .any).matching(identifier: "topTab").matching(NSPredicate(format: "label == 'Card'")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.hover()
        XCTAssertTrue(card.waitForExistence(timeout: 5), "A top tab shows its card too")
        // Lined up with its tab. Below it, not over it, is checked in the attached screenshot: the
        // card layer ignores the safe area, and its accessibility frame comes out 40 pt above
        // where it's drawn with tabs at the top.
        XCTAssertEqual(card.frame.minX, tab.frame.minX, accuracy: 2, "Lined up with its tab")
        let tabsShot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        tabsShot.name = "Hover card below a top tab"
        tabsShot.lifetime = .keepAlways
        add(tabsShot)
    }

    /// A page whose process ends shows "This Page Stopped" in its place, and its row says so and
    /// dims, until Reload brings it back (#75). The Testing menu ends the process, as a crash
    /// would.
    @MainActor
    func testACrashedPageShowsThatItStoppedUntilReload() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        AxoUITests.openPage("data:text/html,<title>Fragile</title><h1>Fragile</h1>", in: app)
        XCTAssertTrue(sidebar.staticTexts["Fragile"].waitForExistence(timeout: 10))
        let stopped = app.descendants(matching: .any)["pageProblem"]
        XCTAssertFalse(stopped.exists)

        app.menuBars.menuBarItems["Testing"].click()
        app.menuBars.menuItems["End the Page’s Process"].click()
        XCTAssertTrue(stopped.waitForExistence(timeout: 10), "The page's place says it stopped")
        XCTAssertTrue(stopped.staticTexts["This Page Stopped"].exists)
        XCTAssertFalse(stopped.buttons["pageProblemDetails"].exists, "WebKit gives no error code to show")
        let row = sidebar.descendants(matching: .any).matching(identifier: "tabRow").element(boundBy: 0)
        XCTAssertTrue((row.value as? String)?.contains("Page stopped working") == true)
        XCTAssertTrue(sidebar.buttons["tabProblemButton"].exists, "The row's warning, which reloads")

        stopped.buttons["pageProblemReload"].click()
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: gone, evaluatedWith: stopped)], timeout: 10), .completed)
        XCTAssertFalse(sidebar.buttons["tabProblemButton"].exists)
        XCTAssertFalse((row.value as? String)?.contains("Page stopped working") == true)
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

        // The control bar's Summarize Page opens one summary, from the bar (no hidden toolbar
        // copy answers too).
        app.descendants(matching: .any)["controlBar"].buttons["summarizeButton"].click()
        XCTAssertTrue(app.staticTexts["summaryText"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.popovers.count, 1, "One summary")
        app.typeKey(.escape, modifierFlags: [])

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

    /// Tabs at the top (#136): Settings › General › Show tabs puts the Space's tabs in a tab bar
    /// across the top, as the board draws it (the Space's name, the pinned group, today's tabs,
    /// New Tab), with the control bar under it. Tabs open, select, pin, and close from the bar,
    /// the Space's name opens the Spaces menu, Hide Tab Bar leaves the page as a card that the bar
    /// floats in over from the top edge, and switching back shows the same tabs in the sidebar.
    @MainActor
    func testTabsOnTop() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        AxoUITests.openPage("data:text/html,<title>Alpha</title>", in: app)
        XCTAssertTrue(sidebar.staticTexts["Alpha"].waitForExistence(timeout: 10))

        app.typeKey(",", modifierFlags: .command)
        AxoUITests.selectSettingsPane("general", in: app)
        app.radioButtons["At the top"].click()
        XCTAssertFalse(app.radioButtons["Above the page"].isEnabled, "Tabs at the top hold the navigation bar above the page")
        app.typeKey("w", modifierFlags: .command)

        let window = app.windows.firstMatch
        let bar = app.descendants(matching: .any)["tabBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "The tab bar shows")
        XCTAssertFalse(sidebar.exists, "No sidebar")
        XCTAssertFalse(window.toolbars.firstMatch.exists, "No toolbar")
        XCTAssertEqual(bar.frame.minY, window.frame.minY, accuracy: 1, "At the window's top")
        let controlBar = app.descendants(matching: .any)["controlBar"]
        XCTAssertGreaterThanOrEqual(controlBar.frame.minY, bar.frame.maxY - 1, "The control bar sits under it")
        let tab = { (title: String) in bar.buttons.matching(NSPredicate(format: "identifier == 'topTab' AND label == %@", title)).firstMatch }
        XCTAssertTrue(tab("Alpha").exists, "Today's tab is on the bar")
        let spaceMenu = bar.descendants(matching: .any)["tabBarSpaceMenu"]
        XCTAssertTrue(spaceMenu.exists)

        // New Tab from the bar, and selecting a tab.
        bar.buttons["tabBarNewTabButton"].click()
        let commandField = app.textFields["commandField"]
        XCTAssertTrue(commandField.waitForExistence(timeout: 5))
        commandField.typeText("data:text/html,<title>Beta</title>\n")
        XCTAssertTrue(tab("Beta").waitForExistence(timeout: 10))
        XCTAssertTrue(tab("Beta").isSelected)
        tab("Alpha").click()
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: tab("Alpha"))
        waitForExpectations(timeout: 5)
        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = "Tabs on top"
        shot.lifetime = .keepAlways
        add(shot)

        // Pinning from a tab's menu moves it into the Pinned group.
        tab("Beta").rightClick()
        window.menuItems["Pin Tab"].click()
        let pinned = bar.descendants(matching: .any)["tabBarPinned"]
        XCTAssertTrue(pinned.waitForExistence(timeout: 5), "A Pinned group appears")
        XCTAssertTrue(pinned.buttons.matching(NSPredicate(format: "identifier == 'topTab' AND label == 'Beta'")).firstMatch.waitForExistence(timeout: 5))

        // Closing from the hover button.
        tab("Alpha").hover()
        let close = bar.buttons["tabBarCloseButton"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.click()
        XCTAssertTrue(tab("Alpha").waitForNonExistence(timeout: 5), "Closed")

        // The Space's name opens the Spaces menu.
        spaceMenu.click()
        XCTAssertTrue(app.menuItems["New Space…"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])

        // Hide Tab Bar: the page is a card and the bar floats in from the top edge.
        controlBar.buttons["tabBarToggleButton"].click()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5), "The tab bar hides")
        XCTAssertTrue(window.buttons[XCUIIdentifierCloseWindow].exists, "The control bar takes the window's controls")
        let floating = app.descendants(matching: .any)["floatingTabBar"]
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 3)).hover()
        XCTAssertTrue(floating.waitForExistence(timeout: 5), "It floats in from the top edge")
        let hiddenShot = XCTAttachment(screenshot: window.screenshot())
        hiddenShot.name = "Tab bar floating over the page card"
        hiddenShot.lifetime = .keepAlways
        add(hiddenShot)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).hover()
        XCTAssertTrue(floating.waitForNonExistence(timeout: 5), "And goes when the pointer leaves")
        controlBar.buttons["tabBarToggleButton"].click()
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "Keep Tab Bar Shown brings it back")
        // View › Hide Tab Bar does the same.
        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuItems["Hide Tab Bar"].click()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5), "View › Hide Tab Bar")
        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuItems["Show Tab Bar"].click()
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "View › Show Tab Bar")

        // Back in the sidebar, the same tabs.
        app.typeKey(",", modifierFlags: .command)
        AxoUITests.selectSettingsPane("general", in: app)
        app.radioButtons["In the sidebar"].firstMatch.click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "The sidebar is back")
        XCTAssertTrue(sidebar.staticTexts["Beta"].exists, "With the same tabs")
        XCTAssertFalse(bar.exists)
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
        // The sidebar's list reaches 1 pt past its column, so the bar may start right at its end.
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any)["controlBar"].frame.minX, sidebar.frame.maxX - 1,
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
    /// it. With the sidebar hidden the page is a card on the Space's theme and the sidebar floats
    /// in from the left edge; with the sidebar's address bar hidden, the toolbar comes back.
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

        // The page is a card on the Space's theme, inset so the margin moves the window (its
        // place is checked in AxoTests' PageLayerTests; the screenshot shows the look).
        let cardShot = XCTAttachment(screenshot: window.screenshot())
        cardShot.name = "Page as a card with the sidebar hidden"
        cardShot.lifetime = .keepAlways
        add(cardShot)

        // The pointer at the window's left edge floats the sidebar in, with the window's
        // controls and Keep Sidebar Shown in its top row.
        let floating = app.descendants(matching: .any)["floatingSidebar"]
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 2, dy: 0))
        edge.hover()
        XCTAssertTrue(floating.waitForExistence(timeout: 5), "The sidebar floats in from the left edge")
        XCTAssertTrue(floating.buttons["keepSidebarShownButton"].exists)
        XCTAssertTrue(window.buttons[XCUIIdentifierCloseWindow].exists, "The window's controls are in its top row")
        // Accessibility reports the card with the margin around it (which counts as the card for
        // the pointer), so its width is checked, not its inset; the screenshot shows the look.
        XCTAssertGreaterThanOrEqual(floating.frame.width, 268, "The board's 268 pt card")
        XCTAssertLessThan(floating.frame.width, window.frame.width / 2, "A card over the page, not across it")
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
        // fills the window too, and ⌃⌘S shows the sidebar again. The page is clicked first, as
        // a person would, so the shortcut doesn't depend on where Keep Sidebar Shown left focus.
        page.click()
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
    /// The top is the sidebar's top row (#67) and, above the page, the page's control bar (#170),
    /// both in line with the window's controls. Checked in light and dark mode, with window
    /// screenshots.
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
        // The menu button appears twice in the accessibility tree, identical; either answers.
        let camera = app.menuButtons.matching(identifier: "sitePermission-camera").firstMatch
        XCTAssertTrue(camera.waitForExistence(timeout: 5))
        XCTAssertEqual(camera.value as? String, "Ask")
        XCTAssertTrue(app.menuButtons["sitePermission-microphone"].exists)
        XCTAssertTrue(app.menuButtons["sitePermission-location"].exists)
        // UI tests run on WebKit, which never asks about notifications or the clipboard, so Site
        // Settings doesn't offer them (Chromium's rows are covered by the model's tests).
        XCTAssertFalse(app.menuButtons["sitePermission-notifications"].exists)
        XCTAssertFalse(app.menuButtons["sitePermission-clipboard"].exists)

        camera.click()
        app.menuItems["Don't Allow"].click()
        expectation(for: NSPredicate(format: "value == %@", "Don't Allow"), evaluatedWith: camera)
        waitForExpectations(timeout: 5)

        app.buttons["resetSiteSettings"].click()
        expectation(for: NSPredicate(format: "value == %@", "Ask"), evaluatedWith: camera)
        waitForExpectations(timeout: 5)

        // Website Permissions (#133): from Site Settings to the site in Settings › Profiles.
        camera.click()
        app.menuItems["Don't Allow"].click()
        expectation(for: NSPredicate(format: "value == %@", "Don't Allow"), evaluatedWith: camera)
        waitForExpectations(timeout: 5)
        app.buttons["manageWebsitePermissions"].click()
        let sheet = app.descendants(matching: .any)["websitePermissionsSheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Settings opens on the site's camera answers")
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "Website Permissions from Site Settings"
        shot.lifetime = .keepAlways
        add(shot)
        // The site's switch: off is Don't Allow.
        let row = sheet.descendants(matching: .any).matching(identifier: "websitePermissionSwitch").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.hasPrefix("Camera for 127.0.0.1"), row.label)
        XCTAssertEqual(row.value as? Int, 0)
        row.click()
        expectation(for: NSPredicate(format: "value == 1"), evaluatedWith: row)
        waitForExpectations(timeout: 5)
        sheet.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove 127.0.0.1'")).firstMatch.click()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "Removed: the site asks again")

        let deny = sheet.radioButtons["Don't Allow"]
        XCTAssertTrue(deny.exists, "The camera's default is Ask or Don't Allow, never Allow")
        XCTAssertFalse(sheet.radioButtons["Allow"].exists)
        deny.click()
        expectation(for: NSPredicate(format: "value == 1"), evaluatedWith: deny)
        waitForExpectations(timeout: 5)

        let newSite = sheet.textFields["websitePermissionNewSite"]
        newSite.click()
        newSite.typeText("not a site")
        sheet.buttons["websitePermissionAddAllow"].click()
        XCTAssertTrue(sheet.staticTexts["Enter a website's address, such as meet.example.com."].waitForExistence(timeout: 5))
    }

    /// Site Settings is one panel for the site (#110): it names the profile its choices apply to,
    /// turns the site's customization off and on, and clears the site's data after asking, with
    /// Cancel the default button.
    @MainActor
    func testSiteSettingsTogglesACustomizationAndClearsData() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        // A closed loopback port: nothing loads, but the tab has a web address.
        let port = try AxoUITests.closedPort()
        app.typeKey("t", modifierFlags: .command)
        let field = app.textFields["commandField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("http://127.0.0.1:\(port)/room")
        expectation(for: NSPredicate(format: "value == %@", "http://127.0.0.1:\(port)/room"), evaluatedWith: field)
        waitForExpectations(timeout: 5)
        field.typeText("\n")
        let address = app.descendants(matching: .any)["sidebarAddressBar"]
        expectation(for: NSPredicate(format: "value CONTAINS %@", "127.0.0.1"), evaluatedWith: address)
        waitForExpectations(timeout: 10)

        func openSiteSettings() {
            app.menuBars.menuBarItems["View"].click()
            app.menuBars.menuItems["Site Settings…"].click()
            XCTAssertTrue(app.descendants(matching: .any)["siteSettings"].waitForExistence(timeout: 5))
        }
        openSiteSettings()
        let profile = app.descendants(matching: .any)["siteSettingsProfile"]
        XCTAssertTrue(profile.exists)
        XCTAssertTrue(((profile.value as? String) ?? profile.label).hasPrefix("Choices apply to 127.0.0.1:\(port) in the "),
                      "\(profile.value ?? profile.label)")
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "Site Settings"
        shot.lifetime = .keepAlways
        add(shot)

        // No customization yet: Customize… adds one for the site.
        XCTAssertFalse(app.descendants(matching: .any)["siteCustomizationSwitch"].exists)
        app.buttons["customizeSiteButton"].click()
        let css = app.textViews["customizationCSSEditor"]
        XCTAssertTrue(css.waitForExistence(timeout: 5))
        css.click()
        css.typeText("p { color: red }")
        app.buttons["saveCustomizationButton"].click()
        XCTAssertTrue(css.waitForNonExistence(timeout: 5))

        openSiteSettings()
        let customization = app.descendants(matching: .any)["siteCustomizationSwitch"]
        XCTAssertTrue(customization.waitForExistence(timeout: 5), "The site's customization is listed")
        XCTAssertEqual(customization.value as? Int, 1)
        customization.click()
        expectation(for: NSPredicate(format: "value == 0"), evaluatedWith: customization)
        waitForExpectations(timeout: 5)
        customization.click()
        expectation(for: NSPredicate(format: "value == 1"), evaluatedWith: customization)
        waitForExpectations(timeout: 5)

        // Clear Website Data… asks; Return is Cancel.
        app.buttons["clearSiteDataButton"].click()
        let confirm = app.buttons["confirmClearSiteData"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Clear website data for “127.0.0.1:\(port)”?"].exists
                      || app.staticTexts.containing(NSPredicate(format: "value CONTAINS '127.0.0.1:\(port)'")).firstMatch.exists)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5), "Return cancels")
        let notice = app.descendants(matching: .any)["notice"]
        // Clearing would post its notice after the engine's round trip, so wait long enough.
        XCTAssertFalse(notice.waitForExistence(timeout: 3), "Nothing was cleared")

        openSiteSettings()
        app.buttons["clearSiteDataButton"].click()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertEqual(notice.label, "Cleared website data for 127.0.0.1:\(port)")
    }

    /// Pages stay below the window toolbar whenever it shows (#167), through what a session
    /// does: hiding and showing the sidebar, a Space switch, the command bar, a new tab, and the
    /// navigation bar moving above the page and back. Frames come from the accessibility tree,
    /// so this holds on the hosted Mac, where pages don't draw. Without a toolbar the page
    /// reaches the window's top edge, as #67 intends.
    @MainActor
    func testPagesStayBelowTheToolbarThroughASession() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        // The browser window, never Settings.
        let window = app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'browser'")).firstMatch
        Self.openPage("data:text/html,<title>First</title><div style='height:40px;background:red'></div>", in: app)
        XCTAssertTrue(sidebar.staticTexts["First"].waitForExistence(timeout: 10))

        func check(_ step: String, toolbar expected: Bool) {
            let page = window.webViews.firstMatch
            XCTAssertTrue(page.waitForExistence(timeout: 10), "\(step): a page shows")
            let toolbar = window.toolbars.firstMatch
            let shows = toolbar.exists && toolbar.frame.height > 1
            XCTAssertEqual(shows, expected, "\(step): the toolbar \(expected ? "shows" : "is hidden")")
            if shows {
                XCTAssertGreaterThanOrEqual(page.frame.minY, toolbar.frame.maxY - 1,
                                            "\(step): the page \(page.frame) starts below the toolbar \(toolbar.frame)")
                XCTAssertLessThanOrEqual(page.frame.minY, toolbar.frame.maxY + 1,
                                         "\(step): and right below it, with no gap: \(page.frame), \(toolbar.frame)")
            } else {
                XCTAssertEqual(page.frame.minY, window.frame.minY, accuracy: 1, "\(step): the page reaches the window's top")
            }
        }

        check("With the sidebar's address bar", toolbar: false)
        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuItems["Hide Address Bar in Sidebar"].click()
        check("With the address bar hidden", toolbar: true)

        app.typeKey("s", modifierFlags: [.control, .command])
        XCTAssertTrue(sidebar.waitForNonExistence(timeout: 5))
        check("Sidebar hidden", toolbar: true)
        app.typeKey("s", modifierFlags: [.control, .command])
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        check("Sidebar shown again", toolbar: true)

        app.buttons["newSpaceButton"].click()
        let spaceName = app.textFields["spaceNameField"]
        XCTAssertTrue(spaceName.waitForExistence(timeout: 5))
        spaceName.typeText("Work")
        app.buttons["createSpaceButton"].click()
        XCTAssertTrue(sidebar.staticTexts["Work"].waitForExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .control)
        XCTAssertTrue(sidebar.staticTexts["First"].waitForExistence(timeout: 5))
        check("After a Space switch", toolbar: true)

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.textFields["commandField"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.textFields["commandField"].waitForNonExistence(timeout: 5))
        check("After the command bar", toolbar: true)

        Self.openPage("data:text/html,<title>Second</title><div style='height:40px;background:red'></div>", in: app)
        XCTAssertTrue(sidebar.staticTexts["Second"].waitForExistence(timeout: 10))
        check("A new tab", toolbar: true)

        app.typeKey(",", modifierFlags: .command)
        Self.selectSettingsPane("general", in: app)
        XCTAssertTrue(app.radioButtons["Above the page"].waitForExistence(timeout: 5))
        app.radioButtons["Above the page"].click()
        let settings = app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'com_apple_SwiftUI_Settings'")).firstMatch
        // Above the page: no toolbar, and the page starts under its control bar.
        let pageBar = window.descendants(matching: .any)["pageAddressBar"]
        XCTAssertTrue(pageBar.waitForExistence(timeout: 5))
        XCTAssertFalse(window.toolbars.firstMatch.exists && window.toolbars.firstMatch.frame.height > 1, "Above the page: no toolbar")
        XCTAssertGreaterThanOrEqual(window.webViews.firstMatch.frame.minY, pageBar.frame.maxY - 1, "The page starts under the control bar")
        // Show tabs has an "In the sidebar" too: the navigation bar's picker's.
        app.descendants(matching: .any)["navigationBarPlacementPicker"].radioButtons["In the sidebar"].click()
        app.typeKey("w", modifierFlags: .command)
        if settings.exists { XCTAssertTrue(settings.waitForNonExistence(timeout: 5), "Settings closed") }
        check("After the navigation bar moved above the page and back", toolbar: true)

        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuItems["Show Address Bar in Sidebar"].click()
        check("With the address bar shown again", toolbar: false)
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

    /// Site Settings lists the extensions that can run on the site (#110), and its pin is the
    /// toolbar's: unpinning there takes the button out of the address bar.
    @MainActor
    func testSiteSettingsListsExtensionsOnTheSiteWithTheirPins() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AxoUITestExtension-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try """
        {"name": "Axo Marker", "version": "1.0", "manifest_version": 3, "description": "UI test extension.",
         "action": {"default_title": "Axo Marker"},
         "content_scripts": [{"matches": ["http://127.0.0.1/*"], "js": ["mark.js"]}]}
        """.write(to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try "document.documentElement.dataset.axo = 'marked';".write(to: folder.appending(path: "mark.js"), atomically: true, encoding: .utf8)

        let app = Self.makeApp()
        app.launchEnvironment["AXO_UI_TESTING_EXTENSION"] = folder.path
        app.launch()
        Self.bringToFront(app)
        let button = app.buttons.matching(NSPredicate(format: "identifier == 'extensionButton' AND label CONTAINS 'Axo Marker'")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "New installs start pinned")

        Self.openPage("http://127.0.0.1:\(try Self.closedPort())/", in: app)
        let address = app.descendants(matching: .any)["sidebarAddressBar"]
        expectation(for: NSPredicate(format: "value CONTAINS %@", "127.0.0.1"), evaluatedWith: address)
        waitForExpectations(timeout: 10)
        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuItems["Site Settings…"].click()
        let row = app.descendants(matching: .any).matching(identifier: "siteExtension").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The extension whose scripts run here is listed")
        XCTAssertTrue(row.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Can read and change this site' OR value CONTAINS 'Can read and change this site'")).firstMatch.exists
                      || row.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Can read and change this site'")).firstMatch.exists)
        let pin = row.buttons["siteExtensionPin"]
        XCTAssertEqual(pin.label, "Unpin Axo Marker from the Toolbar")
        pin.click()
        expectation(for: NSPredicate(format: "label == 'Pin Axo Marker to the Toolbar'"), evaluatedWith: pin)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(button.waitForNonExistence(timeout: 5), "Unpinned, it has no button")
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
        let on = window.descendants(matching: .any)["extensionOnSwitch"]
        XCTAssertTrue(on.waitForExistence(timeout: 5))
        on.click()
        XCTAssertTrue(button.waitForNonExistence(timeout: 10))
    }

    /// Unpinning from a button's context menu takes its button away (#131); the Extensions menu
    /// still lists it and pins it again.
    @MainActor
    func testPinningFromTheExtensionsMenuAndAButtonsMenu() throws {
        let folder = try writeTestExtension(name: "Axo Helper")
        let app = Self.makeApp()
        app.launchEnvironment["AXO_UI_TESTING_EXTENSION"] = folder.path
        app.launch()
        Self.bringToFront(app)
        let button = app.buttons.matching(NSPredicate(format: "identifier == 'extensionButton' AND label CONTAINS 'Axo Helper'")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "New extensions start pinned")

        // Menus opened from the address pill aren't in the accessibility tree XCUITest reads
        // (a screenshot shows them open), so items are chosen with the keyboard: Unpin is the
        // button's first item on WebKit (no Inspect Popup there).
        button.rightClick()
        sleep(1)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "Extension button's menu"
        shot.lifetime = .keepAlways
        add(shot)
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(button.waitForNonExistence(timeout: 10), "Unpinned")

        let menu = app.descendants(matching: .any)["extensionsMenuButton"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Every extension is in the Extensions menu")
        menu.click()
        sleep(1)
        // The menu: Axo Helper (runs it), then Pinned to the Toolbar's "Pin Axo Helper".
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(button.waitForExistence(timeout: 10), "Pinned again")
    }

    /// Settings › Profiles opens the Extensions window on a profile the shown Space doesn't use,
    /// and removing an extension there asks first, naming it and the profile (#131).
    @MainActor
    func testRemovingAnotherProfilesExtension() throws {
        let folder = try writeTestExtension(name: "Axo Helper")
        let app = Self.makeApp()
        app.launchEnvironment["AXO_UI_TESTING_EXTENSION"] = folder.path
        app.launch()
        Self.bringToFront(app)
        let button = app.buttons.matching(NSPredicate(format: "identifier == 'extensionButton' AND label CONTAINS 'Axo Helper'")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))

        // A new profile shows its first Space, so Default is another profile's.
        app.typeKey(",", modifierFlags: .command)
        AxoUITests.selectSettingsPane("profiles", in: app)
        let list = app.outlines["profileList"].exists ? app.outlines["profileList"] : app.tables["profileList"]
        app.buttons["addProfileButton"].click()
        let nameField = app.textFields["settingsNewProfileName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.typeText("Work")
        let firstSpace = app.textFields["profileFirstSpaceField"]
        firstSpace.click()
        firstSpace.typeText("Office")
        app.buttons["createProfileButton"].click()
        XCTAssertTrue(list.staticTexts["Work"].waitForExistence(timeout: 5))
        XCTAssertTrue(button.waitForNonExistence(timeout: 10), "Work has no extensions")

        list.staticTexts["Default"].click()
        let manage = app.buttons["manageProfileExtensions"]
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        manage.click()
        let window = app.descendants(matching: .any)["extensionsWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertEqual(window.popUpButtons["extensionsProfilePicker"].value as? String, "Default")
        XCTAssertTrue(window.staticTexts["Axo Helper"].waitForExistence(timeout: 5))

        let remove = window.buttons["removeExtension"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        XCTAssertTrue(app.staticTexts["Remove “Axo Helper” from Default?"].waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label == 'Remove' OR title == 'Remove'")).firstMatch.click()
        XCTAssertTrue(window.staticTexts["No Extensions"].waitForExistence(timeout: 10), "Gone from Default")
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
