import XCTest

/// Runs Xcode's accessibility audit on each part of Axo's interface.
final class AccessibilityAuditTests: XCTestCase {
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
            func containsSiriOrb(_ s: XCUIElementSnapshot) -> Bool {
                s.identifier == "siri" || s.children.contains(where: containsSiriOrb)
            }
            if containsSiriOrb(snapshot) { return true }
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
                    // The split view's sidebar column, which holds the address field.
                    if children.contains(where: { $0.identifier == "addressField" }) { return true }
                    // A List section header row, which holds only its header text.
                    if children.count == 1, children[0].elementType == .staticText,
                       !children[0].label.isEmpty || !(children[0].value as? String ?? "").isEmpty {
                        return true
                    }
                }
            }
            func describe(_ s: XCUIElementSnapshot, depth: Int) -> String {
                let own = "\(s.elementType.rawValue):\(s.identifier):\(s.label):\((s.value as? String) ?? "")"
                guard depth < 3, !s.children.isEmpty else { return own }
                return own + "[" + s.children.map { describe($0, depth: depth + 1) }.joined(separator: ", ") + "]"
            }
            print("AUDIT [\(screen)] \(issue.compactDescription): \(describe(snapshot, depth: 0)) frame=\(snapshot.frame)")
            return false
        }
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

        app.typeKey("t", modifierFlags: .command)
        app.typeText("data:text/html,<title>Lake</title><p>Still water.</p>\n")
        XCTAssertTrue(sidebar.staticTexts["Lake"].waitForExistence(timeout: 10))
        app.typeKey("=", modifierFlags: [.control, .shift])
        app.typeText("pond")
        let pond = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'commandResult' AND label CONTAINS 'Pond'")).firstMatch
        XCTAssertTrue(pond.waitForExistence(timeout: 5))
        pond.click()
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

        // Peek, from a link in a pinned tab (a closed loopback port, so nothing loads). Peek's
        // header shows the host while loading, and the audit doesn't count a bare IP address
        // as readable, so the link uses "localhost".
        app.typeKey("t", modifierFlags: .command)
        app.typeText("data:text/html,<title>Hub</title><a href='http://localhost:9/far'>Far away</a>\n")
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
        let linkRouting = app.toolbars.buttons["Link Routing"]
        XCTAssertTrue(linkRouting.waitForExistence(timeout: 5))
        linkRouting.click()
        XCTAssertTrue(app.buttons["addDomainRouteButton"].waitForExistence(timeout: 5))
        try audit(app, "settings")

        app.toolbars.buttons["Site Customizations"].click()
        XCTAssertTrue(app.buttons["addSiteCustomizationButton"].waitForExistence(timeout: 5))
        try audit(app, "site customizations")
        app.buttons["addSiteCustomizationButton"].click()
        XCTAssertTrue(app.textFields["customizationDomainField"].waitForExistence(timeout: 5))
        try audit(app, "customization editor")
    }
}
