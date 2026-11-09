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
        #expect(model.selectedTabID == model.tabs.first?.id, "The tab next to it, b, is selected")
        #expect(model.pool.livePage(for: a) === page, "Same profile: the live page carries over")
        #expect(model.pageNotice?.message == "Moved a to Work")

        await model.selectSpace(work.id)
        #expect(paths == ["a"])
    }

    @Test func closingSeveralTabsCanBeUndoneInTheirOrder() async throws {
        let names = ["a", "b", "c", "d", "e", "f"]
        var ids: [AxoCore.Tab.ID] = []
        for name in names { ids.append(try await open(name)) }
        model.select(ids[0])

        await model.closeTabs(below: ids[0])
        #expect(paths == ["a"])
        #expect(model.notice?.message == "Closed 5 tabs")
        let undo = try #require(model.notice?.undo)
        // One of them is reopened meanwhile; Undo brings back the rest, in their order.
        await model.restoreTab(ids[3])
        model.select(ids[0])
        await undo()
        #expect(paths == ["a", "d", "b", "c", "e", "f"])
        #expect(model.selectedTabID == ids[0], "The selection stays")
    }

    @Test func reopeningTabsClosedTogetherKeepsTheirOrder() async throws {
        var ids: [AxoCore.Tab.ID] = []
        for name in ["a", "b", "c", "d", "e", "f"] { ids.append(try await open(name)) }
        await model.closeOtherTabs(than: ids[0])
        for _ in 0..<5 { await model.reopenLastClosedTab() }
        #expect(paths == ["a", "b", "c", "d", "e", "f"])
    }

    @Test func theTabsMenuActsOnATabRowNotOnASelectedFolder() async throws {
        let tab = try await open("a")
        #expect(model.tabForTabActions?.id == tab)
        await model.createFolder(named: "Work")
        let folder = try #require(model.folders.first)
        model.selectSidebarItem(.folder(folder.id))
        #expect(model.selectedTabID == tab, "The page keeps showing")
        #expect(model.tabForTabActions == nil, "But the folder is what's selected")
    }

    @Test func aMovedTabLeavesTheEnginesWindowAndItsNeighborIsActive() async throws {
        let a = try await open("a")
        let b = try await open("b")
        let home = try #require(model.space)
        await model.createSpace(name: "Work")
        let work = try #require(model.space)
        await model.selectSpace(home.id)
        model.select(b)

        await model.moveTab(b, toSpace: work.id)
        let window = try #require(engine.windowPages[home.profileID])
        let pageA = try #require(model.pool.livePage(for: a))
        let pageB = try #require(model.pool.livePage(for: b))
        #expect(!window.pages.contains { $0 === pageB }, "Gone from this Space's window")
        #expect(window.active === pageA, "Its neighbor is the active tab extensions see")
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

    @Test func duplicatingASplitPaneKeepsTheSplitTogether() async throws {
        let a = try await open("a")
        let b = try await open("b")
        try await open("c")
        model.select(a)
        await model.addToSplit(b)

        await model.duplicateTab(a)
        let copy = try #require(model.selectedTabID)
        let order = model.tabs.filter { !$0.isPinned }.map(\.id)
        let split = try #require(model.split(of: a))
        let paneIndexes = model.panes(of: split.id).compactMap { pane in order.firstIndex(of: pane.id) }
        #expect(paneIndexes.max()! - paneIndexes.min()! == 1, "The split's tabs stay next to each other")
        #expect(order.firstIndex(of: copy)! == paneIndexes.max()! + 1, "The copy goes right below the split")

        // Close Tabs Below on the copy leaves the split above alone.
        await model.closeTabs(below: copy)
        #expect(model.split(of: a) != nil)
        #expect(paths.count == 3, "Only c closed")
        #expect(!paths.contains("c"))
    }

    @Test func duplicatingGoesBelowASplitWhoseFirstRowIsItsLastPane() async throws {
        let a = try await open("a")
        let b = try await open("b")
        try await open("c")
        model.select(a)
        await model.addToSplit(b)
        let split = try #require(model.split(of: a))
        let lastPane = try #require(model.panes(of: split.id).last?.id)
        // The split's last pane moved to the top: it now comes first in the sidebar.
        try await model.store.moveTab(id: lastPane, to: .start)
        model.tabs = try await model.store.tabs(in: try #require(model.space).id)

        await model.duplicateTab(a)
        let copy = try #require(model.selectedTabID)
        let order = model.tabs.filter { !$0.isPinned }.map(\.id)
        let paneIndexes = model.panes(of: split.id).compactMap { pane in order.firstIndex(of: pane.id) }
        #expect(paneIndexes.max()! - paneIndexes.min()! == 1, "Not between the split's tabs")
        #expect(order.firstIndex(of: copy)! == paneIndexes.max()! + 1, "Right below the split")
    }

    @Test func closeTabsBelowASplitRowClosesWhatsBelowIt() async throws {
        let a = try await open("a")
        let b = try await open("b")
        try await open("c")
        model.select(a)
        await model.addToSplit(b)
        await model.closeTabs(below: a)
        #expect(paths.sorted() == ["a", "b"])
    }

    @Test func closeOthersIsntForAPinnedTab() async throws {
        let pinned = try await open("pinned")
        await model.setPinned(true, tabID: pinned)
        try await open("a")
        try await open("b")
        model.select(pinned)

        #expect(model.otherUnpinnedTabs(than: pinned).isEmpty)
        #expect(!model.availableActions.contains(.closeOtherTabs))
        await model.closeOtherTabs(than: pinned)
        #expect(paths == ["a", "b"], "Nothing closed")
    }

    @Test func moveToSpaceIsntForASplitPane() async throws {
        let a = try await open("a")
        let b = try await open("b")
        await model.createSpace(name: "Work")
        let work = try #require(model.space)
        await model.selectSpace(try #require(model.spaces.first { $0.name != "Work" }).id)
        model.select(a)
        await model.addToSplit(b)

        #expect(!model.canMoveToSpace(a))
        await model.moveTab(a, toSpace: work.id)
        #expect(model.split(of: a) != nil, "Not broken up")
    }
}
