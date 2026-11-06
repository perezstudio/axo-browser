import AxoCore
import AxoWebTestSupport
import Foundation
import Observation
import Synchronization
import Testing
@testable import AxoWeb

/// ``WebViewPool/liveness(for:)``: each tab's liveness, observable on its own, so a sidebar row
/// redraws only when its own tab becomes live or not, its page is replaced, or it starts or
/// stops loading (#70, #72).
@MainActor
struct LivenessTests {
    let engine = FakeEngine()
    let pool: WebViewPool
    let profileID = UUID()
    let tab = Tab.testTab(url: URL(string: "https://example.com/start")!)
    let other = Tab.testTab(url: URL(string: "https://example.com/other")!)

    init() {
        pool = WebViewPool.withFakeEngine(engine)
    }

    /// Lets the pool's update, a turn later, land.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    /// Whether a view reading `tabID`'s liveness and loading flag is told when `change` runs.
    private func notifies(_ tabID: Tab.ID, _ change: () async -> Void) async -> Bool {
        let entry = pool.liveness(for: tabID)
        let changed = Flag()
        withObservationTracking { _ = (entry.isLive, entry.isLoading) } onChange: { changed.set() }
        await change()
        await settle()
        return changed.isSet
    }

    @Test func aPageMadeForATabMakesItLive() async {
        #expect(!pool.liveness(for: tab.id).isLive)
        let notified = await notifies(tab.id) { pool.page(for: tab, profileID: profileID) }
        #expect(notified)
        #expect(pool.liveness(for: tab.id).isLive)
    }

    @Test func anotherTabChangingDoesntNotify() async {
        pool.page(for: tab, profileID: profileID)
        await settle()
        let notified = await notifies(tab.id) {
            pool.page(for: other, profileID: profileID)
            pool.discard(other.id)
        }
        #expect(!notified, "Rows redraw only for their own tab")
    }

    @Test func hibernatingAndClosingMakeItNotLive() async throws {
        pool.page(for: tab, profileID: profileID)
        await settle()
        let page = try #require(engine.pages.last)
        page.finishLoad()

        let notified = await notifies(tab.id) { _ = await pool.hibernate(tab.id) }
        #expect(notified)
        #expect(!pool.liveness(for: tab.id).isLive)

        pool.page(for: tab, profileID: profileID) // wakes
        await settle()
        #expect(pool.liveness(for: tab.id).isLive)
        pool.discard(tab.id)
        await settle()
        #expect(!pool.liveness(for: tab.id).isLive)
    }

    @Test func aKeptDiscardedPageIsntLive() async throws {
        pool.page(for: tab, profileID: profileID)
        let page = try #require(engine.pages.last)
        page.canDiscard = true
        page.finishLoad()
        #expect(await pool.hibernate(tab.id))
        await settle()
        #expect(!pool.liveness(for: tab.id).isLive, "Kept by the engine, but without its renderer")
    }

    @Test func loadingNotifiesButProgressDoesnt() async throws {
        pool.page(for: tab, profileID: profileID)
        await settle()
        let page = try #require(engine.pages.last)
        let started = await notifies(tab.id) {
            page.isLoading = true
            page.delegate?.pageStateDidChange(page)
        }
        #expect(started)
        #expect(pool.liveness(for: tab.id).isLoading)

        let progressed = await notifies(tab.id) {
            page.estimatedProgress = 0.5
            page.delegate?.pageStateDidChange(page)
        }
        #expect(!progressed, "Rows don't redraw as a page's progress moves")
    }

    @Test func aReplacedPageIsFollowed() async throws {
        pool.page(for: tab, profileID: profileID)
        await settle()
        let first = try #require(engine.pages.last)
        first.isLoading = true
        first.delegate?.pageStateDidChange(first)
        #expect(pool.liveness(for: tab.id).isLoading)

        // Replaced in one turn (another profile's page, a page the engine opened): the old
        // page's state, stuck loading, mustn't keep the row spinning.
        pool.discard(tab.id)
        pool.page(for: tab, profileID: profileID)
        await settle()
        #expect(pool.liveness(for: tab.id).isLive)
        #expect(!pool.liveness(for: tab.id).isLoading)
    }
}

/// A flag the observation callback can set from any thread.
private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}
