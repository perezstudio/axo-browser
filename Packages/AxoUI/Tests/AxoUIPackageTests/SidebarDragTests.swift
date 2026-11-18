import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

/// Dragging rows between Pinned, folders, the tabs section, and Favorites (#77): where each drop
/// lands, what it pins or unpins, and that one row changes per row moved.
@MainActor
struct SidebarDragTests {
    let engine = FakeEngine()
    let model: BrowserModel

    init() async throws {
        let pool = WebViewPool(engine: engine)
        pool.reportsScreenTimeUsage = false
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: pool)
        await model.start()
    }

    private func tab(_ name: String, pinned: Bool = false) async throws -> AxoCore.Tab {
        await model.openTab(url: URL(string: "https://\(name).example/")!)
        let tab = try #require(model.tabs.last)
        if pinned { await model.setPinned(true, tabID: tab.id) }
        return tab
    }

    private func name(_ tab: AxoCore.Tab) -> String { tab.url.host()!.replacingOccurrences(of: ".example", with: "") }

    /// The pinned section as nested names.
    private func describe(_ nodes: [PinnedNode]) -> [String] {
        nodes.map { node in
            switch node {
            case .tab(let tab): name(tab)
            case .folder(let folder, let children): "\(folder.name)[\(describe(children).joined(separator: ", "))]"
            }
        }
    }

    private var unpinned: [String] { model.unpinnedTabs.map(name) }

    @Test func aTabDroppedInPinnedIsPinnedAtTheDropPoint() async throws {
        let a = try await tab("a", pinned: true)
        _ = try await tab("b", pinned: true)
        let c = try await tab("c")
        let sortKeysBefore = Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, $0.sortKey) })

        await model.moveSidebarItems([.tab(c.id)], to: .pinned(nil), before: .tab(a.id))
        #expect(describe(model.pinnedTree) == ["c", "a", "b"])
        #expect(model.tabs.first { $0.id == c.id }?.isPinned == true)
        let changed = model.tabs.filter { sortKeysBefore[$0.id] != $0.sortKey }.map(\.id)
        #expect(changed == [c.id], "One row changes per row moved")
    }

    @Test func aPinnedTabDroppedInTheTabsSectionIsUnpinnedThere() async throws {
        let pinned = try await tab("pinned", pinned: true)
        let x = try await tab("x")
        _ = try await tab("y")

        await model.moveSidebarItems([.tab(pinned.id)], to: .tabs, before: .tab(x.id))
        #expect(unpinned == ["pinned", "x", "y"])
        #expect(model.pinnedTree.isEmpty)
        #expect(model.tabs.first { $0.id == pinned.id }?.homeURL == nil)

        // At the end, with no row under the drop.
        let other = try await tab("other", pinned: true)
        await model.moveSidebarItems([.tab(other.id)], to: .tabs, before: nil)
        #expect(unpinned.last == "other")
    }

    @Test func dropsIntoAFolderLandAmongItsRows() async throws {
        let a = try await tab("a", pinned: true)
        let b = try await tab("b", pinned: true)
        let loose = try await tab("loose")
        await model.createFolder(named: "Work", moving: .tab(a.id))
        await model.move(.tab(b.id), toFolder: try #require(model.folders.first?.id))
        let work = try #require(model.folders.first)
        #expect(describe(model.pinnedTree) == ["Work[a, b]"])

        await model.moveSidebarItems([.tab(loose.id)], to: .pinned(work.id), before: .tab(b.id))
        #expect(describe(model.pinnedTree) == ["Work[a, loose, b]"])
        await model.moveSidebarItems([.tab(a.id)], to: .pinned(nil), before: nil)
        #expect(describe(model.pinnedTree) == ["Work[loose, b]", "a"])
    }

    @Test func foldersMoveBetweenLevelsButNeverIntoThemselvesOrTheTabsSection() async throws {
        let a = try await tab("a", pinned: true)
        await model.createFolder(named: "Outer", moving: .tab(a.id))
        let outer = try #require(model.folders.first { $0.name == "Outer" })
        await model.createFolder(named: "Inner", parent: outer.id)
        let inner = try #require(model.folders.first { $0.name == "Inner" })
        await model.createFolder(named: "Other")
        let other = try #require(model.folders.first { $0.name == "Other" })
        let before = describe(model.pinnedTree)

        await model.moveSidebarItems([.folder(outer.id)], to: .pinned(inner.id), before: nil)
        #expect(describe(model.pinnedTree) == before, "Not into a folder inside it")
        await model.moveSidebarItems([.folder(outer.id)], to: .tabs, before: nil)
        #expect(describe(model.pinnedTree) == before, "Folders stay in Pinned")

        await model.moveSidebarItems([.folder(other.id)], to: .pinned(outer.id), before: nil)
        #expect(describe(model.pinnedTree) == ["Outer[a, Inner[], Other[]]"])
    }

    @Test func aSplitMovesAsOneKeepingItsOrder() async throws {
        let left = try await tab("left")
        let right = try await tab("right")
        _ = try await tab("after")
        model.select(left.id)
        await model.addToSplit(right.id)
        try #require(model.split(of: left.id) != nil)
        let rowTab = model.sidebarRowTab(for: left.id)
        let others = model.tabs.filter { model.split(of: $0.id) == nil }.map(\.id)
        let sortKeysBefore = Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, $0.sortKey) })

        await model.moveSidebarItems([.tab(rowTab)], to: .pinned(nil), before: nil)
        #expect(model.tabs.first { $0.id == left.id }?.isPinned == true)
        #expect(model.tabs.first { $0.id == right.id }?.isPinned == true, "Its other pane goes with it")
        #expect(model.sidebarRowTab(for: left.id) == rowTab, "The same pane still stands for the row")
        #expect(model.pinnedTabs.map(name) == ["left", "right"], "The panes keep their order")
        #expect(unpinned == ["after"])
        let changed = model.tabs.filter { sortKeysBefore[$0.id] != $0.sortKey }.map(\.id)
        #expect(!changed.contains { others.contains($0) }, "Only the split's panes change")
    }

    @Test func aDropAfterASplitsRowNeverLandsBetweenItsPanes() async throws {
        let left = try await tab("left", pinned: true)
        let right = try await tab("right", pinned: true)
        let other = try await tab("other")
        model.select(left.id)
        await model.addToSplit(right.id)
        try #require(model.split(of: left.id) != nil)
        try #require(model.pinnedTabs.map(name) == ["left", "right"])

        await model.moveSidebarItems([.tab(other.id)], to: .pinned(nil), before: nil)
        #expect(model.pinnedTabs.map(name) == ["left", "right", "other"])
    }

    @Test func foldersMixedIntoADragToTheTabsSectionStayPinned() async throws {
        let pinned = try await tab("pinned", pinned: true)
        await model.createFolder(named: "Work")
        let work = try #require(model.folders.first)
        _ = try await tab("x")
        await model.moveSidebarItems([.folder(work.id), .tab(pinned.id)], to: .tabs, before: nil)
        #expect(unpinned == ["x", "pinned"])
        #expect(describe(model.pinnedTree) == ["Work[]"])
    }

    @Test func aFavoriteDroppedInTheSidebarBecomesATabThereKeepingItsID() async throws {
        let fav = try await tab("fav")
        await model.addToFavorites(fav.id)
        try #require(model.favorites.contains { $0.id == fav.id })
        let x = try await tab("x")

        await model.moveFavoriteToSidebar(fav.id, to: .tabs, before: .tab(x.id))
        #expect(!model.favorites.contains { $0.id == fav.id })
        #expect(unpinned == ["fav", "x"], "In the tabs section, at the drop point")
        #expect(model.tabs.first { $0.id == fav.id }?.isPinned == false)

        await model.addToFavorites(fav.id)
        let pinned = try await tab("pinned", pinned: true)
        await model.moveFavoriteToSidebar(fav.id, to: .pinned(nil), before: .tab(pinned.id))
        #expect(describe(model.pinnedTree) == ["fav", "pinned"])

        // Into a folder.
        await model.addToFavorites(fav.id)
        await model.createFolder(named: "Work")
        let work = try #require(model.folders.first)
        await model.moveFavoriteToSidebar(fav.id, to: .pinned(work.id), before: nil)
        #expect(describe(model.pinnedTree) == ["pinned", "Work[fav]"])
    }

    @Test func aRowDroppedOnFavoritesBecomesAFavoriteThere() async throws {
        let first = try await tab("first")
        await model.addToFavorites(first.id)
        let second = try await tab("second")
        await model.addToFavorites(second.id)
        let dragged = try await tab("dragged")

        await model.dropTabOnFavorites(dragged.id, before: second.id)
        try await waitUntil { model.favorites.map(\.id) == [first.id, dragged.id, second.id] }
        #expect(!model.tabs.contains { $0.id == dragged.id })

        // On the grid itself, not a tile: at the end.
        let last = try await tab("last")
        await model.dropTabOnFavorites(last.id, before: nil)
        try await waitUntil { model.favorites.map(\.id).last == last.id }
    }

    @Test func aSplitsRowDoesntBecomeAFavoriteByDrag() async throws {
        let left = try await tab("left")
        let right = try await tab("right")
        model.select(left.id)
        await model.addToSplit(right.id)
        await model.dropTabOnFavorites(left.id, before: nil)
        #expect(model.favorites.isEmpty)
        #expect(model.split(of: left.id) != nil, "The split stays whole")
    }
}
