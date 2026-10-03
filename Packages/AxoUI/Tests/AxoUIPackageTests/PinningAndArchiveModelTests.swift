import AxoCore
import AxoWeb
import Foundation
import Testing
@testable import AxoUI

/// A clock tests can move forward.
@MainActor
final class ModelClock {
    var now = Date()
    func advance(hours: Double) { now += hours * 3600 }
}

@MainActor
struct PinningAndArchiveModelTests {
    let clock = ModelClock()
    let store: TabStore
    let pool: WebViewPool
    let model: BrowserModel
    let directory: URL

    init() async throws {
        store = try TabStore.makeInMemory()
        pool = WebViewPool(makeDataStore: { _ in .nonPersistent() })
        let clock = clock
        model = BrowserModel(store: store, pool: pool, now: { clock.now })
        model.archiveCheckInterval = .seconds(3600)
        directory = FileManager.default.temporaryDirectory
            .appending(path: "AxoPinTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await model.start()
    }

    private func page(_ name: String) throws -> URL {
        let url = directory.appending(path: "\(name).html")
        try "<title>\(name)</title>".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Opens tabs and waits for each page to load, so a load can't overwrite a test's later
    /// changes to the tab.
    private func open(_ names: [String]) async throws -> [AxoCore.Tab] {
        for name in names {
            await model.openTab(url: try page(name))
            try await waitUntil { model.selectedPage?.title == name && model.selectedPage?.isLoading == false }
        }
        return model.tabs
    }

    private func names(_ tabs: [AxoCore.Tab]) -> [String] {
        tabs.map { $0.url.deletingPathExtension().lastPathComponent }
    }

    @Test func pinningMovesATabIntoThePinnedSection() async throws {
        let tabs = try await open(["a", "b", "c"])
        await model.setPinned(true, tabID: tabs[1].id)

        #expect(names(model.pinnedTabs) == ["b"])
        #expect(names(model.unpinnedTabs) == ["a", "c"])
        #expect(model.pinnedTabs.first?.homeURL == tabs[1].url)

        await model.setPinned(false, tabID: tabs[1].id)
        #expect(model.pinnedTabs.isEmpty)
    }

    @Test func closingAnUnpinnedTabArchivesItAndReopenBringsItBack() async throws {
        let tabs = try await open(["a", "b"])
        await model.closeTab(tabs[1].id)

        #expect(names(model.tabs) == ["a"])
        #expect(names(await model.archivedTabs()) == ["b"])

        await model.reopenLastClosedTab()
        #expect(names(model.tabs) == ["a", "b"])
        #expect(model.selectedTabID == tabs[1].id)
        #expect(await model.archivedTabs().isEmpty)
    }

    @Test func closingAPinnedTabUnloadsItAndReturnsHome() async throws {
        let tabs = try await open(["home", "other"])
        await model.setPinned(true, tabID: tabs[0].id)
        let pinnedID = tabs[0].id
        model.select(pinnedID)
        try await store.updateTab(id: pinnedID, url: try page("elsewhere"), title: "Elsewhere")
        try await waitUntil { model.pinnedTabs.first?.hasLeftHome == true }
        #expect(pool.isLive(pinnedID))

        await model.closeTab(pinnedID)

        #expect(model.pinnedTabs.map(\.id) == [pinnedID], "The pinned tab stays in the sidebar")
        #expect(model.pinnedTabs.first?.url == tabs[0].url, "and points at its home page again")
        #expect(!pool.isLive(pinnedID))
        #expect(model.selectedTabID == tabs[1].id)
        #expect(await model.archivedTabs().isEmpty)
    }

    @Test func pinnedHomeCanBeReplacedWithTheCurrentPage() async throws {
        let tab = try await open(["home"])[0]
        await model.setPinned(true, tabID: tab.id)
        let elsewhere = try page("elsewhere")
        try await store.updateTab(id: tab.id, url: elsewhere, title: "Elsewhere")
        try await waitUntil { model.pinnedTabs.first?.url == elsewhere }

        await model.makeCurrentPagePinnedHome(tab.id)

        #expect(model.pinnedTabs.first?.homeURL == elsewhere)
        #expect(model.pinnedTabs.first?.hasLeftHome == false)
    }

    @Test func idleUnpinnedTabsArchiveButTheSelectedAndPinnedOnesStay() async throws {
        let tabs = try await open(["idle", "pinned", "selected"])
        await model.setPinned(true, tabID: tabs[1].id)
        model.select(tabs[2].id)
        try await Task.sleep(for: .milliseconds(100))  // let activity writes land

        clock.advance(hours: 13)
        await model.archiveInactiveTabs()

        #expect(names(model.tabs) == ["pinned", "selected"])
        #expect(names(await model.archivedTabs()) == ["idle"])
        #expect(!pool.isLive(tabs[0].id))
    }

    @Test func recentlyShownTabsDoNotArchive() async throws {
        let tabs = try await open(["a", "b"])
        clock.advance(hours: 11)
        model.select(tabs[0].id)   // marks "a" (and the previously selected "b") active now
        try await Task.sleep(for: .milliseconds(100))

        clock.advance(hours: 11)
        await model.archiveInactiveTabs()

        #expect(names(model.tabs) == ["a", "b"], "Both were shown 11 hours ago, under the 12-hour limit")
    }

    @Test func dragsReorderWithinASection() async throws {
        let tabs = try await open(["p1", "p2", "a", "b"])
        await model.setPinned(true, tabID: tabs[0].id)
        await model.setPinned(true, tabID: tabs[1].id)

        await model.moveTabs(fromOffsets: IndexSet(integer: 1), toOffset: 0, pinned: true)
        await model.moveTabs(fromOffsets: IndexSet(integer: 0), toOffset: 2, pinned: false)

        #expect(names(model.pinnedTabs) == ["p2", "p1"])
        #expect(names(model.unpinnedTabs) == ["b", "a"])
    }
}
