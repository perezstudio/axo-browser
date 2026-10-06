import AxoCore
import Foundation
import Testing
import WebKit
@testable import AxoWeb

@MainActor
struct WebStoreTests {
    let id = "ddkjiahejlhfcafbddmgiahcphecmpfh"
    let profileID = UUID()

    @Test func storeDetailPagesNameTheirExtension() {
        #expect(WebStore.extensionID(fromPageURL: URL(string: "https://chromewebstore.google.com/detail/ublock-origin-lite/\(id)")!) == id)
        #expect(WebStore.extensionID(fromPageURL: URL(string: "https://chromewebstore.google.com/detail/\(id)")!) == id)
        #expect(WebStore.extensionID(fromPageURL: URL(string: "https://chromewebstore.google.com/category/extensions")!) == nil)
        #expect(WebStore.extensionID(fromPageURL: URL(string: "https://example.com/detail/x/\(id)")!) == nil)
        #expect(WebStore.extensionID(fromPageURL: URL(string: "http://chromewebstore.google.com/detail/x/\(id)")!) == nil)
        #expect(WebStore.isValidExtensionID(id))
        #expect(!WebStore.isValidExtensionID("zzkjiahejlhfcafbddmgiahcphecmpfh"))
        #expect(!WebStore.isValidExtensionID("short"))
    }

    /// Loads `body` as if it came from `url`, without the network (a base URL only sets the
    /// page's address and origin).
    private func load(_ body: String, at url: String, pool: WebViewPool) async throws -> WKWebView {
        let tab = Tab.testTab(url: URL(string: "about:blank")!)
        let webView = pool.webView(for: tab, profileID: profileID)
        webView.loadHTMLString("<!doctype html><meta charset=utf-8><body>\(body)</body>", baseURL: URL(string: url)!)
        try await waitUntil("page") { webView.url?.absoluteString == url && !webView.isLoading }
        return webView
    }

    private func axoButton(in webView: WKWebView, _ property: String) async throws -> String? {
        try await webView.evaluateJavaScript("document.querySelector('button[data-axo]')?.\(property) ?? null") as? String
    }

    @Test func theButtonSitsBesideTheStoresInstallButton() async throws {
        let pool = WebViewPool.forTesting()
        let webView = try await load("<div><h1>uBlock</h1><button>Add to Chrome</button></div>",
                                     at: "https://chromewebstore.google.com/detail/ublock/\(id)", pool: pool)
        try await waitUntilAsync("button") { try await axoButton(in: webView, "textContent") == "Add to Axo" }
        #expect(try await axoButton(in: webView, "nextElementSibling.textContent") == "Add to Chrome")
        #expect(try await axoButton(in: webView, "dataset.floating") == nil)
    }

    @Test func withoutTheStoresButtonItFloats() async throws {
        let pool = WebViewPool.forTesting()
        let webView = try await load("<h1>uBlock</h1>", at: "https://chromewebstore.google.com/detail/ublock/\(id)", pool: pool)
        try await waitUntilAsync("button") { try await axoButton(in: webView, "dataset.floating") == "1" }
    }

    @Test func otherSitesAndStorePagesDontGetIt() async throws {
        let pool = WebViewPool.forTesting()
        let elsewhere = try await load("<button>Add to Chrome</button>", at: "https://example.com/detail/ublock/\(id)", pool: pool)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await axoButton(in: elsewhere, "textContent") == nil)

        let store = try await load("<button>Add to Chrome</button>", at: "https://chromewebstore.google.com/detail/ublock/\(id)", pool: pool)
        try await waitUntilAsync("button") { try await axoButton(in: store, "textContent") != nil }
        // The store moves between pages without loading; leaving a detail page removes it.
        _ = try await store.evaluateJavaScript("history.pushState({}, '', '/category/extensions'); document.body.append(document.createElement('p')); 1")
        try await waitUntilAsync("removed") { try await axoButton(in: store, "textContent") == nil }
    }

    @Test func onlyRealClicksFromTheStoreInstall() async throws {
        let pool = WebViewPool.forTesting()
        var installs: [String] = []
        pool.onWebStoreInstall = { id, _ in installs.append(id) }
        let store = try await load("<button>Add to Chrome</button>", at: "https://chromewebstore.google.com/detail/ublock/\(id)", pool: pool)
        try await waitUntilAsync("button") { try await axoButton(in: store, "textContent") != nil }

        // A click the page fakes isn't trusted, so nothing happens.
        _ = try await store.evaluateJavaScript("document.querySelector('button[data-axo]').click(); 1")
        try await Task.sleep(for: .milliseconds(200))
        #expect(installs.isEmpty)

        // The button's own message, from the store's main frame, installs.
        _ = try await store.callAsyncJavaScript("window.webkit.messageHandlers.axoWebStore.postMessage(id)", arguments: ["id": id], contentWorld: WebStore.world)
        try await waitUntil("install") { installs == [id] }

        // The same message from another site, or with a bad ID, is ignored.
        let elsewhere = try await load("", at: "https://example.com/detail/ublock/\(id)", pool: pool)
        _ = try await elsewhere.callAsyncJavaScript("window.webkit.messageHandlers.axoWebStore.postMessage(id)", arguments: ["id": id], contentWorld: WebStore.world)
        _ = try await store.callAsyncJavaScript("window.webkit.messageHandlers.axoWebStore.postMessage('not-an-id')", arguments: [:], contentWorld: WebStore.world)
        try await Task.sleep(for: .milliseconds(200))
        #expect(installs == [id])
    }

    @Test func pageScriptsCantReachTheHandler() async throws {
        let pool = WebViewPool.forTesting()
        let store = try await load("", at: "https://chromewebstore.google.com/detail/ublock/\(id)", pool: pool)
        let visible = try await store.evaluateJavaScript("typeof window.webkit?.messageHandlers?.axoWebStore") as? String
        #expect(visible == "undefined")
    }
}

/// Polls an async condition until it's true, or fails after 10 seconds.
@MainActor
private func waitUntilAsync(_ what: String, _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while try await !condition() {
        try #require(ContinuousClock.now < deadline, "Timed out waiting for \(what)")
        try await Task.sleep(for: .milliseconds(50))
    }
}
