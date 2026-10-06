import AxoCore
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

@MainActor
struct PeekTests {
    let store: TabStore
    let model: BrowserModel
    let pool: WebViewPool
    let directory: URL
    /// A closed loopback port: Peek's page never loads, and nothing leaves the machine.
    let elsewhere = URL(string: "http://127.0.0.1:9/article")!

    init() async throws {
        store = try TabStore.makeInMemory()
        pool = WebViewPool(makeDataStore: { _ in .nonPersistent() })
        model = BrowserModel(store: store, pool: pool)
        directory = FileManager.default.temporaryDirectory
            .appending(path: "AxoPeekTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await model.start()
        model.announce = { _ in }
    }

    /// A tab on a local page, pinned unless `pinned` is false, and selected.
    private func tab(pinned: Bool = true) async throws -> AxoCore.Tab {
        let url = directory.appending(path: "home.html")
        try "<title>Home</title>".write(to: url, atomically: true, encoding: .utf8)
        let tab = try await store.openTab(url: url, title: "Home", in: try #require(model.space).id)
        if pinned { try await store.setPinned(true, tabID: tab.id) }
        try await waitUntil { model.tabs.contains { $0.id == tab.id } }
        model.select(tab.id)
        return tab
    }

    private func click(_ url: URL, in tab: AxoCore.Tab, modifiers: LinkModifiers = []) -> Bool {
        model.handleLinkClick(LinkClick(tabID: tab.id, url: url, sourceURL: tab.url, modifiers: modifiers))
    }

    @Test func linksToOtherSitesFromPinnedTabsOpenInPeek() async throws {
        let pinned = try await tab()
        #expect(click(elsewhere, in: pinned))
        #expect(model.peek?.tab.url == elsewhere)
        #expect(model.peek?.sourceTabID == pinned.id)
        #expect(model.tabs.count == 1, "Peek isn't in the sidebar")
    }

    @Test func otherClicksNavigateAsUsual() async throws {
        let pinned = try await tab()
        #expect(!click(elsewhere, in: pinned, modifiers: .command), "Modified clicks are the person's choice")
        #expect(!click(URL(string: "mailto:a@example.com")!, in: pinned))
        let unpinned = try await tab(pinned: false)
        #expect(!click(elsewhere, in: unpinned), "Only pinned tabs use Peek")
        #expect(model.peek == nil)
    }

    @Test func newWindowLinksFromPinnedTabsOpenInPeek() async throws {
        let pinned = try await tab()
        pool.onOpenInNewTab?(elsewhere, pinned.id)
        #expect(model.peek?.tab.url == elsewhere)
        #expect(model.tabs.count == 1)

        // A new-window link inside Peek stays in Peek.
        let peekID = try #require(model.peek?.id)
        pool.onOpenInNewTab?(URL(string: "http://127.0.0.1:9/next")!, peekID)
        #expect(model.peek?.id == peekID)
        #expect(model.tabs.count == 1)
    }

    @Test func promotingPeekMakesATabWithTheSameID() async throws {
        let pinned = try await tab()
        model.openPeek(elsewhere, from: pinned.id)
        let peekID = try #require(model.peek?.id)

        await model.promotePeek()
        #expect(model.peek == nil)
        #expect(model.selectedTabID == peekID, "The page carries over under the same ID")
        #expect(model.tabs.first { $0.id == peekID }?.isPinned == false)
    }

    @Test func peekCanOpenInASplitWithItsPinnedTab() async throws {
        let pinned = try await tab()
        model.openPeek(elsewhere, from: pinned.id)
        let peekID = try #require(model.peek?.id)

        await model.promotePeek(inSplit: true)
        let split = try #require(model.selectedSplit)
        #expect(model.panes(of: split.id).map(\.id) == [pinned.id, peekID])
    }

    @Test func closingOrLeavingTheTabClosesPeek() async throws {
        let pinned = try await tab()
        model.openPeek(elsewhere, from: pinned.id)
        model.closePeek()
        #expect(model.peek == nil)

        model.openPeek(elsewhere, from: pinned.id)
        let other = try await tab(pinned: false)
        #expect(model.selectedTabID == other.id)
        #expect(model.peek == nil, "Switching tabs closes Peek")
    }
}
