import Testing
#if os(macOS)
import AppKit
#endif
@testable import AxoUI

/// The Settings window's panes and the sidebar's search (#85).
struct SettingsPaneTests {
    @Test func panesAreInTheBoardsOrder() {
        #expect(SettingsPane.allCases.map(\.title) == ["General", "Profiles", "Spaces", "Search", "Link Routing", "Site Customizations", "iCloud"])
    }

    @Test func rawValuesStayStableForTheRememberedPane() {
        // Settings remembers the last pane by raw value; renaming one would forget it.
        #expect(SettingsPane.allCases.map(\.rawValue) == ["general", "profiles", "spaces", "search", "linkRouting", "siteCustomizations", "iCloud"])
        #expect(SettingsPane.linkRouting.rowIdentifier == "settingsPane.linkRouting")
    }

    @Test func everyPaneHasASymbolAndKeywords() {
        for pane in SettingsPane.allCases {
            #expect(!pane.systemImage.isEmpty)
            #expect(!pane.keywords.isEmpty, "\(pane) can be found by its settings")
        }
    }

    @Test func anEmptyQueryShowsEveryPane() {
        #expect(SettingsPane.filtered(SettingsPane.allCases, by: "") == SettingsPane.allCases)
        #expect(SettingsPane.filtered(SettingsPane.allCases, by: "   ") == SettingsPane.allCases)
    }

    @Test func searchFindsAPaneByItsSettings() {
        #expect(SettingsPane.filtered(SettingsPane.allCases, by: "navigation bar") == [.general])
        #expect(SettingsPane.filtered(SettingsPane.allCases, by: "cookies") == [.profiles])
        #expect(SettingsPane.filtered(SettingsPane.allCases, by: "CSS") == [.siteCustomizations])
        #expect(SettingsPane.filtered(SettingsPane.allCases, by: "sync") == [.iCloud])
        #expect(SettingsPane.filtered(SettingsPane.allCases, by: "pinned tabs") == [.iCloud], "The iCloud switch's words")
    }

    @Test func searchMatchesTitlesIgnoringCaseAndAccents() {
        #expect(SettingsPane.filtered(SettingsPane.allCases, by: "link rout") == [.linkRouting])
        #expect(SettingsPane.filtered(SettingsPane.allCases, by: "PRÓFILES") == [.profiles])
    }

    @Test func everyWordMustMatch() {
        #expect(SettingsPane.filtered(SettingsPane.allCases, by: "theme icon") == [.spaces])
        #expect(SettingsPane.filtered(SettingsPane.allCases, by: "sync cookies").isEmpty)
        #expect(SettingsPane.filtered(SettingsPane.allCases, by: "zebra").isEmpty)
    }

    @Test func filteringKeepsTheOfferedPanesOrder() {
        let withoutICloud = SettingsPane.allCases.filter { $0 != .iCloud }
        #expect(SettingsPane.filtered(withoutICloud, by: "sync").isEmpty, "No iCloud pane, no match")
        #expect(SettingsPane.filtered(withoutICloud, by: "profile") == [.profiles, .spaces])
    }
}

#if os(macOS)
import CoreGraphics

/// The Settings window is fitted on its screen when shown (#85): it opened 2168 pt tall on the
/// hosted Mac's 768 pt screen.
struct WindowScreenFitTests {
    let visible = CGRect(x: 0, y: 0, width: 1024, height: 740)
    let size = CGSize(width: 780, height: 560)
    // A title bar's worth taller than the content, as AppKit's frameRect(forContentRect:) adds.
    func contentFrame(_ size: CGSize) -> CGRect { CGRect(origin: .zero, size: CGSize(width: size.width, height: size.height + 28)) }

    @Test func aWindowThatFitsIsLeftAlone() {
        let window = CGRect(x: 100, y: 100, width: 780, height: 588)
        #expect(WindowScreenFit.fittedFrame(for: window, contentFrame: contentFrame, size: size, in: visible) == nil)
    }

    @Test func aWindowTallerThanTheScreenTakesTheDefaultSizeCentered() throws {
        let window = CGRect(x: 122, y: -698, width: 780, height: 2168)
        let frame = try #require(WindowScreenFit.fittedFrame(for: window, contentFrame: contentFrame, size: size, in: visible))
        #expect(frame.size == CGSize(width: 780, height: 588))
        #expect(visible.contains(frame))
        #expect(frame.midX == visible.midX && frame.midY == visible.midY)
    }

    @Test func aWindowPartlyOffScreenMovesOnKeepingItsSize() throws {
        let window = CGRect(x: 600, y: 300, width: 780, height: 588)
        let frame = try #require(WindowScreenFit.fittedFrame(for: window, contentFrame: contentFrame, size: size, in: visible))
        #expect(frame.size == window.size)
        #expect(visible.contains(frame))
    }

    @Test func aScreenSmallerThanTheDefaultSizeGetsAllOfIt() throws {
        let small = CGRect(x: 0, y: 0, width: 700, height: 500)
        let window = CGRect(x: 0, y: -100, width: 900, height: 900)
        let frame = try #require(WindowScreenFit.fittedFrame(for: window, contentFrame: contentFrame, size: size, in: small))
        #expect(frame == small)
    }

    /// SwiftUI's Settings scene makes a fixed-size window, so the fitting view makes it
    /// resizable once it's in the window. (XCUITest's drags don't resize windows on the hosted
    /// runner, so this is checked here rather than by dragging.)
    @MainActor
    @Test func theWindowBecomesResizable() async throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 780, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        #expect(!window.styleMask.contains(.resizable))
        window.contentView = WindowScreenFit.FittingView(size: size)
        for _ in 0..<100 where !window.styleMask.contains(.resizable) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(window.styleMask.contains(.resizable))
    }
}
#endif
