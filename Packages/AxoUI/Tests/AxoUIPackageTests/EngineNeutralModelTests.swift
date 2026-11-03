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

    @Test func theLinkStatusFollowsTheShownPage() async throws {
        let first = try await openPage(URL(string: "https://example.com/")!)
        let firstID = try #require(model.selectedTabID)
        let link = URL(string: "https://example.com/axolotl")!
        first.hoverLink(link)
        #expect(model.selectedPage?.hoveredLink == link)

        let second = try await openPage(URL(string: "https://example.org/")!)
        second.hoverLink(URL(string: "https://example.org/other")!)
        #expect(model.selectedPage?.hoveredLink == URL(string: "https://example.org/other"))
        model.select(firstID)
        #expect(model.selectedPage?.hoveredLink == link, "Each tab's own link")
    }

    @Test func coveringThePagesHidesTheirLinkStatus() async throws {
        _ = try await openPage(URL(string: "https://example.com/")!)
        #expect(!model.arePagesCovered)
        model.showCommandBar()
        #expect(model.arePagesCovered)
        model.hideCommandBar()
        #expect(!model.arePagesCovered)
    }

    @Test func hibernatingBackgroundTabsLeavesTheShownOneAlone() async throws {
        let background = try await openPage(URL(string: "https://example.com/")!)
        let backgroundID = try #require(model.selectedTabID)
        _ = try await openPage(URL(string: "https://example.org/")!)
        let shownID = try #require(model.selectedTabID)
        // The window's page view shows the selected tab.
        model.pool.beginShowing(shownID)
        var announcements: [String] = []
        model.announce = { announcements.append($0) }

        await model.hibernateBackgroundTabs()
        #expect(model.pool.isHibernated(backgroundID), "Hibernated at once, though it was just used")
        #expect(background.isClosed, "This engine can't discard, so the page closes")
        #expect(model.pool.isLive(shownID))
        #expect(announcements == ["1 tab hibernated"])
    }

    @Test func siteSettingsKeepTheEnginesLastingAnswersInStep() async throws {
        _ = try await openPage(URL(string: "https://news.example.com/today")!)
        let site = PageOrigin(scheme: "https", host: "news.example.com")

        await model.setSitePermission(.deny, for: .notifications)
        await model.setSitePermission(.allow, for: .camera)
        await model.setSitePermission(.allow, for: .clipboard)
        #expect(engine.lastingPermissions.map(\.kind) == [.notifications, .clipboard], "The camera is asked about each time")
        #expect(engine.lastingPermissions.map(\.decision) == [.deny, .allow])
        #expect(engine.lastingPermissions.allSatisfy { $0.origin == site })

        await model.resetSiteSettings()
        #expect(engine.lastingPermissions.suffix(2).map(\.kind) == [.notifications, .clipboard])
        #expect(engine.lastingPermissions.suffix(2).allSatisfy { $0.decision == nil }, "Reset clears them in the engine too")
    }

    @Test func savedLastingAnswersReachTheEngineAtLaunch() async throws {
        let profileID = try #require(model.space?.profileID)
        try await model.store.sitePermissions.setDecision(.allow, for: [.notifications], origin: "https://news.example.com", profileID: profileID)
        try await model.store.sitePermissions.setDecision(.deny, for: [.clipboard, .location], origin: "http://127.0.0.1:8080", profileID: profileID)

        let relaunchedEngine = FakeEngine()
        let pool = WebViewPool(engine: relaunchedEngine)
        pool.reportsScreenTimeUsage = false
        let relaunched = BrowserModel(store: model.store, pool: pool)
        relaunched.announce = { _ in }
        await relaunched.start()

        // Each profile's answers replace the engine's own, the profile without any included.
        let replaced = try #require(relaunchedEngine.replacedLastingPermissions[profileID])
        #expect(Set(replaced) == [
            LastingPermission(kind: .notifications, origin: PageOrigin(scheme: "https", host: "news.example.com"), decision: .allow),
            LastingPermission(kind: .clipboard, origin: PageOrigin(scheme: "http", host: "127.0.0.1", port: 8080), decision: .deny),
        ])
        let other = try await model.store.createProfile(name: "Work")
        await relaunched.syncLastingPermissions()
        #expect(relaunchedEngine.replacedLastingPermissions[other.id] == [], "Clearing whatever the engine had")
    }

    @Test func clearingWebsiteDataGivesTheEngineAxosAnswersAgain() async throws {
        let profileID = try #require(model.space?.profileID)
        try await model.store.sitePermissions.setDecision(.allow, for: [.notifications], origin: "https://news.example.com", profileID: profileID)

        await model.clearWebsiteData(for: profileID)
        #expect(engine.clearedProfiles == [profileID])
        #expect(engine.replacedLastingPermissions[profileID]?.map(\.kind) == [.notifications])
    }

    @Test func answeringAPromptForALastingKindTellsTheEngine() async throws {
        let site = PageOrigin(scheme: "https", host: "news.example.com")
        let answering = Task { @MainActor in
            while !Task.isCancelled {
                if case .permission = model.currentPrompt?.content { model.answerPermission(.allow) }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { answering.cancel() }
        let profileID = try #require(model.space?.profileID)

        #expect(await model.pool.decidePermission(.notifications, origin: site, tabID: UUID(), profileID: profileID) == .allow)
        #expect(engine.lastingPermissions.last?.kind == .notifications)
        #expect(engine.lastingPermissions.last?.decision == .allow, "In case the engine stopped waiting for it")
    }

    @Test func siteSettingsOfferOnlyWhatTheSiteCanAskFor() async throws {
        _ = try await openPage(URL(string: "https://news.example.com/")!)
        #expect(model.siteSettingsKinds == SitePermission.Kind.allCases)

        _ = try await openPage(URL(string: "http://plain.example.com/")!)
        #expect(model.siteSettingsKinds == [.camera, .microphone, .location], "Notifications need a secure site")
        _ = try await openPage(URL(string: "http://localhost:8000/")!)
        #expect(model.siteSettingsKinds.contains(.notifications), "This Mac counts as secure")

        engine.askedPermissionKinds = [.camera, .microphone, .cameraAndMicrophone, .location]
        _ = try await openPage(URL(string: "https://news.example.com/")!)
        #expect(model.siteSettingsKinds == [.camera, .microphone, .location], "Not for an engine that never asks")
    }

    @Test func aPageAskingToBeShownBringsItsTabForwardEvenInAnotherSpace() async throws {
        let mail = try await openPage(URL(string: "https://mail.example.com/")!)
        let mailID = try #require(model.selectedTabID)
        _ = try await openPage(URL(string: "https://news.example.com/")!)
        let firstSpace = try #require(model.space?.id)
        var broughtForward = 0
        model.showBrowserWindow = { broughtForward += 1 }

        await model.createSpace(name: "Work")
        #expect(model.space?.id != firstSpace)
        mail.askToBeShown()
        try await waitUntil { model.selectedTabID == mailID }
        #expect(model.space?.id == firstSpace, "Its Space is shown again")
        #expect(broughtForward == 1)
    }

    @Test func aPageAskingToBeShownIsIgnoredWhileAxoIsntActive() async throws {
        let mail = try await openPage(URL(string: "https://mail.example.com/")!)
        let mailID = try #require(model.selectedTabID)
        _ = try await openPage(URL(string: "https://news.example.com/")!)
        var broughtForward = 0
        model.showBrowserWindow = { broughtForward += 1 }
        model.isAppActive = { false }

        await model.showTabForPage(mailID)
        #expect(model.selectedTabID != mailID, "Another app is in use: no tab switching under it")
        #expect(broughtForward == 0)
        _ = mail
    }

    @Test func theSelectedTabAskingToBeShownChangesNothing() async throws {
        _ = try await openPage(URL(string: "https://video.example.com/")!)
        let videoID = try #require(model.selectedTabID)
        var broughtForward = 0
        model.showBrowserWindow = { broughtForward += 1 }

        // As a page entering full screen asks.
        await model.showTabForPage(videoID)
        #expect(broughtForward == 0)
    }

    @Test func aFavoriteAskingToBeShownIsSelected() async throws {
        let mail = try await openPage(URL(string: "https://mail.example.com/")!)
        let mailID = try #require(model.selectedTabID)
        await model.addToFavorites(mailID)
        #expect(model.isFavorite(mailID))
        _ = try await openPage(URL(string: "https://news.example.com/")!)
        var broughtForward = 0
        model.showBrowserWindow = { broughtForward += 1 }

        mail.askToBeShown()
        try await waitUntil { model.selectedTabID == mailID }
        #expect(broughtForward == 1)
    }

    @Test func anUnknownTabAskingToBeShownChangesNothing() async throws {
        _ = try await openPage(URL(string: "https://news.example.com/")!)
        let selected = model.selectedTabID
        var broughtForward = 0
        model.showBrowserWindow = { broughtForward += 1 }

        await model.showTabForPage(UUID())
        #expect(model.selectedTabID == selected)
        #expect(broughtForward == 0)
    }

    @Test func findGoesToThePage() async throws {
        let page = try await openPage(URL(string: "https://example.com/")!)
        page.findResult = false

        model.findText = "axolotl"
        await model.findNext()

        #expect(page.finds.map(\.text) == ["axolotl"])
        #expect(model.findHasNoMatches)
    }

    @Test func aReplacedFindsAnswerIsIgnored() async throws {
        let page = try await openPage(URL(string: "https://example.com/")!)
        var announcements: [String] = []
        model.announce = { announcements.append($0) }
        page.holdsFinds = true

        model.findText = "l"
        let first = Task { await model.findNext() }
        try await waitForHeldFinds(1, on: page)
        model.findText = "la"
        let second = Task { await model.findNext() }
        try await waitForHeldFinds(2, on: page)

        // Chromium answers the find a newer one replaced "no match".
        page.answerHeldFind(false)
        await first.value
        #expect(!model.findHasNoMatches)
        page.answerHeldFind(true)
        await second.value
        #expect(!model.findHasNoMatches)
        #expect(announcements.isEmpty)
    }

    @Test func closingTheFindBarIgnoresTheFindStillWaiting() async throws {
        let page = try await openPage(URL(string: "https://example.com/")!)
        var announcements: [String] = []
        model.announce = { announcements.append($0) }
        page.holdsFinds = true

        model.findText = "lakes"
        let find = Task { await model.findNext() }
        try await waitForHeldFinds(1, on: page)
        model.closeFindBar()
        page.answerHeldFind(false)
        await find.value

        #expect(!model.findHasNoMatches)
        #expect(announcements.isEmpty)
    }

    @Test func emptyingTheFindTextClearsThePagesFind() async throws {
        let page = try await openPage(URL(string: "https://example.com/")!)
        model.findText = "lakes"
        await model.findNext()

        model.findText = ""
        await model.findNext()

        #expect(page.endedFinds == 1)
        #expect(page.finds.map(\.text) == ["lakes"])
    }

    private func waitForHeldFinds(_ count: Int, on page: FakePage) async throws {
        for _ in 0..<1000 where page.heldFindCount < count { await Task.yield() }
        try #require(page.heldFindCount == count)
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

    @Test func pagesAPageOpensKeepTheirConnection() async throws {
        let source = try await openPage(URL(string: "https://example.com/source")!)
        _ = try await openPage(URL(string: "https://example.com/other")!)
        let sourceID = try #require(model.tabs.first?.id)
        model.select(sourceID)
        let profileID = try #require(model.space?.profileID)
        // The sidebar's observation can show a new tab before the model selects it; the
        // model's .opened event comes right before the selection, in the same turn.
        var openedEvents = 0
        model.onTabEvent = { if case .opened = $0 { openedEvents += 1 } }

        // window.open from a click: a tab right after its opener, keeping the page Chromium made.
        let opened = FakePage(profileID: profileID)
        source.open(opened, url: URL(string: "https://example.com/opened")!, as: .tab(inBackground: false))
        try await waitUntil { openedEvents == 1 }
        #expect(model.tabs.map(\.url.lastPathComponent) == ["source", "opened", "other"])
        let openedID = model.tabs[1].id
        #expect(model.pool.livePage(for: openedID) === opened, "The same page, so window.opener still works")
        #expect(opened.loads.isEmpty, "It isn't loaded again")
        #expect(model.selectedTabID == openedID)

        // ⌘-click: in the background.
        model.select(sourceID)
        let background = FakePage(profileID: profileID)
        source.open(background, url: URL(string: "https://example.com/later")!, as: .tab(inBackground: true))
        try await waitUntil { openedEvents == 2 }
        #expect(model.tabs.count == 4)
        #expect(model.selectedTabID == sourceID)

        // A sign-in popup: a mini window, sized as it asked.
        let popup = FakePage(profileID: profileID)
        source.open(popup, url: URL(string: "https://accounts.example.com/")!, as: .popup(size: CGSize(width: 500, height: 600)))
        let mini = try #require(model.miniWindows.last)
        #expect(mini.contentSize == CGSize(width: 500, height: 600))
        #expect(model.pool.livePage(for: mini.tab.id) === popup)
        #expect(model.tabs.count == 4)
    }

    @Test func pagesPinnedTabsOpenGoToPeek() async throws {
        let pinnedPage = try await openPage(URL(string: "https://example.com/pinned")!)
        let pinnedID = try #require(model.selectedTabID)
        try await model.store.setPinned(true, tabID: pinnedID)
        try await waitUntil { model.tabs.first?.isPinned == true }
        let profileID = try #require(model.space?.profileID)

        let opened = FakePage(profileID: profileID)
        pinnedPage.open(opened, url: URL(string: "https://example.com/elsewhere")!, as: .tab(inBackground: false))
        #expect(opened.isClosed, "Peek loads the link itself")
        #expect(model.peek?.tab.url == URL(string: "https://example.com/elsewhere")!)
    }

    @Test func aPageCanFillTheScreenUntilItOrThePersonStops() async throws {
        let shown = try await openPage(URL(string: "https://example.com/video")!)
        let shownID = try #require(model.selectedTabID)

        shown.setFullscreen(true)
        #expect(model.fullscreenTabID == shownID)
        shown.setFullscreen(false)
        #expect(model.fullscreenTabID == nil, "The page left full screen (Esc, or its own button)")

        shown.setFullscreen(true)
        model.exitPageFullscreen()
        #expect(model.fullscreenTabID == nil)
        #expect(shown.exitedFullscreen == 1, "Leaving full screen another way tells the page")

        shown.setFullscreen(true)
        let other = try await openPage(URL(string: "https://example.com/other")!)
        #expect(model.fullscreenTabID == nil, "Switching tabs ends it")
        #expect(shown.exitedFullscreen == 2)

        // A page that isn't showing can't take over the screen.
        shown.setFullscreen(true)
        #expect(model.fullscreenTabID == nil)
        #expect(shown.exitedFullscreen == 3)
        _ = other
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

    /// Chromium restores a page from its back/forward cache without loading it: the URL and
    /// title arrive together, then the engine reports the page finished, with no load before it.
    @Test func aPageRestoredFromTheCacheGetsItsFaviconAndOneVisit() async throws {
        let first = URL(string: "https://example.com/first")!
        let second = URL(string: "https://example.com/second")!
        let page = try await openPage(first)
        let profileID = try #require(model.space?.profileID)
        page.navigate(to: first, title: "First")
        page.navigate(to: second, title: "Second")
        let scriptsBefore = page.scripts.count

        page.navigate(to: first, title: "First")
        page.delegate?.pageDidFinishLoad(page)

        // The favicon is looked up again for the restored page.
        try await waitUntil { page.scripts.count > scriptsBefore }
        try await waitUntilAsync {
            try await model.store.history.recent(profileID: profileID).first { $0.url == first }?.visitCount == 2
        }
        let history = try await model.store.history.recent(profileID: profileID)
        #expect(history.first { $0.url == first }?.title == "First")
        #expect(history.first { $0.url == second }?.visitCount == 1)
        #expect(model.selectedPage?.title == "First")
    }
}
