import AxoCore
import Foundation
import Testing
import WebKit
@testable import AxoWeb

@MainActor
struct SiteCustomizationTests {
    let profileID = UUID()

    /// Shows `html` as if it came from `address`, without the network, and waits for it.
    private func load(_ html: String, at address: String, pool: WebViewPool) async throws -> WKWebView {
        let tab = Tab(spaceID: UUID(), url: URL(string: "about:blank")!, sortKey: "a0")
        let webView = pool.webView(for: tab, profileID: profileID)
        webView.loadHTMLString(html, baseURL: URL(string: address)!)
        try await waitUntil("the page") { webView.url?.absoluteString == address && !webView.isLoading }
        return webView
    }

    private func run(_ script: String, in webView: WKWebView, world: WKContentWorld = .page) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, contentWorld: world)
    }

    private let page = "<!doctype html><title>Page</title><p id=p>Hello</p>"

    @Test func cssAndJavaScriptApplyToTheSiteAndItsSubdomains() async throws {
        let pool = WebViewPool.forTesting()
        pool.setSiteCustomizations([
            SiteCustomization(domain: "example.com", css: "#p { color: rgb(255, 0, 0) }", js: "document.title = 'Customized ' + typeof window.pageValue"),
        ])
        let webView = try await load(page + "<script>window.pageValue = 1</script>", at: "http://docs.example.com/", pool: pool)

        #expect(try await run("return getComputedStyle(document.getElementById('p')).color", in: webView) as? String == "rgb(255, 0, 0)")
        try await waitUntil("the script") { webView.title == "Customized number" }
        // The JavaScript ran in the page's world, so it saw the page's own variable.
    }

    @Test func otherSitesAreLeftAlone() async throws {
        let pool = WebViewPool.forTesting()
        pool.setSiteCustomizations([SiteCustomization(domain: "example.com", css: "#p { color: rgb(255, 0, 0) }", js: "document.title = 'Customized'")])
        let webView = try await load(page, at: "http://notexample.com/", pool: pool)
        #expect(try await run("return getComputedStyle(document.getElementById('p')).color", in: webView) as? String == "rgb(0, 0, 0)")
        try await Task.sleep(for: .milliseconds(200))
        #expect(webView.title == "Page")
    }

    @Test func theMostSpecificSiteWinsAndBrokenCodeStaysContained() async throws {
        let pool = WebViewPool.forTesting()
        pool.setSiteCustomizations([
            SiteCustomization(domain: "example.com", js: "document.title = 'General'"),
            SiteCustomization(domain: "docs.example.com", js: "document.title = 'Specific'"),
            SiteCustomization(domain: "broken.example.com", js: "this is not { javascript"),
            SiteCustomization(domain: "off.example.com", js: "document.title = 'Off'", isEnabled: false),
        ])
        let docs = try await load(page, at: "http://docs.example.com/", pool: pool)
        try await waitUntil("the specific script") { docs.title == "Specific" }

        let off = try await load(page, at: "http://off.example.com/", pool: pool)
        try await waitUntil("the general script") { off.title == "General" }
    }

    @Test func pageSecurityPoliciesDontBlockCustomizations() async throws {
        let pool = WebViewPool.forTesting()
        pool.setSiteCustomizations([SiteCustomization(domain: "example.com", css: "#p { color: rgb(0, 128, 0) }", js: "document.title = 'Ran'")])
        let strict = "<!doctype html><meta http-equiv='Content-Security-Policy' content=\"script-src 'none'; style-src 'none'\"><title>Page</title><p id=p>Hi</p>"
        let webView = try await load(strict, at: "http://example.com/", pool: pool)
        try await waitUntil("the script") { webView.title == "Ran" }
        #expect(try await run("return getComputedStyle(document.getElementById('p')).color", in: webView, world: SiteCustomizationScripts.cssWorld) as? String == "rgb(0, 128, 0)")
    }

    @Test func changesReachLiveWebViewsOnTheirNextLoad() async throws {
        let pool = WebViewPool.forTesting()
        let webView = try await load(page, at: "http://example.com/", pool: pool)
        #expect(webView.title == "Page")

        pool.setSiteCustomizations([SiteCustomization(domain: "example.com", js: "document.title = 'After'")])
        webView.loadHTMLString(page, baseURL: URL(string: "http://example.com/")!)
        try await waitUntil("the new script") { webView.title == "After" }

        pool.setSiteCustomizations([])
        webView.loadHTMLString(page, baseURL: URL(string: "http://example.com/")!)
        try await waitUntil("the page without the script") { webView.title == "Page" }
    }

    @Test func codeIsEmbeddedSafely() {
        // U+2028 ends a line in older JavaScript engines, so it must be escaped.
        #expect(SiteCustomizationScripts.literal("a'b\"c\u{2028}") == #""a'b\"c\u2028""#)
        #expect(SiteCustomizationScripts.literal(["x.com"]) == #"["x.com"]"#)
    }
}
