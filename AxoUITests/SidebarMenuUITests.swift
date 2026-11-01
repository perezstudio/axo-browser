import XCTest

/// Every item in the sidebar's context menus: tabs, pinned tabs, split views, folders,
/// favorites, and Spaces. Each test picks items from the menu a right-click opens and checks
/// the sidebar afterwards.
final class SidebarMenuUITests: XCTestCase {
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
    private func launchApp() -> (XCUIApplication, XCUIElement) {
        let app = AxoUITests.makeApp()
        app.launch()
        AxoUITests.bringToFront(app)
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        return (app, sidebar)
    }

    /// Opens a tab on a page with only a title, so tests never touch the network.
    @MainActor
    private func openTab(_ title: String, in app: XCUIApplication, sidebar: XCUIElement) {
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.textFields["commandField"].waitForExistence(timeout: 5))
        app.typeText("data:text/html,<title>\(title)</title>\n")
        XCTAssertTrue(sidebar.staticTexts[title].waitForExistence(timeout: 10))
    }

    /// Loads another page in the selected tab, from the address field.
    @MainActor
    private func browse(to title: String, in app: XCUIApplication) {
        app.typeKey("l", modifierFlags: .command)
        app.typeText("data:text/html,<title>\(title)</title>\n")
        expectSelected(title, in: app)
    }

    @MainActor
    private func expectSelected(_ title: String, in app: XCUIApplication) {
        expectation(for: NSPredicate(format: "value CONTAINS %@", title), evaluatedWith: app.textFields["addressField"])
        waitForExpectations(timeout: 10)
    }

    /// Right-clicks `element` and returns the context menu's item called `title`. Context menus
    /// open in the window; the menu bar has items with the same names.
    @MainActor
    private func menuItem(_ title: String, on element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        element.rightClick()
        let item = app.windows.firstMatch.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "No \(title) in the menu")
        return item
    }

    /// Picks `title` from `element`'s context menu.
    @MainActor
    private func choose(_ title: String, on element: XCUIElement, in app: XCUIApplication) {
        menuItem(title, on: element, in: app).click()
    }

    /// Whether `title` is enabled in `element`'s context menu, closing the menu again. Waits for
    /// the menu to close: a click right after Esc closes a menu can be lost.
    @MainActor
    private func isEnabled(_ title: String, on element: XCUIElement, in app: XCUIApplication) -> Bool {
        let item = menuItem(title, on: element, in: app)
        let enabled = item.isEnabled
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(item.waitForNonExistence(timeout: 5))
        return enabled
    }

    /// The unpinned tabs' titles, in sidebar order.
    private func tabRows(in sidebar: XCUIElement) -> [String] {
        sidebar.staticTexts.matching(identifier: "tabRow").allElementsBoundByIndex.map { row in
            // SwiftUI Text exposes its string as the value.
            (row.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? row.label
        }
    }

    /// A folder's row, by its name and item count. (The Pinned section's identifier replaces
    /// the row's own.)
    private func folderRow(_ name: String, in sidebar: XCUIElement) -> XCUIElement {
        sidebar.staticTexts
            .matching(NSPredicate(format: "label == %@ AND (value ENDSWITH ' items' OR value == '1 item')", name)).firstMatch
    }

    // MARK: Tabs

    /// Close Tab on the only tab leaves the sidebar empty and shows the empty state.
    @MainActor
    func testCloseTabOnTheOnlyTab() throws {
        let (app, sidebar) = launchApp()
        openTab("Solo", in: app, sidebar: sidebar)

        choose("Close Tab", on: sidebar.staticTexts["Solo"], in: app)

        XCTAssertTrue(sidebar.staticTexts["Solo"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["emptyState"].waitForExistence(timeout: 5))
        XCTAssertEqual(tabRows(in: sidebar), [])
        // ⇧⌘T brings it back, so it was closed (archived), not lost.
        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertTrue(sidebar.staticTexts["Solo"].waitForExistence(timeout: 5))
    }

    /// Close Tab on the selected tab of several shows the next one; on another tab it keeps the
    /// selection.
    @MainActor
    func testCloseTabAmongSeveralTabs() throws {
        let (app, sidebar) = launchApp()
        for title in ["One", "Two", "Three"] {
            openTab(title, in: app, sidebar: sidebar)
        }
        sidebar.staticTexts["Two"].click()
        expectSelected("Two", in: app)

        choose("Close Tab", on: sidebar.staticTexts["Two"], in: app)
        XCTAssertTrue(sidebar.staticTexts["Two"].waitForNonExistence(timeout: 5))
        expectSelected("Three", in: app)
        XCTAssertEqual(tabRows(in: sidebar), ["One", "Three"])

        choose("Close Tab", on: sidebar.staticTexts["One"], in: app)
        XCTAssertTrue(sidebar.staticTexts["One"].waitForNonExistence(timeout: 5))
        expectSelected("Three", in: app)
        XCTAssertEqual(tabRows(in: sidebar), ["Three"])
    }

    /// A pinned tab's menu: Go to Pinned Page and Pin This Page Instead (enabled only once it
    /// has left its page), Unload Tab, and Unpin Tab.
    @MainActor
    func testPinnedTabMenu() throws {
        let (app, sidebar) = launchApp()
        openTab("Start", in: app, sidebar: sidebar)
        choose("Pin Tab", on: sidebar.staticTexts["Start"], in: app)
        XCTAssertTrue(sidebar.staticTexts["Pinned"].waitForExistence(timeout: 5))
        XCTAssertFalse(isEnabled("Go to Pinned Page", on: sidebar.staticTexts["Start"], in: app),
                       "It's on its pinned page")
        XCTAssertFalse(isEnabled("Pin This Page Instead", on: sidebar.staticTexts["Start"], in: app))

        // Titles without spaces: the address field shows them percent-encoded.
        browse(to: "Away", in: app)
        XCTAssertTrue(sidebar.staticTexts["Away"].waitForExistence(timeout: 5))
        choose("Go to Pinned Page", on: sidebar.staticTexts["Away"], in: app)
        XCTAssertTrue(sidebar.staticTexts["Start"].waitForExistence(timeout: 10))
        expectSelected("Start", in: app)

        browse(to: "Later", in: app)
        XCTAssertTrue(sidebar.staticTexts["Later"].waitForExistence(timeout: 5))
        choose("Pin This Page Instead", on: sidebar.staticTexts["Later"], in: app)
        let goHome = menuItem("Go to Pinned Page", on: sidebar.staticTexts["Later"], in: app)
        expectation(for: NSPredicate(format: "isEnabled == false"), evaluatedWith: goHome)
        waitForExpectations(timeout: 5)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(goHome.waitForNonExistence(timeout: 5))

        choose("Unload Tab", on: sidebar.staticTexts["Later"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["emptyState"].waitForExistence(timeout: 5),
                      "Its page goes away")
        XCTAssertTrue(sidebar.staticTexts["Later"].exists, "It stays pinned")
        XCTAssertTrue(sidebar.staticTexts["Pinned"].exists)

        choose("Unpin Tab", on: sidebar.staticTexts["Later"], in: app)
        XCTAssertTrue(sidebar.staticTexts["Pinned"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(tabRows(in: sidebar), ["Later"])
    }

    /// Add to Split View from a tab's menu, then the split row's Stack Panes, Show Panes Side by
    /// Side, and Separate Split View.
    @MainActor
    func testSplitViewMenu() throws {
        let (app, sidebar) = launchApp()
        for title in ["Notes", "Docs"] {
            openTab(title, in: app, sidebar: sidebar)
        }

        choose("Add to Split View", on: sidebar.staticTexts["Notes"], in: app)
        let splitView = app.descendants(matching: .any)["splitView"]
        XCTAssertTrue(splitView.waitForExistence(timeout: 10))
        let row = sidebar.descendants(matching: .any).matching(identifier: "splitRow").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        choose("Stack Panes", on: row, in: app)
        choose("Show Panes Side by Side", on: row, in: app)
        XCTAssertTrue(menuItem("Stack Panes", on: row, in: app).exists, "Back side by side")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.windows.firstMatch.menuItems["Stack Panes"].waitForNonExistence(timeout: 5))

        choose("Separate Split View", on: row, in: app)
        XCTAssertTrue(splitView.waitForNonExistence(timeout: 5))
        XCTAssertEqual(tabRows(in: sidebar).sorted(), ["Docs", "Notes"])
    }

    // MARK: Folders

    /// A folder's menu: New Folder Inside…, Rename…, and Delete Folder; and a tab's Move to
    /// Folder into a nested folder and back out with Pinned (No Folder).
    @MainActor
    func testFolderMenu() throws {
        let (app, sidebar) = launchApp()
        openTab("Docs", in: app, sidebar: sidebar)
        app.typeKey("n", modifierFlags: [.command, .control])
        let nameField = app.textFields["nameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.typeText("Work\n")
        let work = folderRow("Work", in: sidebar)
        XCTAssertTrue(work.waitForExistence(timeout: 5))

        choose("New Folder Inside…", on: work, in: app)
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.typeText("Inner\n")
        XCTAssertTrue(folderRow("Inner", in: sidebar).waitForExistence(timeout: 5))
        XCTAssertEqual(work.value as? String, "1 item", "Inner is inside Work")

        choose("Rename…", on: folderRow("Inner", in: sidebar), in: app)
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        XCTAssertEqual(nameField.value as? String, "Inner")
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText("Drafts\n")
        let drafts = folderRow("Drafts", in: sidebar)
        XCTAssertTrue(drafts.waitForExistence(timeout: 5))
        XCTAssertFalse(folderRow("Inner", in: sidebar).exists)

        // Nested folders are indented in the menu, and VoiceOver names their parent.
        sidebar.staticTexts["Docs"].rightClick()
        let menu = app.windows.firstMatch
        menu.menuItems["Move to Folder"].hover()
        let nested = menu.menuItems.matching(NSPredicate(format: "label == 'Drafts, inside Work' OR title CONTAINS 'Drafts'")).firstMatch
        XCTAssertTrue(nested.waitForExistence(timeout: 5))
        nested.click()
        XCTAssertTrue(sidebar.staticTexts["Pinned"].waitForExistence(timeout: 5), "Moving into a folder pins the tab")
        expectation(for: NSPredicate(format: "value == '1 item'"), evaluatedWith: drafts)
        waitForExpectations(timeout: 5)

        sidebar.staticTexts["Docs"].rightClick()
        menu.menuItems["Move to Folder"].hover()
        let topLevel = menu.menuItems["Pinned (No Folder)"]
        XCTAssertTrue(topLevel.waitForExistence(timeout: 5))
        topLevel.click()
        expectation(for: NSPredicate(format: "value == '0 items'"), evaluatedWith: drafts)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(sidebar.staticTexts["Docs"].exists, "It stays pinned, at the top level")

        choose("Delete Folder", on: drafts, in: app)
        XCTAssertTrue(drafts.waitForNonExistence(timeout: 5))
        choose("Delete Folder", on: work, in: app)
        XCTAssertTrue(work.waitForNonExistence(timeout: 5))
        XCTAssertTrue(sidebar.staticTexts["Docs"].exists, "Deleting folders keeps what was in them")
    }

    // MARK: Favorites

    /// A favorite's menu: Move Left and Move Right (each disabled at its end), Make This Page
    /// the Favorite (enabled once it has left its page), Unload, and Move to Pinned Tabs.
    @MainActor
    func testFavoriteMenu() throws {
        let (app, sidebar) = launchApp()
        for title in ["Mail", "News", "Docs"] {
            openTab(title, in: app, sidebar: sidebar)
        }
        choose("Add to Favorites", on: sidebar.staticTexts["Mail"], in: app)
        choose("Add to Favorites", on: sidebar.staticTexts["News"], in: app)
        let tiles = app.buttons.matching(identifier: "favoriteTile")
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: tiles)
        waitForExpectations(timeout: 5)
        func order() -> [String] { tiles.allElementsBoundByIndex.map(\.label) }
        XCTAssertEqual(order(), ["Mail", "News"])

        XCTAssertFalse(isEnabled("Move Left", on: tiles.element(boundBy: 0), in: app))
        XCTAssertFalse(isEnabled("Move Right", on: tiles.element(boundBy: 1), in: app))
        choose("Move Right", on: tiles.element(boundBy: 0), in: app)
        expectation(for: NSPredicate(format: "label == 'Mail'"), evaluatedWith: tiles.element(boundBy: 1))
        waitForExpectations(timeout: 5)
        XCTAssertEqual(order(), ["News", "Mail"])
        choose("Move Left", on: tiles.element(boundBy: 1), in: app)
        expectation(for: NSPredicate(format: "label == 'Mail'"), evaluatedWith: tiles.element(boundBy: 0))
        waitForExpectations(timeout: 5)

        let mail = tiles.element(boundBy: 0)
        mail.click()
        expectSelected("Mail", in: app)
        XCTAssertFalse(isEnabled("Make This Page the Favorite", on: mail, in: app), "It's on its page")
        browse(to: "Inbox", in: app)
        expectation(for: NSPredicate(format: "value == 'Away from favorite page'"), evaluatedWith: mail)
        waitForExpectations(timeout: 5)
        choose("Make This Page the Favorite", on: mail, in: app)
        expectation(for: NSPredicate(format: "value == ''"), evaluatedWith: mail)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(isEnabled("Make This Page the Favorite", on: mail, in: app))

        choose("Unload", on: mail, in: app)
        expectation(for: NSPredicate(format: "isSelected == false"), evaluatedWith: mail)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(isEnabled("Unload", on: mail, in: app), "Its page is gone")
        XCTAssertEqual(tiles.count, 2, "It stays a favorite")

        choose("Move to Pinned Tabs", on: mail, in: app)
        expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: tiles)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(sidebar.staticTexts["Pinned"].waitForExistence(timeout: 5))
        XCTAssertTrue(sidebar.staticTexts["Inbox"].exists, "It keeps the page it was made the favorite")
    }

    // MARK: Spaces

    /// A Space's menu in the switcher: Rename…, and Delete Space… (disabled for the only Space),
    /// plus the New Space sheet's "Use a separate profile".
    @MainActor
    func testSpaceMenu() throws {
        let (app, sidebar) = launchApp()
        let dots = app.buttons.matching(identifier: "spaceButton")
        XCTAssertEqual(dots.count, 1)
        XCTAssertFalse(isEnabled("Delete Space…", on: dots.element(boundBy: 0), in: app), "The only Space stays")

        choose("Rename…", on: dots.element(boundBy: 0), in: app)
        let nameField = app.textFields["nameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        XCTAssertEqual(nameField.value as? String, "Home")
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText("Personal\n")
        XCTAssertTrue(sidebar.staticTexts["Personal"].waitForExistence(timeout: 5))
        XCTAssertEqual(dots.element(boundBy: 0).label, "Personal")

        app.buttons["newSpaceButton"].click()
        let spaceName = app.textFields["spaceNameField"]
        XCTAssertTrue(spaceName.waitForExistence(timeout: 5))
        spaceName.typeText("Work")
        let separate = app.descendants(matching: .any)["separateProfileToggle"]
        XCTAssertTrue(separate.exists)
        separate.click()
        // The profile's name field has only a placeholder (the Space's name).
        let profileName = app.textFields.matching(NSPredicate(format: "placeholderValue == 'Work' AND identifier != 'spaceNameField'"))
        XCTAssertTrue(profileName.firstMatch.waitForExistence(timeout: 5), "It asks for the profile's name")
        app.buttons["createSpaceButton"].click()
        XCTAssertTrue(sidebar.staticTexts["Work"].waitForExistence(timeout: 5))
        XCTAssertEqual(dots.count, 2)

        choose("Delete Space…", on: dots.element(boundBy: 1), in: app)
        let confirm = app.sheets.buttons["Delete Space"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: dots)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(sidebar.staticTexts["Personal"].waitForExistence(timeout: 5))
    }
}
