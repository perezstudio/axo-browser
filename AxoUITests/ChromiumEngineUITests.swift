//
//  ChromiumEngineUITests.swift
//  AxoUITests
//

import AppKit
import XCTest

/// Axo running its tabs on the Chromium engine (Phase 1 of docs/chromium-engine.md).
///
/// Opt-in, like the real-extension tests: it needs a Debug build with the engine embedded (a
/// built axo-chromium checkout; see scripts/embed-chromium-engine.sh). Run it with
/// `TEST_RUNNER_AXO_CHROMIUM_UI_TESTS=1 xcodebuild … test -only-testing:AxoUITests/ChromiumEngineUITests`.
final class ChromiumEngineUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AXO_CHROMIUM_UI_TESTS"] == "1",
            "Set AXO_CHROMIUM_UI_TESTS=1 (TEST_RUNNER_AXO_CHROMIUM_UI_TESTS for xcodebuild) with the engine embedded."
        )
    }

    override func tearDown() async throws {
        await MainActor.run { XCUIApplication().terminate() }
        try await super.tearDown()
    }

    /// Launches Axo in UI testing mode on the Chromium engine.
    @MainActor
    private func launchChromiumApp(extensionFolder: URL? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AXO_UI_TESTING"] = "1"
        app.launchEnvironment["AXO_UI_TESTING_CHROMIUM"] = "1"
        if let extensionFolder {
            app.launchEnvironment["AXO_UI_TESTING_EXTENSION"] = extensionFolder.path
        }
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        AxoUITests.bringToFront(app)
        return app
    }

    /// An extension's toolbar button shows its badge, and clicking it opens its popup, with
    /// Chromium running the extension. The same extension as the WebKit test
    /// (testExtensionToolbarButtonOpensItsPopup).
    @MainActor
    func testExtensionToolbarButtonOpensItsPopupInChromium() throws {
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

        let app = launchChromiumApp(extensionFolder: folder)
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        // Toolbar buttons belong to a page, so open one.
        app.typeKey("t", modifierFlags: .command)
        app.typeText("data:text/html,<title>Page</title><p>Page</p>\n")

        let button = app.buttons.matching(NSPredicate(format: "identifier == 'extensionButton' AND label CONTAINS 'Axo Helper'")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 30))
        expectation(for: NSPredicate(format: "label CONTAINS '3'"), evaluatedWith: button)
        waitForExpectations(timeout: 15)

        button.click()
        XCTAssertTrue(app.popovers.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.popovers.firstMatch.staticTexts["Hello from Axo Helper"].waitForExistence(timeout: 15))
    }

    /// An extension's keyboard shortcuts (chrome.commands) are menu items under Tabs › Extension
    /// Shortcuts, and pressing them while the page has keyboard focus runs them: ⌘⇧Y reaches the
    /// extension's chrome.commands.onCommand (which sets its badge), and ⌘⇧U opens its popup.
    @MainActor
    func testExtensionShortcutsRunWhileThePageHasFocus() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AxoUITestShortcuts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {"name": "Axo Shortcuts", "version": "1.0", "manifest_version": 3, "description": "UI test extension.",
         "action": {"default_title": "Axo Shortcuts", "default_popup": "popup.html"},
         "background": {"service_worker": "bg.js"},
         "commands": {
           "_execute_action": {"suggested_key": {"default": "Ctrl+Shift+U"}},
           "mark": {"suggested_key": {"default": "Ctrl+Shift+Y"}, "description": "Mark the button"}}}
        """.write(to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try "chrome.commands.onCommand.addListener(() => chrome.action.setBadgeText({ text: 'OK' }));"
            .write(to: folder.appending(path: "bg.js"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>Shortcuts</title><body style='width:240px'><p>Opened by a shortcut</p></body>"
            .write(to: folder.appending(path: "popup.html"), atomically: true, encoding: .utf8)

        let app = launchChromiumApp(extensionFolder: folder)
        XCTAssertTrue(app.descendants(matching: .any)["sidebar"].waitForExistence(timeout: 10))
        app.typeKey("t", modifierFlags: .command)
        app.typeText("data:text/html,<title>Page</title><p>Page</p>\n")
        let button = app.buttons.matching(NSPredicate(format: "identifier == 'extensionButton' AND label CONTAINS 'Axo Shortcuts'")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 30))

        let markItem = app.menuBars.menuItems["Axo Shortcuts: Mark the button"]
        XCTAssertTrue(markItem.waitForExistence(timeout: 10), "The shortcut is a menu item")

        // Keyboard focus in the page, where Chromium sees key presses first.
        app.webViews.firstMatch.exists ? app.webViews.firstMatch.click() : app.windows.firstMatch.click()
        app.typeKey("y", modifierFlags: [.command, .shift])
        expectation(for: NSPredicate(format: "label CONTAINS 'OK'"), evaluatedWith: button)
        waitForExpectations(timeout: 15)

        app.typeKey("u", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.popovers.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.popovers.firstMatch.staticTexts["Opened by a shortcut"].waitForExistence(timeout: 15))
    }

    /// An extension's permission request (chrome.permissions.request) is Axo's alert, not
    /// Chrome's dialog, and choosing Allow grants it.
    @MainActor
    func testExtensionPermissionRequestsAreAxosAlerts() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AxoUITestPermissions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {"name": "Axo Asker", "version": "1.0", "manifest_version": 3, "description": "UI test extension.",
         "action": {"default_title": "Axo Asker"}, "background": {"service_worker": "bg.js"},
         "optional_permissions": ["clipboardRead"]}
        """.write(to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try """
        chrome.action.onClicked.addListener(async () => {
          const granted = await chrome.permissions.request({ permissions: ['clipboardRead'] });
          chrome.action.setBadgeText({ text: granted ? 'YES' : 'NO' });
        });
        """.write(to: folder.appending(path: "bg.js"), atomically: true, encoding: .utf8)

        let app = launchChromiumApp(extensionFolder: folder)
        XCTAssertTrue(app.descendants(matching: .any)["sidebar"].waitForExistence(timeout: 10))
        app.typeKey("t", modifierFlags: .command)
        app.typeText("data:text/html,<title>Page</title><p>Page</p>\n")
        let button = app.buttons.matching(NSPredicate(format: "identifier == 'extensionButton' AND label CONTAINS 'Axo Asker'")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 30))

        button.click()
        let alert = app.sheets.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 15), "Axo's alert, not Chrome's dialog")
        XCTAssertTrue(alert.staticTexts["“Axo Asker” wants more access"].exists)
        alert.buttons["Allow"].click()

        expectation(for: NSPredicate(format: "label CONTAINS 'YES'"), evaluatedWith: button)
        waitForExpectations(timeout: 15)
    }

    /// Right-clicking a page shows Axo's own menu (not Chromium's), with extensions' items, and
    /// choosing an extension's item runs it.
    @MainActor
    func testRightClickShowsAxosMenuWithExtensionItems() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AxoUITestMenu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {"name": "Axo Marker", "version": "1.0", "manifest_version": 3, "description": "UI test extension.",
         "permissions": ["contextMenus"], "action": {"default_title": "Axo Marker"},
         "background": {"service_worker": "bg.js"}}
        """.write(to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try """
        chrome.runtime.onInstalled.addListener(() =>
          chrome.contextMenus.create({ id: 'mark', title: 'Mark This Page', contexts: ['all'] }));
        chrome.contextMenus.onClicked.addListener(() => chrome.action.setBadgeText({ text: 'OK' }));
        """.write(to: folder.appending(path: "bg.js"), atomically: true, encoding: .utf8)

        let app = launchChromiumApp(extensionFolder: folder)
        XCTAssertTrue(app.descendants(matching: .any)["sidebar"].waitForExistence(timeout: 10))
        app.typeKey("t", modifierFlags: .command)
        app.typeText("data:text/html,<title>Page</title><p style='font-size:60px'>Right-click me</p>\n")
        let button = app.buttons.matching(NSPredicate(format: "identifier == 'extensionButton' AND label CONTAINS 'Axo Marker'")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 30))

        // The page column's middle, away from the sidebar.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).rightClick()
        let mark = app.menuItems["Mark This Page"]
        XCTAssertTrue(mark.waitForExistence(timeout: 10), "Axo's menu has the extension's item")
        XCTAssertTrue(app.menuItems["Reload"].exists, "and Axo's own items")
        mark.click()

        expectation(for: NSPredicate(format: "label CONTAINS 'OK'"), evaluatedWith: button)
        waitForExpectations(timeout: 15)
    }

    /// An extension's side panel (chrome.sidePanel) shows beside the page in Axo's window when
    /// its toolbar button is clicked, and its close button hides it.
    @MainActor
    func testExtensionSidePanelShowsBesideThePage() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AxoUITestPanel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {"name": "Axo Panel", "version": "1.0", "manifest_version": 3, "description": "UI test extension.",
         "permissions": ["sidePanel"], "action": {"default_title": "Axo Panel"},
         "side_panel": {"default_path": "panel.html"}, "background": {"service_worker": "bg.js"}}
        """.write(to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try "chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true });"
            .write(to: folder.appending(path: "bg.js"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>Panel</title><p>Hello from the side panel</p>"
            .write(to: folder.appending(path: "panel.html"), atomically: true, encoding: .utf8)

        let app = launchChromiumApp(extensionFolder: folder)
        XCTAssertTrue(app.descendants(matching: .any)["sidebar"].waitForExistence(timeout: 10))
        app.typeKey("t", modifierFlags: .command)
        app.typeText("data:text/html,<title>Page</title><p>Page</p>\n")
        let button = app.buttons.matching(NSPredicate(format: "identifier == 'extensionButton' AND label CONTAINS 'Axo Panel'")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 30))

        button.click()
        let panel = app.descendants(matching: .any)["extensionSidePanel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 15), "The panel shows in Axo's window")
        XCTAssertTrue(panel.staticTexts["Axo Panel"].exists, "Titled with the extension's name")
        XCTAssertTrue(panel.staticTexts["Hello from the side panel"].waitForExistence(timeout: 15), "Showing its page")

        panel.buttons["closeExtensionSidePanel"].click()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: panel)
        waitForExpectations(timeout: 10)
    }

    /// The Extensions window's Allow User Scripts switch, shown for an extension that uses
    /// chrome.userScripts, makes the API available to it.
    @MainActor
    func testAllowUserScriptsTurnsOnTheAPI() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AxoUITestScripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {"name": "Axo Scripter", "version": "1.0", "manifest_version": 3, "description": "UI test extension.",
         "permissions": ["userScripts"], "action": {"default_title": "Axo Scripter"},
         "background": {"service_worker": "bg.js"}}
        """.write(to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try "chrome.action.onClicked.addListener(() => chrome.action.setBadgeText({ text: chrome.userScripts ? 'YES' : 'NO' }));"
            .write(to: folder.appending(path: "bg.js"), atomically: true, encoding: .utf8)

        let app = launchChromiumApp(extensionFolder: folder)
        XCTAssertTrue(app.descendants(matching: .any)["sidebar"].waitForExistence(timeout: 10))
        app.typeKey("t", modifierFlags: .command)
        app.typeText("data:text/html,<title>Page</title><p>Page</p>\n")
        let button = app.buttons.matching(NSPredicate(format: "identifier == 'extensionButton' AND label CONTAINS 'Axo Scripter'")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 30))
        button.click()
        expectation(for: NSPredicate(format: "label CONTAINS 'NO'"), evaluatedWith: button)
        waitForExpectations(timeout: 15)

        app.typeKey("e", modifierFlags: [.command, .shift])
        let window = app.descendants(matching: .any)["extensionsWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let allow = window.checkBoxes["allowUserScripts"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10), "Shown for an extension that uses user scripts")
        allow.click()
        let done = app.sheets.firstMatch.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "The Extensions window stays open")
        done.click()

        button.click()
        expectation(for: NSPredicate(format: "label CONTAINS 'YES'"), evaluatedWith: button)
        waitForExpectations(timeout: 15)
    }

    /// Extensions see the sidebar as bookmarks (chrome.bookmarks): the Space is a folder in the
    /// other bookmarks, and a bookmark an extension creates there becomes a pinned tab. The
    /// extension names the Space in its badge, then adds the bookmark, which isn't loaded.
    @MainActor
    func testExtensionsSeeTheSidebarAsBookmarks() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AxoUITestBookmarks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {"name": "Axo Bookmarker", "version": "1.0", "manifest_version": 3, "description": "UI test extension.",
         "permissions": ["bookmarks"], "action": {"default_title": "Axo Bookmarker"},
         "background": {"service_worker": "bg.js"}}
        """.write(to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try """
        chrome.action.onClicked.addListener(async () => {
          const [root] = await chrome.bookmarks.getTree();
          const space = root.children[1].children[0];
          await chrome.action.setBadgeText({ text: space.title });
          await chrome.bookmarks.create({ parentId: space.id, title: 'Axo Docs', url: 'https://docs.example/' });
        });
        """.write(to: folder.appending(path: "bg.js"), atomically: true, encoding: .utf8)

        let app = launchChromiumApp(extensionFolder: folder)
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        app.typeKey("t", modifierFlags: .command)
        app.typeText("data:text/html,<title>Page</title><p>Page</p>\n")
        let button = app.buttons.matching(NSPredicate(format: "identifier == 'extensionButton' AND label CONTAINS 'Axo Bookmarker'")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 30))
        button.click()

        expectation(for: NSPredicate(format: "label CONTAINS 'Home'"), evaluatedWith: button)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(sidebar.staticTexts["Axo Docs"].waitForExistence(timeout: 15), "The new bookmark is a pinned tab")
    }

    /// History an extension adds (chrome.history.addUrl) reaches Axo's history, so the command
    /// bar finds it. The engine keeps its own copy of history for visited links and extensions.
    @MainActor
    func testExtensionsHistoryReachesAxosHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AxoUITestHistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {"name": "Axo Historian", "version": "1.0", "manifest_version": 3, "description": "UI test extension.",
         "permissions": ["history"], "action": {"default_title": "Axo Historian"},
         "background": {"service_worker": "bg.js"}}
        """.write(to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try """
        chrome.action.onClicked.addListener(async () => {
          await chrome.history.addUrl({ url: 'https://axo-historian.example/' });
          await chrome.action.setBadgeText({ text: 'ADD' });
        });
        """.write(to: folder.appending(path: "bg.js"), atomically: true, encoding: .utf8)

        let app = launchChromiumApp(extensionFolder: folder)
        XCTAssertTrue(app.descendants(matching: .any)["sidebar"].waitForExistence(timeout: 10))
        app.typeKey("t", modifierFlags: .command)
        app.typeText("data:text/html,<title>Page</title><p>Page</p>\n")
        let button = app.buttons.matching(NSPredicate(format: "identifier == 'extensionButton' AND label CONTAINS 'Axo Historian'")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 30))
        button.click()
        expectation(for: NSPredicate(format: "label CONTAINS 'ADD'"), evaluatedWith: button)
        waitForExpectations(timeout: 15)

        app.typeKey("t", modifierFlags: .command)
        app.typeText("axo-historian")
        let result = app.descendants(matching: .any)["commandBar"].buttons
            .matching(NSPredicate(format: "label CONTAINS 'axo-historian.example'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10), "The command bar finds the page in Axo's history")
    }

    /// Clicks the middle of the page, right of the sidebar. (Chromium's page view has its own
    /// accessibility, so it doesn't keep Axo's "webContent" identifier.)
    @MainActor
    private func clickPage(in app: XCUIApplication) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)).click()
    }

    /// Opens a page in a new tab and waits for its title in the sidebar.
    @MainActor
    private func openPage(_ html: String, titled title: String, in app: XCUIApplication) -> XCUIElement {
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        app.typeKey("t", modifierFlags: .command)
        app.typeText("data:text/html,\(html)\n")
        XCTAssertTrue(sidebar.staticTexts[title].waitForExistence(timeout: 30))
        return sidebar
    }

    /// A page's confirm() is Axo's alert, and the answer reaches the page.
    @MainActor
    func testJavaScriptDialogsAreAxosAlerts() throws {
        let app = launchChromiumApp()
        let sidebar = openPage(
            "<title>Asking</title><script>setTimeout(() => document.title = confirm('Keep going?') ? 'Confirmed' : 'Declined', 300)</script>",
            titled: "Asking", in: app
        )
        let ok = app.sheets.firstMatch.buttons["OK"]
        XCTAssertTrue(ok.waitForExistence(timeout: 15), "Axo's alert shows the dialog")
        XCTAssertTrue(app.sheets.firstMatch.staticTexts["Keep going?"].exists)
        ok.click()
        XCTAssertTrue(sidebar.staticTexts["Confirmed"].waitForExistence(timeout: 10))
    }

    /// A page's file field opens Axo's Open panel; cancelling reaches the page.
    @MainActor
    func testFileUploadsUseAxosOpenPanel() throws {
        let app = launchChromiumApp()
        let sidebar = openPage(
            "<title>Upload</title><label style='display:block;width:100vw;height:100vh'><input type=file id=f style='width:100%;height:100%' oncancel=\"document.title='Cancelled'\" onchange=\"document.title='Chosen'\"></label>",
            titled: "Upload", in: app
        )
        clickPage(in: app)
        let cancel = app.sheets.firstMatch.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), "Axo's Open panel appears")
        cancel.click()
        XCTAssertTrue(sidebar.staticTexts["Cancelled"].waitForExistence(timeout: 10))
    }

    /// A page asking to fill the screen shows alone, without the sidebar or toolbar; Esc ends it,
    /// and the page knows. (The window going full screen isn't checked: macOS doesn't make
    /// windows full screen while UI tests drive the app, even from the green button.)
    @MainActor
    func testPagesFillTheWindowUntilEscape() throws {
        let app = launchChromiumApp()
        let sidebar = openPage(
            "<title>Video</title><body style='margin:0' onclick='document.documentElement.requestFullscreen()'><div style='width:100vw;height:100vh'></div><script>document.onfullscreenchange = () => document.title = document.fullscreenElement ? 'Full' : 'Back'</script></body>",
            titled: "Video", in: app
        )
        clickPage(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["fullscreenPage"].waitForExistence(timeout: 15), "Only the page shows")
        XCTAssertFalse(sidebar.exists)
        XCTAssertFalse(app.buttons["backButton"].exists, "The toolbar is hidden too")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sidebar.staticTexts["Back"].waitForExistence(timeout: 15), "The page left full screen, and the sidebar is back")
    }

    /// window.open keeps the new page connected to its opener: it's a sidebar tab whose page can
    /// reach window.opener.
    @MainActor
    func testWindowOpenKeepsTheOpener() throws {
        let app = launchChromiumApp()
        let sidebar = openPage(
            "<title>Opener</title><script>function go() { const w = window.open(''); w.document.title = w.opener === window ? 'Has opener' : 'No opener' }</script><body style='margin:0' onclick='go()'><div style='width:100vw;height:100vh'></div></body>",
            titled: "Opener", in: app
        )
        clickPage(in: app)
        XCTAssertTrue(sidebar.staticTexts["Has opener"].waitForExistence(timeout: 15), "A tab connected to the page that opened it")
    }

    /// A link leaving a pinned tab's site opens in Peek, and the pinned tab stays where it was:
    /// Chromium asks Axo before following a link click, as WebKit does. The link points at a
    /// closed loopback port, so nothing leaves the machine.
    @MainActor
    func testLinksFromPinnedTabsOpenInPeek() throws {
        let app = launchChromiumApp()
        let sidebar = openPage(
            "<title>Home</title><body style='margin:0'><a href='http://127.0.0.1:9/far' style='display:block;width:100vw;height:100vh'>Far away</a></body>",
            titled: "Home", in: app
        )
        app.typeKey("p", modifierFlags: [.command, .control])
        XCTAssertTrue(sidebar.staticTexts["Pinned"].waitForExistence(timeout: 5))

        clickPage(in: app)
        let peek = app.descendants(matching: .any)["peek"]
        XCTAssertTrue(peek.waitForExistence(timeout: 10), "The link opens in Peek")
        XCTAssertTrue(peek.staticTexts["127.0.0.1"].waitForExistence(timeout: 10), "Peek shows the clicked link")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(peek.waitForNonExistence(timeout: 5), "Esc closes Peek")
        // Long enough for a navigation that wasn't stopped to reach the closed port and fail.
        sleep(2)
        XCTAssertTrue(sidebar.staticTexts["Home"].exists, "The pinned tab stayed on its page")
        XCTAssertFalse(sidebar.staticTexts["127.0.0.1"].exists, "The pinned tab didn't navigate to the link")
    }

    /// Find in page works on Chromium pages: a word on the page is found, one that isn't says
    /// "No matches", and Esc closes the find bar.
    @MainActor
    func testFindInPage() throws {
        let app = launchChromiumApp()
        _ = openPage("<title>Pond</title><p>Axolotls live in lakes.</p>", titled: "Pond", in: app)

        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["findField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.typeText("lakes")
        XCTAssertFalse(app.staticTexts["findNoMatches"].waitForExistence(timeout: 3), "The word on the page is found")

        app.typeKey("a", modifierFlags: .command)
        app.typeText("ocean")
        XCTAssertTrue(app.staticTexts["findNoMatches"].waitForExistence(timeout: 5))

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
    }

    /// A tab loads its page in Chromium. The page names the engine from its user agent, which
    /// says "Chrome/" only in Chromium, so the test can't pass on WebKit.
    @MainActor
    func testATabLoadsInChromium() throws {
        let app = XCUIApplication()
        app.launchEnvironment["AXO_UI_TESTING"] = "1"
        app.launchEnvironment["AXO_UI_TESTING_CHROMIUM"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        AxoUITests.bringToFront(app)

        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        app.typeKey("t", modifierFlags: .command)
        app.typeText("data:text/html,<title>Loading</title><h1>Hello from Axo</h1><script>document.title = navigator.userAgent.includes('Chrome/') ? 'Chromium page' : 'WebKit page'</script>\n")

        let chromium = sidebar.staticTexts["Chromium page"]
        let webKit = sidebar.staticTexts["WebKit page"]
        let loaded = NSPredicate { _, _ in chromium.exists || webKit.exists }
        wait(for: [expectation(for: loaded, evaluatedWith: nil)], timeout: 30)
        XCTAssertTrue(chromium.exists, "The tab ran in Chromium, not WebKit")
        XCTAssertFalse(webKit.exists)
    }
}
