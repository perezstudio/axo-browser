import AppKit
import XCTest

/// Screenshots of each built screen, in light and dark, for comparing with the design canvas's
/// boards (the visual audit). They capture only Axo's window. Nothing here checks pixels: run it
/// on demand (`scripts/run-ui-tests-remotely.sh AxoUITests/VisualAuditUITests`) and read the
/// screenshots in the result bundle. It skips unless `TEST_RUNNER_AXO_VISUAL_AUDIT=1`, so the
/// usual runs stay as long as they are.
final class VisualAuditUITests: XCTestCase {
    override class func setUp() {
        super.setUp()
        AxoUITests.connectRunnerToWindowServer()
    }

    override func setUpWithError() throws {
        continueAfterFailure = true
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AXO_VISUAL_AUDIT"] == "1",
                          "The visual audit runs only on demand")
    }

    override func tearDown() async throws {
        await MainActor.run { XCUIApplication().terminate() }
        try await super.tearDown()
    }

    private static let appearances = ["light", "dark"]

    @MainActor
    private func launch(_ appearance: String, firstRun: Bool = false) -> XCUIApplication {
        let app = AxoUITests.makeApp()
        app.launchEnvironment["AXO_UI_TESTING_APPEARANCE"] = appearance
        if firstRun { app.launchEnvironment["AXO_UI_TESTING_FIRST_RUN"] = "1" }
        app.launch()
        AxoUITests.bringToFront(app)
        return app
    }

    /// Attaches a screenshot of Axo's front window, kept whether the test passes or not.
    @MainActor
    private func shoot(_ app: XCUIApplication, _ appearance: String, _ name: String) {
        usleep(600_000) // Let animations settle.
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "\(name) (\(appearance))"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func open(_ titles: [String], in app: XCUIApplication, sidebar: XCUIElement) {
        for title in titles {
            AxoUITests.openPage("data:text/html,<title>\(title)</title><h1>\(title)</h1>", in: app)
            _ = sidebar.staticTexts[title].waitForExistence(timeout: 10)
        }
    }

    /// The 1.0 window with the sidebar: Favorites, the Space's name, Pinned with a folder,
    /// today's tabs; the hover card; the sidebar hidden, and floating in.
    @MainActor
    func testWindowAndSidebar() throws {
        for appearance in Self.appearances {
            let app = launch(appearance)
            let sidebar = app.descendants(matching: .any)["sidebar"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
            open(["Lisbon trip", "Design notes", "Swift Docs", "Recipes", "Weekly sync"], in: app, sidebar: sidebar)
            // A favorite, a pinned tab, and a folder.
            sidebar.staticTexts["Lisbon trip"].rightClick()
            app.windows.firstMatch.menuItems["Add to Favorites"].click()
            sidebar.staticTexts["Swift Docs"].click()
            app.typeKey("p", modifierFlags: [.command, .control])
            sidebar.staticTexts["Recipes"].click()
            app.typeKey("p", modifierFlags: [.command, .control])
            app.menuBars.menuBarItems["Tabs"].click()
            app.menuBars.menuItems["Move to Folder"].hover()
            app.menuBars.menuItems["New Folder…"].click()
            let name = app.textFields["nameField"]
            if name.waitForExistence(timeout: 5) { name.typeText("Work\n") }
            // The sheet hides the sidebar from the accessibility tree until it has gone.
            _ = sidebar.staticTexts["Work"].waitForExistence(timeout: 5)
            let weeklySync = sidebar.staticTexts["Weekly sync"]
            if weeklySync.waitForExistence(timeout: 5) { weeklySync.click() }
            shoot(app, appearance, "Window, sidebar")

            sidebar.staticTexts["Design notes"].hover()
            _ = app.descendants(matching: .any)["tabPreviewCard"].waitForExistence(timeout: 5)
            shoot(app, appearance, "Hover card")

            if app.buttons["hideSidebarButton"].waitForExistence(timeout: 5) { app.buttons["hideSidebarButton"].click() }
            app.descendants(matching: .any)["webContent"].hover()
            shoot(app, appearance, "Sidebar hidden")
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 2, dy: 0)).hover()
            _ = app.descendants(matching: .any)["floatingSidebar"].waitForExistence(timeout: 5)
            shoot(app, appearance, "Floating sidebar")
            app.terminate()
        }
    }

    /// The navigation bar above the page (the control bar), and tabs at the top with its
    /// floating tab bar.
    @MainActor
    func testControlBarAndTabsOnTop() throws {
        for appearance in Self.appearances {
            let app = launch(appearance)
            let sidebar = app.descendants(matching: .any)["sidebar"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
            open(["Design notes", "Swift Docs", "Weekly sync"], in: app, sidebar: sidebar)

            app.typeKey(",", modifierFlags: .command)
            AxoUITests.selectSettingsPane("general", in: app)
            shoot(app, appearance, "Settings, General")
            app.radioButtons["Above the page"].click()
            app.typeKey("w", modifierFlags: .command)
            _ = app.descendants(matching: .any)["controlBar"].waitForExistence(timeout: 5)
            shoot(app, appearance, "Navigation bar above the page")

            app.typeKey(",", modifierFlags: .command)
            AxoUITests.selectSettingsPane("general", in: app)
            app.radioButtons["At the top"].click()
            app.typeKey("w", modifierFlags: .command)
            _ = app.descendants(matching: .any)["tabBar"].waitForExistence(timeout: 5)
            shoot(app, appearance, "Tabs on top")
            if app.buttons["tabBarToggleButton"].waitForExistence(timeout: 5) { app.buttons["tabBarToggleButton"].click() }
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 3)).hover()
            _ = app.descendants(matching: .any)["floatingTabBar"].waitForExistence(timeout: 5)
            shoot(app, appearance, "Floating tab bar")
            app.terminate()
        }
    }

    /// Tab row states and pages in the page's place: a playing tab's speaker, a stopped page,
    /// Can't Connect, and the command bar.
    @MainActor
    func testRowStatesAndPages() throws {
        for appearance in Self.appearances {
            let app = launch(appearance)
            let sidebar = app.descendants(matching: .any)["sidebar"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
            open(["Design notes"], in: app, sidebar: sidebar)
            AxoUITests.openPage("data:text/html,<title>Lo-fi playlist</title><body style='height:100vh'><script>addEventListener('click', () => { const c = new AudioContext(); const o = c.createOscillator(); const g = c.createGain(); g.gain.value = 0.001; o.connect(g).connect(c.destination); o.start() })</script>", in: app)
            _ = sidebar.staticTexts["Lo-fi playlist"].waitForExistence(timeout: 10)
            app.webViews.firstMatch.click()
            _ = sidebar.buttons["tabMuteButton"].waitForExistence(timeout: 10)
            shoot(app, appearance, "Tab row, playing audio")

            open(["Accounts"], in: app, sidebar: sidebar)
            app.menuBars.menuBarItems["Testing"].click()
            app.menuBars.menuItems["End the Page’s Process"].click()
            _ = app.descendants(matching: .any)["pageProblem"].waitForExistence(timeout: 10)
            shoot(app, appearance, "Page stopped")

            AxoUITests.openPage("http://127.0.0.1:\(9)/", in: app)
            _ = app.descendants(matching: .any)["pageLoadError"].waitForExistence(timeout: 15)
            shoot(app, appearance, "Can't Connect")

            app.typeKey("t", modifierFlags: .command)
            if app.textFields["commandField"].waitForExistence(timeout: 5) { app.textFields["commandField"].typeText("des") }
            shoot(app, appearance, "Command bar")
            app.terminate()
        }
    }

    /// First run's welcome and Space setup.
    @MainActor
    func testFirstRun() throws {
        for appearance in Self.appearances {
            let app = launch(appearance, firstRun: true)
            let start = app.buttons["firstRunGetStarted"]
            XCTAssertTrue(start.waitForExistence(timeout: 10))
            shoot(app, appearance, "First run, welcome")
            start.click()
            _ = app.buttons["firstRunCreateSpace"].waitForExistence(timeout: 5)
            shoot(app, appearance, "First run, Space")
            app.terminate()
        }
    }
}
