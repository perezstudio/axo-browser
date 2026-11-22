import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

/// The iPhone's ••• menu (#181): its items nearest the thumb first, what's enabled, and what
/// they do.
@MainActor
struct MobileMenuTests {
    let model: BrowserModel

    init() async throws {
        let pool = WebViewPool(engine: FakeEngine())
        pool.reportsScreenTimeUsage = false
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: pool)
        model.announce = { _ in }
        await model.start()
    }

    private func items(_ placement: MobileAddressBarPlacement = .bottom) -> [[String]] {
        model.mobileMenu(placement: placement).map { $0.map { $0.isEnabled ? $0.item.title : "(\($0.item.title))" } }
    }

    @Test func withoutAPageOnlyThePlacementWorks() {
        #expect(items() == [
            ["(Back)", "(Forward)", "(Reload)", "(Share)"],
            ["(Find on Page)", "(Copy Link)", "(Site Settings)"],
            ["Address Bar at Top"],
        ])
    }

    @Test func aPageGetsItsToolsAndThePlacementOffersTheOtherEdge() async throws {
        await model.openTab(url: URL(string: "https://example.com/")!)
        let tabID = try #require(model.selectedTabID)
        let page = try #require(model.pool.livePage(for: tabID) as? FakePage)
        page.canGoBack = true
        page.navigate(to: URL(string: "https://example.com/next")!, title: "Next")
        #expect(items() == [
            ["Back", "(Forward)", "Reload", "Share"],
            ["Find on Page", "Copy Link", "Add to Pinned", "Site Settings"],
            ["Address Bar at Top"],
        ])
        #expect(items(.top).last == ["Address Bar at Bottom"])
    }

    @Test func menuItemsActOnTheShownPage() async throws {
        var copied: [URL] = []
        model.copyLink = { copied.append($0) }
        await model.openTab(url: URL(string: "https://example.com/")!)
        let tabID = try #require(model.selectedTabID)
        let page = try #require(model.pool.livePage(for: tabID) as? FakePage)

        model.performMobileMenu(.back)
        model.performMobileMenu(.reload)
        #expect(page.navigation == ["back", "reload"])
        model.performMobileMenu(.copyLink)
        #expect(copied == [URL(string: "https://example.com/")!])
        model.performMobileMenu(.findOnPage)
        #expect(model.isFindBarVisible)

        model.performMobileMenu(.addToPinned)
        try await waitUntil { model.selectedTab?.isPinned == true }
        #expect(model.mobileMenu(placement: .bottom)[1].contains { $0.item == .removeFromPinned })
        model.performMobileMenu(.siteSettings)
        try await waitUntil { model.isShowingSiteSettings }
    }

    @Test func aLoadingPageOffersStopAndANonWebPageNoShare() async throws {
        await model.openTab(url: URL(string: "data:text/html,<p>hi</p>")!)
        let tabID = try #require(model.selectedTabID)
        let page = try #require(model.pool.livePage(for: tabID) as? FakePage)
        page.isLoading = true
        page.delegate?.pageStateDidChange(page)
        let menu = model.mobileMenu(placement: .bottom)
        #expect(menu[0].map(\.item) == [.back, .forward, .stop, .share])
        #expect(menu[0].last?.isEnabled == false, "Nothing to share from a data: page")
        #expect(menu[1].first { $0.item == .siteSettings }?.isEnabled == false)
    }

    @Test func theAddressNamesTheSite() async throws {
        #expect(model.mobileAddressText == nil, "No page: the placeholder")
        await model.openTab(url: URL(string: "https://www.example.com/a/b")!)
        #expect(model.mobileAddressText?.contains("example.com") == true)
    }
}
