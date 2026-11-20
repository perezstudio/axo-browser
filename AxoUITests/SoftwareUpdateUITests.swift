import AppKit
import XCTest

/// Software Update (#180) with the test runs' stand-in updater, which never checks for updates:
/// Settings › General's section and Check Now, the update window's flow from the Axo menu, and the
/// notice and Restart to Update Axo for an update that downloaded in the background.
final class SoftwareUpdateUITests: XCTestCase {
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
    private func launchApp(offeringUpdate: Bool = false) -> XCUIApplication {
        let app = AxoUITests.makeApp()
        if offeringUpdate { app.launchEnvironment["AXO_UI_TESTING_UPDATE"] = "available" }
        app.launch()
        AxoUITests.bringToFront(app)
        XCTAssertTrue(app.descendants(matching: .any)["sidebar"].waitForExistence(timeout: 5))
        return app
    }

    /// Settings › General › Check Now ends with "You're up to date!", and OK closes it.
    @MainActor
    func testCheckNowFromSettingsSaysUpToDate() throws {
        let app = launchApp()
        app.typeKey(",", modifierFlags: .command)
        AxoUITests.selectSettingsPane("general", in: app)
        let checkNow = app.buttons["checkForUpdatesButton"]
        XCTAssertTrue(checkNow.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["automaticallyChecksToggle"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["includesBetasToggle"].exists)
        XCTAssertTrue(app.staticTexts["Not checked yet"].exists)
        checkNow.click()

        let update = app.descendants(matching: .any)["softwareUpdate"]
        XCTAssertTrue(update.staticTexts["You’re up to date!"].waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.windows["Software Update"].screenshot())
        shot.name = "Up to date"
        shot.lifetime = .keepAlways
        add(shot)
        update.buttons["updateOKButton"].click()
        XCTAssertTrue(update.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["lastUpdateCheck"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Not checked yet"].exists, "Settings says when it last checked")
    }

    /// Axo › Check for Updates… offers the stand-in's update; Install Update downloads it, and
    /// Install and Relaunch ends the session (the stand-in installs nothing).
    @MainActor
    func testInstallingAnUpdateWalksItsWindows() throws {
        let app = launchApp(offeringUpdate: true)
        app.menuBars.menuBarItems["Axo"].click()
        app.menuBars.menuItems["Check for Updates…"].click()

        let update = app.descendants(matching: .any)["softwareUpdate"]
        XCTAssertTrue(update.staticTexts["A new version of Axo is available!"].waitForExistence(timeout: 10))
        XCTAssertTrue(update.buttons["skipVersionButton"].exists)
        XCTAssertTrue(update.buttons["remindLaterButton"].exists)
        XCTAssertTrue(update.descendants(matching: .any)["releaseNotes"].staticTexts.firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.windows["Software Update"].screenshot())
        shot.name = "Update available"
        shot.lifetime = .keepAlways
        add(shot)

        update.buttons["installUpdateButton"].click()
        let relaunch = update.buttons["installAndRelaunchButton"]
        XCTAssertTrue(relaunch.waitForExistence(timeout: 10), "Downloaded, unpacked, and ready")
        XCTAssertTrue(update.staticTexts["Ready to Install"].exists)
        relaunch.click()
        XCTAssertTrue(update.waitForNonExistence(timeout: 5))
    }

    /// Remind Me Later closes the window without installing.
    @MainActor
    func testRemindMeLaterCloses() throws {
        let app = launchApp(offeringUpdate: true)
        app.menuBars.menuBarItems["Axo"].click()
        app.menuBars.menuItems["Check for Updates…"].click()
        let update = app.descendants(matching: .any)["softwareUpdate"]
        XCTAssertTrue(update.buttons["remindLaterButton"].waitForExistence(timeout: 10))
        update.buttons["remindLaterButton"].click()
        XCTAssertTrue(update.waitForNonExistence(timeout: 5))
        app.menuBars.menuBarItems["Axo"].click()
        XCTAssertFalse(app.menuBars.menuItems["Restart to Update Axo"].exists, "Nothing downloaded")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// An update that downloaded in the background says so with a notice whose Restart Now
    /// installs it, and the Axo menu offers Restart to Update Axo until it installs.
    @MainActor
    func testAnUpdateReadyOnQuitShowsANoticeAndAMenuItem() throws {
        let app = launchApp()
        app.menuBars.menuBarItems["Testing"].click()
        app.menuBars.menuItems["Download an Update in the Background"].click()

        let notice = app.descendants(matching: .any)["notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertEqual(notice.label, "Axo 99.0 is ready. It installs the next time Axo quits.")
        XCTAssertEqual(app.buttons["noticeUndoButton"].label, "Restart Now")

        app.menuBars.menuBarItems["Axo"].click()
        let restart = app.menuBars.menuItems["Restart to Update Axo"]
        XCTAssertTrue(restart.waitForExistence(timeout: 5))
        restart.click()
        // The stand-in installs nothing, and Sparkle lets Axo ask again if a page kept it from
        // quitting, so the item stays until the update installs.
        app.menuBars.menuBarItems["Axo"].click()
        XCTAssertTrue(app.menuBars.menuItems["Restart to Update Axo"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
    }
}
