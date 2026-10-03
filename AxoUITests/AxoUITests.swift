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

    @MainActor
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

    /// A page's `confirm()` shows as a dialog naming the page, and the page gets the answer.
    @MainActor
    func testJavaScriptConfirmShowsAndReturnsTheAnswer() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))

        app.typeKey("t", modifierFlags: .command)
        // Ask after a moment, so the dialog doesn't open while the typed Return is still being delivered.
        app.typeText("data:text/html,<title>Ask</title><script>setTimeout(() => document.title = confirm('Delete everything?') ? 'Yes' : 'No', 300)</script>\n")

        XCTAssertTrue(app.staticTexts["This page says"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Delete everything?"].exists)
        let dialog = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch
        dialog.buttons["Cancel"].firstMatch.click()

        XCTAssertTrue(sidebar.staticTexts["No"].waitForExistence(timeout: 10))
    }

    /// Create a Space from the switcher, see its tabs separately, and switch back with ⌃1.
    @MainActor
    func testCreatingAndSwitchingSpaces() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        app.typeKey("t", modifierFlags: .command)
        app.typeText("data:text/html,<title>Home tab</title>\n")
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

    /// Pin a tab from its context menu, close and reopen an unpinned tab, and see that closing
    /// the pinned tab keeps it in the sidebar.
    @MainActor
    func testPinCloseAndReopenTabs() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        for title in ["Mail", "Article"] {
            app.typeKey("t", modifierFlags: .command)
            app.typeText("data:text/html,<title>\(title)</title>\n")
            XCTAssertTrue(sidebar.staticTexts[title].waitForExistence(timeout: 10))
        }

        sidebar.staticTexts["Mail"].rightClick()
        app.menuItems["Pin Tab"].click()
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
        app.typeKey("t", modifierFlags: .command)
        app.typeText("data:text/html,<title>Docs</title>\n")
        XCTAssertTrue(sidebar.staticTexts["Docs"].waitForExistence(timeout: 10))

        app.typeKey("n", modifierFlags: [.command, .control])
        let nameField = app.textFields["nameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.typeText("Work\n")
        XCTAssertTrue(sidebar.staticTexts["Work"].waitForExistence(timeout: 5))

        sidebar.staticTexts["Docs"].rightClick()
        app.menuItems["Move to Folder"].hover()
        app.menuItems["Work"].click()
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
            XCTAssertTrue(app.textFields["commandField"].waitForExistence(timeout: 5))
            app.typeText("data:text/html,<title>\(title)</title>\n")
            XCTAssertTrue(sidebar.staticTexts[title].waitForExistence(timeout: 10))
            XCTAssertFalse(app.textFields["commandField"].exists, "The command bar closes after opening a page")
        }

        app.typeKey("t", modifierFlags: .command)
        app.typeText("garden")
        let tabRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'commandResult' AND label CONTAINS 'Garden notes'"))
            .firstMatch
        XCTAssertTrue(tabRow.waitForExistence(timeout: 5))
        // The first row searches for "garden"; the matching tab is next.
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])

        XCTAssertFalse(app.textFields["commandField"].waitForExistence(timeout: 2))
        let address = app.textFields["addressField"]
        expectation(for: NSPredicate(format: "value CONTAINS 'Garden'"), evaluatedWith: address)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(sidebar.staticTexts.matching(identifier: "tabRow").count, 2, "Switching doesn't open a tab")

        // Esc closes the command bar without doing anything.
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.textFields["commandField"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.textFields["commandField"].waitForNonExistence(timeout: 5))
    }

    /// A link sent from another app opens as a tab in the existing window, not a new window.
    @MainActor
    func testLinksFromOtherAppsOpenAsTabs() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))

        // Port 9 on the loopback address refuses connections, so nothing leaves the machine.
        app.open(URL(string: "http://127.0.0.1:9/from-another-app")!)

        XCTAssertTrue(sidebar.staticTexts["127.0.0.1"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 1, "The link opens in the existing window")
    }

    /// Site Settings shows the current site's camera, microphone, and location answers, which
    /// can be changed and reset.
    @MainActor
    func testSiteSettingsChangeAndResetASitesPermissions() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["siteSettingsButton"].isEnabled, "No site without a web page")

        // A closed loopback port: nothing loads, but the tab has a web address.
        app.typeKey("t", modifierFlags: .command)
        app.typeText("http://127.0.0.1:9/room\n")
        XCTAssertTrue(sidebar.staticTexts["127.0.0.1"].waitForExistence(timeout: 10))

        app.buttons["siteSettingsButton"].click()
        let camera = app.popUpButtons["sitePermission-camera"]
        XCTAssertTrue(camera.waitForExistence(timeout: 5))
        XCTAssertEqual(camera.value as? String, "Ask")
        XCTAssertTrue(app.popUpButtons["sitePermission-microphone"].exists)
        XCTAssertTrue(app.popUpButtons["sitePermission-location"].exists)

        camera.click()
        app.menuItems["Don't Allow"].click()
        expectation(for: NSPredicate(format: "value == %@", "Don't Allow"), evaluatedWith: camera)
        waitForExpectations(timeout: 5)

        app.buttons["resetSiteSettings"].click()
        expectation(for: NSPredicate(format: "value == %@", "Ask"), evaluatedWith: camera)
        waitForExpectations(timeout: 5)
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
        XCTAssertTrue(sidebar.staticTexts["Library"].waitForExistence(timeout: 5))
        XCTAssertTrue(sidebar.staticTexts["Favorites"].exists)

        // Chrome's bookmarks go into the current Space.
        app.typeKey("t", modifierFlags: .command)
        app.typeText("import")
        let action = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'commandResult' AND label CONTAINS 'Import from Another Browser'")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        // The first row searches for "import"; the action is next.
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        let picker = app.popUpButtons["importSourcePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.click()
        app.menuItems["Google Chrome"].click()
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

        let button = app.buttons.matching(NSPredicate(format: "identifier == 'extensionButton' AND label CONTAINS 'Axo Helper'")).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label CONTAINS '3'"), evaluatedWith: button)
        waitForExpectations(timeout: 10)

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
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        app.typeKey("t", modifierFlags: .command)
        app.typeText("data:text/html,<title>Inspect</title><h1>Inspect me</h1>\n")
        XCTAssertTrue(sidebar.staticTexts["Inspect"].waitForExistence(timeout: 10))

        app.typeKey("i", modifierFlags: [.command, .option])

        // The inspector's own interface is a web page with tabs like Elements and Console.
        let inspectorTab = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Elements' OR title == 'Elements' OR value == 'Elements'"))
            .firstMatch
        XCTAssertTrue(inspectorTab.waitForExistence(timeout: 15))
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(inspectorTab.frame), "Docked inside the browser window")
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
