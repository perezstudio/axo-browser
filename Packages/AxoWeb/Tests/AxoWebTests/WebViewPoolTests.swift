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
