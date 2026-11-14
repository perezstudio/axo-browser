import XCTest

/// Runs Xcode's accessibility audit on each part of Axo's interface.
final class AccessibilityAuditTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        AxoUITests.connectRunnerToWindowServer()
    }

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    override func tearDown() async throws {
        await MainActor.run { XCUIApplication().terminate() }
        try await super.tearDown()
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AXO_UI_TESTING"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchArguments += ["-__WebInspectorPageGroupLevel1__.WebKit2InspectorStartsAttached", "YES"]
        // For the mini window screen (a closed loopback port, so nothing loads).
        app.launchEnvironment["AXO_UI_TESTING_EXTERNAL_URL"] = "http://localhost:9/from-another-app"
        app.launch()
        AxoUITests.bringToFront(app)
        return app
    }

    /// Audits the app now and fails on every issue except ones macOS itself creates.
    ///
    /// Contrast isn't audited: the sidebar's translucent material, system views like
    /// `ContentUnavailableView`, and web pages' own text all give unreliable readings, and Axo
    /// uses system colors throughout.
    @MainActor
    private func audit(_ app: XCUIApplication, _ screen: String) throws {
        let containerFrames = (app.windows.allElementsBoundByIndex + app.sheets.allElementsBoundByIndex
            + app.popovers.allElementsBoundByIndex).map(\.frame)
        let sliderFrames = app.sliders.allElementsBoundByIndex.filter { !$0.label.isEmpty }.map(\.frame)
        try app.performAccessibilityAudit(for: .all.subtracting(.contrast)) { issue in
            guard let element = issue.element else {
                // Reported with no element while a text field's system field editor has focus.
                return true
            }
            // Read everything from one snapshot: querying an element that disappeared mid-audit
            // (a loading bar, say) would fail the test, while a snapshot just throws.
            guard let snapshot = try? element.snapshot() else { return true }
            // The Touch Bar, the text input menu ("emoji & symbols"), and the Siri and Dictation
            // orb belong to macOS.
            if snapshot.elementType == .touchBar || snapshot.label == "emoji & symbols" { return true }
            @MainActor func containsSiriOrb(_ s: XCUIElementSnapshot) -> Bool {
                s.identifier == "siri" || s.children.contains(where: containsSiriOrb)
            }
            if containsSiriOrb(snapshot) { return true }
            // A tooltip window (help tag), shown wherever the pointer happens to rest, sometimes
            // with no text while it appears. The text belongs to the control's `.help`, which
            // VoiceOver reads on the control itself, and the audit checks those controls.
            if snapshot.elementType == .helpTag { return true }
            // A slider's thumb: AppKit's NSSlider exposes it as a value indicator child with no
            // description of its own. VoiceOver reads the slider, which has a label and value,
            // so only thumbs inside a labeled slider are let through.
            if snapshot.elementType == .valueIndicator,
               sliderFrames.contains(where: { $0.contains(snapshot.frame) }) { return true }
            // Containers SwiftUI creates and gives no way to label. VoiceOver moves straight into
            // unlabeled groups, so they don't get in the way.
            if snapshot.identifier.isEmpty, snapshot.label.isEmpty {
                // NSPopover itself, and hosting groups that fill a window, sheet, or popover.
                if snapshot.elementType == .popover { return true }
                if snapshot.elementType == .group,
                   containerFrames.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(snapshot.frame) && $0.width - snapshot.frame.width < 2 }) {
                    return true
                }
                if snapshot.elementType == .group {
                    let children = snapshot.children
                    // HSplitView's and VSplitView's host for one pane of a split view.
                    if children.count == 1, children[0].identifier == "splitPane" { return true }
                    // The split view's sidebar column, which holds the address bar, or Settings'
                    // list of panes.
                    if children.contains(where: { ["sidebarAddressBar", "sidebarAddressField", "addressField", "settingsPaneList"].contains($0.identifier) }) { return true }
                    // A List section header row, which holds only its header text.
                    if children.count == 1, children[0].elementType == .staticText,
                       !children[0].label.isEmpty || !(children[0].value as? String ?? "").isEmpty {
                        return true
                    }
                }
            }
            @MainActor func describe(_ s: XCUIElementSnapshot, depth: Int) -> String {
                let own = "\(s.elementType.rawValue):\(s.identifier):\(s.label):\((s.value as? String) ?? "")"
                guard depth < 3, !s.children.isEmpty else { return own }
                return own + "[" + s.children.map { describe($0, depth: depth + 1) }.joined(separator: ", ") + "]"
            }
            print("AUDIT [\(screen)] \(issue.compactDescription): \(describe(snapshot, depth: 0)) frame=\(snapshot.frame)")
            return false
        }
    }

    /// The address edited in the sidebar (Settings › General › Edit the address in › Sidebar),
    /// with its suggestions below it.
    @MainActor
    func testAuditAddressEditedInTheSidebar() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        AxoUITests.openPage("data:text/html,<title>Pond</title>", in: app)
        XCTAssertTrue(sidebar.staticTexts["Pond"].waitForExistence(timeout: 10))

        app.typeKey(",", modifierFlags: .command)
        AxoUITests.selectSettingsPane("general", in: app)
        let inSidebar = app.radioButtons["Sidebar"]
        XCTAssertTrue(inSidebar.waitForExistence(timeout: 5))
        inSidebar.click()
        app.typeKey("w", modifierFlags: .command)

        app.typeKey("l", modifierFlags: .command)
        XCTAssertTrue(app.textFields["sidebarAddressField"].waitForExistence(timeout: 5))
        app.typeText("pond")
        XCTAssertTrue(app.descendants(matching: .any)["addressSuggestions"].waitForExistence(timeout: 5))
        try audit(app, "address edited in the sidebar")
        app.typeKey(.escape, modifierFlags: [])

        // A notice with Undo, after closing the tab (#103).
        XCTAssertTrue(app.textFields["sidebarAddressField"].waitForNonExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.buttons["noticeUndoButton"].waitForExistence(timeout: 5))
        try audit(app, "notice")
    }

    /// First run's steps (#175): the welcome and setting up the first Space (nothing to import
    /// in UI testing mode's empty folder).
    @MainActor
    func testAuditFirstRun() throws {
        let app = XCUIApplication()
        app.launchEnvironment["AXO_UI_TESTING"] = "1"
        app.launchEnvironment["AXO_UI_TESTING_FIRST_RUN"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        AxoUITests.bringToFront(app)
        let getStarted = app.buttons["firstRunGetStarted"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 10))
        try audit(app, "first run's welcome")
        getStarted.click()
        XCTAssertTrue(app.buttons["firstRunCreateSpace"].waitForExistence(timeout: 5))
        try audit(app, "first run's Space setup")
    }

    @MainActor
    func testAuditEveryScreen() throws {
        let app = launchApp()
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        try audit(app, "empty window")

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.textFields["commandField"].waitForExistence(timeout: 5))
        try audit(app, "command bar")
        app.typeText("data:text/html,<title>Pond</title><p>Axolotls live in lakes.</p>\n")
        XCTAssertTrue(sidebar.staticTexts["Pond"].waitForExistence(timeout: 10))
        try audit(app, "page")

        app.buttons["summarizeButton"].click()
        XCTAssertTrue(app.staticTexts["summaryText"].waitForExistence(timeout: 10))
        try audit(app, "page summary")
        app.typeKey(.escape, modifierFlags: [])

        AxoUITests.openPage("data:text/html,<title>Lake</title><p>Still water.</p>", in: app)
        XCTAssertTrue(sidebar.staticTexts["Lake"].waitForExistence(timeout: 10))
        app.typeKey("=", modifierFlags: [.control, .shift])
        app.typeText("pond")
        let pond = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'commandResult' AND label CONTAINS 'Pond'")).firstMatch
        XCTAssertTrue(pond.waitForExistence(timeout: 5))
        // The first row searches for "pond"; the Pond tab is next. (Return is steadier than
        // clicking a row that may still be moving into place.)
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.descendants(matching: .any)["splitView"].waitForExistence(timeout: 10))
        try audit(app, "split view")

        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(app.textFields["findField"].waitForExistence(timeout: 5))
        app.typeText("ocean")
        _ = app.staticTexts["findNoMatches"].waitForExistence(timeout: 5)
        try audit(app, "find bar")
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("a", modifierFlags: [.command, .shift])
        sleep(1)
        try audit(app, "archived tabs")
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("e", modifierFlags: [.command, .shift])
        sleep(1)
        try audit(app, "extensions")
        app.typeKey(.escape, modifierFlags: [])

        app.buttons["newSpaceButton"].click()
        _ = app.textFields["spaceNameField"].waitForExistence(timeout: 5)
        try audit(app, "new space")
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("n", modifierFlags: [.command, .control])
        _ = app.textFields["nameField"].waitForExistence(timeout: 5)
        try audit(app, "new folder")
        app.typeKey(.escape, modifierFlags: [])

        app.menuBars.menuItems["Import from Another Browser…"].click()
        sleep(1)
        try audit(app, "import")
        app.typeKey(.escape, modifierFlags: [])

        app.typeKey("l", modifierFlags: [.command, .option])
        sleep(1)
        try audit(app, "downloads")
        app.typeKey(.escape, modifierFlags: [])

        // A favorite in the grid above the pinned tabs.
        AxoUITests.openPage("data:text/html,<title>Starred</title><p>Kept close.</p>", in: app)
        XCTAssertTrue(sidebar.staticTexts["Starred"].waitForExistence(timeout: 10))
        sidebar.staticTexts["Starred"].rightClick()
        app.windows.firstMatch.menuItems["Add to Favorites"].click()
        XCTAssertTrue(app.buttons["favoriteTile"].waitForExistence(timeout: 5))
        try audit(app, "favorites")

        // Peek, from a link in a pinned tab (a closed loopback port, so nothing loads). Peek's
        // header shows the host while loading, and the audit doesn't count a bare IP address
        // as readable, so the link uses "localhost".
        AxoUITests.openPage("data:text/html,<title>Hub</title><a href='http://localhost:9/far'>Far away</a>", in: app)
        XCTAssertTrue(sidebar.staticTexts["Hub"].waitForExistence(timeout: 10))
        app.typeKey("p", modifierFlags: [.command, .control])
        let link = app.webViews.firstMatch.links["Far away"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.click()
        XCTAssertTrue(app.descendants(matching: .any)["peek"].waitForExistence(timeout: 5))
        try audit(app, "peek")
        app.typeKey(.escape, modifierFlags: [])

        // A mini window, for a link from another app (a closed loopback port, as above).
        AxoUITests.sendExternalLink(in: app)
        XCTAssertTrue(app.buttons["miniOpenInAxoButton"].waitForExistence(timeout: 10))
        try audit(app, "mini window")

        app.menuBars.menuItems["Settings…"].click()
        // Settings reopens on the last pane used, so choose one.
        AxoUITests.selectSettingsPane("linkRouting", in: app)
        XCTAssertTrue(app.buttons["addDomainRouteButton"].waitForExistence(timeout: 5))
        try audit(app, "settings")

        AxoUITests.selectSettingsPane("general", in: app)
        XCTAssertTrue(app.radioButtons["Above the page"].waitForExistence(timeout: 5))
        try audit(app, "general settings")

        AxoUITests.selectSettingsPane("profiles", in: app)
        XCTAssertTrue(app.textFields["profileNameField"].waitForExistence(timeout: 5))
        try audit(app, "profiles")

        AxoUITests.selectSettingsPane("spaces", in: app)
        XCTAssertTrue(app.textFields["spaceNameSettingsField"].waitForExistence(timeout: 5))
        try audit(app, "spaces")

        // The Space theme editor, with a theme chosen so all its controls show (#137).
        app.buttons["editThemeSettingsButton"].click()
        let themeEditor = app.descendants(matching: .any)["spaceThemeEditor"]
        XCTAssertTrue(themeEditor.waitForExistence(timeout: 5))
        themeEditor.buttons["themePresetOcean"].click()
        XCTAssertTrue(themeEditor.sliders["themeGrainSlider"].waitForExistence(timeout: 5))
        try audit(app, "space theme")
        themeEditor.buttons["themeCancelButton"].click()
        XCTAssertTrue(themeEditor.waitForNonExistence(timeout: 5))

        AxoUITests.selectSettingsPane("siteCustomizations", in: app)
        XCTAssertTrue(app.buttons["addSiteCustomizationButton"].waitForExistence(timeout: 5))
        try audit(app, "site customizations")

        AxoUITests.selectSettingsPane("iCloud", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["syncToggle"].waitForExistence(timeout: 5))
        try audit(app, "iCloud")
        AxoUITests.selectSettingsPane("siteCustomizations", in: app)
        XCTAssertTrue(app.buttons["addSiteCustomizationButton"].waitForExistence(timeout: 5))
        app.buttons["addSiteCustomizationButton"].click()
        XCTAssertTrue(app.textFields["customizationDomainField"].waitForExistence(timeout: 5))
        try audit(app, "customization editor")
    }
}
