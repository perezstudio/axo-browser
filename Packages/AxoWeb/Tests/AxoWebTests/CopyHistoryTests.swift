import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoWeb

/// ``WebViewPool/copyHistory(from:to:)``: Duplicate Tab's new tab restores the original's back
/// and forward history when first shown.
@MainActor
struct CopyHistoryTests {
    let engine = FakeEngine()
    let pool: WebViewPool
    let profileID = UUID()
    let source = Tab.testTab(url: URL(string: "https://example.com/start")!)
    let copy = Tab.testTab(url: URL(string: "https://example.com/second")!)

    init() {
        pool = WebViewPool.withFakeEngine(engine)
    }

    @Test func theCopyRestoresTheSourcesHistoryInsteadOfLoading() throws {
        pool.page(for: source, profileID: profileID)
        let original = try #require(engine.pages.last)
        original.navigate(to: URL(string: "https://example.com/second")!, title: "Second")

        #expect(pool.copyHistory(from: source.id, to: copy.id))
        pool.page(for: copy, profileID: profileID)
        let page = try #require(engine.pages.last)
        #expect(page !== original, "A page of its own")
        #expect(page.restoredState == "history:https://example.com/second")
        #expect(page.loads.isEmpty, "Not loaded from its URL")
    }

    /// The source shown, loaded, then hidden, so the pool snapshots it.
    private func hiddenSource() async throws -> FakePage {
        pool.page(for: source, profileID: profileID)
        let original = try #require(engine.pages.last)
        original.snapshotImage = SnapshotTimingTests.image(width: 40, height: 30, red: 1, green: 0, blue: 0)
        original.navigate(to: source.url, title: "Start")
        original.finishLoad()
        pool.beginShowing(source.id)
        pool.endShowing(source.id)
        try await waitUntil("the snapshot") { !pool.isSnapshotting(source.id) }
        #expect(original.snapshotCount == 1)
        return original
    }

    @Test func theCopyShowsTheSourcesPictureWhileItRestores() async throws {
        _ = try await hiddenSource()
        #expect(pool.copyHistory(from: source.id, to: copy.id))
        #expect(pool.snapshot(for: copy.id) != nil, "The page as it is")
    }

    @Test func aPictureOfAnEarlierPageIsntCopied() async throws {
        let original = try await hiddenSource()
        // Shown again and gone to another page: the picture is of the one before.
        pool.beginShowing(source.id)
        original.navigate(to: URL(string: "https://example.com/second")!, title: "Second")
        #expect(pool.copyHistory(from: source.id, to: copy.id))
        #expect(pool.snapshot(for: copy.id) == nil, "No picture rather than the wrong page's")
    }

    @Test func aHibernatedSourcesHistoryIsCopiedToo() async throws {
        pool.page(for: source, profileID: profileID)
        let original = try #require(engine.pages.last)
        original.navigate(to: URL(string: "https://example.com/second")!, title: "Second")
        original.finishLoad()
        #expect(await pool.hibernate(source.id))

        #expect(pool.copyHistory(from: source.id, to: copy.id))
        pool.page(for: copy, profileID: profileID)
        #expect(engine.pages.last?.restoredState == "history:https://example.com/second")
    }

    @Test func aSourceNeverLoadedHasNothingToCopy() throws {
        #expect(!pool.copyHistory(from: source.id, to: copy.id))
        pool.page(for: copy, profileID: profileID)
        #expect(engine.pages.last?.loads == [copy.url], "Loads its URL as usual")
    }

    @Test func aKeptDiscardedSourcesHistoryIsCopied() async throws {
        // Chromium hibernates by discarding: the page is kept, with its history in it.
        pool.page(for: source, profileID: profileID)
        let original = try #require(engine.pages.last)
        original.canDiscard = true
        original.navigate(to: URL(string: "https://example.com/second")!, title: "Second")
        original.finishLoad()
        #expect(await pool.hibernate(source.id))
        #expect(original.isDiscarded)

        #expect(pool.copyHistory(from: source.id, to: copy.id))
        pool.page(for: copy, profileID: profileID)
        #expect(engine.pages.last?.restoredState == "history:https://example.com/second")
    }
}
