import AxoCore
import AxoWeb
import Foundation
import Testing
@testable import AxoUI

@MainActor
struct BrowserModelTests {
    let model: BrowserModel
    let pool: WebViewPool
    let directory: URL

    init() async throws {
        pool = WebViewPool(makeDataStore: { _ in .nonPersistent() })
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: pool)
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

    @Test func submittingWhileComposingOpensANewTab() async throws {
        let first = try await openTabs(["one"])[0]
        model.beginNewTab()
        #expect(model.isComposingNewTab)

        await model.submitAddress(try page("two").absoluteString)

        #expect(model.tabs.count == 2)
        #expect(model.selectedTabID != first.id)
        #expect(!model.isComposingNewTab)
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

    @Test func cancelingANewTabKeepsTheSelection() async throws {
        let tab = try await openTabs(["one"])[0]
        model.beginNewTab()
        model.cancelNewTab()
        #expect(!model.isComposingNewTab)
        #expect(model.selectedTabID == tab.id)
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
        await model.moveTabs(fromOffsets: IndexSet(integer: source), toOffset: destination)
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
        try await waitUntil { model.tabs.count == 3 }

        #expect(model.tabs.map(\.url.lastPathComponent) == ["one.html", "target.html", "two.html"])
        #expect(model.selectedTab?.url == target)
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
