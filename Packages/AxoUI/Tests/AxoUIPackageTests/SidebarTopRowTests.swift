#if os(macOS)
import AppKit
import AxoCore
import AxoWebTestSupport
import CoreGraphics
import Testing
@testable import AxoUI
@testable import AxoWeb

/// The sidebar's top row, footer, and address bar with the navigation bar in the sidebar (#67).
@MainActor
struct SidebarTopRowTests {
    @Test func theWindowsControlsSitWhereMacOSPutsThem() throws {
        // A window with a toolbar, as the browser window has while its sidebar is hidden: where
        // macOS puts its own controls is where the top row puts its copies.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.toolbar = NSToolbar(identifier: "SidebarTopRowTests")
        window.toolbarStyle = .unified
        window.layoutIfNeeded()
        let close = try #require(window.standardWindowButton(.closeButton))
        let minimize = try #require(window.standardWindowButton(.miniaturizeButton))
        let zoom = try #require(window.standardWindowButton(.zoomButton))
        func frame(_ button: NSButton) -> CGRect { button.convert(button.bounds, to: nil) }
        #expect(frame(close).minX == WindowControls.leading)
        #expect(frame(minimize).minX - frame(close).minX == WindowControls.pitch)
        #expect(frame(zoom).maxX == SidebarTopRow.windowControlsWidth)
        #expect(frame(close).height == WindowControls.size.height)
        // Centered 26 pt down, as the row's buttons are.
        #expect(abs(window.frame.height - frame(close).midY - SidebarTopRow.height / 2) <= 1)
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

    /// The floating sidebar stays while something it opened shows (#67), so a popover or sheet
    /// from it never loses its anchor when the pointer moves onto it.
    @Test func theFloatingSidebarStaysWhileItsPopoversShow() throws {
        let pool = WebViewPool(engine: FakeEngine())
        pool.reportsScreenTimeUsage = false
        let model = BrowserModel(store: try TabStore.makeInMemory(), pool: pool)
        model.announce = { _ in }
        #expect(!FloatingSidebar.isHolding(model))
        model.isShowingDownloads = true
        #expect(FloatingSidebar.isHolding(model))
        model.isShowingDownloads = false
        model.isShowingSiteSettings = true
        #expect(FloatingSidebar.isHolding(model))
        model.isShowingSiteSettings = false
        model.isShowingSummary = true
        #expect(FloatingSidebar.isHolding(model))
        model.isShowingSummary = false
        model.isCreatingSpace = true
        #expect(FloatingSidebar.isHolding(model))
        model.isCreatingSpace = false
        model.isShowingArchive = true
        #expect(FloatingSidebar.isHolding(model))
        model.isShowingArchive = false
        model.isShowingExtensions = true
        #expect(FloatingSidebar.isHolding(model))
        model.isShowingExtensions = false
        #expect(!FloatingSidebar.isHolding(model))
    }

    /// An extension's popup is a child window of the browser window, which the model doesn't
    /// know of: the card stays while one shows.
    @Test func theFloatingSidebarStaysWhileAChildWindowShows() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let child = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        child.isReleasedWhenClosed = false
        defer { child.close(); window.close() }
        #expect(!FloatingSidebar.isHolding(window))
        window.addChildWindow(child, ordered: .above)
        #expect(FloatingSidebar.isHolding(window))
        window.removeChildWindow(child)
        #expect(!FloatingSidebar.isHolding(window))
        #expect(!FloatingSidebar.isHolding(nil as NSWindow?))
    }

    /// The floating sidebar's address bar and the sidebar's can both be on screen for a moment
    /// as one replaces the other: the bar counts as shown until both have gone.
    @Test func theAddressBarStaysOnScreenUntilBothCopiesGo() throws {
        let pool = WebViewPool(engine: FakeEngine())
        pool.reportsScreenTimeUsage = false
        let model = BrowserModel(store: try TabStore.makeInMemory(), pool: pool)
        model.sidebarAddressBarsOnScreen += 1 // the floating sidebar's
        model.sidebarAddressBarsOnScreen += 1 // the sidebar's, shown again
        model.sidebarAddressBarsOnScreen -= 1 // the floating one leaves after
        #expect(model.isSidebarAddressBarOnScreen)
        model.sidebarAddressBarsOnScreen -= 1
        #expect(!model.isSidebarAddressBarOnScreen)
    }

    /// The floating sidebar covers the page and takes the pointer, so the page's hovered-link
    /// label hides as it does under Peek.
    @Test func theFloatingSidebarCoversThePage() throws {
        let pool = WebViewPool(engine: FakeEngine())
        pool.reportsScreenTimeUsage = false
        let model = BrowserModel(store: try TabStore.makeInMemory(), pool: pool)
        #expect(!model.arePagesCovered)
        model.isFloatingSidebarShown = true
        #expect(model.arePagesCovered)
    }
}
#endif
