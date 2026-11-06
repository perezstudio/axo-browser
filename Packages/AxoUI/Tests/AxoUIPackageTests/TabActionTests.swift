import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

/// The tab actions of #81: Duplicate, Copy Link, Move to Space, Close Other Tabs, Close Tabs
/// Below.
@MainActor
struct TabActionTests {
    let engine = FakeEngine()
    let model: BrowserModel

    init() async throws {
        let pool = WebViewPool(engine: engine)
        pool.reportsScreenTimeUsage = false
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: pool)
        model.announce = { _ in }
        model.noticeSleep = { _ in }
        await model.start()
    }

    @discardableResult
    private func open(_ path: String) async throws -> AxoCore.Tab.ID {
        let url = URL(string: "https://example.com/\(path)")!
        await model.openTab(url: url)
        let id = try #require(model.selectedTabID)
        (model.pool.livePage(for: id) as? FakePage)?.navigate(to: url, title: path)
        return id
    }

    private var paths: [String] { model.tabs.filter { !$0.isPinned }.map { $0.url.lastPathComponent } }

    @Test func duplicateOpensACopyBelowWithItsHistory() async throws {
        let a = try await open("a")
        try await open("b")
        let page = try #require(model.pool.livePage(for: a) as? FakePage)
        page.navigate(to: URL(string: "https://example.com/a2")!, title: "A2")

        await model.duplicateTab(a)
        let copy = try #require(model.selectedTabID)
        #expect(copy != a)
        #expect(paths == ["a", "a2", "b"], "Right below, at the page it's on now")
        let copyPage = try #require(model.pool.livePage(for: copy) as? FakePage)
        #expect(copyPage.restoredState == "history:https://example.com/a2", "Its back and forward history came along")
        #expect(copyPage.loads.isEmpty)
    }

    @Test func copyLinkCopiesTheTabsCurrentAddress() async throws {
        var copied: [URL] = []
        model.copyLink = { copied.append($0) }
        let a = try await open("a")
        try await open("b")
        (model.pool.livePage(for: a) as? FakePage)?.navigate(to: URL(string: "https://example.com/a2")!, title: "A2")

        model.copyLink(of: a)
        #expect(copied == [URL(string: "https://example.com/a2")!])
        #expect(model.pageNotice?.message == "Link copied", "Not the selected tab's: shown over the page")
    }

    @Test func moveToSpaceKeepsThePageAndOffersOnlyTheProfilesSpaces() async throws {
        let a = try await open("a")
        try await open("b")
        let home = try #require(model.space)
        await model.createSpace(name: "Work")
        await model.createSpace(name: "Personal", newProfileName: "Personal")
        await model.selectSpace(home.id)
        #expect(model.spacesToMoveTabsTo.map(\.name) == ["Work"], "Another profile's Space isn't offered")
        let work = try #require(model.spacesToMoveTabsTo.first)
        let page = try #require(model.pool.livePage(for: a))

        model.select(a)
        await model.moveTab(a, toSpace: work.id)
        #expect(paths == ["b"])
        #expect(model.selectedTabID != a, "The tab next to it is selected")
        #expect(model.pool.livePage(for: a) === page, "Same profile: the live page carries over")
        #expect(model.pageNotice?.message == "Moved a to Work")

        await model.selectSpace(work.id)
        #expect(paths == ["a"])
    }

    @Test func closeOtherTabsLeavesPinnedTabsAndTheSplit() async throws {
        let pinned = try await open("pinned")
        await model.setPinned(true, tabID: pinned)
        let a = try await open("a")
        let b = try await open("b")
        try await open("c")
        model.select(a)
        await model.addToSplit(b)

        await model.closeOtherTabs(than: a)
        #expect(paths.sorted() == ["a", "b"], "Its split's other pane stays")
        #expect(model.tabs.contains { $0.id == pinned }, "Pinned tabs never close")
        #expect(model.pageNotice?.message == "Closed 1 tab")
        await model.reopenLastClosedTab()
        #expect(paths.contains("c"), "Reopen Closed Tab brings them back")
    }

    @Test func closeTabsBelowClosesOnlyThoseAfterIt() async throws {
        try await open("a")
        let b = try await open("b")
        try await open("c")
        try await open("d")

        await model.closeTabs(below: b)
        #expect(paths == ["a", "b"])
        #expect(model.selectedTabID == b, "The selection was below: the tab it was run on is selected")
        #expect(model.pageNotice?.message == "Closed 2 tabs")
    }

    @Test func theCommandBarOffersTheActionsOnlyWhenTheyDoSomething() async throws {
        try await open("a")
        #expect(model.availableActions.contains(.duplicateTab))
        #expect(!model.availableActions.contains(.closeOtherTabs), "No other tabs")
        #expect(!model.availableActions.contains(.closeTabsBelow))
        let first = try #require(model.selectedTabID)
        try await open("b")
        model.select(first)
        #expect(model.availableActions.contains(.closeOtherTabs))
        #expect(model.availableActions.contains(.closeTabsBelow))
    }
}
