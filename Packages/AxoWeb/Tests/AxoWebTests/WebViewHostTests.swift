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
