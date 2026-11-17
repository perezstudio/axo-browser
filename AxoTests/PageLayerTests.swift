import AppKit
import AxoUI
import Testing
import WebKit
@testable import Axo

/// Where the page sits in the real browser window (#67), which these tests host in: with the
/// navigation bar in the sidebar, the window has no toolbar and the page reaches the window's top
/// edge, with the sidebar shown or hidden; with the sidebar's address bar hidden, the toolbar
/// comes back and the page sits below it, never under it (a visible toolbar takes every click in
/// its 52 pt). Checked here
/// rather than in a UI test because the hosted runner's accessibility reports a web view's frame
/// without following the layout.
@MainActor
@Suite(.serialized)
struct PageLayerTests {
    @Test func thePageReachesTheWindowsTopUnlessTheToolbarShows() async throws {
        let model = try #require(AppEnvironment.browserModel)
        let window = try #require(NSApp.windows.first { $0.identifier?.rawValue.contains("browser") == true })
        let split = try #require(Self.splitController(in: window.contentView))
        let sidebar = try #require(split.splitViewItems.first { $0.behavior == .sidebar })
        if sidebar.isCollapsed { split.toggleSidebar(nil) }

        let before = model.selectedTabID
        await model.openTab(url: URL(string: "data:text/html,<title>Layer</title>")!)
        // Closed at the end only if it's the one opened here, never a tab that was already there.
        let tabID = model.selectedTabID != before ? model.selectedTabID : nil
        #expect(tabID != nil, "A tab opened")
        let top = window.frame.height
        // In window coordinates, which count up from the bottom: the page's top is its maxY.
        try await Self.waitUntil("the page reaches the window's top") {
            Self.pageFrame(in: window).map { abs($0.maxY - top) < 1 } ?? false
        }

        // Hidden, the sidebar floats in from the edge instead, and the page still fills the
        // window: no toolbar comes back (part 3 of #67).
        split.toggleSidebar(nil)
        try await Self.waitUntil("the sidebar collapses") { sidebar.isCollapsed }
        try await Task.sleep(for: .milliseconds(500))
        #expect(Self.pageFrame(in: window).map { abs($0.maxY - top) < 1 } == true, "The page still reaches the top")
        split.toggleSidebar(nil)
        try await Self.waitUntil("the sidebar shows again") { !sidebar.isCollapsed }

        // With the sidebar's address bar hidden, the toolbar comes back, with the page below it.
        model.setSidebarAddressBarShown(false)
        try await Self.waitUntil("the page moves below the toolbar") {
            Self.pageFrame(in: window).map { $0.maxY <= top - 40 } ?? false
        }
        model.setSidebarAddressBarShown(true)
        try await Self.waitUntil("the page reaches the top again") {
            Self.pageFrame(in: window).map { abs($0.maxY - top) < 1 } ?? false
        }
        if let tabID { await model.closeTab(tabID) }
    }

    /// The sidebar's top row draws the window's own controls (its title bar is hidden); each is
    /// aimed at its window, so a click on a window in the background never closes, minimizes,
    /// or zooms the key one.
    @Test func theTopRowsWindowControlsActOnTheirOwnWindow() throws {
        let window = try #require(NSApp.windows.first { $0.identifier?.rawValue.contains("browser") == true })
        // The row's copies are the window's only close, minimize, and zoom buttons inside its
        // content; the real ones live in the (hidden) title bar, outside it.
        let kinds: Set<NSWindow.ButtonType> = [.closeButton, .miniaturizeButton, .zoomButton]
        let real = kinds.compactMap { window.standardWindowButton($0) }
        func controls(in view: NSView) -> [NSButton] {
            let own = view.subviews.compactMap { $0 as? NSButton }.filter { button in
                real.contains { type(of: $0) == type(of: button) } && !real.contains { $0 === button }
            }
            return own + view.subviews.flatMap(controls)
        }
        let buttons = controls(in: try #require(window.contentView))
        #expect(buttons.count == 3, "Close, minimize, and zoom")
        for button in buttons {
            #expect(button.target === window, "\(String(describing: button.action)) acts on its own window")
        }
    }

    /// The shown page's frame in window coordinates.
    private static func pageFrame(in window: NSWindow) -> CGRect? {
        func find(_ view: NSView) -> NSView? {
            if view is WKWebView, view.window != nil, !view.isHiddenOrHasHiddenAncestor { return view }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        return window.contentView.flatMap(find).map { $0.convert($0.bounds, to: nil) }
    }

    /// The browser window's split view controller.
    private static func splitController(in view: NSView?) -> NSSplitViewController? {
        guard let view else { return nil }
        if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController { return controller }
        for subview in view.subviews { if let found = splitController(in: subview) { return found } }
        return nil
    }

    /// Waits for `condition`, failing after a limit that only guards against hangs.
    private static func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting until \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
