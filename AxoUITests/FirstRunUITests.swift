import XCTest

/// First run (#175), which UI tests see only when they ask for it (`AXO_UI_TESTING_FIRST_RUN`).
final class FirstRunUITests: XCTestCase {
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
    private func launchApp(importRoot: URL? = nil) -> XCUIApplication {
        let app = AxoUITests.makeApp()
        app.launchEnvironment["AXO_UI_TESTING_FIRST_RUN"] = "1"
        if let importRoot { app.launchEnvironment["AXO_UI_TESTING_IMPORT_ROOT"] = importRoot.path }
        app.launch()
        AxoUITests.bringToFront(app)
        return app
    }

    /// Nothing to import: the welcome leads straight to setting up the first Space, whose name,
    /// icon, and color it takes.
    @MainActor
    func testFirstRunSetsUpTheFirstSpace() throws {
        let app = launchApp()
        XCTAssertTrue(app.staticTexts["Welcome to Axo"].waitForExistence(timeout: 10))
        app.buttons["firstRunGetStarted"].click()

        let name = app.textFields["firstRunSpaceName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "Nothing to import: straight to the Space")
        XCTAssertFalse(app.descendants(matching: .any)["firstRunImportStep"].exists)
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Personal")
        app.buttons["Leaf"].click()
        app.buttons["firstRunColorSage"].click()
        app.buttons["firstRunCreateSpace"].click()

        XCTAssertTrue(app.descendants(matching: .any)["firstRun"].waitForNonExistence(timeout: 5), "First run is done")
        let dot = app.buttons.matching(identifier: "spaceButton").element(boundBy: 0)
        XCTAssertTrue(dot.waitForExistence(timeout: 5))
        let renamed = NSPredicate(format: "label == 'Personal'")
        XCTAssertTrue(app.buttons.matching(identifier: "spaceButton").matching(renamed).firstMatch.waitForExistence(timeout: 5),
                      "The Space takes the name")
    }

    /// Arc found: first run offers to import it, and after importing, Continue finishes without
    /// setting up a Space (the imported ones are there).
    @MainActor
    func testFirstRunImportsFromArc() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "AxoUITestFirstRun-\(UUID().uuidString)")
        let arc = root.appending(path: "Arc")
        try FileManager.default.createDirectory(at: arc, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Pages point at a closed loopback port, so nothing leaves the machine even if one loads.
        try """
        {"sidebar": {"containers": [{"global": {}}, {
          "topAppsContainerIDs": [{"default": true}, "top"],
          "spaces": ["s", {"id": "s", "title": "Reading", "profile": {"default": true}, "containerIDs": ["pinned", "p", "unpinned", "u"]}],
          "items": [
            "top", {"id": "top", "childrenIds": [], "data": {"itemContainer": {}}},
            "p", {"id": "p", "childrenIds": ["lib"], "data": {"itemContainer": {}}},
            "lib", {"id": "lib", "childrenIds": [], "data": {"tab": {"savedURL": "http://127.0.0.1:9/library", "savedTitle": "Library"}}},
            "u", {"id": "u", "childrenIds": [], "data": {"itemContainer": {}}}
          ]}]}}
        """.write(to: arc.appending(path: "StorableSidebar.json"), atomically: true, encoding: .utf8)

        let app = launchApp(importRoot: root)
        XCTAssertTrue(app.buttons["firstRunGetStarted"].waitForExistence(timeout: 10))
        app.buttons["firstRunGetStarted"].click()
        XCTAssertTrue(app.staticTexts["firstRunImportCounts"].waitForExistence(timeout: 10), "Arc is read")
        XCTAssertTrue(app.buttons["firstRunStartFresh"].exists)
        app.buttons["firstRunImport"].click()
        XCTAssertTrue(app.staticTexts["firstRunImportResult"].waitForExistence(timeout: 10))
        app.buttons["firstRunContinue"].click()

        XCTAssertTrue(app.descendants(matching: .any)["firstRun"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "spaceButton").count, 2, "Arc's Space is added")
    }
}
