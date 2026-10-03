import XCTest

/// Runs Xcode's accessibility audit on each part of Axo's interface.
final class AccessibilityAuditTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AXO_UI_TESTING"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
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
            // The Touch Bar and the text input menu ("emoji & symbols") belong to macOS.
            if element.elementType == .touchBar || element.label == "emoji & symbols" { return true }
            // Containers SwiftUI creates and gives no way to label. VoiceOver moves straight into
            // unlabeled groups, so they don't get in the way.
            if element.identifier.isEmpty, element.label.isEmpty {
                // NSPopover itself, and hosting groups that fill a window, sheet, or popover.
                if element.elementType == .popover { return true }
                if element.elementType == .group,
                   containerFrames.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(element.frame) && $0.width - element.frame.width < 2 }) {
                    return true
                }
                if element.elementType == .group {
                    let children = element.children(matching: .any).allElementsBoundByIndex
                    // The split view's sidebar column, which holds the address field.
                    if children.contains(where: { $0.identifier == "addressField" }) { return true }
                    // A List section header row, which holds only its header text.
                    if children.count == 1, children[0].elementType == .staticText,
                       !children[0].label.isEmpty || !(children[0].value as? String ?? "").isEmpty {
                        return true
                    }
                }
            }
            print("AUDIT [\(screen)] \(issue.compactDescription): \(element.elementType.rawValue) id=\(element.identifier) label=\(element.label) frame=\(element.frame)")
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
    }
}
