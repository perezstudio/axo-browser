import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

/// What sidebar rows show about their pages: a spinner while loading (#70), dimmed without a
/// live page (#72), and the matching VoiceOver values.
@MainActor
struct TabRowStateTests {
    let engine = FakeEngine()
    let model: BrowserModel

    init() async throws {
        let pool = WebViewPool(engine: engine)
        pool.reportsScreenTimeUsage = false
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: pool)
        model.announce = { _ in }
        await model.start()
    }

    /// Lets the pool's liveness, which follows a turn later, land.
    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    private func open(_ url: String) async throws -> (AxoCore.Tab.ID, FakePage) {
        await model.openTab(url: URL(string: url)!)
        let id = try #require(model.selectedTabID)
        let page = try #require(model.pool.livePage(for: id) as? FakePage)
        await settle()
        return (id, page)
    }

    @Test func theLoadingFlagFollowsThePage() async throws {
        let (id, page) = try await open("https://example.com/")
        #expect(!model.isTabLoading(id))

        page.isLoading = true
        page.delegate?.pageStateDidChange(page)
        #expect(model.isTabLoading(id))

        // Engines report loading changes as state changes (WebKit's KVO, Chromium's delegate).
        page.isLoading = false
        page.delegate?.pageStateDidChange(page)
        #expect(!model.isTabLoading(id))
    }

    @Test func aTabWithoutAPageNeverSpinsAndIsDimmed() async throws {
        let (first, firstPage) = try await open("https://example.com/")
        let (second, _) = try await open("https://example.org/")
        #expect(!model.isTabDimmed(second, isSelected: true), "The selected row is never dimmed")
        #expect(!model.isTabDimmed(first, isSelected: false), "Live in the background")

        // Closed mid-load: its last state said loading, but without a page it never spins.
        firstPage.isLoading = true
        firstPage.delegate?.pageStateDidChange(firstPage)
        #expect(model.isTabLoading(first))
        model.pool.discard(first)
        await settle()
        #expect(model.isTabDimmed(first, isSelected: false))
        #expect(!model.isTabLoading(first))
    }

    @Test func unloadingAPinnedTabDimsItUntilItsSelectedAgain() async throws {
        let (pinned, _) = try await open("https://example.com/")
        await model.setPinned(true, tabID: pinned)
        _ = try await open("https://example.org/")
        await model.closeTab(pinned, byPerson: true) // Unload Tab
        await settle()
        #expect(model.pinnedTree.contains { if case .tab(let tab) = $0 { tab.id == pinned } else { false } }, "Still in the sidebar")
        #expect(model.isTabDimmed(pinned, isSelected: false))

        model.select(pinned)
        await settle()
        #expect(model.isTabLive(pinned), "Selecting loads it again")
        #expect(!model.isTabDimmed(pinned, isSelected: false), "Live again: not dimmed even once it's left")
    }

    @Test func voiceOverHearsTheRowsState() {
        #expect(TabRow.stateDescription(isLoading: false, isDimmed: false) == "")
        #expect(TabRow.stateDescription(isLoading: true, isDimmed: false) == "Loading")
        #expect(TabRow.stateDescription(isLoading: false, isDimmed: true, isAwayFromHome: true) == "Unloaded, Away from pinned page")
    }

    @Test func aSplitRowHoldsTheSelectionForAnyPane() async throws {
        let (first, _) = try await open("https://example.com/")
        let (second, _) = try await open("https://example.org/")
        model.select(first)
        await model.addToSplit(second)
        let row = try #require(model.tabs.first { $0.id == first })
        model.select(second)
        #expect(model.rowHoldsSelection(row), "The split's row stands for both panes")
    }

    /// A pinned tab away from its pinned page names both pages in its tooltip (#73); on its
    /// pinned page, or unpinned, only its title.
    @Test func awayFromItsPinnedPageTheTooltipNamesBothPages() {
        var tab = AxoCore.Tab(id: UUID(), spaceID: UUID(), url: URL(string: "https://news.example/story")!,
                              title: "A Story", sortKey: "a", isPinned: true,
                              homeURL: URL(string: "https://start.example/")!)
        #expect(tab.hasLeftHome)
        #expect(TabRow.tooltip(for: tab) == "A Story\nPinned page: start.example")
        #expect(TabRow.stateDescription(isLoading: false, isDimmed: false, isAwayFromHome: tab.hasLeftHome) == "Away from pinned page")

        let markup = String(repeating: "<p>pond</p>", count: 100)
        var dataPage = tab
        dataPage.homeURL = URL(string: "data:text/html,\(markup)")!
        let shown = TabRow.tooltip(for: dataPage)
        #expect(shown.count < 120, "A page without a site shows only the start of its address")
        #expect(shown.hasPrefix("A Story\nPinned page: data:text/html,"))

        tab.url = URL(string: "https://start.example/")!
        #expect(TabRow.tooltip(for: tab) == "A Story", "On its pinned page")
        tab.isPinned = false
        tab.url = URL(string: "https://news.example/story")!
        #expect(TabRow.tooltip(for: tab) == "A Story", "Not pinned")
    }
}
