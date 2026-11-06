import AxoCore
import AxoWebTestSupport
import Foundation
import Synchronization
import Observation
import Testing
@testable import AxoWeb

/// ``WebViewPool/liveness``: which tabs have a live page, observable, so sidebar rows can dim
/// unloaded tabs (#72) and show loading (#70) without polling.
@MainActor
struct LivenessTests {
    let engine = FakeEngine()
    let pool: WebViewPool
    let profileID = UUID()
    let tab = Tab.testTab(url: URL(string: "https://example.com/start")!)

    init() {
        pool = WebViewPool.withFakeEngine(engine)
    }

    /// Lets the pool's update, a turn later, land.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    /// Whether reading `liveness` gets told when `change` runs.
    private func notifies(_ change: () async -> Void) async -> Bool {
        let changed = Flag()
        withObservationTracking { _ = pool.liveness.liveTabIDs } onChange: { changed.set() }
        await change()
        await settle()
        return changed.isSet
    }

    @Test func aPageMadeForATabMakesItLive() async {
        #expect(!pool.liveness.isLive(tab.id))
        let notified = await notifies { pool.page(for: tab, profileID: profileID) }
        #expect(notified)
        #expect(pool.liveness.isLive(tab.id))
    }

    @Test func hibernatingAndClosingMakeItNotLive() async throws {
        pool.page(for: tab, profileID: profileID)
        await settle()
        let page = try #require(engine.pages.last)
        page.finishLoad()

        let notified = await notifies { _ = await pool.hibernate(tab.id) }
        #expect(notified)
        #expect(!pool.liveness.isLive(tab.id))

        pool.page(for: tab, profileID: profileID) // wakes
        await settle()
        #expect(pool.liveness.isLive(tab.id))
        pool.discard(tab.id)
        await settle()
        #expect(!pool.liveness.isLive(tab.id))
    }

    @Test func aKeptDiscardedPageIsntLive() async throws {
        pool.page(for: tab, profileID: profileID)
        let page = try #require(engine.pages.last)
        page.canDiscard = true
        page.finishLoad()
        #expect(await pool.hibernate(tab.id))
        await settle()
        #expect(!pool.liveness.isLive(tab.id), "Kept by the engine, but without its renderer")
    }

    @Test func loadingProgressDoesntNotify() async throws {
        pool.page(for: tab, profileID: profileID)
        await settle()
        let page = try #require(engine.pages.last)
        let notified = await notifies { page.navigate(to: URL(string: "https://example.com/next")!, title: "Next") }
        #expect(!notified, "Rows don't redraw as pages load")
    }
}

/// A flag the observation callback can set from any thread.
private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}
