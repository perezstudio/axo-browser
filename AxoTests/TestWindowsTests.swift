//
//  TestWindowsTests.swift
//  AxoTests
//

import CoreGraphics
import Foundation
import Testing
@testable import Axo

/// Test runs' browser windows: saved apart from the person's, and placed on the primary display.
@MainActor
struct TestWindowsTests {
    @Test func testRunsHaveTheirOwnWindowID() {
        #expect(TestWindows.browserWindowID(isTestRun: false) == "browser")
        #expect(TestWindows.browserWindowID(isTestRun: true) == "browser-testing")
        #expect(AppEnvironment.isTestRun, "These tests host in Axo")
        #expect(AppEnvironment.browserWindowID == "browser-testing", "Hosting these tests never saves the person's frame")
    }

    @Test func uiTestingAndHostedUnitTestsAreTestRuns() {
        #expect(!TestWindows.isTestRun(isUITesting: false, environment: [:]))
        #expect(TestWindows.isTestRun(isUITesting: true, environment: [:]))
        #expect(TestWindows.isTestRun(isUITesting: false, environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
    }

    @Test func forgettingFramesRemovesOnlyTestWindowKeys() throws {
        let name = "com.perezstudio.AxoTests.TestWindows-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let personsKeys = [
            "NSWindow Frame browser-AppWindow-1",
            "NSSplitView Subview Frames browser-AppWindow-1, SidebarNavigationSplitView",
            "NSWindow Frame com_apple_SwiftUI_Settings_window",
            "lastSpaceID",
        ]
        let testKeys = [
            "NSWindow Frame browser-testing-AppWindow-1",
            "NSWindow Frame browser-testing-AppWindow-2",
            "NSSplitView Subview Frames browser-testing-AppWindow-1, SidebarNavigationSplitView",
        ]
        for key in personsKeys + testKeys {
            defaults.set("0 0 1200 800 0 0 1512 949 ", forKey: key)
        }

        #expect(Set(TestWindows.savedFrameKeys(in: defaults)) == Set(testKeys))
        TestWindows.forgetSavedFrames(in: defaults)

        for key in testKeys {
            #expect(defaults.object(forKey: key) == nil, "\(key) should be forgotten")
        }
        for key in personsKeys {
            #expect(defaults.string(forKey: key) != nil, "\(key) is the person's and stays")
        }
    }

    @Test func windowsAreCenteredOnTheGivenScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 916)
        #expect(TestWindows.frame(for: CGSize(width: 1200, height: 800), in: screen)
            == CGRect(x: 156, y: 58, width: 1200, height: 800))
    }

    @Test func windowsShrinkToFitTheScreen() {
        // A display above and to the left of the primary one, as macOS arranges them.
        let screen = CGRect(x: -2560, y: 949, width: 1000, height: 600)
        let frame = TestWindows.frame(for: CGSize(width: 1513, height: 949), in: screen)
        #expect(frame == CGRect(x: -2560, y: 949, width: 1000, height: 600))
        #expect(screen.contains(frame))
    }
}
