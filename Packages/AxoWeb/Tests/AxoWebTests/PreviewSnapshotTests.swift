import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoWeb

/// Pictures for tab rows' hover cards (#76): reused while current, taken only when the page
/// changed and can be pictured, never by making a page.
@MainActor
struct PreviewSnapshotTests {
    let engine = FakeEngine()
    let pool: WebViewPool
    let profileID = UUID()
    let tab = Tab.testTab(url: URL(string: "https://example.com/")!)

    init() {
        pool = WebViewPool.withFakeEngine(engine)
    }

    private func livePage() throws -> FakePage {
        pool.page(for: tab, profileID: profileID)
        let page = try #require(engine.pages.last)
        page.snapshotImage = SnapshotTimingTests.image(width: 40, height: 30, red: 0, green: 0, blue: 1)
        page.navigate(to: tab.url, title: "Page")
        return page
    }

    @Test func aCurrentPictureIsReusedAndAChangedPageIsPicturedAgain() async throws {
        let page = try livePage()
        #expect(await pool.previewSnapshot(for: tab.id) != nil)
        #expect(await pool.previewSnapshot(for: tab.id) != nil)
        #expect(page.snapshotCount == 1, "The second card reuses the first picture")

        page.navigate(to: URL(string: "https://example.com/next")!, title: "Next")
        #expect(await pool.previewSnapshot(for: tab.id) != nil)
        #expect(page.snapshotCount == 2)
    }

    @Test func aLoadingPageOffersNoPictureOfThePageBefore() async throws {
        let page = try livePage()
        #expect(await pool.previewSnapshot(for: tab.id) != nil)
        page.navigate(to: URL(string: "https://example.com/next")!, title: "Next")
        page.isLoading = true
        #expect(await pool.previewSnapshot(for: tab.id) == nil, "The last picture shows another page")
        #expect(page.snapshotCount == 1, "Nor is a half-drawn one taken")
    }

    @Test func aShowingPageIsPicturedWithoutReplacingItsHibernationSnapshot() async throws {
        let page = try livePage()
        pool.beginShowing(tab.id)
        #expect(await pool.previewSnapshot(for: tab.id) != nil)
        #expect(await pool.previewSnapshot(for: tab.id) != nil)
        #expect(page.snapshotCount == 2, "Not kept: a page showing changes without telling")
        pool.endShowing(tab.id)
        try await waitUntil("the snapshot taken on hiding") { !pool.isSnapshotting(tab.id) }
        #expect(page.snapshotCount == 3, "Hiding it still takes the snapshot hibernation uses")
    }

    @Test func aHibernatedTabOffersItsSnapshotAndATabWithNoPageNothing() async throws {
        _ = try livePage()
        pool.beginShowing(tab.id)
        pool.endShowing(tab.id)
        #expect(await pool.hibernate(tab.id))
        let pages = engine.pages.count
        #expect(await pool.previewSnapshot(for: tab.id) == pool.snapshot(for: tab.id))
        #expect(pool.snapshot(for: tab.id) != nil)

        let never = Tab.testTab(url: URL(string: "https://example.org/")!)
        #expect(await pool.previewSnapshot(for: never.id) == nil)
        #expect(engine.pages.count == pages, "No page is made for a picture")
    }
}
