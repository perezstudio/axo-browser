import AxoCore
import Foundation
import Testing
@testable import AxoIntegration

/// An index that keeps entries in memory instead of writing to Spotlight.
actor FakeSpotlightIndex: SpotlightIndex {
    var domains: [String: [SpotlightEntry]] = [:]
    var replacements = 0

    func replace(domain: String, with entries: [SpotlightEntry]) async throws {
        domains[domain] = entries
        replacements += 1
    }
}

@MainActor
struct SpotlightTests {
    let store: TabStore
    let home: Space

    init() async throws {
        store = try TabStore.makeInMemory()
        home = try await store.bootstrap()
    }

    @Test func pinnedTabsAndHistoryBecomeEntries() async throws {
        let tab = try await store.openTab(url: URL(string: "https://mail.example.com")!, title: "Mail", in: home.id)
        try await store.setPinned(true, tabID: tab.id)
        try await store.history.recordVisit(to: URL(string: "https://mail.example.com")!, title: "Mail", profileID: home.profileID)
        try await store.history.recordVisit(to: URL(string: "https://news.example.com/a")!, title: "", profileID: home.profileID)
        let content = try await store.searchableContent()

        let pinned = SpotlightIndexer.pinnedEntries(content)
        #expect(pinned.map(\.title) == ["Mail"])
        #expect(pinned.first?.detail == "Pinned in Home")
        #expect(pinned.first.flatMap { SpotlightTarget(identifier: $0.identifier) } == .tab(tab.id))

        let history = SpotlightIndexer.historyEntries(content)
        #expect(history.map(\.title) == ["news.example.com"], "Pages already pinned aren't listed twice; untitled pages use their host")
        #expect(history.first.flatMap { SpotlightTarget(identifier: $0.identifier) } == .page(URL(string: "https://news.example.com/a")!))
    }

    @Test func identifiersThatArentAxosAreIgnored() {
        #expect(SpotlightTarget(identifier: "tab:not-a-uuid") == nil)
        #expect(SpotlightTarget(identifier: "something-else") == nil)
    }

    @Test func theIndexFollowsChangesAfterAShortDelay() async throws {
        let index = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(store: store, index: index, delay: .milliseconds(50))
        indexer.start()
        defer { indexer.stop() }

        let tab = try await store.openTab(url: URL(string: "https://docs.example.com")!, title: "Docs", in: home.id)
        try await store.setPinned(true, tabID: tab.id)

        let deadline = ContinuousClock.now + .seconds(5)
        while await index.domains[SpotlightIndexer.pinnedTabsDomain]?.map(\.title) != ["Docs"] {
            try #require(ContinuousClock.now < deadline, "Timed out")
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await index.domains[SpotlightIndexer.historyDomain] == [])
    }
}
