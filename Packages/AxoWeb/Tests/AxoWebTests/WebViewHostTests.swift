import AxoCore
import Foundation
import ScreenTime
import Testing
import WebKit
@testable import AxoWeb

// The Mac tests use AppKit windows; iPhone and iPad have their own below.
#if os(macOS)
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

    // MARK: Screen Time

    @Test func screenTimeFollowsThePageAndLetsClicksThrough() async throws {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = WebViewContainer(frame: window.contentView!.bounds)
        window.contentView?.addSubview(container)
        let webView = WKWebView()
        container.mount(webView)
        let profile = UUID()
        container.configureScreenTime(profileID: profile, recordsUsage: false)

        let screenTime = try #require(container.screenTime)
        #expect(screenTime.view.superview === container)
        #expect(container.subviews.last === screenTime.view, "On top of the page")
        #expect(screenTime.suppressUsageRecording)
        #expect(screenTime.profileIdentifier?.rawValue == profile.uuidString)

        webView.loadHTMLString("<title>Page</title><p>Hi</p>", baseURL: URL(string: "http://example.com/news")!)
        try await waitUntil("the page") { screenTime.url?.absoluteString == "http://example.com/news" }

        // Unless it's showing the block screen, it must not take the page's clicks.
        let hit = container.hitTest(NSPoint(x: 400, y: 300))
        #expect(hit === webView || hit?.isDescendant(of: webView) == true, "Clicks reach the page: \(String(describing: hit))")

        container.unmount()
        #expect(screenTime.url == nil, "Nothing is reported while no page is mounted")
    }

    @Test func remountingKeepsOneScreenTimeControllerBelowNothing() {
        let container = WebViewContainer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        container.mount(WKWebView())
        container.configureScreenTime(profileID: UUID(), recordsUsage: true)
        let controller = container.screenTime
        let second = WKWebView()
        container.mount(second)
        container.configureScreenTime(profileID: UUID(), recordsUsage: true)
        #expect(container.screenTime === controller)
        #expect(container.subviews == [second, controller!.view], "The new page goes under Screen Time's view")
        #expect(controller?.suppressUsageRecording == false)
    }

    @Test func testPoolsDontReportUsage() {
        #expect(WebViewPool.forTesting().reportsScreenTimeUsage == false)
        #expect(WebViewPool(makeDataStore: { _ in .nonPersistent() }).reportsScreenTimeUsage)
    }
}
#else
import UIKit

@MainActor
struct WebViewContainerTests {
    @Test func mountedWebViewsFillTheContainerAndFollowItsSize() {
        let container = WebViewContainer(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let webView = WKWebView(frame: .zero)
        container.mount(webView)
        #expect(webView.superview === container)
        #expect(webView.frame == container.bounds)

        container.frame.size = CGSize(width: 820, height: 1000)
        container.layoutIfNeeded()
        #expect(webView.frame.size == CGSize(width: 820, height: 1000), "It follows the container")

        container.unmount()
        #expect(webView.superview == nil)
        #expect(container.mountedWebView == nil)
    }
}
#endif
