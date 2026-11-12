import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoWeb

/// When the pool reads pages' colors for the toolbar tint (#107): only while asked, for shown
/// pages, once per load, dropping reads a newer load overtook.
@MainActor
struct PageColorPoolTests {
    let engine = FakeEngine()
    let pool: WebViewPool
    let profileID = UUID()
    let tab = Tab.testTab(url: URL(string: "https://example.com/")!)
    let first: [[String]] = [["rgb(10, 20, 30)", ""]]
    let second: [[String]] = [["rgb(200, 100, 50)", ""]]

    init() {
        pool = WebViewPool.withFakeEngine(engine)
        pool.readsPageColors = true
    }

    private func page() throws -> FakePage {
        pool.page(for: tab, profileID: profileID)
        return try #require(engine.pages.last)
    }

    private var colorScripts: Int {
        engine.pages.last?.scripts.filter { $0.world == PageText.world }.count ?? 0
    }

    private func waitForColors(_ color: PageColor?) async throws {
        try await waitUntil("page colors") { pool.state(for: tab.id)?.pageColors?.themeColor == color && !pool.isReadingPageColors(tab.id) }
    }

    @Test func readsAShownPageWhenItFinishesLoading() async throws {
        pool.beginShowing(tab.id)
        let page = try page()
        page.scriptResult = first
        page.finishLoad()
        #expect(pool.isReadingPageColors(tab.id))
        try await waitForColors(PageColor(red: 10 / 255, green: 20 / 255, blue: 30 / 255))
    }

    @Test func readsNothingWhileNotAsked() throws {
        pool.readsPageColors = false
        pool.beginShowing(tab.id)
        let page = try page()
        page.scriptResult = first
        page.finishLoad()
        #expect(!pool.isReadingPageColors(tab.id))
        #expect(colorScripts == 0)
    }

    @Test func turningItOnReadsShownPages() async throws {
        pool.readsPageColors = false
        pool.beginShowing(tab.id)
        let page = try page()
        page.scriptResult = first
        page.finishLoad()

        pool.readsPageColors = true
        #expect(pool.isReadingPageColors(tab.id))
        try await waitForColors(PageColor(red: 10 / 255, green: 20 / 255, blue: 30 / 255))
    }

    @Test func aPageThatLoadedHiddenIsReadWhenShown() async throws {
        let page = try page()
        page.scriptResult = first
        page.finishLoad()
        #expect(!pool.isReadingPageColors(tab.id), "Hidden pages aren't read; they may never have been drawn")

        pool.beginShowing(tab.id)
        #expect(pool.isReadingPageColors(tab.id))
        try await waitForColors(PageColor(red: 10 / 255, green: 20 / 255, blue: 30 / 255))
    }

    @Test func aLoadIsReadOnceNotEachTimeItsShown() async throws {
        pool.beginShowing(tab.id)
        let page = try page()
        page.scriptResult = first
        page.finishLoad()
        try await waitForColors(PageColor(red: 10 / 255, green: 20 / 255, blue: 30 / 255))

        pool.endShowing(tab.id)
        pool.beginShowing(tab.id)
        #expect(!pool.isReadingPageColors(tab.id))
        #expect(colorScripts == 1)
    }

    @Test func aReadANewerLoadOvertookIsDroppedAndTheNewerLoadIsRead() async throws {
        pool.beginShowing(tab.id)
        let page = try page()
        page.holdsScripts = true
        page.scriptResult = first
        page.finishLoad()
        try await waitUntil("first read asked") { page.heldScriptCount == 1 }

        // The page loads again (the same address, as a reload) before the first read answers.
        page.finishLoad()
        page.answerHeldScript()
        try await waitUntil("second read asked") { page.heldScriptCount == 1 }
        #expect(pool.state(for: tab.id)?.pageColors == nil, "The first load's read was dropped")

        page.scriptResult = second
        page.answerHeldScript()
        try await waitForColors(PageColor(red: 200 / 255, green: 100 / 255, blue: 50 / 255))
    }

    @Test func aFailedLoadKeepsTheColorsOfThePageStillShowing() async throws {
        pool.beginShowing(tab.id)
        let page = try page()
        page.scriptResult = first
        page.finishLoad()
        try await waitForColors(PageColor(red: 10 / 255, green: 20 / 255, blue: 30 / 255))

        page.failLoad()
        #expect(pool.state(for: tab.id)?.pageColors?.themeColor == PageColor(red: 10 / 255, green: 20 / 255, blue: 30 / 255))
    }

    @Test func aPageWithNoSizeYetIsReadAgainWhenNextShown() async throws {
        pool.beginShowing(tab.id)
        let page = try page()
        page.scriptResult = [[String]]() // No theme-color, so its top color is needed.
        page.snapshotImage = SnapshotTimingTests.image(width: 40, height: 30, red: 0, green: 0, blue: 1)
        page.finishLoad()
        try await waitUntil("first read") { !pool.isReadingPageColors(tab.id) && colorScripts == 1 }
        #expect(page.snapshotCount == 0, "A page with no size isn't snapshotted")
        #expect(pool.state(for: tab.id)?.pageColors?.topColor == nil)

        page.view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        pool.endShowing(tab.id)
        pool.beginShowing(tab.id)
        try await waitUntil("top color") { pool.state(for: tab.id)?.pageColors?.topColor != nil }
        let top = try #require(pool.state(for: tab.id)?.pageColors?.topColor)
        #expect(top.blue > 0.9 && top.red < 0.1, "\(top)")

        // Now it's complete, so showing it again reads nothing.
        try await waitUntil("read done") { !pool.isReadingPageColors(tab.id) }
        pool.endShowing(tab.id)
        pool.beginShowing(tab.id)
        #expect(!pool.isReadingPageColors(tab.id))
    }
}
