import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

/// The browser model runs on any engine, not only WebKit, so the Mac can move to Chromium
/// (see `docs/chromium-engine.md`).
@MainActor
struct EngineNeutralModelTests {
    let engine = FakeEngine()
    let model: BrowserModel

    init() async throws {
        let pool = WebViewPool(engine: engine)
        pool.reportsScreenTimeUsage = false
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: pool)
        model.announce = { _ in }
        await model.start()
    }

    private func openPage(_ url: URL) async throws -> FakePage {
        await model.openTab(url: url)
        let id = try #require(model.selectedTabID)
        return try #require(model.pool.livePage(for: id) as? FakePage)
    }

    @Test func openingATabMakesAPageInItsProfile() async throws {
        let url = URL(string: "https://example.com/")!
        let page = try await openPage(url)

        #expect(page.loads == [url])
        #expect(page.profileID == model.space?.profileID)
        #expect(model.pool.webKitEngine == nil)
    }

    @Test func theToolbarFollowsThePage() async throws {
        let page = try await openPage(URL(string: "https://example.com/")!)

        page.canGoBack = true
        page.navigate(to: URL(string: "https://example.com/next")!, title: "Next")

        #expect(model.selectedPage?.title == "Next")
        #expect(model.selectedPage?.canGoBack == true)
        model.goBack()
        model.reloadOrStop()
        #expect(page.navigation == ["back", "reload"])
    }

    @Test func findGoesToThePage() async throws {
        let page = try await openPage(URL(string: "https://example.com/")!)
        page.findResult = false

        model.findText = "axolotl"
        await model.findNext()

        #expect(page.finds.map(\.text) == ["axolotl"])
        #expect(model.findHasNoMatches)
    }

    // MARK: The engine's window

    @Test func theEnginesWindowFollowsTheSidebarAndSelection() async throws {
        let first = try await openPage(URL(string: "https://example.com/1")!)
        let second = try await openPage(URL(string: "https://example.com/2")!)
        let profileID = try #require(model.space?.profileID)

        let window = try #require(engine.windowPages[profileID])
        #expect(window.pages.map { ObjectIdentifier($0) } == [first, second].map { ObjectIdentifier($0) })
        #expect(window.active === second)

        model.select(model.tabs.first?.id)
        #expect(engine.windowPages[profileID]?.active === first)
    }

    @Test func aSelectedPinnedTabIsTheWindowsActiveTab() async throws {
        let pinned = try await openPage(URL(string: "https://example.com/pinned")!)
        let pinnedID = try #require(model.selectedTabID)
        await model.setPinned(true, tabID: pinnedID)
        let other = try await openPage(URL(string: "https://example.com/other")!)
        let profileID = try #require(model.space?.profileID)
        #expect(engine.windowPages[profileID]?.active === other)

        model.select(pinnedID)
        let window = try #require(engine.windowPages[profileID])
        #expect(window.active === pinned)
        #expect(window.pages.contains { $0 === pinned })
    }

    @Test func favoritesAreInTheWindowFirstAndCanBeItsActiveTab() async throws {
        let favorite = try await openPage(URL(string: "https://example.com/favorite")!)
        let favoriteID = try #require(model.selectedTabID)
        await model.addToFavorites(favoriteID)
        let tab = try await openPage(URL(string: "https://example.com/tab")!)
        let profileID = try #require(model.space?.profileID)

        var window = try #require(engine.windowPages[profileID])
        #expect(window.pages.map { ObjectIdentifier($0) } == [favorite, tab].map { ObjectIdentifier($0) }, "Favorites first, as in the sidebar")
        #expect(window.active === tab)

        model.select(favoriteID)
        window = try #require(engine.windowPages[profileID])
        #expect(window.active === favorite, "Extensions see the favorite as the active tab")
    }

    @Test func pagesTheEngineOpensBecomeSidebarTabs() async throws {
        let first = try await openPage(URL(string: "https://example.com/1")!)
        _ = try await openPage(URL(string: "https://example.com/2")!)
        let firstID = try #require(model.tabs.first?.id)
        let profileID = try #require(model.space?.profileID)
        let opened = FakePage(profileID: profileID)
        opened.navigate(to: URL(string: "https://example.com/from-an-extension")!, title: "Extension")

        engine.openPageOnItsOwn(opened, profileID: profileID, at: 1)
        try await waitUntil { model.tabs.count == 3 }

        #expect(model.tabs.map(\.url.lastPathComponent) == ["1", "from-an-extension", "2"], "Right after the tab before it")
        let adoptedID = model.tabs[1].id
        #expect(model.pool.livePage(for: adoptedID) === opened, "It keeps the page that's already loading")
        #expect(opened.loads.isEmpty)
        #expect(model.pool.livePage(for: firstID) === first)
    }

    @Test func aTabTheEngineOpensAndSelectsIsSelectedInTheSidebar() async throws {
        let first = try await openPage(URL(string: "https://example.com/1")!)
        let profileID = try #require(model.space?.profileID)
        let opened = FakePage(profileID: profileID)
        opened.navigate(to: URL(string: "https://example.com/options")!, title: "Options")

        // chrome.tabs.create: Chrome reports the new tab, then makes it active, at once.
        engine.openPageOnItsOwn(opened, profileID: profileID, at: 1)
        engine.activatePageOnItsOwn(opened)
        #expect(engine.windowPages[profileID]?.active === opened, "The engine's window keeps it active meanwhile")
        #expect(engine.windowPages[profileID]?.pages.contains { $0 === opened } == true, "And keeps it in its tabs")

        try await waitUntil { model.tabs.count == 2 }
        let openedID = try #require(model.tabs.last?.id)
        #expect(model.selectedTabID == openedID)
        #expect(model.pool.livePage(for: openedID) === opened)
        #expect(engine.windowPages[profileID]?.active === opened)
        _ = first
    }

    @Test func anotherProfilesWindowCantChangeTheSelection() async throws {
        let shown = try await openPage(URL(string: "https://example.com/shown")!)
        let shownID = try #require(model.selectedTabID)
        let profile = try await model.store.createProfile(name: "Other")
        let otherTab = AxoCore.Tab(spaceID: UUID(), url: URL(string: "https://example.com/other")!, sortKey: SortKey.initial)
        model.pool.page(for: otherTab, profileID: profile.id)
        let otherPage = try #require(model.pool.livePage(for: otherTab.id))

        engine.activatePageOnItsOwn(otherPage)
        #expect(model.selectedTabID == shownID)
        _ = shown
    }

    @Test func tabsTheEngineClosesOrSelectsFollowInTheSidebar() async throws {
        let first = try await openPage(URL(string: "https://example.com/1")!)
        let second = try await openPage(URL(string: "https://example.com/2")!)
        let firstID = try #require(model.tabs.first?.id)

        engine.activatePageOnItsOwn(first)
        #expect(model.selectedTabID == firstID)

        engine.closePageOnItsOwn(second)
        try await waitUntil { model.tabs.count == 1 }
        #expect(model.tabs.map(\.id) == [firstID])
    }

    @Test func extensionPopupWindowsOpenAsMiniWindowsAndCloseWithTheirPage() async throws {
        _ = try await openPage(URL(string: "https://example.com/")!)
        let profileID = try #require(model.space?.profileID)
        var presented: [MiniWindow] = []
        var dismissed: [MiniWindow.ID] = []
        model.presentMiniWindow = { presented.append($0) }
        model.dismissMiniWindow = { dismissed.append($0) }
        let popup = FakePage(profileID: profileID)
        popup.navigate(to: URL(string: "https://example.com/pop-out")!, title: "Pop-out")

        engine.openPopupWindowOnItsOwn(popup, size: CGSize(width: 380, height: 600), profileID: profileID)

        let mini = try #require(presented.first)
        #expect(mini.isExtensionWindow)
        #expect(mini.contentSize == CGSize(width: 380, height: 600))
        #expect(model.miniWindows.map(\.id) == [mini.id])
        #expect(model.pool.livePage(for: mini.id) === popup, "It keeps the page that's already loading")
        #expect(model.tabs.count == 1, "It isn't a sidebar tab")

        engine.closePageOnItsOwn(popup)
        try await waitUntil { model.miniWindows.isEmpty }
        #expect(dismissed == [mini.id], "chrome.windows.remove closes the window")
    }

    @Test func extensionWindowSizesMustBeUsable() {
        #expect(BrowserModel.extensionWindowSize(CGSize(width: 380, height: 600)) == CGSize(width: 380, height: 600))
        #expect(BrowserModel.extensionWindowSize(CGSize(width: 10, height: 600)) == CGSize(width: 100, height: 600))
        #expect(BrowserModel.extensionWindowSize(CGSize(width: 0, height: 600)) == nil)
        #expect(BrowserModel.extensionWindowSize(CGSize(width: CGFloat.infinity, height: 600)) == nil)
        #expect(BrowserModel.extensionWindowSize(CGSize(width: CGFloat.nan, height: 600)) == nil)
    }

    @Test func closingATabClosesItsPage() async throws {
        let page = try await openPage(URL(string: "https://example.com/")!)

        await model.closeSelectedTab()

        #expect(page.isClosed)
    }
}
