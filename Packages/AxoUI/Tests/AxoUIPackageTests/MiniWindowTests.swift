import AxoCore
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

@MainActor
struct MiniWindowTests {
    let store: TabStore
    let model: BrowserModel
    let pool: WebViewPool
    /// Mini windows the model asked to show and to close, instead of real windows.
    let windows = Windows()
    /// A closed loopback port: the page never loads, and nothing leaves the machine.
    let link = URL(string: "http://127.0.0.1:9/from-another-app")!

    final class Windows {
        var shown: [MiniWindow] = []
        var dismissed: [MiniWindow.ID] = []
    }

    init() async throws {
        store = try TabStore.makeInMemory()
        pool = WebViewPool(makeDataStore: { _ in .nonPersistent() })
        model = BrowserModel(store: store, pool: pool)
        let windows = windows
        model.presentMiniWindow = { windows.shown.append($0) }
        model.dismissMiniWindow = { windows.dismissed.append($0) }
        await model.start()
    }

    @Test func eachLinkGetsItsOwnMiniWindow() async throws {
        await model.openExternalURL(link)
        await model.openExternalURL(URL(string: "http://127.0.0.1:9/second")!)
        #expect(windows.shown.count == 2)
        #expect(model.miniWindows.map(\.tab.url.lastPathComponent) == ["from-another-app", "second"])
        #expect(model.tabs.isEmpty)
    }

    @Test func openingInAxoMakesATabWithTheSameIDAndClosesTheWindow() async throws {
        await model.openExternalURL(link)
        let id = try #require(model.miniWindows.first?.id)

        await model.openMiniWindowInAxo(id)
        #expect(model.miniWindows.isEmpty)
        #expect(windows.dismissed == [id])
        #expect(model.selectedTabID == id, "The page carries over under the same ID")
        #expect(model.tabs.map(\.id) == [id])
    }

    @Test func closingTheWindowLetsThePageGo() async throws {
        await model.openExternalURL(link)
        let mini = try #require(model.miniWindows.first)
        _ = pool.webView(for: mini.tab, profileID: mini.profileID)
        #expect(pool.isLive(mini.id))

        model.closeMiniWindow(mini.id)
        #expect(model.miniWindows.isEmpty)
        #expect(!pool.isLive(mini.id))
        #expect(model.tabs.isEmpty)
    }

    @Test func newWindowLinksInAMiniWindowStayThere() async throws {
        await model.openExternalURL(link)
        let mini = try #require(model.miniWindows.first)
        pool.onOpenInNewTab?(URL(string: "http://127.0.0.1:9/next")!, mini.id)
        #expect(model.tabs.isEmpty)
        #expect(model.miniWindows.count == 1)
    }

    @Test func miniWindowPagesAreHistoryButNotTabs() async throws {
        await model.openExternalURL(URL(string: "https://example.com/news")!)
        let mini = try #require(model.miniWindows.first)
        pool.onPageChange?(mini.id, URL(string: "https://example.com/news")!, "News")
        try await waitUntilAsync {
            try await store.history.recent(profileID: try #require(model.space).profileID).first?.title == "News"
        }
        #expect(model.tabs.isEmpty)
    }
}
