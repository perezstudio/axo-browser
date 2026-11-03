import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
import WebKit
@testable import AxoWeb

@MainActor
struct HoveredLinkTests {
    let profileID = UUID()
    private let linkPage = """
        <!doctype html><title>Links</title>
        <a id=near href="/axolotl">An axolotl</a> <a id=far href="https://example.org/far">Far away</a>
        """

    // MARK: The pool, on the fake engine

    @Test func theTabsStateFollowsTheLinkItsPageReports() throws {
        let engine = FakeEngine()
        let pool = WebViewPool.withFakeEngine(engine)
        let tab = Tab.testTab(url: URL(string: "https://example.com/")!)
        _ = pool.page(for: tab, profileID: profileID)
        let page = try #require(engine.pages.last)
        let state = try #require(pool.state(for: tab.id))
        #expect(state.hoveredLink == nil)

        page.hoverLink(URL(string: "https://example.com/a"))
        #expect(state.hoveredLink == URL(string: "https://example.com/a"))
        page.hoverLink(nil)
        #expect(state.hoveredLink == nil)
    }

    @Test func hidingThePageClearsItsLink() throws {
        let engine = FakeEngine()
        let pool = WebViewPool.withFakeEngine(engine)
        let tab = Tab.testTab(url: URL(string: "https://example.com/")!)
        let page = pool.page(for: tab, profileID: profileID)
        let state = try #require(pool.state(for: tab.id))
        let container = WebViewContainer()
        container.mount(page.view, state: state)
        try #require(engine.pages.last).hoverLink(URL(string: "https://example.com/a"))

        // The pointer can't be over a page that isn't showing, and the engine may not say so.
        container.unmount()
        #expect(state.hoveredLink == nil)
    }

    @Test func aPageThatMovedToAnotherHostKeepsItsLink() throws {
        let engine = FakeEngine()
        let pool = WebViewPool.withFakeEngine(engine)
        let tab = Tab.testTab(url: URL(string: "https://example.com/")!)
        let page = pool.page(for: tab, profileID: profileID)
        let state = try #require(pool.state(for: tab.id))
        let old = WebViewContainer()
        let new = WebViewContainer()
        old.mount(page.view, state: state)
        new.mount(page.view, state: state)
        try #require(engine.pages.last).hoverLink(URL(string: "https://example.com/a"))

        // SwiftUI can dismantle the old host after the new one mounted the page.
        old.unmount()
        #expect(state.hoveredLink == URL(string: "https://example.com/a"))
    }

    // MARK: WebKit pages

    /// Shows `html` as if it came from example.com, without the network, and waits for it.
    private func load(_ html: String, in pool: WebViewPool) async throws -> (WKWebView, WebTabState) {
        let tab = Tab.testTab(url: URL(string: "about:blank")!)
        let webView = pool.webView(for: tab, profileID: profileID)
        webView.loadHTMLString(html, baseURL: URL(string: "http://example.com/")!)
        try await waitUntil("the page") { webView.url?.absoluteString == "http://example.com/" && !webView.isLoading }
        return (webView, try #require(pool.state(for: tab.id)))
    }

    private func run(_ script: String, in webView: WKWebView) async throws {
        _ = try await webView.callAsyncJavaScript(script, contentWorld: .page)
    }

    @Test func webKitReportsTheFocusedLinkAndClearsIt() async throws {
        let pool = WebViewPool.forTesting()
        let (webView, state) = try await load(linkPage, in: pool)

        try await run("document.getElementById('near').focus()", in: webView)
        try await waitUntil("the focused link") { state.hoveredLink == URL(string: "http://example.com/axolotl") }
        try await run("document.getElementById('far').focus()", in: webView)
        try await waitUntil("the next link") { state.hoveredLink == URL(string: "https://example.org/far") }
        try await run("document.activeElement.blur()", in: webView)
        try await waitUntil("no link") { state.hoveredLink == nil }
    }

    @Test func pagesCantFakeAHover() async throws {
        let pool = WebViewPool.forTesting()
        let (webView, state) = try await load(linkPage, in: pool)

        try await run("""
            const link = document.getElementById('far');
            link.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
            link.dispatchEvent(new FocusEvent('focusin', { bubbles: true }));
            """, in: webView)
        // A round trip through the script's world, after which its messages would have arrived.
        _ = try await webView.callAsyncJavaScript("return 1", contentWorld: HoveredLinks.world)
        try await Task.sleep(for: .milliseconds(200))
        #expect(state.hoveredLink == nil, "Faked events don't count")
        // A real focus afterwards does report, so the script was listening.
        try await run("document.getElementById('near').focus()", in: webView)
        try await waitUntil("the focused link") { state.hoveredLink != nil }
        #expect(state.hoveredLink == URL(string: "http://example.com/axolotl"))
    }

    @Test func linksInWebComponentsAndSVGShowTheirFullAddress() async throws {
        let pool = WebViewPool.forTesting()
        let (webView, state) = try await load("""
            <!doctype html><title>Components</title><div id=host></div>
            <svg><a id=svg href="/drawn"><text y=20>Drawn</text></a></svg>
            <script>
              document.getElementById('host').attachShadow({ mode: 'open' }).innerHTML = '<a href="/inside">Inside</a>';
            </script>
            """, in: pool)

        try await run("document.getElementById('host').shadowRoot.querySelector('a').focus()", in: webView)
        try await waitUntil("the shadow link") { state.hoveredLink == URL(string: "http://example.com/inside") }
        try await run("document.getElementById('svg').focus()", in: webView)
        try await waitUntil("the SVG link") { state.hoveredLink == URL(string: "http://example.com/drawn") }
    }

    @Test func hugeAddressesAreCut() async throws {
        let pool = WebViewPool.forTesting()
        let (webView, state) = try await load("""
            <!doctype html><title>Export</title><a id=csv>Download</a>
            <script>document.getElementById('csv').href = 'data:text/csv,' + 'x'.repeat(100000)</script>
            """, in: pool)
        try await run("document.getElementById('csv').focus()", in: webView)
        try await waitUntil("the data link") { state.hoveredLink != nil }
        let shown = try #require(state.hoveredLink).absoluteString
        #expect(shown.hasPrefix("data:text/csv,xxx"))
        #expect(shown.count == HoveredLinks.maxLength)
    }

    @Test func theEnginesHugeAddressesAreCutToo() throws {
        let engine = FakeEngine()
        let pool = WebViewPool.withFakeEngine(engine)
        let tab = Tab.testTab(url: URL(string: "https://example.com/")!)
        _ = pool.page(for: tab, profileID: profileID)
        try #require(engine.pages.last).hoverLink(URL(string: "data:text/csv," + String(repeating: "x", count: 100_000)))
        #expect(pool.state(for: tab.id)?.hoveredLink?.absoluteString.count == HoveredLinks.maxLength)
    }

    @Test func showingThePageAgainStartsWithNoLink() throws {
        let engine = FakeEngine()
        let pool = WebViewPool.withFakeEngine(engine)
        let tab = Tab.testTab(url: URL(string: "https://example.com/")!)
        let page = pool.page(for: tab, profileID: profileID)
        let state = try #require(pool.state(for: tab.id))
        // A report that arrived after the page was hidden.
        try #require(engine.pages.last).hoverLink(URL(string: "https://example.com/late"))

        WebViewContainer().mount(page.view, state: state)
        #expect(state.hoveredLink == nil)
    }

    @Test func theScriptStaysAfterSiteCustomizationsChange() async throws {
        let pool = WebViewPool.forTesting()
        let (webView, liveState) = try await load(linkPage, in: pool)
        pool.setSiteCustomizations([SiteCustomization(domain: "example.com", css: "a { color: red }")])

        let (sameWebView, state) = try await load(linkPage, in: pool)
        #expect(sameWebView !== webView, "Each load makes a fresh tab")
        try await run("document.getElementById('near').focus()", in: sameWebView)
        try await waitUntil("the focused link") { state.hoveredLink == URL(string: "http://example.com/axolotl") }

        // A page that was live when they changed gets it again on its next load.
        webView.loadHTMLString(linkPage, baseURL: URL(string: "http://example.com/")!)
        try await waitUntil("the reload") { !webView.isLoading }
        try await run("document.getElementById('far').focus()", in: webView)
        try await waitUntil("the live page's link") { liveState.hoveredLink == URL(string: "https://example.org/far") }
    }
}
