import AppKit
import AxoCore
import AxoWeb
import Foundation
import Testing
@testable import AxoUI

@MainActor
struct BrowserModelTests {
    let model: BrowserModel
    let store: TabStore
    let pool: WebViewPool
    let directory: URL

    init() async throws {
        pool = WebViewPool(makeDataStore: { _ in .nonPersistent() })
        store = try TabStore.makeInMemory()
        model = BrowserModel(store: store, pool: pool)
        directory = FileManager.default.temporaryDirectory
            .appending(path: "AxoUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await model.start()
    }

    /// A local page, so selecting a tab never touches the network.
    private func page(_ name: String) throws -> URL {
        let url = directory.appending(path: "\(name).html")
        try "<!doctype html><title>\(name)</title>".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func openTabs(_ names: [String]) async throws -> [AxoCore.Tab] {
        for name in names {
            await model.openTab(url: try page(name))
        }
        return model.tabs
    }

    @Test func startsWithTheDefaultSpaceAndNoTabs() {
        #expect(model.space?.name == TabStore.defaultSpaceName)
        #expect(model.tabs.isEmpty)
        #expect(model.selectedTabID == nil)
        #expect(model.selectedPage == nil)
    }

    @Test func openingATabSelectsItAndCreatesItsWebView() async throws {
        let tabs = try await openTabs(["one", "two"])

        #expect(tabs.map(\.url.lastPathComponent) == ["one.html", "two.html"])
        #expect(model.selectedTabID == tabs[1].id)
        #expect(model.selectedPage != nil)
        #expect(pool.isLive(tabs[1].id))
    }

    @Test func newTabOpensTheCommandBar() async throws {
        let first = try await openTabs(["one"])[0]
        model.beginNewTab()
        #expect(model.isCommandBarVisible)

        model.setCommandQuery(try page("two").absoluteString)
        await model.runCommand()

        #expect(model.tabs.count == 2)
        #expect(model.selectedTabID != first.id)
        #expect(!model.isCommandBarVisible)
    }

    @Test func submittingWithATabSelectedLoadsInThatTab() async throws {
        let tab = try await openTabs(["one"])[0]
        await model.submitAddress(try page("two").absoluteString)

        #expect(model.tabs.count == 1)
        try await waitUntil { model.selectedPage?.title == "two" }
        #expect(model.selectedTabID == tab.id)
    }

    @Test func submittingWithNoTabsOpensOne() async throws {
        await model.submitAddress(try page("one").absoluteString)
        #expect(model.tabs.count == 1)
        #expect(model.selectedTabID == model.tabs.first?.id)
    }

    @Test func submittingBlankTextDoesNothing() async {
        await model.submitAddress("   ")
        #expect(model.tabs.isEmpty)
    }

    @Test func closingTheSelectedTabSelectsTheNextOne() async throws {
        let tabs = try await openTabs(["one", "two", "three"])
        model.select(tabs[1].id)

        await model.closeSelectedTab()
        #expect(model.tabs.map(\.id) == [tabs[0].id, tabs[2].id])
        #expect(model.selectedTabID == tabs[2].id)
        #expect(!pool.isLive(tabs[1].id))

        await model.closeSelectedTab()
        #expect(model.selectedTabID == tabs[0].id)

        await model.closeSelectedTab()
        #expect(model.tabs.isEmpty)
        #expect(model.selectedTabID == nil)
        #expect(model.selectedPage == nil)
    }

    @Test func closingAnotherTabKeepsTheSelection() async throws {
        let tabs = try await openTabs(["one", "two"])
        await model.closeTab(tabs[0].id)
        #expect(model.selectedTabID == tabs[1].id)
    }

    @Test(arguments: [
        // (source, destination) as List.onMove reports them, and the resulting order.
        (0, 3, ["b", "c", "a"]),
        (2, 0, ["c", "a", "b"]),
        (0, 2, ["b", "a", "c"]),
        (1, 1, ["a", "b", "c"]),
        (1, 2, ["a", "b", "c"]),
    ])
    func draggingReordersTabs(source: Int, destination: Int, expected: [String]) async throws {
        _ = try await openTabs(["a", "b", "c"])
        await model.moveTabs(fromOffsets: IndexSet(integer: source), toOffset: destination, pinned: false)
        #expect(model.tabs.map { $0.url.deletingPathExtension().lastPathComponent } == expected)
    }

    @Test func pageChangesAreSavedToTheTab() async throws {
        let tab = try await openTabs(["titled"])[0]
        try await waitUntil { model.tabs.first?.title == "titled" }
        #expect(model.tabs.first?.id == tab.id)
    }

    @Test func linksThatOpenANewWindowOpenATabAfterTheirSource() async throws {
        let tabs = try await openTabs(["one", "two"])
        let target = try page("target")

        pool.onOpenInNewTab?(target, tabs[0].id)
        // The tab list can update (through observation) before the new tab is selected.
        try await waitUntil { model.tabs.count == 3 && model.selectedTab?.url == target }

        #expect(model.tabs.map(\.url.lastPathComponent) == ["one.html", "target.html", "two.html"])
    }

    // MARK: Find

    /// Opens a tab with `body` and waits for it to load.
    private func openLoadedTab(_ name: String, body: String) async throws {
        let url = directory.appending(path: "\(name).html")
        try "<!doctype html><title>\(name)</title>\(body)".write(to: url, atomically: true, encoding: .utf8)
        await model.openTab(url: url)
        try await waitUntil { model.selectedPage?.title == name && model.selectedPage?.isLoading == false }
    }

    @Test func theFindBarNeedsATab() {
        model.showFindBar()
        #expect(!model.isFindBarVisible)
    }

    @Test func findingReportsMatchesAndMisses() async throws {
        try await openLoadedTab("Pond", body: "<p>Axolotls live in lakes.</p>")
        model.showFindBar()
        #expect(model.isFindBarVisible)

        model.findText = "lakes"
        await model.findNext()
        #expect(!model.findHasNoMatches)

        model.findText = "ocean"
        await model.findPrevious()
        #expect(model.findHasNoMatches)

        model.findText = ""
        await model.findNext()
        #expect(!model.findHasNoMatches, "Empty text isn't a miss")
    }

    @Test func findNextOpensTheBarIfItWasClosed() async throws {
        try await openLoadedTab("Pond", body: "<p>Axolotls live in lakes.</p>")
        model.findText = "lakes"
        await model.findNext()
        #expect(model.isFindBarVisible)
    }

    @Test func closingOrSwitchingTabsHidesTheFindBar() async throws {
        try await openLoadedTab("One", body: "<p>first</p>")
        let first = try #require(model.selectedTabID)
        try await openLoadedTab("Two", body: "<p>second</p>")
        model.showFindBar()
        model.findText = "nothing here"
        await model.findNext()

        model.select(first)
        #expect(!model.isFindBarVisible)
        #expect(!model.findHasNoMatches)

        model.showFindBar()
        model.closeFindBar()
        #expect(!model.isFindBarVisible)
    }

    // MARK: Favicons

    /// A 16 px PNG, standing in for a normalized favicon.
    private func iconData() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func reportedFaviconsShowForEveryTabOnThatHostAndAreSaved() async throws {
        let page = URL(string: "https://example.com/a")!
        let sameSite = AxoCore.Tab(spaceID: UUID(), url: URL(string: "https://EXAMPLE.com/b")!, sortKey: "a0")
        let otherSite = AxoCore.Tab(spaceID: UUID(), url: URL(string: "https://swift.org")!, sortKey: "a0")

        pool.onFaviconChange?(UUID(), page, try iconData())

        #expect(model.favicon(for: sameSite) != nil)
        #expect(model.favicon(for: otherSite) == nil)
        try await waitUntilAsync { try await !store.favicons(forHosts: ["example.com"]).isEmpty }
    }

    @Test func savedFaviconsLoadForTabsAtLaunch() async throws {
        // A fresh model over a store that already has a tab and its site's icon.
        let space = try await store.bootstrap()
        let tab = try await store.openTab(url: try page("saved"), in: space.id)
        let webTab = try await store.openTab(url: URL(string: "about:blank")!, in: space.id)
        try await store.saveFavicon(try iconData(), for: URL(string: "https://apple.com")!)
        try await store.updateTab(id: webTab.id, url: URL(string: "https://apple.com/mac")!, title: "Mac")

        let relaunched = BrowserModel(store: store, pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        await relaunched.start()

        let reloaded = try #require(relaunched.tabs.first { $0.id == webTab.id })
        #expect(relaunched.favicon(for: reloaded) != nil)
        #expect(relaunched.favicon(for: tab) == nil)
    }

}

/// Polls until `condition` is true, or fails after 10 seconds.
@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        try #require(ContinuousClock.now < deadline, "Timed out")
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Polls an async condition until it's true, or fails after 10 seconds.
@MainActor
func waitUntilAsync(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while try await !condition() {
        try #require(ContinuousClock.now < deadline, "Timed out")
        try await Task.sleep(for: .milliseconds(20))
    }
}
