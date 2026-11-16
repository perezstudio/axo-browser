#if os(macOS)
import CoreGraphics
import Testing
@testable import AxoUI

/// The sidebar's top row and footer with the navigation bar in the sidebar (#67).
struct SidebarTopRowTests {
    @Test func theNarrowestSidebarFitsTheTopRow() {
        // The window's controls, back and forward's capsule (two 30 pt buttons in 3 pt of
        // padding), reload and Hide Sidebar's circles, three 6 pt gaps, and the trailing 8 pt.
        let capsule: CGFloat = 30 * 2 + 3 * 2
        let needed = SidebarTopRow.windowControlsWidth + capsule + SidebarGlassButtonStyle.side * 2 + 6 * 3 + 8
        #expect(SidebarTopRow.minimumSidebarWidth >= needed)
    }

    @Test func theRowIsCenteredWithTheWindowsControls() {
        // macOS 27 centers the window's controls 26 pt down in a window with a toolbar's title
        // bar area; the row's 36 pt buttons are centered in it too.
        #expect(SidebarTopRow.height / 2 == 26)
    }

    @Test func downloadsSaysWhatItHolds() {
        #expect(FooterDownloadsButton.value(activeCount: 0, count: 0) == "None")
        #expect(FooterDownloadsButton.value(activeCount: 2, count: 3) == "2 in progress")
        #expect(FooterDownloadsButton.value(activeCount: 0, count: 3) == "")
    }
}
#endif
