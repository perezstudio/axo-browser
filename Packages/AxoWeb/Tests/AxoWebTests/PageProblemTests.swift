import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
import WebKit
@testable import AxoWeb

/// Crashed and unresponsive pages (#75): the engine's reports reach the tab's state and the pool's
/// handler, recovering clears them, and a stopped page's blank picture never becomes its snapshot.
@MainActor
struct PageProblemTests {
    let engine = FakeEngine()
    let pool: WebViewPool
    let profileID = UUID()
    let tab = Tab.testTab(url: URL(string: "https://example.com/start")!)

    init() {
        pool = WebViewPool.withFakeEngine(engine)
    }

    @Test func aCrashIsReportedUntilThePageReloads() throws {
        var reported: [PageProblem?] = []
        pool.onPageProblem = { tabID, problem in
            #expect(tabID == tab.id)
            reported.append(problem)
        }
        pool.page(for: tab, profileID: profileID)
        let page = try #require(engine.pages.last)
        let state = try #require(pool.state(for: tab.id))
        #expect(state.problem == nil)

        page.simulateProblem(.crashed(errorCode: 5))
        #expect(state.problem == .crashed(errorCode: 5))
        // The same report again changes nothing.
        page.simulateProblem(.crashed(errorCode: 5))
        #expect(reported == [.crashed(errorCode: 5)])

        // The engine reports the page working again once it reloaded.
        page.simulateProblem(nil)
        #expect(state.problem == nil)
        #expect(reported == [.crashed(errorCode: 5), nil])
    }

    @Test func aHungPageCanBeGivenMoreTime() throws {
        pool.page(for: tab, profileID: profileID)
        let page = try #require(engine.pages.last)
        let state = try #require(pool.state(for: tab.id))

        page.simulateProblem(.unresponsive)
        #expect(state.problem == .unresponsive)
        pool.livePage(for: tab.id)?.waitForResponse()
        #expect(page.waitsForResponse == 1)
        page.simulateProblem(nil)
        #expect(state.problem == nil)

        // Still hung after waiting: reported again, and it can recover on its own.
        page.simulateProblem(.unresponsive)
        #expect(state.problem == .unresponsive)
        page.simulateProblem(nil)
        #expect(state.problem == nil)
    }

    @Test func aPageThatStartsStoppedSaysSo() throws {
        // A page whose renderer is already gone when its tab becomes live.
        engine.problemForNewPages = .outOfMemory
        pool.page(for: tab, profileID: profileID)
        #expect(pool.state(for: tab.id)?.problem == .outOfMemory)
    }

    @Test func aMissedReportClearsOnceThePageMovesOn() throws {
        pool.page(for: tab, profileID: profileID)
        let page = try #require(engine.pages.last)
        page.simulateProblem(.crashed(errorCode: 5))
        // The engine's page went to another site with a new renderer, but said nothing.
        page.changeProblemQuietly(nil)
        page.finishLoad()
        #expect(pool.state(for: tab.id)?.problem == nil)
    }

    @Test func aStoppedPageIsntSnapshotted() async throws {
        pool.page(for: tab, profileID: profileID)
        let page = try #require(engine.pages.last)
        page.snapshotImage = SnapshotTimingTests.image(width: 10, height: 10, red: 0, green: 1, blue: 0)
        page.simulateProblem(.crashed(errorCode: nil))

        pool.beginShowing(tab.id)
        pool.endShowing(tab.id)
        #expect(!pool.isSnapshotting(tab.id))
        #expect(await pool.hibernate(tab.id))
        #expect(page.snapshotCount == 0, "A crashed page draws nothing worth keeping")

        // Once it works again, it's snapshotted as usual.
        let working = Tab.testTab(url: URL(string: "https://example.com/working")!)
        pool.page(for: working, profileID: profileID)
        let workingPage = try #require(engine.pages.last)
        workingPage.snapshotImage = SnapshotTimingTests.image(width: 10, height: 10, red: 0, green: 1, blue: 0)
        pool.beginShowing(working.id)
        pool.endShowing(working.id)
        try await waitUntil("the snapshot") { !pool.isSnapshotting(working.id) }
        #expect(workingPage.snapshotCount == 1)
    }

    /// WebKit reports its content process ending, and that it's over once the page loads again.
    /// Its process can't be ended from a test without private API, so the test calls the
    /// navigation delegate as WebKit does.
    @Test func webKitReportsAnEndedContentProcessUntilThePageLoadsAgain() async throws {
        let pages = try TestPages()
        let webKitPool = WebViewPool.forTesting()
        let webKitTab = Tab.testTab(url: try pages.page("Start"))
        var reported: [PageProblem?] = []
        webKitPool.onPageProblem = { _, problem in reported.append(problem) }
        let page = try #require(webKitPool.page(for: webKitTab, profileID: profileID) as? WebKitPage)
        let state = try #require(webKitPool.state(for: webKitTab.id))
        try await waitUntil("the page") { state.title == "Start" && !state.isLoading }

        page.webViewWebContentProcessDidTerminate(page.webView)
        #expect(state.problem == .crashed(errorCode: nil))

        page.reload()
        try await waitUntil("the reload") { state.problem == nil }
        try await waitUntil("the page again") { state.title == "Start" && !state.isLoading }
        #expect(reported == [.crashed(errorCode: nil), nil])
    }
}
