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

    @Test func closingATabClosesItsPage() async throws {
        let page = try await openPage(URL(string: "https://example.com/")!)

        await model.closeSelectedTab()

        #expect(page.isClosed)
    }
}
