import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

/// The tab bar with tabs at the top (#136) draws the same rows as the sidebar, split into its
/// sections in the sidebar's order: pinned tabs, pinned folders, then the other tabs, a split as
/// one tab.
@MainActor
struct TabBarSectionsTests {
    let model: BrowserModel

    init() async throws {
        let pool = WebViewPool(engine: FakeEngine())
        pool.reportsScreenTimeUsage = false
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: pool)
        model.announce = { _ in }
        await model.start()
    }

    private func open(_ titles: [String]) async throws -> [AxoCore.Tab.ID] {
        for title in titles {
            await model.openTab(url: try #require(URL(string: "data:text/html,<title>\(title)</title>")))
        }
        try await waitUntil { model.tabs.count == titles.count }
        return model.tabs.map(\.id)
    }

    @Test func pinnedTabsFoldersAndTodaysTabsLandInTheirSections() async throws {
        let ids = try await open(["A", "B", "C", "D", "E"])
        await model.setPinned(true, tabID: ids[0])
        await model.setPinned(true, tabID: ids[1])
        await model.createFolder(named: "Reading", moving: .tab(ids[1]))
        try await waitUntil { model.folders.count == 1 && model.tabs.filter(\.isPinned).count == 2 }

        let sections = TabBarSections(try #require(model.shownSpaceRows))
        #expect(sections.pinnedTabs.map(\.id) == [ids[0]], "A pinned tab outside a folder is in the Pinned group")
        #expect(sections.folders.map(\.folder.name) == ["Reading"], "A folder is a collapsed group")
        #expect(sections.folders.first.map { PinnedNode.allTabs(in: $0.children).map(\.id) } == [ids[1]])
        #expect(sections.today.map(\.id) == [ids[2], ids[3], ids[4]], "The other tabs, in order")
    }

    @Test func aSplitIsOneTab() async throws {
        let ids = try await open(["A", "B", "C"])
        model.select(ids[0])
        await model.addToSplit(ids[1])
        try await waitUntil { model.split(of: ids[0]) != nil }

        let sections = TabBarSections(try #require(model.shownSpaceRows))
        #expect(sections.today.count == 2, "The split's two tabs are one row, and C another")
        if case .split(_, let panes) = sections.today.first {
            #expect(Set(panes.map(\.id)) == [ids[0], ids[1]])
        } else {
            Issue.record("The first row is the split")
        }
    }

    @Test func switchingSpacesSwapsTheBarsTabs() async throws {
        _ = try await open(["Home tab"])
        await model.createSpace(name: "Work")
        try await waitUntil { model.spaces.count == 2 }
        let work = try #require(model.spaces.first { $0.name == "Work" })
        await model.selectSpace(work.id)
        try await waitUntil { model.space?.id == work.id }
        #expect(TabBarSections(try #require(model.shownSpaceRows)).today.isEmpty, "Work's bar has none of Home's tabs")
    }
}
