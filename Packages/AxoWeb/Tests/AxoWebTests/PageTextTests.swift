import AxoCore
import Foundation
import Testing
import WebKit
@testable import AxoWeb

@MainActor
struct PageTextTests {
    let pages: TestPages
    let profileID = UUID()

    init() throws {
        pages = try TestPages()
    }

    private func load(_ body: String) async throws -> (WebViewPool, Tab) {
        let pool = WebViewPool.forTesting()
        // Declare UTF-8; without it WebKit reads the file's accented text as Latin-1.
        let tab = Tab.testTab(url: try pages.page("Text", body: "<meta charset=utf-8>" + body))
        _ = pool.webView(for: tab, profileID: profileID)
        try await waitUntil("the page") { pool.state(for: tab.id)?.title == "Text" && pool.state(for: tab.id)?.isLoading == false }
        return (pool, tab)
    }

    private func bodyText(_ pool: WebViewPool, _ tab: Tab) async throws -> String {
        try await pool.liveWebView(for: tab.id)!.callAsyncJavaScript("return document.body.innerText", contentWorld: .page) as? String ?? ""
    }

    @Test func visibleTextIsCollectedInOrderSkippingCode() async throws {
        let (pool, tab) = try await load("<h1>Hola</h1><p> Buenos días </p><script>var x = 1</script><code>let y</code><p>Adiós</p>")
        let segments = try await pool.pageTextSegments(in: tab.id)
        #expect(segments == ["Hola", "Buenos días", "Adiós"])
        #expect(try await pool.pageTextSegments(in: tab.id, limit: 2) == ["Hola", "Buenos días"])
    }

    @Test func textIsReplacedAndRestored() async throws {
        let (pool, tab) = try await load("<h1>Hola</h1><p>Buenos días</p>")
        _ = try await pool.pageTextSegments(in: tab.id)
        try await pool.replacePageText(["Hello", "Good morning"], in: tab.id)
        #expect(try await bodyText(pool, tab) == "Hello\n\nGood morning")

        try await pool.restorePageText(in: tab.id)
        #expect(try await bodyText(pool, tab) == "Hola\n\nBuenos días")
    }

    @Test func readableTextIsTrimmedForSummaries() async throws {
        let (pool, tab) = try await load("<h1>Title</h1><p>\(String(repeating: "word ", count: 50))</p>")
        let text = try await pool.readablePageText(in: tab.id)
        #expect(text.hasPrefix("Title"))
        #expect(try await pool.readablePageText(in: tab.id, limit: 20).count == 20)
    }

    @Test func pagesCantSeeTheHelpers() async throws {
        let (pool, tab) = try await load("<p>Hola</p>")
        _ = try await pool.pageTextSegments(in: tab.id)
        let visible = try await pool.liveWebView(for: tab.id)!.callAsyncJavaScript("return typeof window.axoTextNodes", contentWorld: .page) as? String
        #expect(visible == "undefined", "The helpers live in an isolated world")
    }
}
