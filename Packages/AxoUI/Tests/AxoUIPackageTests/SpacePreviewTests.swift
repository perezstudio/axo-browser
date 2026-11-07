import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

/// Every Space's sidebar rows, kept loaded so a swipe between Spaces can slide the neighboring
/// Space in under the fingers (#84).
@MainActor
struct SpacePreviewTests {
    let engine = FakeEngine()
    let model: BrowserModel

    init() async throws {
        let pool = WebViewPool(engine: engine)
        pool.reportsScreenTimeUsage = false
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: pool)
        model.announce = { _ in }
        await model.start()
    }

    private func open(_ path: String) async throws -> AxoCore.Tab.ID {
        await model.openTab(url: URL(string: "https://example.com/\(path)")!)
        return try #require(model.selectedTabID)
    }

    /// Waits for the previews' reload, a turn after the Spaces change.
    private func previewsSettle() async {
        for _ in 0..<50 {
            await Task.yield()
            if let load = model.spacePreviewLoad { await load.value }
        }
    }

    @Test func aPreviewShowsRowsAsTheSidebarDoes() throws {
        let space = Space(id: UUID(), profileID: UUID(), name: "Work", sortKey: "a")
        let splitID = UUID()
        var a = AxoCore.Tab(id: UUID(), spaceID: space.id, url: URL(string: "https://a.example")!, title: "A", sortKey: "a")
        var b = AxoCore.Tab(id: UUID(), spaceID: space.id, url: URL(string: "https://b.example")!, title: "B", sortKey: "b")
        let c = AxoCore.Tab(id: UUID(), spaceID: space.id, url: URL(string: "https://c.example")!, title: "C", sortKey: "c")
        var pinned = AxoCore.Tab(id: UUID(), spaceID: space.id, url: URL(string: "https://p.example")!, title: "P", sortKey: "a")
        pinned.isPinned = true
        a.splitID = splitID
        a.splitSortKey = "b"
        b.splitID = splitID
        b.splitSortKey = "a"
        let split = TabSplit(id: splitID, spaceID: space.id, orientation: .horizontal)

        let preview = SpaceSidebarPreview.make(
            space: space, tabs: [pinned, a, b, c], folders: [], splits: [split], selectedTabID: b.id)
        #expect(preview.rows.map(\.id) == [a.id, c.id], "The split is one row, standing for its first tab")
        #expect(preview.rows.first == .split(leader: a.id, panes: [b, a]), "Panes in pane order")
        #expect(preview.pinnedTree.map(\.id) == [.tab(pinned.id)])
        #expect(preview.selectedTabID == b.id)
        #expect(preview.holdsSelection(a.id), "A split's row holds the selection when any pane has it")
        #expect(!preview.holdsSelection(c.id))
        #expect(!preview.holdsSelection(pinned.id))

        let forgotten = SpaceSidebarPreview.make(space: space, tabs: [c], folders: [], splits: [], selectedTabID: UUID())
        #expect(forgotten.selectedTabID == c.id, "A remembered tab that's gone: the first tab, as switching does")
    }

    @Test func theOtherSpacesAreLoadedAndTheShownOneIsLive() async throws {
        let home = try #require(model.space)
        _ = try await open("home")
        await model.createSpace(name: "Work")
        _ = try await open("work")
        await previewsSettle()

        let work = try #require(model.space)
        #expect(model.spacePreviews[work.id] == nil, "The shown Space's rows are live")
        let homePreview = try #require(model.spacePreviews[home.id])
        #expect(homePreview.rows.count == 1)
        #expect(model.neighboringSpaces.previous?.id == home.id)
        #expect(model.neighboringSpaces.next == nil)
    }

    @Test func leavingASpaceKeepsItsRowsAsTheyWere() async throws {
        let home = try #require(model.space)
        let kept = try await open("kept")
        await model.createSpace(name: "Work")
        await previewsSettle()
        await model.selectSpace(home.id)
        _ = try await open("later")
        let work = try #require(model.spaces.first { $0.name == "Work" })

        await model.selectSpace(work.id)
        let homePreview = try #require(model.spacePreviews[home.id])
        #expect(homePreview.rows.count == 2, "The Space left, with the tab opened just before")
        #expect(homePreview.selectedTabID != kept, "Its selection as it was left")
    }

    @Test func aSwipeReadsTheNeighborsAgain() async throws {
        let home = try #require(model.space)
        await model.createSpace(name: "Work")
        await previewsSettle()
        // Something else changes Home meanwhile (an extension, iCloud).
        try await model.store.openTab(url: URL(string: "https://example.com/elsewhere")!, in: home.id)

        await model.refreshNeighborPreviews()
        #expect(model.spacePreviews[home.id]?.rows.count == 1)
    }
}
