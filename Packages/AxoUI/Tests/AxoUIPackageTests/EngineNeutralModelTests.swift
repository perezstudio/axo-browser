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

    @Test func closingATabClosesItsPage() async throws {
        let page = try await openPage(URL(string: "https://example.com/")!)

        await model.closeSelectedTab()

        #expect(page.isClosed)
    }
}
