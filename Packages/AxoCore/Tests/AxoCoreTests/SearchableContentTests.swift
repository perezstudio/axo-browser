import Foundation
import Testing
@testable import AxoCore

struct SearchableContentTests {
    let store: TabStore
    let home: Space

    init() async throws {
        store = try TabStore.makeInMemory()
        home = try await store.bootstrap()
    }

    @Test func pinnedTabsFromEverySpaceAndRecentHistoryAreSearchable() async throws {
        let work = try await store.createSpace(name: "Work", profileID: home.profileID)
        let mail = try await store.openTab(url: URL(string: "https://mail.example.com")!, title: "Mail", in: home.id)
        let docs = try await store.openTab(url: URL(string: "https://docs.example.com")!, title: "Docs", in: work.id)
        _ = try await store.openTab(url: URL(string: "https://unpinned.example.com")!, in: home.id)
        try await store.setPinned(true, tabID: mail.id)
        try await store.setPinned(true, tabID: docs.id)
        for (index, page) in ["https://a.example.com", "https://b.example.com", "https://c.example.com"].enumerated() {
            try await store.history.recordVisit(to: URL(string: page)!, title: page, profileID: home.profileID, at: Date(timeIntervalSince1970: Double(index)))
        }

        let content = try await store.searchableContent(historyLimit: 2)
        #expect(Set(content.pinnedTabs.map(\.tab.id)) == [mail.id, docs.id], "Only pinned tabs")
        #expect(content.pinnedTabs.first { $0.tab.id == docs.id }?.spaceName == "Work")
        #expect(content.history.map { $0.item.url.host() } == ["c.example.com", "b.example.com"], "Newest first, limited")
        #expect(content.history.first?.profileName == TabStore.defaultProfileName)
    }

    @Test func changesAreStreamed() async throws {
        var updates = store.observeSearchableContent().makeAsyncIterator()
        #expect(try await updates.next()?.pinnedTabs.isEmpty == true)
        let tab = try await store.openTab(url: URL(string: "https://example.com")!, title: "Example", in: home.id)
        try await store.setPinned(true, tabID: tab.id)
        var latest = try await updates.next()
        while latest?.pinnedTabs.isEmpty == true { latest = try await updates.next() }
        #expect(latest?.pinnedTabs.map(\.tab.id) == [tab.id])
    }
}
