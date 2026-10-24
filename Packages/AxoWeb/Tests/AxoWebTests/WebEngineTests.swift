import AxoCore
import Foundation
import Testing
@testable import AxoWeb
import AxoWebTestSupport

/// The pool's logic on an engine with no browser behind it, so it doesn't depend on WebKit.
@MainActor
struct WebEngineTests {
    let engine = FakeEngine()
    let clock = TestClock()
    let pool: WebViewPool
    let profileID = UUID()
    let url = URL(string: "https://example.com/start")!

    init() {
        pool = WebViewPool.withFakeEngine(engine, clock: clock)
    }

    private func livePage(for tab: Tab) throws -> FakePage {
        try #require(pool.livePage(for: tab.id) as? FakePage)
    }

    // MARK: Pages

    @Test func aTabGetsOnePageThatLoadsItsURL() throws {
        let tab = Tab.testTab(url: url)
        #expect(pool.livePage(for: tab.id) == nil)

        let first = pool.page(for: tab, profileID: profileID)
        let second = pool.page(for: tab, profileID: profileID)

        #expect(first === second)
        #expect(engine.pages.count == 1)
        let page = try livePage(for: tab)
        #expect(page.profileID == profileID)
        #expect(page.loads == [url])
        #expect(page.delegate != nil, "The pool listens to its pages")
    }

    @Test func stateFollowsThePageAndChangesAreReported() throws {
        var changes: [String] = []
        pool.onPageChange = { _, url, title in changes.append("\(url.lastPathComponent) \(title)") }
        let tab = Tab.testTab(url: url)
        pool.page(for: tab, profileID: profileID)
        let page = try livePage(for: tab)

        page.canGoBack = true
        page.isLoading = true
        page.navigate(to: URL(string: "https://example.com/next")!, title: "Next")

        let state = try #require(pool.state(for: tab.id))
        #expect(state.url?.lastPathComponent == "next")
        #expect(state.title == "Next")
        #expect(state.canGoBack)
        #expect(state.isLoading)
        #expect(changes == ["next Next"])

        page.delegate?.pageStateDidChange(page)
        #expect(changes == ["next Next"], "Only real URL or title changes are reported")
    }

    @Test func navigationGoesToTheTabsPage() throws {
        let tab = Tab.testTab(url: url)
        pool.page(for: tab, profileID: profileID)
        let page = try livePage(for: tab)

        pool.goBack(in: tab.id)
        pool.goForward(in: tab.id)
        pool.reload(tab.id)
        pool.stopLoading(tab.id)
        let next = URL(string: "https://example.com/other")!
        pool.load(next, in: tab.id)
        pool.startDownload(next, in: tab.id)

        #expect(page.navigation == ["back", "forward", "reload", "stop"])
        #expect(page.loads == [url, next])
        #expect(page.downloadRequests == [next])
    }

    @Test func findSkipsEmptyTextAndClearFindRunsInItsOwnWorld() async throws {
        let tab = Tab.testTab(url: url)
        pool.page(for: tab, profileID: profileID)
        let page = try livePage(for: tab)

        #expect(await pool.find("", in: tab.id) == false)
        #expect(await pool.find("axolotl", in: tab.id, backwards: true))
        await pool.clearFind(in: tab.id)

        #expect(page.finds.map(\.text) == ["axolotl"])
        #expect(page.finds.first?.backwards == true)
        #expect(page.scripts.map(\.world) == ["AxoFind"])
    }

    // MARK: Hibernation

    @Test func hibernationClosesThePageAndWakingRestoresItsHistory() async throws {
        let tab = Tab.testTab(url: url)
        pool.page(for: tab, profileID: profileID)
        let sleeping = try livePage(for: tab)
        sleeping.navigate(to: URL(string: "https://example.com/deep")!, title: "Deep")

        #expect(await pool.hibernate(tab.id))
        #expect(sleeping.isClosed)
        #expect(sleeping.delegate == nil)
        #expect(pool.isHibernated(tab.id))

        pool.page(for: tab, profileID: profileID)
        let woken = try livePage(for: tab)
        #expect(woken !== sleeping)
        #expect(woken.restoredState == "history:https://example.com/deep")
        #expect(woken.loads.isEmpty, "It restores history instead of loading the tab's URL")
    }

    @Test func discardingClosesThePage() throws {
        let tab = Tab.testTab(url: url)
        pool.page(for: tab, profileID: profileID)
        let page = try livePage(for: tab)

        pool.discard(tab.id)

        #expect(page.isClosed)
        #expect(!pool.isLive(tab.id))
    }

    // MARK: Events

    @Test func linkClicksAndNewTabRequestsNameTheirTab() throws {
        var clicks: [LinkClick] = []
        var newTabs: [(URL, Tab.ID)] = []
        pool.onLinkClick = { clicks.append($0); return true }
        pool.onOpenInNewTab = { newTabs.append(($0, $1)) }
        let tab = Tab.testTab(url: url)
        pool.page(for: tab, profileID: profileID)
        let page = try livePage(for: tab)
        page.navigate(to: url, title: "Start")
        let link = URL(string: "https://elsewhere.example/")!

        let handled = page.delegate?.page(page, shouldHandleLinkTo: link, modifiers: .command)
        page.delegate?.page(page, wantsToOpenInNewTab: link)

        #expect(handled == true)
        #expect(clicks.first?.tabID == tab.id)
        #expect(clicks.first?.sourceURL == url)
        #expect(clicks.first?.modifiers == .command)
        #expect(newTabs.first?.0 == link)
        #expect(newTabs.first?.1 == tab.id)
    }

    @Test func focusIsReportedForTheTab() throws {
        var focused: [Tab.ID] = []
        pool.onWebViewFocus = { focused.append($0) }
        let tab = Tab.testTab(url: url)
        pool.page(for: tab, profileID: profileID)
        let page = try livePage(for: tab)

        page.delegate?.pageDidTakeFocus(page)

        #expect(focused == [tab.id])
    }

    @Test func permissionAnswersAreRememberedPerOrigin() async throws {
        var asked = 0
        pool.onPermissionRequest = { _ in asked += 1; return .allow }
        let tab = Tab.testTab(url: url)
        pool.page(for: tab, profileID: profileID)
        let page = try livePage(for: tab)
        let origin = PageOrigin(scheme: "https", host: "meet.example.com")

        let first = await page.delegate?.page(page, requestsPermission: .camera, origin: origin)
        let second = await page.delegate?.page(page, requestsPermission: .camera, origin: origin)

        #expect(first == .allow)
        #expect(second == .allow)
        #expect(asked == 1)
    }

    @Test func downloadsJoinThePoolsListAndCancelThroughTheEngine() throws {
        let tab = Tab.testTab(url: url)
        pool.page(for: tab, profileID: profileID)
        let page = try livePage(for: tab)
        var cancelled = false
        let source = URL(string: "https://example.com/report.pdf")!

        let item = try #require(page.delegate?.page(page, didStartDownloadFrom: source) { cancelled = true })

        #expect(pool.downloads.items.first === item)
        #expect(item.sourceTabID == tab.id)
        #expect(item.filename == "report.pdf")
        pool.downloads.cancel(item)
        #expect(cancelled)
        #expect(item.state == .cancelled)
    }

    // MARK: Profiles and customizations

    @Test func profileDataGoesThroughTheEngine() async throws {
        let other = UUID()
        let mine = Tab.testTab(url: url), theirs = Tab.testTab(url: url)
        pool.page(for: mine, profileID: profileID)
        pool.page(for: theirs, profileID: other)
        let theirPage = try livePage(for: theirs)

        await pool.clearWebsiteData(for: profileID)
        await pool.removeWebsiteData(for: other)

        #expect(engine.clearedProfiles == [profileID])
        #expect(engine.removedProfiles == [other])
        #expect(theirPage.isClosed, "A removed profile's pages close first")
        #expect(pool.isLive(mine.id))
    }

    @Test func siteCustomizationsGoToTheEngine() {
        let customization = SiteCustomization(domain: "example.com", css: "body { color: red }")
        pool.setSiteCustomizations([customization])
        #expect(engine.siteCustomizations.map(\.domain) == ["example.com"])
    }

    @Test func webKitOnlyAccessorsAreEmptyWithAnotherEngine() {
        let tab = Tab.testTab(url: url)
        pool.page(for: tab, profileID: profileID)
        #expect(pool.webKitEngine == nil)
        #expect(pool.liveWebView(for: tab.id) == nil)
    }
}

/// Engines report downloads through ``DownloadItem``.
@MainActor
struct DownloadReportingTests {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "AxoWebTests-Reporting-\(UUID().uuidString)", directoryHint: .isDirectory)

    @Test func destinationsAreUniqueAndFinishingQuarantinesAndReports() throws {
        let manager = DownloadManager(directory: directory)
        var ended: [DownloadState] = []
        manager.onEnd = { ended.append($0.state) }
        let item = manager.begin(sourceURL: URL(string: "https://example.com/a.txt"), sourceTabID: nil) {}

        let destination = try #require(item.chooseDestination(suggestedFilename: "a.txt", expectedLength: 4))
        #expect(item.totalBytes == 4)
        try "data".write(to: destination, atomically: true, encoding: .utf8)
        item.reportProgress(completedBytes: 2, totalBytes: 4)
        #expect(item.fractionCompleted == 0.5)
        item.reportFinished()

        #expect(item.state == .finished)
        #expect(item.completedBytes == 4)
        #expect(ended == [.finished])
        item.reportFailed("late")
        #expect(item.state == .finished, "A stopped download ignores later reports")

        let second = manager.begin(sourceURL: nil, sourceTabID: nil) {}
        let next = try #require(second.chooseDestination(suggestedFilename: "a.txt", expectedLength: nil))
        #expect(next.lastPathComponent == "a 2.txt")
    }

    @Test func failuresAreReportedOnce() {
        let manager = DownloadManager(directory: directory)
        var ended = 0
        manager.onEnd = { _ in ended += 1 }
        let item = manager.begin(sourceURL: nil, sourceTabID: nil) {}

        item.reportFailed("The network went away.")
        item.reportFailed("Again")

        #expect(item.state == .failed("The network went away."))
        #expect(ended == 1)
        #expect(item.chooseDestination(suggestedFilename: "x", expectedLength: nil) == nil)
    }
}
