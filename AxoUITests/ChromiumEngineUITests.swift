//
//  ChromiumEngineUITests.swift
//  AxoUITests
//

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
