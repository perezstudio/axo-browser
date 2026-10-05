import AxoCore
import Foundation
import Testing
import WebKit
@testable import AxoWeb

@MainActor
struct WebViewHostTests {
    let pages: TestPages
    let profileID = UUID()

    init() throws {
        pages = try TestPages()
    }

    @Test func mountedWebViewsFillTheContainerAndLeaveRoomForADockedInspector() {
        let container = WebViewContainer(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let webView = WKWebView()
        container.mount(webView)
        #expect(webView.frame == container.bounds)

        container.setFrameSize(NSSize(width: 1000, height: 700))
        #expect(webView.frame.size == NSSize(width: 1000, height: 700), "It follows the container")

        // Docking the Web Inspector shrinks the web view to make room. A layout pass must keep
        // that size (constraints used to stretch it back over the inspector).
        webView.frame = NSRect(x: 0, y: 400, width: 1000, height: 300)
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        #expect(webView.frame == NSRect(x: 0, y: 400, width: 1000, height: 300))
    }

    @Test func containerMountsOneWebViewAtATime() {
        let container = WebViewContainer()
        let first = WKWebView()
        let second = WKWebView()

        container.mount(first)
        container.mount(first)
        #expect(container.subviews == [first])

        container.mount(second)
        #expect(container.subviews == [second])
        #expect(first.superview == nil)

        container.unmount()
        #expect(container.subviews.isEmpty)
        #expect(container.mountedWebView == nil)
    }

    @Test func coordinatorMountsThePooledWebViewAndTracksVisibility() throws {
        let pool = WebViewPool.forTesting()
        let coordinator = WebViewHost.Coordinator(pool: pool)
        let container = WebViewContainer()
        let one = Tab.testTab(url: try pages.page("one"))
        let two = Tab.testTab(url: try pages.page("two"))

        coordinator.show(one, profileID: profileID, in: container)
        coordinator.show(one, profileID: profileID, in: container)
        #expect(container.mountedWebView === pool.liveWebView(for: one.id))
        #expect(pool.isVisible(one.id))

        coordinator.show(two, profileID: profileID, in: container)
        #expect(container.mountedWebView === pool.liveWebView(for: two.id))
        #expect(!pool.isVisible(one.id))
        #expect(pool.isVisible(two.id))
        #expect(pool.isLive(one.id), "Switching tabs must not destroy the previous web view")

        coordinator.hide(from: container)
        #expect(container.mountedWebView == nil)
        #expect(!pool.isVisible(two.id))
        #expect(pool.isLive(two.id))
    }
}
