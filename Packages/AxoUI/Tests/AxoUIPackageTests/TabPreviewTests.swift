import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
#if os(macOS)
import AppKit
#else
import UIKit
#endif
@testable import AxoUI
@testable import AxoWeb

/// Tab rows' hover card (#76): when it shows and goes, what it says, and that its pictures never
/// make a page or get taken while the sidebar scrolls.
@MainActor
struct TabPreviewTests {
    let engine = FakeEngine()
    let model: BrowserModel
    let anchor = CGRect(x: 10, y: 100, width: 240, height: 28)

    init() async throws {
        let pool = WebViewPool(engine: engine)
        pool.reportsScreenTimeUsage = false
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: pool)
        model.tabPreviewDelay = .milliseconds(30)
        await model.start()
    }

    /// Opens a tab whose page loaded `url` and can be pictured.
    private func openPage(_ url: URL, title: String) async throws -> (AxoCore.Tab.ID, FakePage) {
        await model.openTab(url: url)
        let id = try #require(model.selectedTabID)
        let page = try #require(model.pool.livePage(for: id) as? FakePage)
        page.navigate(to: url, title: title)
        page.snapshotImage = Self.picture()
        return (id, page)
    }

    private func waitForCard(_ condition: (TabPreview) -> Bool = { _ in true }) async throws -> TabPreview {
        let deadline = ContinuousClock.now + .seconds(60)
        while true {
            if let preview = model.tabPreview, condition(preview) { return preview }
            try #require(ContinuousClock.now < deadline, "The card didn't show")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func restingOnARowShowsItsTitleAddressAndPicture() async throws {
        let (id, page) = try await openPage(URL(string: "https://example.com/news?day=1")!, title: "News")
        model.beginTabPreview([id], anchor: anchor, edge: .trailing)
        #expect(model.tabPreview == nil, "Not before the delay")

        let preview = try await waitForCard { $0.pages.first?.picture != nil }
        #expect(preview.pages.map(\.title) == ["News"])
        #expect(preview.pages.first?.url == URL(string: "https://example.com/news?day=1"))
        #expect(preview.anchor == anchor)
        #expect(page.snapshotCount == 1)

        model.endTabPreview([id])
        #expect(model.tabPreview == nil)
    }

    @Test func leavingBeforeTheDelayShowsNothingAndPicturesNothing() async throws {
        let (id, page) = try await openPage(URL(string: "https://example.com/")!, title: "Home")
        model.beginTabPreview([id], anchor: anchor, edge: .trailing)
        let task = try #require(model.tabPreviewTask)
        model.endTabPreview([id])
        #expect(task.isCancelled)
        // Once the cancelled wait ends, it has shown and pictured nothing.
        await task.value
        #expect(model.tabPreview == nil)
        #expect(page.snapshotCount == 0)
    }

    @Test func closingAHoveredTabHidesItsCard() async throws {
        let (first, _) = try await openPage(URL(string: "https://example.com/")!, title: "First")
        _ = try await openPage(URL(string: "https://example.org/")!, title: "Second")
        model.beginTabPreview([first], anchor: anchor, edge: .trailing)
        _ = try await waitForCard()
        // The row's close button closes it without selecting it, and the row may never say the
        // pointer left.
        await model.closeTab(first, byPerson: true)
        #expect(model.tabPreview == nil)
    }

    @Test func switchingSpacesMidScrollDoesntLeaveCardsOff() async throws {
        let (id, _) = try await openPage(URL(string: "https://example.com/")!, title: "Home")
        model.setSidebarScrolling(true)
        // The old Space's list is hidden before it says its scrolling stopped.
        await model.createSpace(name: "Work")
        #expect(!model.isSidebarScrolling)
        let work = try #require(model.space?.id)
        await model.selectSpace(try #require(model.spaces.first { $0.id != work }?.id))
        model.beginTabPreview([id], anchor: anchor, edge: .trailing)
        _ = try await waitForCard()
    }

    @Test func scrollingShowsNothingAndTakesNoPictures() async throws {
        let (id, page) = try await openPage(URL(string: "https://example.com/")!, title: "Home")
        model.setSidebarScrolling(true)
        model.beginTabPreview([id], anchor: anchor, edge: .trailing)
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.tabPreview == nil)
        #expect(page.snapshotCount == 0, "No snapshot work while the sidebar scrolls")

        model.setSidebarScrolling(false)
        model.beginTabPreview([id], anchor: anchor, edge: .trailing)
        _ = try await waitForCard()
        model.setSidebarScrolling(true)
        #expect(model.tabPreview == nil, "Scrolling hides a card that's showing")
    }

    @Test func anotherRowsCardShowsAtOnceWhileOneShows() async throws {
        let (first, _) = try await openPage(URL(string: "https://example.com/")!, title: "First")
        let (second, _) = try await openPage(URL(string: "https://example.org/")!, title: "Second")
        model.beginTabPreview([first], anchor: anchor, edge: .trailing)
        _ = try await waitForCard()

        model.tabPreviewDelay = .seconds(60)
        model.endTabPreview([first])
        model.beginTabPreview([second], anchor: anchor.offsetBy(dx: 0, dy: 28), edge: .trailing)
        let preview = try await waitForCard { $0.tabIDs == [second] }
        #expect(preview.pages.map(\.title) == ["Second"], "Without waiting for the long delay")
    }

    @Test func aSplitsCardShowsEachPane() async throws {
        let (left, _) = try await openPage(URL(string: "https://example.com/")!, title: "Left")
        let (right, _) = try await openPage(URL(string: "https://example.org/")!, title: "Right")
        model.beginTabPreview([left, right], anchor: anchor, edge: .trailing)
        let preview = try await waitForCard { $0.pages.allSatisfy { $0.picture != nil } }
        #expect(preview.pages.map(\.title) == ["Left", "Right"])
    }

    @Test func aHibernatedTabShowsItsSnapshotWithoutWakingAndAPagelessOneHasNoPicture() async throws {
        let (sleeping, _) = try await openPage(URL(string: "https://example.com/")!, title: "Sleeping")
        let (other, _) = try await openPage(URL(string: "https://example.org/")!, title: "Other")
        model.pool.beginShowing(sleeping)
        model.pool.endShowing(sleeping)
        #expect(await model.pool.hibernate(sleeping))
        let pagesBefore = engine.pages.count

        model.beginTabPreview([sleeping], anchor: anchor, edge: .trailing)
        let preview = try await waitForCard { $0.pages.first?.picture != nil }
        #expect(preview.pages.first?.expectsPicture == true)
        #expect(engine.pages.count == pagesBefore, "No page is made for a picture")
        #expect(model.pool.isHibernated(sleeping), "It stays asleep")

        // A tab that never had a page (opened in the background, say) gets no picture.
        model.hideTabPreview()
        let spaceID = try #require(model.space?.id)
        let pageless = try await model.store.openTab(url: URL(string: "https://example.net/")!,
                                                     title: "Never loaded", in: spaceID)
        let deadline = ContinuousClock.now + .seconds(60)
        while !model.tabs.contains(where: { $0.id == pageless.id }) {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        model.beginTabPreview([pageless.id], anchor: anchor, edge: .trailing)
        let none = try await waitForCard { $0.tabIDs == [pageless.id] }
        #expect(none.pages.first?.expectsPicture == false)
        #expect(engine.pages.count == pagesBefore)
        _ = other
    }

    @Test func selectingATabHidesTheCard() async throws {
        let (first, _) = try await openPage(URL(string: "https://example.com/")!, title: "First")
        let (second, _) = try await openPage(URL(string: "https://example.org/")!, title: "Second")
        model.beginTabPreview([first], anchor: anchor, edge: .trailing)
        _ = try await waitForCard()
        model.select(first)
        #expect(model.tabPreview == nil)
        _ = second
    }

    @Test func theCardSitsBesideTheRowInsideTheWindow() {
        let card = CGSize(width: 264, height: 220)
        let window = CGSize(width: 1000, height: 700)
        let beside = TabPreviewLayer.offset(for: anchor, edge: .trailing, card: card, in: window)
        #expect(beside.width >= anchor.maxX, "Never over the row")
        let low = CGRect(x: 10, y: 680, width: 240, height: 28)
        let clamped = TabPreviewLayer.offset(for: low, edge: .trailing, card: card, in: window)
        #expect(clamped.height + card.height <= window.height, "Kept inside the window")

        let tab = CGRect(x: 900, y: 10, width: 160, height: 32)
        let below = TabPreviewLayer.offset(for: tab, edge: .bottom, card: card, in: window)
        #expect(below.height >= tab.maxY, "Below the tab, not over it")
        #expect(below.width + card.width <= window.width)
    }

    @Test func theAddressStressesTheHost() {
        let parts = TabPreviewAddress.parts(of: URL(string: "https://news.example/story/1?x=2")!)
        #expect(parts.host == "news.example")
        #expect(parts.rest == "/story/1?x=2")
        #expect(TabPreviewAddress.parts(of: URL(string: "https://news.example/")!).rest == "")
        let data = TabPreviewAddress.parts(of: URL(string: "data:text/html," + String(repeating: "a", count: 500))!)
        #expect(data.host.isEmpty)
        #expect(data.rest.count == 80)
    }

    /// A small solid image the pool can turn into a JPEG, as a page's snapshot.
    static func picture() -> PlatformImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        guard let image = context.makeImage() else { return nil }
        #if os(macOS)
        return NSImage(cgImage: image, size: NSSize(width: 40, height: 30))
        #else
        return UIImage(cgImage: image)
        #endif
    }
}
