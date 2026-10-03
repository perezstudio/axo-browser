import AxoCore
import AxoWeb
import Foundation
import Testing
@testable import AxoUI

@MainActor
struct SplitViewModelTests {
    let store: TabStore
    let model: BrowserModel
    let directory: URL

    init() async throws {
        store = try TabStore.makeInMemory()
        model = BrowserModel(store: store, pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        directory = FileManager.default.temporaryDirectory
            .appending(path: "AxoSplitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await model.start()
        model.announce = { _ in }
    }

    /// Adds a titled tab without loading it, and returns it.
    private func add(_ name: String) async throws -> AxoCore.Tab {
        let url = directory.appending(path: "\(name).html")
        try "<title>\(name)</title>".write(to: url, atomically: true, encoding: .utf8)
        let tab = try await store.openTab(url: url, title: name, in: try #require(model.space).id)
        try await waitUntil { model.tabs.contains { $0.id == tab.id } }
        return tab
    }

    /// Tabs by file name. Titles can be briefly empty while a selected tab's page loads.
    private func names(_ tabs: [AxoCore.Tab]) -> [String] {
        tabs.map { $0.url.deletingPathExtension().lastPathComponent }
    }

    private func split(_ names: [String]) async throws -> [AxoCore.Tab] {
        var tabs: [AxoCore.Tab] = []
        for name in names { tabs.append(try await add(name)) }
        model.select(tabs[0].id)
        for tab in tabs.dropFirst() {
            await model.addToSplit(tab.id)
            model.select(tabs[0].id)
        }
        return tabs
    }

    @Test func addingATabMakesOneSidebarRowShowingBoth() async throws {
        let tabs = try await split(["A", "B"])
        let splitView = try #require(model.selectedSplit)
        #expect(names(model.panes(of: splitView.id)) == ["A", "B"])
        #expect(model.isSplitFollower(tabs[1]))
        #expect(!model.isSplitFollower(tabs[0]))
        #expect(model.sidebarRowTab(for: tabs[1].id) == tabs[0].id)
    }

    @Test func focusingAPaneSelectsItButKeepsTheRow() async throws {
        let tabs = try await split(["A", "B"])
        model.paneDidTakeFocus(tabs[1].id)
        #expect(model.selectedTabID == tabs[1].id)
        #expect(model.selectedSidebarItem == .tab(tabs[0].id), "The split's row stays selected")

        // Selecting another tab and coming back returns to the focused pane.
        let other = try await add("Other")
        model.select(other.id)
        model.paneDidTakeFocus(tabs[0].id)
        #expect(model.selectedTabID == other.id, "Panes of a split that isn't on screen don't take over")
        model.selectSidebarItem(.tab(tabs[0].id))
        #expect(model.selectedTabID == tabs[1].id)
    }

    @Test func addSplitViewUsesTheCommandBarChoice() async throws {
        let a = try await add("A"), b = try await add("B")
        model.select(a.id)
        model.beginSplitWithNewTab()
        #expect(model.isCommandBarVisible && model.pendingSplitAnchor == a.id)

        model.setCommandQuery("B")
        let row = try #require(model.commandResults.firstIndex { if case .tab(let tab) = $0 { tab.id == b.id } else { false } })
        await model.runCommand(at: row)
        #expect(model.selectedSplit != nil)
        #expect(model.panes(of: try #require(model.selectedSplit).id).map(\.id) == [a.id, b.id])
        #expect(model.pendingSplitAnchor == nil)
    }

    @Test func addSplitViewCanOpenANewPage() async throws {
        let a = try await add("A")
        model.select(a.id)
        model.beginSplitWithNewTab()
        model.setCommandQuery(directory.appending(path: "A.html").absoluteString)
        await model.runCommand(at: 0)
        #expect(model.tabs.count == 2)
        #expect(model.selectedSplit.map { model.panes(of: $0.id).count } == 2)
    }

    @Test func cancellingTheCommandBarCancelsTheSplit() async throws {
        let a = try await add("A")
        model.select(a.id)
        model.beginSplitWithNewTab()
        model.hideCommandBar()
        #expect(model.pendingSplitAnchor == nil)
    }

    @Test func splitsAreLimitedToFourPanes() async throws {
        _ = try await split(["1", "2", "3", "4"])
        #expect(!model.canAddToSplit)
        #expect(!model.availableActions.contains(.addSplitView))
        #expect(model.availableActions.contains(.separateSplitView))
    }

    @Test func closingAPaneKeepsTheRestOfTheSplit() async throws {
        let tabs = try await split(["A", "B", "C"])
        model.select(tabs[1].id)
        await model.closeSelectedTab()
        let splitView = try #require(model.selectedSplit)
        #expect(names(model.panes(of: splitView.id)) == ["A", "C"])
    }

    @Test func splitsCanBeRotatedSeparatedAndLeft() async throws {
        let tabs = try await split(["A", "B", "C"])
        await model.toggleSplitOrientation()
        #expect(model.selectedSplit?.orientation == .vertical)

        model.select(tabs[2].id)
        await model.removeSelectedTabFromSplit()
        #expect(model.split(of: tabs[2].id) == nil)
        #expect(model.split(of: tabs[0].id) != nil)

        model.select(tabs[0].id)
        await model.separateSelectedSplit()
        #expect(model.splits.isEmpty)
        #expect(model.selectedSplit == nil)
    }

    @Test func nextTabStepsThroughEachPane() async throws {
        let tabs = try await split(["A", "B"])
        let c = try await add("C")
        #expect(model.visibleTabOrder == [tabs[0].id, tabs[1].id, c.id])
    }

    @Test func movingASplitRowMovesItsPanesTogether() async throws {
        let tabs = try await split(["A", "B"])
        let c = try await add("C")
        model.select(c.id)
        await model.moveSelectedItem(by: -1)
        #expect(names(model.tabs) == ["C", "A", "B"])
        _ = tabs
    }
}
