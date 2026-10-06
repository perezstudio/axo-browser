import AxoCore
import Foundation
import Testing
import WebKit
@testable import AxoWeb

@MainActor
struct WebViewPoolTests {
    let pages: TestPages
    let profileID = UUID()

    init() throws {
        pages = try TestPages()
    }

    /// Waits for the tab's live web view to finish loading a page with `title`.
    private func waitForPage(_ title: String, tab: Tab, pool: WebViewPool) async throws {
        try await waitUntil("page \(title)") {
            guard let state = pool.state(for: tab.id) else { return false }
            return !state.isLoading && state.title == title
        }
    }

    // MARK: Ownership

    @Test func returnsTheSameWebViewForATabUntilItHibernates() throws {
        let pool = WebViewPool.forTesting()
        let tab = Tab.testTab(url: try pages.page("one"))

        let first = pool.webView(for: tab, profileID: profileID)
        let second = pool.webView(for: tab, profileID: profileID)

        #expect(first === second)
        #expect(pool.isLive(tab.id))
        #expect(pool.liveWebView(for: tab.id) === first)
    }

    @Test func liveWebViewDoesNotCreateOne() throws {
        let pool = WebViewPool.forTesting()
        let tab = Tab.testTab(url: try pages.page("one"))
        #expect(pool.liveWebView(for: tab.id) == nil)
        #expect(pool.state(for: tab.id) == nil)
        #expect(!pool.isLive(tab.id))
    }

    @Test func eachProfileGetsItsOwnDataStoreSharedByItsTabs() throws {
        var created: [Profile.ID] = []
        let pool = WebViewPool(
            makeDataStore: { id in
                created.append(id)
                return .nonPersistent()
            },
            downloads: DownloadManager(directory: pages.directory.appending(path: "Downloads"))
        )
        let other = UUID()
        let a = pool.webView(for: .testTab(url: try pages.page("a")), profileID: profileID)
        let b = pool.webView(for: .testTab(url: try pages.page("b")), profileID: profileID)
        let c = pool.webView(for: .testTab(url: try pages.page("c")), profileID: other)

        #expect(a.configuration.websiteDataStore === b.configuration.websiteDataStore)
        #expect(a.configuration.websiteDataStore !== c.configuration.websiteDataStore)
        #expect(created == [profileID, other])
    }

    @Test func newWebViewsCanBeConfiguredPerProfile() throws {
        let pool = WebViewPool.forTesting()
        var configured: [Profile.ID] = []
        var order: [String] = []
        pool.addWebViewConfigurator { configuration, profile in
            configured.append(profile)
            order.append("first")
            configuration.applicationNameForUserAgent = "AxoTest"
        }
        pool.addWebViewConfigurator { _, _ in order.append("second") }

        let webView = pool.webView(for: .testTab(url: try pages.page("one")), profileID: profileID)

        #expect(configured == [profileID])
        #expect(webView.configuration.applicationNameForUserAgent == "AxoTest")
        _ = pool.webView(for: .testTab(url: try pages.page("two")), profileID: profileID)
        #expect(configured.count == 2, "Every new web view is configured")
        #expect(order == ["first", "second", "first", "second"], "Configurators run in order")
    }

    @Test func someWebViewsStartFromTheirOwnConfiguration() throws {
        let pool = WebViewPool.forTesting()
        let special = try pages.page("special")
        var asked: [(URL, Profile.ID)] = []
        pool.baseConfiguration = { url, profile in
            asked.append((url, profile))
            guard url == special else { return nil }
            let configuration = WKWebViewConfiguration()
            configuration.preferences.minimumFontSize = 17
            return configuration
        }
        var configuratorRan = false
        pool.addWebViewConfigurator { _, _ in configuratorRan = true }

        let ordinary = pool.webView(for: .testTab(url: try pages.page("ordinary")), profileID: profileID)
        let own = pool.webView(for: .testTab(url: special), profileID: profileID)

        #expect(asked.map(\.0) == [try pages.page("ordinary"), special])
        #expect(asked.allSatisfy { $0.1 == profileID })
        #expect(ordinary.configuration.preferences.minimumFontSize == 0)
        #expect(own.configuration.preferences.minimumFontSize == 17)
        #expect(own.configuration.websiteDataStore === pool.dataStore(for: profileID), "The pool's own settings still apply")
        #expect(configuratorRan)
    }

    // MARK: Loading and state

    @Test func loadsTheTabURLAndReportsPageChanges() async throws {
        let pool = WebViewPool.forTesting()
        let url = try pages.page("Hello")
        let tab = Tab.testTab(url: url)
        var changes: [(Tab.ID, URL, String)] = []
        pool.onPageChange = { changes.append(($0, $1, $2)) }

        _ = pool.webView(for: tab, profileID: profileID)
        try await waitForPage("Hello", tab: tab, pool: pool)

        let state = try #require(pool.state(for: tab.id))
        #expect(state.url == url)
        #expect(state.estimatedProgress == 1)
        let last = try #require(changes.last)
        #expect(last.0 == tab.id)
        #expect(last.1 == url)
        #expect(last.2 == "Hello")
    }

    @Test func navigatesBackAndForward() async throws {
        let pool = WebViewPool.forTesting()
        let tab = Tab.testTab(url: try pages.page("first"))
        _ = pool.webView(for: tab, profileID: profileID)
        try await waitForPage("first", tab: tab, pool: pool)

        pool.load(try pages.page("second"), in: tab.id)
        try await waitForPage("second", tab: tab, pool: pool)
        let state = try #require(pool.state(for: tab.id))
        #expect(state.canGoBack)
        #expect(!state.canGoForward)

        pool.goBack(in: tab.id)
        try await waitForPage("first", tab: tab, pool: pool)
        #expect(state.canGoForward)

        pool.goForward(in: tab.id)
        try await waitForPage("second", tab: tab, pool: pool)
    }

    @Test func linksThatTargetANewWindowAskForANewTab() async throws {
        let pool = WebViewPool.forTesting()
        let target = try pages.page("target")
        let opener = try pages.page(
            "opener",
            body: "<a id='link' href='\(target.lastPathComponent)' target='_blank'>Open</a>"
        )
        let tab = Tab.testTab(url: opener)
        var requests: [(URL, Tab.ID)] = []
        pool.onOpenInNewTab = { requests.append(($0, $1)) }

        let webView = pool.webView(for: tab, profileID: profileID)
        try await waitForPage("opener", tab: tab, pool: pool)
        _ = try await webView.callAsyncJavaScript(
            "document.getElementById('link').click()",
            contentWorld: .page
        )
        try await waitUntil("new tab request") { !requests.isEmpty }

        #expect(requests.first?.0.lastPathComponent == target.lastPathComponent)
        #expect(requests.first?.1 == tab.id)
        #expect(pool.liveTabIDs == [tab.id])
    }

    @Test func pagesSeeASafariUserAgent() async throws {
        let pool = WebViewPool.forTesting()
        let tab = Tab.testTab(url: try pages.page("agent"))
        let webView = pool.webView(for: tab, profileID: profileID)
        try await waitForPage("agent", tab: tab, pool: pool)

        let agent = try #require(try await webView.callAsyncJavaScript("return navigator.userAgent", contentWorld: .page) as? String)
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        #expect(agent.contains(" Version/\(major)."), "\(agent)")
        #expect(agent.contains(" Safari/"), "Sites and extensions that detect Safari recognize Axo: \(agent)")
    }

    @Test func linkClicksCanBeTakenOver() async throws {
        let pool = WebViewPool.forTesting()
        let target = try pages.page("target")
        let tab = Tab.testTab(url: try pages.page("links", body: "<a id='link' href='\(target.lastPathComponent)'>Go</a>"))
        var clicks: [LinkClick] = []
        var takesClicks = true
        pool.onLinkClick = { click in
            clicks.append(click)
            return takesClicks
        }
        let webView = pool.webView(for: tab, profileID: profileID)
        try await waitForPage("links", tab: tab, pool: pool)

        _ = try await webView.callAsyncJavaScript("document.getElementById('link').click()", contentWorld: .page)
        try await waitUntil("the click") { !clicks.isEmpty }
        #expect(clicks.first?.tabID == tab.id)
        #expect(clicks.first?.url.lastPathComponent == target.lastPathComponent)
        #expect(clicks.first?.sourceURL?.lastPathComponent == "links.html")
        try await Task.sleep(for: .milliseconds(300))
        #expect(pool.state(for: tab.id)?.title == "links", "A taken click doesn't navigate")

        takesClicks = false
        _ = try await webView.callAsyncJavaScript("document.getElementById('link').click()", contentWorld: .page)
        try await waitForPage("target", tab: tab, pool: pool)
    }

    @Test(arguments: [
        ("https://news.example.com/a", "https://www.news.example.com/b", false),
        ("https://news.example.com/a", "https://other.example.com/", true),
        ("data:text/html,hi", "https://example.com/", true),
    ])
    func linksKnowWhenTheyLeaveTheSite(from source: String, to destination: String, leaves: Bool) {
        let click = LinkClick(tabID: UUID(), url: URL(string: destination)!, sourceURL: URL(string: source))
        #expect(click.leavesSite == leaves)
    }

    #if os(macOS)
    @Test func focusingAWebViewReportsItsTab() throws {
        let pool = WebViewPool.forTesting()
        let first = Tab.testTab(url: try pages.page("one")), second = Tab.testTab(url: try pages.page("two"))
        var focused: [Tab.ID] = []
        pool.onWebViewFocus = { focused.append($0) }

        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let left = pool.webView(for: first, profileID: profileID), right = pool.webView(for: second, profileID: profileID)
        window.contentView?.addSubview(left)
        window.contentView?.addSubview(right)

        window.makeFirstResponder(right)
        window.makeFirstResponder(left)
        #expect(focused == [second.id, first.id])
    }
    #endif

    @Test func pagesCanGoFullscreen() async throws {
        let pool = WebViewPool.forTesting()
        let tab = Tab.testTab(url: try pages.page("full"))
        let webView = pool.webView(for: tab, profileID: profileID)
        try await waitForPage("full", tab: tab, pool: pool)

        let enabled = try await webView.callAsyncJavaScript("return document.fullscreenEnabled", contentWorld: .page) as? Bool
        #expect(enabled == true, "The Fullscreen API is on, so videos can fill the screen")
    }

    // MARK: Hibernation

    @Test func hibernatingDiscardsTheWebViewAndWakingRestoresHistory() async throws {
        let pool = WebViewPool.forTesting()
        let tab = Tab.testTab(url: try pages.page("first"))
        let original = pool.webView(for: tab, profileID: profileID)
        try await waitForPage("first", tab: tab, pool: pool)
        pool.load(try pages.page("second"), in: tab.id)
        try await waitForPage("second", tab: tab, pool: pool)

        await pool.hibernate(tab.id)
        #expect(!pool.isLive(tab.id))
        #expect(pool.isHibernated(tab.id))
        #expect(original.navigationDelegate == nil)

        let woken = pool.webView(for: tab, profileID: profileID)
        #expect(woken !== original)
        #expect(!pool.isHibernated(tab.id))
        try await waitForPage("second", tab: tab, pool: pool)
        #expect(pool.state(for: tab.id)?.canGoBack == true)
    }

    @Test func visibleTabsNeverHibernate() async throws {
        let pool = WebViewPool.forTesting()
        let tab = Tab.testTab(url: try pages.page("one"))
        _ = pool.webView(for: tab, profileID: profileID)
        pool.beginShowing(tab.id)

        await pool.hibernate(tab.id)

        #expect(pool.isLive(tab.id))
        #expect(!pool.isHibernated(tab.id))
    }

    @Test func idleHiddenTabsHibernateAfterTheTimeout() async throws {
        let clock = TestClock()
        let pool = WebViewPool.forTesting(clock: clock, timeout: 60)
        let visible = Tab.testTab(url: try pages.page("visible"))
        let idle = Tab.testTab(url: try pages.page("idle"))
        let recent = Tab.testTab(url: try pages.page("recent"))

        _ = pool.webView(for: visible, profileID: profileID)
        _ = pool.webView(for: idle, profileID: profileID)
        pool.beginShowing(visible.id)
        clock.advance(by: 30)
        _ = pool.webView(for: recent, profileID: profileID)

        clock.advance(by: 29)
        #expect(await pool.hibernateIdleTabs().isEmpty)

        clock.advance(by: 1)
        #expect(await pool.hibernateIdleTabs() == [idle.id])
        #expect(pool.liveTabIDs == [visible.id, recent.id])

        clock.advance(by: 60)
        #expect(await pool.hibernateIdleTabs() == [recent.id])
        #expect(pool.liveTabIDs == [visible.id])
    }

    @Test func idleTimerStartsWhenATabIsHidden() async throws {
        let clock = TestClock()
        let pool = WebViewPool.forTesting(clock: clock, timeout: 60)
        let tab = Tab.testTab(url: try pages.page("one"))
        _ = pool.webView(for: tab, profileID: profileID)
        pool.beginShowing(tab.id)

        clock.advance(by: 600)
        pool.endShowing(tab.id)
        clock.advance(by: 59)
        #expect(await pool.hibernateIdleTabs().isEmpty)

        clock.advance(by: 1)
        #expect(await pool.hibernateIdleTabs() == [tab.id])
    }

    @Test func visibilityIsCountedAcrossHosts() throws {
        let pool = WebViewPool.forTesting()
        let tab = Tab.testTab(url: try pages.page("one"))
        pool.beginShowing(tab.id)
        pool.beginShowing(tab.id)

        pool.endShowing(tab.id)
        #expect(pool.isVisible(tab.id))
        pool.endShowing(tab.id)
        #expect(!pool.isVisible(tab.id))
        pool.endShowing(tab.id)
        #expect(!pool.isVisible(tab.id))
    }

    @Test func hibernationTimerHibernatesIdleTabs() async throws {
        let clock = TestClock()
        let pool = WebViewPool.forTesting(clock: clock, timeout: 60)
        pool.configuration.hibernationCheckInterval = .milliseconds(10)
        let tab = Tab.testTab(url: try pages.page("one"))
        _ = pool.webView(for: tab, profileID: profileID)
        clock.advance(by: 61)

        pool.startHibernationTimer()
        defer { pool.stopHibernationTimer() }
        try await waitUntil("timer hibernation") { pool.isHibernated(tab.id) }
    }

    @Test func discardForgetsLiveAndHibernatedTabs() async throws {
        let pool = WebViewPool.forTesting()
        let live = Tab.testTab(url: try pages.page("live"))
        let sleeping = Tab.testTab(url: try pages.page("sleeping"))
        _ = pool.webView(for: live, profileID: profileID)
        _ = pool.webView(for: sleeping, profileID: profileID)
        await pool.hibernate(sleeping.id)

        pool.discard(live.id)
        pool.discard(sleeping.id)

        #expect(pool.liveTabIDs.isEmpty)
        #expect(!pool.isHibernated(sleeping.id))
    }
}
