import AxoPersistence
import Foundation
import GRDB
import Testing
@testable import AxoCore

struct PinningAndArchiveTests {
    let store: TabStore
    let space: Space

    init() async throws {
        store = try TabStore.makeInMemory()
        space = try await store.bootstrap()
    }

    private func url(_ path: String) -> URL { URL(string: "https://example.com/\(path)")! }

    private func open(_ names: [String]) async throws -> [Tab] {
        var tabs: [Tab] = []
        for name in names {
            tabs.append(try await store.openTab(url: url(name), title: name, in: space.id))
        }
        return tabs
    }

    private func titles() async throws -> [String] {
        try await store.tabs(in: space.id).map(\.title)
    }

    // MARK: Pinning

    @Test func pinnedTabsComeFirstInTheirOwnOrder() async throws {
        let tabs = try await open(["a", "b", "c", "d"])
        try await store.setPinned(true, tabID: tabs[2].id)
        try await store.setPinned(true, tabID: tabs[0].id)

        #expect(try await titles() == ["c", "a", "b", "d"])
        try await store.openTab(url: url("e"), title: "e", in: space.id, at: .start)
        #expect(try await titles() == ["c", "a", "e", "b", "d"], "New tabs go in the unpinned section")
    }

    @Test func pinningRemembersTheHomePageAndUnpinningForgetsIt() async throws {
        let tab = try await open(["home"])[0]
        try await store.setPinned(true, tabID: tab.id)
        var pinned = try #require(try await store.tab(id: tab.id))
        #expect(pinned.isPinned && pinned.homeURL == url("home"))

        try await store.updateTab(id: tab.id, url: url("elsewhere"), title: "Elsewhere")
        pinned = try #require(try await store.tab(id: tab.id))
        #expect(pinned.hasLeftHome)

        try await store.setPinned(false, tabID: tab.id)
        let unpinned = try #require(try await store.tab(id: tab.id))
        #expect(!unpinned.isPinned && unpinned.homeURL == nil && !unpinned.hasLeftHome)
    }

    @Test func resettingAPinnedTabReturnsToItsHomePage() async throws {
        let tab = try await open(["home"])[0]
        try await store.setPinned(true, tabID: tab.id)
        try await store.updateTab(id: tab.id, url: url("elsewhere"), title: "Elsewhere")

        #expect(try await store.resetPinnedTab(id: tab.id) == url("home"))
        let reset = try #require(try await store.tab(id: tab.id))
        #expect(reset.url == url("home") && reset.title == "")

        let unpinned = try await open(["loose"])[0]
        #expect(try await store.resetPinnedTab(id: unpinned.id) == nil)
    }

    @Test func homeCanBeChangedToTheCurrentPage() async throws {
        let tab = try await open(["home"])[0]
        try await store.setPinned(true, tabID: tab.id)
        try await store.setHomeURL(url("new-home"), tabID: tab.id)
        #expect(try await store.tab(id: tab.id)?.homeURL == url("new-home"))
    }

    @Test func movesStayWithinASection() async throws {
        let tabs = try await open(["p", "a", "b"])
        try await store.setPinned(true, tabID: tabs[0].id)

        try await store.moveTab(id: tabs[2].id, to: .start)
        #expect(try await titles() == ["p", "b", "a"])
        await #expect(throws: TabStoreError.anchorInDifferentSection(tabs[0].id)) {
            try await store.moveTab(id: tabs[1].id, to: .after(tabs[0].id))
        }
    }

    // MARK: Archiving

    @Test func archivedTabsLeaveTheSidebarAndRestoreAtTheEnd() async throws {
        let tabs = try await open(["a", "b", "c"])
        try await store.archiveTab(id: tabs[0].id, at: Date(timeIntervalSince1970: 100))
        try await store.archiveTab(id: tabs[1].id, at: Date(timeIntervalSince1970: 200))
        #expect(try await titles() == ["c"])
        #expect(try await store.archivedTabs(in: space.id).map(\.title) == ["b", "a"], "Newest first")

        let restored = try await store.restoreTab(id: tabs[0].id)
        #expect(restored.archivedAt == nil)
        #expect(try await titles() == ["c", "a"])
    }

    @Test func idleUnpinnedTabsArchiveButPinnedAndKeptTabsStay() async throws {
        let old = Date(timeIntervalSinceNow: -48 * 3600)
        let tabs = try await open(["idle", "pinned", "visible", "fresh"])
        for tab in tabs.prefix(3) {
            try await store.markActive(id: tab.id, at: old)
        }
        try await store.setPinned(true, tabID: tabs[1].id)

        let archived = try await store.archiveInactiveTabs(
            lastActiveBefore: Date(timeIntervalSinceNow: -12 * 3600),
            keeping: [tabs[2].id]
        )

        #expect(archived == [tabs[0].id])
        #expect(try await titles() == ["pinned", "visible", "fresh"])
    }

    @Test func archivingTwiceKeepsTheFirstDate() async throws {
        let tab = try await open(["a"])[0]
        let first = Date(timeIntervalSince1970: 1_000)
        try await store.archiveTab(id: tab.id, at: first)
        try await store.archiveTab(id: tab.id, at: Date(timeIntervalSince1970: 2_000))
        #expect(try await store.tab(id: tab.id)?.archivedAt == first)
    }
}
