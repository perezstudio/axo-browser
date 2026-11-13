import XCTest

/// Space themes for the window's background (#137): the editor from a Space's menu, its live
/// preview, Cancel and Done, each Space keeping its theme, and going back to the system's
/// material from Settings. Colors are read from window screenshots, never the desktop.
final class SpaceThemeUITests: XCTestCase {
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

    typealias RGB = (red: Double, green: Double, blue: Double)

    /// Sky, the light preset, as drawn: solid, so exactly its color.
    let sky: RGB = (0xcf / 255.0, 0xe3 / 255.0, 0xf5 / 255.0)

    @MainActor
    func testThemesColorTheSidebarAndEachSpaceKeepsItsOwn() throws {
        let app = AxoUITests.makeApp()
        app.launchEnvironment["AXO_UI_TESTING_APPEARANCE"] = "light"
        app.launch()
        AxoUITests.bringToFront(app)
        let sidebar = app.descendants(matching: .any)["sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        // An empty part of the sidebar: the top right of its list, beside the Space's name and
        // clear of the editor's popover, which rises from the Space dots at the bottom.
        let point = CGPoint(x: sidebar.frame.maxX - 25 - window.frame.minX, y: sidebar.frame.minY + 50 - window.frame.minY)
        let plain = AxoUITests.color(at: point, in: window)
        func sidebarColor() -> RGB { AxoUITests.color(at: point, in: window) }
        func waitForSidebar(_ name: String, _ matches: (RGB) -> Bool) {
            var color = sidebarColor()
            let deadline = Date.now.addingTimeInterval(5)
            while !matches(color), Date.now < deadline {
                RunLoop.current.run(until: .now.addingTimeInterval(0.2))
                color = sidebarColor()
            }
            let shot = XCTAttachment(screenshot: window.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
            XCTAssertTrue(matches(color), "\(name): sidebar pixel \(color), plain \(plain)")
        }
        func luminance(_ color: RGB) -> Double { 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue }

        // The editor, from the Space's menu in the switcher.
        let dot = app.buttons.matching(identifier: "spaceButton").element(boundBy: 0)
        func openEditor() -> XCUIElement {
            dot.rightClick()
            let item = window.menuItems["Edit Theme…"]
            XCTAssertTrue(item.waitForExistence(timeout: 5))
            item.click()
            let editor = app.descendants(matching: .any)["spaceThemeEditor"]
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            return editor
        }
        var editor = openEditor()
        XCTAssertTrue(editor.buttons["themePresetSystem"].isSelected, "Spaces start with the system's material")
        XCTAssertFalse(editor.sliders["themeTransparencySlider"].exists, "System has nothing to adjust")

        // A preset changes the window as soon as it's chosen.
        editor.buttons["themePresetMidnight"].click()
        waitForSidebar("Midnight, previewed") { luminance($0) < 0.3 }
        XCTAssertTrue(editor.staticTexts["Theme for Home"].exists)
        let transparency = editor.sliders["themeTransparencySlider"]
        XCTAssertTrue(transparency.waitForExistence(timeout: 5))
        transparency.adjust(toNormalizedSliderPosition: 1)
        XCTAssertEqual(transparency.value as? String, "100 percent")
        let grain = editor.sliders["themeGrainSlider"]
        grain.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertEqual(grain.value as? String, "50 percent")
        editor.buttons["themeAddColorButton"].click()
        XCTAssertTrue(editor.colorWells["themeColor2"].waitForExistence(timeout: 5), "Up to three colors make a gradient")

        // Cancel puts the old look back.
        editor.buttons["themeCancelButton"].click()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        waitForSidebar("Cancelled") { AxoUITests.isClose($0, to: plain) }

        // Done keeps it.
        editor = openEditor()
        editor.buttons["themePresetSky"].click()
        XCTAssertTrue(editor.buttons["themePresetSky"].isSelected)
        editor.buttons["themeDoneButton"].click()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        waitForSidebar("Sky, saved") { AxoUITests.isClose($0, to: self.sky) }

        // A new Space has the system's material, and each Space keeps its own look.
        app.buttons["newSpaceButton"].click()
        let spaceName = app.textFields["spaceNameField"]
        XCTAssertTrue(spaceName.waitForExistence(timeout: 5))
        spaceName.typeText("Work\n")
        XCTAssertTrue(sidebar.staticTexts["Work"].waitForExistence(timeout: 5))
        waitForSidebar("A new Space") { AxoUITests.isClose($0, to: plain) }
        app.typeKey("1", modifierFlags: .control)
        XCTAssertTrue(sidebar.staticTexts["Home"].waitForExistence(timeout: 5))
        waitForSidebar("Back to Home") { AxoUITests.isClose($0, to: self.sky) }

        // Settings › Spaces edits it too, and System goes back to the material.
        app.typeKey(",", modifierFlags: .command)
        let spaces = app.toolbars.buttons["Spaces"]
        XCTAssertTrue(spaces.waitForExistence(timeout: 5))
        spaces.click()
        let edit = app.buttons["editThemeSettingsButton"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.click()
        editor = app.descendants(matching: .any)["spaceThemeEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(editor.buttons["themePresetSky"].isSelected)
        editor.buttons["themePresetSystem"].click()
        editor.buttons["themeDoneButton"].click()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(spaces.waitForNonExistence(timeout: 5))
        waitForSidebar("System again") { AxoUITests.isClose($0, to: plain) }
    }
}
