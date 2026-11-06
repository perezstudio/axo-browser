import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

/// Brief notices for actions with no other visible result (#103): which actions post them,
/// where they show, how long they stay, and Undo.
@MainActor
struct NoticeTests {
    let engine = FakeEngine()
    let model: BrowserModel
    /// Every announcement, in order.
    let announcements = Announcements()
    /// Notices' timers, released by the test.
    let timers = Timers()

    @MainActor final class Announcements { var messages: [String] = [] }

    /// Stands in for a notice's time on screen: each wait stays pending until the test ends it.
    @MainActor final class Timers {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        var pending: Int { waiting.count }
        func wait() async { await withCheckedContinuation { waiting.append($0) } }
        /// Ends the oldest pending wait, or every one, and lets the dismissals that follow run.
        func elapse(onlyTheOldest: Bool = false) async {
            let ended = onlyTheOldest ? Array(waiting.prefix(1)) : waiting
            waiting.removeFirst(ended.count)
            ended.forEach { $0.resume() }
            for _ in 0..<5 { await Task.yield() }
        }
    }

    init() async throws {
        let pool = WebViewPool(engine: engine)
        pool.reportsScreenTimeUsage = false
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: pool)
        let announcements = announcements
        model.announce = { announcements.messages.append($0) }
        let timers = timers
        model.noticeSleep = { _ in await timers.wait() }
        model.copyLink = { _ in }
        await model.start()
    }

    private func openPage(_ url: URL, title: String = "Page") async throws -> AxoCore.Tab.ID {
        await model.openTab(url: url)
        let id = try #require(model.selectedTabID)
        (model.pool.livePage(for: id) as? FakePage)?.navigate(to: url, title: title)
        return id
    }

    /// Waits until `count` notice timers are pending.
    private func timerStarted(count: Int = 1) async {
        for _ in 0..<100 where timers.pending < count { await Task.yield() }
    }

    // MARK: Which actions post notices

    @Test func copyLinkShowsInTheAddressBarWhileItsOnScreen() async throws {
        _ = try await openPage(URL(string: "https://example.com/")!)
        model.isSidebarAddressBarOnScreen = true
        model.copyShownPageLink()
        #expect(model.notice?.message == "Link copied")
        #expect(model.addressBarNotice != nil, "Shown in the bar, as in Dia")
        #expect(model.pageNotice == nil, "Not twice")
        #expect(announcements.messages.last == "Link copied", "VoiceOver hears the same thing")
    }

    @Test func copyLinkShowsOverThePageWhenTheBarIsntOnScreen() async throws {
        _ = try await openPage(URL(string: "https://example.com/")!)
        model.isSidebarAddressBarOnScreen = false // hidden, collapsed, or above the page
        model.copyShownPageLink()
        #expect(model.pageNotice?.message == "Link copied")
        #expect(model.addressBarNotice == nil)
    }

    @Test func closingATabOffersUndoThatBringsItBack() async throws {
        let id = try await openPage(URL(string: "https://example.com/")!, title: "Example")
        _ = try await openPage(URL(string: "https://example.org/")!)
        model.select(id)

        await model.closeSelectedTab()
        #expect(!model.tabs.contains { $0.id == id })
        let notice = try #require(model.pageNotice)
        #expect(notice.canUndo)
        #expect(announcements.messages.last?.hasSuffix("Undo is available.") == true)

        await model.undoNotice()
        #expect(model.tabs.contains { $0.id == id }, "Undo restores the tab")
        #expect(model.selectedTabID == id)
        #expect(model.notice?.canUndo != true, "The notice went with the Undo")
    }

    @Test func closesTheEngineAsksForAreOnlyAnnounced() async throws {
        let id = try await openPage(URL(string: "https://example.com/")!)
        await model.closeTab(id) // an extension's chrome.tabs.remove, or the engine
        #expect(model.notice == nil)
        #expect(announcements.messages.last?.hasPrefix("Closed") == true)
    }

    @Test func unloadingAPinnedTabHasNoUndo() async throws {
        let id = try await openPage(URL(string: "https://example.com/")!)
        await model.setPinned(true, tabID: id)
        await model.closeTab(id, byPerson: true)
        #expect(model.notice == nil, "Nothing to undo: it's still in the sidebar")
    }

    @Test func movingToAFolderAndFavoritesPostNotices() async throws {
        let id = try await openPage(URL(string: "https://example.com/")!)
        await model.setPinned(true, tabID: id)
        await model.createFolder(named: "Work")
        let work = try #require(model.folders.first { $0.name == "Work" })
        await model.move(.tab(id), toFolder: work.id)
        #expect(model.pageNotice?.message == "Moved to Work")

        let other = try await openPage(URL(string: "https://example.org/")!, title: "Org")
        await model.addToFavorites(other)
        #expect(model.pageNotice?.message.hasPrefix("Added") == true)
        #expect(model.pageNotice?.message.hasSuffix("to Favorites") == true)
    }

    // MARK: How long they stay

    @Test func aNoticeGoesAfterItsTime() async throws {
        _ = try await openPage(URL(string: "https://example.com/")!)
        model.copyShownPageLink()
        await timerStarted()
        #expect(model.notice != nil)
        await timers.elapse()
        #expect(model.notice == nil)
    }

    @Test func hoveringKeepsItUpUntilThePointerLeaves() async throws {
        _ = try await openPage(URL(string: "https://example.com/")!)
        model.copyShownPageLink()
        await timerStarted()
        let held = try #require(model.notice)
        model.holdNotice(true, id: held.id)
        await timers.elapse()
        #expect(model.notice != nil, "Held while the pointer is over it")

        model.holdNotice(false, id: held.id)
        await timerStarted()
        await timers.elapse()
        #expect(model.notice == nil, "Goes a moment after the pointer leaves")
    }

    @Test func aNewNoticeReplacesTheOldOneAndKeepsItsOwnTime() async throws {
        let id = try await openPage(URL(string: "https://example.com/")!)
        _ = try await openPage(URL(string: "https://example.org/")!)
        model.copyShownPageLink()
        await timerStarted()
        model.select(id)
        await model.closeSelectedTab()
        let closed = try #require(model.notice)
        #expect(closed.message.hasPrefix("Closed"))

        // The first notice's timer ending doesn't take down the second.
        await timerStarted(count: 2)
        await timers.elapse(onlyTheOldest: true)
        #expect(model.notice?.id == closed.id)
        await timers.elapse()
        #expect(model.notice == nil)
    }

    @Test func switchingSpacesDropsAnUndoForTheSpaceLeft() async throws {
        _ = try await openPage(URL(string: "https://example.com/")!)
        _ = try await openPage(URL(string: "https://example.org/")!)
        await model.closeSelectedTab()
        #expect(model.notice?.canUndo == true)

        await model.createSpace(name: "Work")
        #expect(model.notice == nil)
    }

    @Test func aNewNoticeWhereThePointerRestsKeepsItsOwnTime() async throws {
        let id = try await openPage(URL(string: "https://example.com/")!)
        _ = try await openPage(URL(string: "https://example.org/")!)
        model.copyShownPageLink()
        let first = try #require(model.notice)
        model.holdNotice(true, id: first.id) // the pointer rests on it

        // ⌘W with the pointer still there: macOS never says it left the replaced view.
        model.select(id)
        await model.closeSelectedTab()
        let second = try #require(model.notice)
        #expect(second.id != first.id)
        await timerStarted(count: 2)
        await timers.elapse()
        #expect(model.notice == nil, "The old notice's hold doesn't keep the new one up")
    }

    @Test func undoDoesNothingOnceTheTabIsBack() async throws {
        let id = try await openPage(URL(string: "https://example.com/")!)
        _ = try await openPage(URL(string: "https://example.org/")!)
        model.select(id)
        await model.closeSelectedTab()
        let undo = try #require(model.notice?.undo)
        await model.reopenLastClosedTab() // ⇧⌘T first
        let other = try #require(model.tabs.first { $0.id != id }?.id)
        model.select(other)

        await undo()
        #expect(model.selectedTabID == other, "Nothing to undo: it's already back")
        #expect(model.tabs.filter { $0.id == id }.count == 1)
    }

    @Test func undoDoesNothingInAnotherSpace() async throws {
        let id = try await openPage(URL(string: "https://example.com/")!)
        _ = try await openPage(URL(string: "https://example.org/")!)
        model.select(id)
        await model.closeSelectedTab()
        let undo = try #require(model.notice?.undo)

        await model.createSpace(name: "Work")
        await undo()
        #expect(model.space?.name == "Work")
        #expect(model.selectedTabID != id, "Not restored into a Space it isn't in")
        #expect(!model.tabs.contains { $0.id == id })
    }
}
