#if os(macOS)
import CoreGraphics
import Testing
@testable import AxoUI

/// The sidebar's top row, footer, and address bar with the navigation bar in the sidebar (#67).
@MainActor
struct SidebarTopRowTests {
    @Test func theWindowsControlsSitWhereMacOSPutsThem() {
        // Close at 19 pt, zoom ending at 79 pt, as in a window with a toolbar on macOS 27.
        #expect(WindowControls.leading == 19)
        #expect(SidebarTopRow.windowControlsWidth == 79)
    }

    @Test func theNarrowestSidebarFitsTheTopRow() {
        #expect(SidebarTopRow.minimumSidebarWidth >= SidebarTopRow.requiredWidth)
        // The row is laid out from the same numbers, and holds three controls after the
        // window's: changing one changes what it needs.
        #expect(SidebarTopRow.requiredWidth > SidebarTopRow.windowControlsWidth + SidebarGlassButtonStyle.side * 3)
    }

    @Test func downloadsSaysWhatItHolds() {
        #expect(FooterDownloadsButton.value(activeCount: 0, count: 0) == "None")
        #expect(FooterDownloadsButton.value(activeCount: 2, count: 3) == "2 in progress")
        #expect(FooterDownloadsButton.value(activeCount: 0, count: 3) == "")
    }

    @Test func theAddressBarShowsAFewExtensionsAndAMenuForTheRest() {
        let limit = ExtensionToolbarButtons.addressBarLimit
        #expect(ExtensionToolbarButtons.split([1, 2], limit: limit) == ([1, 2], []))
        #expect(ExtensionToolbarButtons.split([1, 2, 3], limit: limit) == ([1, 2, 3], []))
        // One more than fits: the last button's place goes to the menu, which holds the rest.
        #expect(ExtensionToolbarButtons.split([1, 2, 3, 4], limit: limit) == ([1, 2], [3, 4]))
        #expect(ExtensionToolbarButtons.split(Array(1...12), limit: limit).menu.count == 10)
        #expect(ExtensionToolbarButtons.shownCount(of: 12, limit: limit) == limit)
    }

    @Test func theToolbarShowsEveryExtension() {
        #expect(ExtensionToolbarButtons.split(Array(1...12), limit: nil) == (Array(1...12), []))
        #expect(ExtensionToolbarButtons.shownCount(of: 12, limit: nil) == 12)
    }
}
#endif
