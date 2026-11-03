import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoWeb

/// Hibernation on engines that can discard a page (Chromium): the page is kept, with its history
/// and its place in the engine's window, so extensions still see the tab.
@MainActor
struct DiscardTests {
    let engine = FakeEngine()
    let pool: WebViewPool
    let profileID = UUID()
    let tab = Tab.testTab(url: URL(string: "https://example.com/start")!)

    init() {
        pool = WebViewPool.withFakeEngine(engine)
    }

    /// A loaded tab whose page can be discarded, with a snapshot ready.
    private func loadedPage() throws -> FakePage {
        pool.page(for: tab, profileID: profileID)
        let page = try #require(engine.pages.last)
        page.canDiscard = true
        page.snapshotImage = SnapshotTimingTests.image(width: 40, height: 30, red: 1, green: 0, blue: 0)
        page.navigate(to: URL(string: "https://example.com/second")!, title: "Second")
        page.finishLoad()
        return page
    }

    @Test func hibernatingDiscardsThePageAndKeepsIt() async throws {
        let page = try loadedPage()

        #expect(await pool.hibernate(tab.id))
        #expect(page.isDiscarded)
        #expect(!page.isClosed, "The engine keeps it, with its history")
        #expect(pool.isHibernated(tab.id))
        #expect(!pool.isLive(tab.id))
        #expect(pool.snapshot(for: tab.id) != nil)
    }

    @Test func wakingLoadsTheSamePageAgainAndShowsItsSnapshot() async throws {
        let page = try loadedPage()
        #expect(await pool.hibernate(tab.id))

        let woken = pool.page(for: tab, profileID: profileID)
        #expect(woken === page, "No new page: its history is still in it")
        #expect(engine.pages.count == 1)
        #expect(page.discardedLoads == 1)
        #expect(page.loads == [tab.url], "It isn't loaded from the tab's URL again")
        #expect(pool.isLive(tab.id))
        #expect(!pool.isHibernated(tab.id))
        #expect(pool.state(for: tab.id)?.restoringSnapshot != nil, "The snapshot shows while it loads")
        page.finishLoad()
        #expect(pool.state(for: tab.id)?.restoringSnapshot == nil)
    }

    @Test func aDiscardedTabStaysInTheEnginesWindow() async throws {
        let page = try loadedPage()
        let other = Tab.testTab(url: URL(string: "https://example.com/other")!)
        pool.page(for: other, profileID: profileID)
        let otherPage = try #require(engine.pages.last)
        #expect(await pool.hibernate(tab.id))

        pool.setWindowTabs([tab.id, other.id], selected: other.id, profileID: profileID)
        let window = try #require(engine.windowPages[profileID])
        #expect(window.pages.map(ObjectIdentifier.init) == [ObjectIdentifier(page), ObjectIdentifier(otherPage)])
        #expect(window.active === otherPage)
    }

    @Test func pagesThatCantBeDiscardedCloseAsBefore() async throws {
        pool.page(for: tab, profileID: profileID)
        let page = try #require(engine.pages.last)
        page.navigate(to: tab.url, title: "Start")

        #expect(await pool.hibernate(tab.id))
        #expect(page.isClosed)
        pool.setWindowTabs([tab.id], selected: nil, profileID: profileID)
        #expect(engine.windowPages[profileID]?.pages.isEmpty == true, "A closed page leaves the window")

        let woken = try #require(pool.page(for: tab, profileID: profileID) as? FakePage)
        #expect(woken !== page)
        #expect(woken.restoredState == "history:\(tab.url.absoluteString)")
    }

    @Test func aTabWithNoSavedHistoryStillShowsItsSnapshotWhenItWakes() async throws {
        // A closed page with no history to save (Chromium before it could discard) reloads its
        // URL, and its snapshot still shows meanwhile.
        pool.page(for: tab, profileID: profileID)
        let page = try #require(engine.pages.last)
        page.snapshotImage = SnapshotTimingTests.image(width: 40, height: 30, red: 0, green: 0, blue: 1)
        #expect(await pool.hibernate(tab.id))

        let woken = try #require(pool.page(for: tab, profileID: profileID) as? FakePage)
        #expect(woken.loads == [tab.url])
        #expect(pool.state(for: tab.id)?.restoringSnapshot != nil)
    }

    @Test func theEngineDiscardingAHiddenTabHibernatesIt() async throws {
        let page = try loadedPage()

        page.discardOnItsOwn()
        #expect(pool.isHibernated(tab.id))
        #expect(!pool.isLive(tab.id))
        #expect(!page.isClosed)

        #expect(pool.page(for: tab, profileID: profileID) === page)
        #expect(page.discardedLoads == 1)
    }

    @Test func theEngineDiscardingATabThatsShowingLoadsItAgain() async throws {
        let page = try loadedPage()
        pool.beginShowing(tab.id)

        page.discardOnItsOwn()
        #expect(pool.isLive(tab.id))
        #expect(page.discardedLoads == 1)
    }

    @Test func closingAHibernatedTabClosesItsKeptPage() async throws {
        let page = try loadedPage()
        #expect(await pool.hibernate(tab.id))

        pool.discard(tab.id)
        #expect(page.isClosed)
        #expect(!pool.isHibernated(tab.id))
    }

    @Test func theEngineClosingAKeptPageClosesItsTab() async throws {
        let page = try loadedPage()
        #expect(await pool.hibernate(tab.id))
        var closed: [Tab.ID] = []
        pool.onEngineClosedTab = { closed.append($0) }

        engine.closePageOnItsOwn(page)
        #expect(closed == [tab.id], "An extension can close a discarded tab")
        #expect(!pool.isHibernated(tab.id))
    }

    @Test func theEngineActivatingAKeptPageSelectsItsTab() async throws {
        let page = try loadedPage()
        #expect(await pool.hibernate(tab.id))
        var activated: [Tab.ID] = []
        pool.onEngineActivatedTab = { activated.append($0) }

        engine.activatePageOnItsOwn(page)
        #expect(activated == [tab.id])
    }

    @Test func removingTheProfilesDataClosesItsKeptPages() async throws {
        let page = try loadedPage()
        #expect(await pool.hibernate(tab.id))

        await pool.removeWebsiteData(for: profileID)
        #expect(page.isClosed)
        #expect(!pool.isHibernated(tab.id))
    }

    @Test func hibernatingHiddenTabsDoesntWaitForTheTimeout() async throws {
        let page = try loadedPage()
        let shown = Tab.testTab(url: URL(string: "https://example.com/shown")!)
        pool.page(for: shown, profileID: profileID)
        pool.beginShowing(shown.id)
        let inspected = Tab.testTab(url: URL(string: "https://example.com/inspected")!)
        pool.page(for: inspected, profileID: profileID)
        try #require(engine.pages.last).hasDevTools = true

        #expect(await pool.hibernateIdleTabs() == [], "None has been idle half an hour")
        #expect(await pool.hibernateHiddenTabs() == [tab.id])
        #expect(page.isDiscarded)
        #expect(pool.isLive(shown.id))
        #expect(pool.isLive(inspected.id), "Developer tools keep it live, as for the timer")
    }

    @Test func aKeptPageThatLoadsAgainOnItsOwnIsLiveAgain() async throws {
        let page = try loadedPage()
        #expect(await pool.hibernate(tab.id))

        // An extension reloads it (chrome.tabs.reload) while its tab is hidden.
        page.reloadOnItsOwn()
        #expect(pool.isLive(tab.id), "So it can hibernate again once it's idle")
        #expect(!pool.isHibernated(tab.id))

        // Shown, it's ready: no old snapshot over it, no second load.
        #expect(pool.page(for: tab, profileID: profileID) === page)
        #expect(pool.state(for: tab.id)?.restoringSnapshot == nil)
        #expect(page.discardedLoads == 0)
    }

    @Test func aDiscardTheEngineSkipsClosesThePageAsBefore() async throws {
        let page = try loadedPage()
        page.discardIsSkipped = true

        #expect(await pool.hibernate(tab.id))
        #expect(page.isClosed)
        #expect(pool.isHibernated(tab.id))
    }

    @Test func wakingAndHibernatingAgainKeepsTheSnapshot() async throws {
        let page = try loadedPage()
        #expect(await pool.hibernate(tab.id))
        #expect(page.snapshotCount == 1)

        pool.page(for: tab, profileID: profileID)
        #expect(await pool.hibernate(tab.id))
        #expect(page.snapshotCount == 1, "Nothing changed, so the snapshot from before still stands")
        #expect(pool.snapshot(for: tab.id) != nil)
    }

    @Test func theEngineDiscardingAPageWaitingForItsTabLeavesItLive() async throws {
        var opened: [EngineOpenedPage] = []
        pool.onEngineOpenedPage = { opened.append($0) }
        let page = FakePage(profileID: profileID)
        engine.openPageOnItsOwn(page, profileID: profileID, at: 0)
        let tabID = try #require(opened.first?.tabID)

        page.discardOnItsOwn()
        #expect(pool.isLive(tabID))
        #expect(pool.isAwaitingAdoption(tabID))
    }

    @Test func adoptingAKeptPageUnderAnotherIDForgetsTheOldOne() async throws {
        let page = try loadedPage()
        #expect(await pool.hibernate(tab.id))

        let newTab = Tab.testTab(url: tab.url)
        pool.adopt(page, as: newTab, profileID: profileID)
        #expect(!pool.isHibernated(tab.id))
        #expect(pool.livePage(for: newTab.id) === page)
        pool.discard(tab.id)
        #expect(!page.isClosed, "The old ID no longer owns it")
    }

    @Test func theEngineDiscardingAPageThatChangedSinceItsSnapshotDropsTheSnapshot() async throws {
        let page = try loadedPage()
        pool.beginShowing(tab.id)
        pool.endShowing(tab.id)
        try await waitUntil("the snapshot") { !pool.isSnapshotting(tab.id) }
        page.navigate(to: URL(string: "https://example.com/third")!, title: "Third")

        page.discardOnItsOwn()
        #expect(pool.isHibernated(tab.id))
        #expect(pool.snapshot(for: tab.id) == nil, "It showed the second page, not the third")
    }
}
