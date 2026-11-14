import AppKit
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
        AxoUITests.openPage("data:text/html,<title>\(title)</title>", in: app)
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
        expectation(for: NSPredicate(format: "value CONTAINS %@", title), evaluatedWith: app.descendants(matching: .any)["sidebarAddressBar"])
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

    /// Waits until `title` in `element`'s context menu is `enabled`, opening the menu again
    /// each time: an action runs after its menu closes, so a menu opened at once can still show
    /// the state from before it.
    @MainActor
    private func expectMenuItem(_ title: String, on element: XCUIElement, enabled: Bool, in app: XCUIApplication,
                                _ message: String = "", line: UInt = #line) {
        let deadline = Date.now.addingTimeInterval(10)
        var lastSeen = !enabled
        repeat {
            lastSeen = isEnabled(title, on: element, in: app)
            if lastSeen == enabled { return }
        } while Date.now < deadline
        XCTFail("\(title) stayed \(lastSeen ? "enabled" : "disabled"). \(message)", line: line)
    }

    /// Opens `element`'s Move to Folder submenu and returns its item titled `title` (a nested
    /// folder's title is its path, such as "Work › Drafts").
    @MainActor
    private func moveToFolderItem(_ title: String, on element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        element.rightClick()
        let menu = app.windows.firstMatch
        let move = menu.menuItems["Move to Folder"]
        XCTAssertTrue(move.waitForExistence(timeout: 5))
        move.hover()
        let item = menu.menuItems.matching(NSPredicate(format: "title == %@", title)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "No \(title) in Move to Folder")
        return item
    }

    /// Closes an open context menu and its submenus, waiting until they're gone.
    @MainActor
    private func closeMenus(in app: XCUIApplication) {
        let menu = app.windows.firstMatch.menus.firstMatch
        for _ in 0..<3 where menu.exists {
            app.typeKey(.escape, modifierFlags: [])
            _ = menu.waitForNonExistence(timeout: 2)
        }
        XCTAssertFalse(menu.exists, "The menu didn't close")
    }

    /// The unpinned tabs' titles, in sidebar order.
    @MainActor
    private func tabRows(in sidebar: XCUIElement) -> [String] {
        sidebar.staticTexts.matching(identifier: "tabRow").allElementsBoundByIndex.map { row in
            // The row's label is its title; its value is its state ("Unloaded" for a tab not
            // loaded since launch), when it has one.
            row.label.isEmpty ? (row.value as? String) ?? "" : row.label
        }
    }

    /// A folder's row, by its name, as `testFoldersHoldPinnedTabs` finds it. (The Pinned
    /// section's identifier replaces the row's own, so folder names here differ from tab titles.)
    @MainActor
    private func folderRow(_ name: String, in sidebar: XCUIElement) -> XCUIElement {
        sidebar.staticTexts[name]
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
        expectMenuItem("Go to Pinned Page", on: sidebar.staticTexts["Later"], enabled: false, in: app,
                       "This page is the pinned page now")

        choose("Unload Tab", on: sidebar.staticTexts["Later"], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["emptyState"].waitForExistence(timeout: 5),
                      "Its page goes away")
        XCTAssertTrue(sidebar.staticTexts["Later"].exists, "It stays pinned")
        XCTAssertTrue(sidebar.staticTexts["Pinned"].exists)

        choose("Unpin Tab", on: sidebar.staticTexts["Later"], in: app)
        XCTAssertTrue(sidebar.staticTexts["Pinned"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(tabRows(in: sidebar), ["Later"])
    }

    /// Makes a split of `first` and `second` (selected) with `first`'s Add to Split View, and
    /// returns its sidebar row.
    @MainActor
    private func makeSplit(_ first: String, _ second: String, in app: XCUIApplication, sidebar: XCUIElement) -> XCUIElement {
        sidebar.staticTexts[second].click()
        expectSelected(second, in: app)
        choose("Add to Split View", on: sidebar.staticTexts[first], in: app)
        XCTAssertTrue(app.descendants(matching: .any)["splitView"].waitForExistence(timeout: 10))
        // Pinned, the row takes the Pinned section's identifier and shows its spoken text only
        // as its value; it's the only pinned row here without a label of its own.
        let row = sidebar.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'splitRow' OR (identifier == 'pinnedSection' AND label == '')")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        return row
    }

    /// Waits until the split's two panes sit side by side (`true`) or stacked.
    @MainActor
    private func expectPanes(sideBySide: Bool, in app: XCUIApplication) {
        let panes = app.descendants(matching: .any).matching(identifier: "splitPane")
        let deadline = Date.now.addingTimeInterval(10)
        while Date.now < deadline {
            let frames = panes.allElementsBoundByIndex.map(\.frame)
            if frames.count == 2 {
                let apartHorizontally = abs(frames[0].midX - frames[1].midX) > abs(frames[0].midY - frames[1].midY)
                if apartHorizontally == sideBySide { return }
            }
            _ = panes.firstMatch.waitForNonExistence(timeout: 0.5)
        }
        XCTFail("The panes aren't \(sideBySide ? "side by side" : "stacked")")
    }

    /// Add to Split View from a tab's menu, then the split row's Stack Panes, Show Panes Side by
    /// Side, and Separate Split View.
    @MainActor
    func testSplitViewMenu() throws {
        let (app, sidebar) = launchApp()
        for title in ["Notes", "Docs"] {
            openTab(title, in: app, sidebar: sidebar)
        }
        let row = makeSplit("Notes", "Docs", in: app, sidebar: sidebar)
        expectPanes(sideBySide: true, in: app)

        choose("Stack Panes", on: row, in: app)
        expectPanes(sideBySide: false, in: app)
        choose("Show Panes Side by Side", on: row, in: app)
        expectPanes(sideBySide: true, in: app)

        choose("Separate Split View", on: row, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["splitView"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(tabRows(in: sidebar).sorted(), ["Docs", "Notes"])
    }

    /// A tab's context menu duplicates it, copies its link, moves it to another of the profile's
    /// Spaces, and closes the other tabs or those below it (#81).
    @MainActor
    func testTabContextMenuActions() throws {
        let (app, sidebar) = launchApp()
        for title in ["Alpha", "Beta", "Gamma", "Delta"] {
            openTab(title, in: app, sidebar: sidebar)
        }

        // Duplicate: a second Alpha, selected.
        choose("Duplicate Tab", on: sidebar.staticTexts["Alpha"], in: app)
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: sidebar.staticTexts.matching(NSPredicate(format: "label == 'Alpha'")))
        waitForExpectations(timeout: 10)

        // Copy Link: the tab's address, on the test run's own pasteboard.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.perezstudio.Axo.testing"))
        pasteboard.clearContents()
        choose("Copy Link", on: sidebar.staticTexts["Gamma"], in: app)
        let copied = expectation(description: "the link is copied")
        Task { @MainActor in
            for _ in 0..<50 where pasteboard.string(forType: .string) == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if pasteboard.string(forType: .string)?.contains("Gamma") == true { copied.fulfill() }
        }
        wait(for: [copied], timeout: 10)

        // Close Tabs Below Gamma: Delta goes.
        choose("Close Tabs Below", on: sidebar.staticTexts["Gamma"], in: app)
        XCTAssertTrue(sidebar.staticTexts["Delta"].waitForNonExistence(timeout: 5))

        // Move to Space: Beta goes to a new Space of the same profile.
        app.buttons["newSpaceButton"].click()
        let nameField = app.textFields["spaceNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.click()
        nameField.typeText("Work")
        app.buttons["createSpaceButton"].click()
        XCTAssertTrue(sidebar.staticTexts["Work"].waitForExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .control)
        XCTAssertTrue(sidebar.staticTexts["Beta"].waitForExistence(timeout: 5))
        sidebar.staticTexts["Beta"].rightClick()
        let moveMenu = app.windows.firstMatch.menuItems["Move to Space"]
        XCTAssertTrue(moveMenu.waitForExistence(timeout: 5))
        moveMenu.hover()
        let work = app.windows.firstMatch.menuItems["Work"]
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        work.click()
        XCTAssertTrue(sidebar.staticTexts["Beta"].waitForNonExistence(timeout: 5))

        // Close Other Tabs on Gamma: both Alphas go.
        choose("Close Other Tabs", on: sidebar.staticTexts["Gamma"], in: app)
        XCTAssertTrue(sidebar.staticTexts["Alpha"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(tabRows(in: sidebar), ["Gamma"])

        app.typeKey("2", modifierFlags: .control)
        XCTAssertTrue(sidebar.staticTexts["Beta"].waitForExistence(timeout: 5), "Beta is in Work")
    }

    /// The tab items on a split's row act on the split: Pin Tab and Unpin Tab pin it whole, Move
    /// to Folder › New Folder… moves it into a new folder and Pinned (No Folder) back out, and
    /// Add to Favorites and Close Tab take the row's tab out, which ends a two-pane split.
    @MainActor
    func testSplitRowTabItems() throws {
        let (app, sidebar) = launchApp()
        for title in ["Notes", "Docs", "Mail", "News"] {
            openTab(title, in: app, sidebar: sidebar)
        }
        var row = makeSplit("Notes", "Docs", in: app, sidebar: sidebar)

        choose("Pin Tab", on: row, in: app)
        XCTAssertTrue(sidebar.staticTexts["Pinned"].waitForExistence(timeout: 5))
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The split stays together")
        XCTAssertEqual(tabRows(in: sidebar).sorted(), ["Mail", "News"], "Both panes are pinned")

        let newFolder = moveToFolderItem("New Folder…", on: row, in: app)
        newFolder.click()
        let nameField = app.textFields["nameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.typeText("Box\n")
        let box = folderRow("Box", in: sidebar)
        XCTAssertTrue(box.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value == '1 item'"), evaluatedWith: box)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        moveToFolderItem("Pinned (No Folder)", on: row, in: app).click()
        expectation(for: NSPredicate(format: "value == '0 items'"), evaluatedWith: box)
        waitForExpectations(timeout: 5)
        choose("Delete Folder", on: box, in: app)
        XCTAssertTrue(box.waitForNonExistence(timeout: 5))

        choose("Unpin Tab", on: row, in: app)
        XCTAssertTrue(sidebar.staticTexts["Pinned"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The split stays together")
        XCTAssertEqual(tabRows(in: sidebar).sorted(), ["Mail", "News"])

        choose("Add to Favorites", on: row, in: app)
        XCTAssertTrue(app.buttons["favoriteTile"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["splitView"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(tabRows(in: sidebar).count, 3, "The other pane is a tab again")

        row = makeSplit("Mail", "News", in: app, sidebar: sidebar)
        choose("Close Tab", on: row, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["splitView"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(tabRows(in: sidebar).count, 2, "One pane closed, the other is a tab again")
    }

    // MARK: Folders

    /// A folder's menu: New Folder Inside…, Rename…, Move to Folder (never into itself or its
    /// subfolders), and Delete Folder; and a tab's Move to Folder into a nested folder and back
    /// out with Pinned (No Folder).
    @MainActor
    func testFolderMenu() throws {
        let (app, sidebar) = launchApp()
        openTab("Docs", in: app, sidebar: sidebar)
        app.typeKey("n", modifierFlags: [.command, .control])
        let nameField = app.textFields["nameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.typeText("Work\n")
        let work = folderRow("Work", in: sidebar)
        XCTAssertTrue(work.waitForExistence(timeout: 10))

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

        // A folder can't move into itself or its subfolders.
        let intoItself = moveToFolderItem("Work", on: work, in: app)
        XCTAssertFalse(intoItself.isEnabled)
        XCTAssertFalse(app.windows.firstMatch.menuItems.matching(NSPredicate(format: "title == 'Work › Drafts'")).firstMatch.isEnabled)
        closeMenus(in: app)

        // A nested folder's title names its parent, for VoiceOver too (menus have no labels).
        moveToFolderItem("Work › Drafts", on: sidebar.staticTexts["Docs"], in: app).click()
        XCTAssertTrue(sidebar.staticTexts["Pinned"].waitForExistence(timeout: 5), "Moving into a folder pins the tab")
        expectation(for: NSPredicate(format: "value == '1 item'"), evaluatedWith: drafts)
        waitForExpectations(timeout: 5)

        moveToFolderItem("Pinned (No Folder)", on: sidebar.staticTexts["Docs"], in: app).click()
        expectation(for: NSPredicate(format: "value == '0 items'"), evaluatedWith: drafts)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(sidebar.staticTexts["Docs"].exists, "It stays pinned, at the top level")

        // A folder's own Move to Folder takes it out of its parent.
        moveToFolderItem("Pinned (No Folder)", on: drafts, in: app).click()
        expectation(for: NSPredicate(format: "value == '0 items'"), evaluatedWith: work)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(drafts.exists)

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

        // Settings › Profiles lists the new Space's own profile, named after it.
        app.typeKey(",", modifierFlags: .command)
        let profiles = app.toolbars.buttons["Profiles"]
        XCTAssertTrue(profiles.waitForExistence(timeout: 5))
        profiles.click()
        let list = app.outlines["profileList"].exists ? app.outlines["profileList"] : app.tables["profileList"]
        XCTAssertTrue(list.staticTexts["Work"].waitForExistence(timeout: 5), "The Space got its own profile")
        XCTAssertTrue(list.staticTexts["Default"].exists)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(profiles.waitForNonExistence(timeout: 5))

        choose("Delete Space…", on: dots.element(boundBy: 1), in: app)
        let confirm = app.sheets.buttons["Delete Space"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: dots)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(sidebar.staticTexts["Personal"].waitForExistence(timeout: 5))
    }
}
