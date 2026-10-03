import Foundation
import Testing
@testable import AxoCore

struct SplitStoreTests {
    let store: TabStore
    let space: Space

    init() async throws {
        store = try TabStore.makeInMemory()
        space = try await store.bootstrap()
    }

    private func open(_ name: String) async throws -> Tab {
        try await store.openTab(url: URL(string: "https://example.com/\(name)")!, title: name, in: space.id)
    }

    private func tab(_ id: Tab.ID) async throws -> Tab {
        try #require(try await store.tab(id: id))
    }

    /// The split's tabs in pane order, by title.
    private func panes(_ splitID: TabSplit.ID) async throws -> [String] {
        try await store.tabs(in: space.id)
            .filter { $0.splitID == splitID }
            .sorted { ($0.splitSortKey ?? "") < ($1.splitSortKey ?? "") }
            .map(\.title)
    }

    @Test func addingATabToAnotherMakesASplitWithPanesInOrder() async throws {
        let a = try await open("A"), b = try await open("B"), c = try await open("C"), d = try await open("D")
        let split = try await store.addToSplit(c.id, with: a.id)
        #expect(split.orientation == .horizontal)
        #expect(try await panes(split.id) == ["A", "C"])

        #expect(try await store.addToSplit(d.id, with: c.id) == split, "Adding to any pane extends the split")
        #expect(try await panes(split.id) == ["A", "C", "D"])
        #expect(try await store.splits(in: space.id) == [split])

        // The split's tabs sit together after the first one, so it reads as one row.
        let order = try await store.tabs(in: space.id).map(\.title)
        #expect(order == ["A", "C", "D", "B"])
        _ = b
    }

    @Test func splitsHoldAtMostFourTabs() async throws {
        let tabs = try await [open("1"), open("2"), open("3"), open("4"), open("5")]
        let split = try await store.addToSplit(tabs[1].id, with: tabs[0].id)
        try await store.addToSplit(tabs[2].id, with: tabs[0].id)
        try await store.addToSplit(tabs[3].id, with: tabs[0].id)
        await #expect(throws: TabStoreError.splitFull(split.id)) {
            try await store.addToSplit(tabs[4].id, with: tabs[0].id)
        }
    }

    @Test func joiningAPinnedSplitPinsTheTabInItsFolder() async throws {
        let a = try await open("A"), b = try await open("B")
        let folder = try await store.createFolder(named: "Work", in: space.id)
        try await store.movePinnedItem(.tab(a.id), into: folder.id, after: nil)

        try await store.addToSplit(b.id, with: a.id)
        let joined = try await tab(b.id)
        #expect(joined.isPinned && joined.folderID == folder.id)
        #expect(joined.homeURL == joined.url)

        // Unpinning any pane unpins the whole split.
        try await store.setPinned(false, tabID: b.id)
        #expect(try await tab(a.id).isPinned == false)
        #expect(try await tab(a.id).homeURL == nil)
    }

    @Test func movingOnePaneMovesTheWholeSplit() async throws {
        let a = try await open("A"), b = try await open("B"), c = try await open("C")
        try await store.addToSplit(b.id, with: a.id)
        try await store.moveTab(id: a.id, to: .after(c.id))
        #expect(try await store.tabs(in: space.id).map(\.title) == ["C", "A", "B"])

        let folder = try await store.createFolder(named: "Work", in: space.id)
        try await store.movePinnedItem(.tab(a.id), into: folder.id, after: nil)
        #expect(try await tab(b.id).folderID == folder.id, "Moving into a folder takes the split along")
    }

    @Test func removingOrClosingTabsEndsASplitLeftWithOne() async throws {
        let a = try await open("A"), b = try await open("B"), c = try await open("C")
        let split = try await store.addToSplit(b.id, with: a.id)
        try await store.addToSplit(c.id, with: a.id)

        try await store.removeFromSplit(c.id)
        #expect(try await tab(c.id).splitID == nil)
        #expect(try await panes(split.id) == ["A", "B"])

        try await store.archiveTab(id: b.id)
        #expect(try await store.splits(in: space.id).isEmpty, "One tab isn't a split")
        let left = try await tab(a.id)
        #expect(left.splitID == nil && left.splitSortKey == nil)
        #expect(try await tab(b.id).splitID == nil, "An archived tab leaves its split")
    }

    @Test func idleSplitTabsArchiveAndLeaveTheSplit() async throws {
        let a = try await open("A"), b = try await open("B")
        try await store.addToSplit(b.id, with: a.id)
        let archived = try await store.archiveInactiveTabs(lastActiveBefore: Date().addingTimeInterval(60))
        #expect(Set(archived) == [a.id, b.id])
        #expect(try await store.splits(in: space.id).isEmpty)
    }

    @Test func splitsCanBeSeparatedAndRotated() async throws {
        let a = try await open("A"), b = try await open("B")
        let split = try await store.addToSplit(b.id, with: a.id)
        try await store.setSplitOrientation(.vertical, id: split.id)
        #expect(try await store.splits(in: space.id).first?.orientation == .vertical)

        try await store.separateSplit(split.id)
        #expect(try await store.splits(in: space.id).isEmpty)
        #expect(try await tab(a.id).splitID == nil)
        #expect(try await tab(b.id).splitID == nil)
    }

    @Test func aTabMovesFromOneSplitToAnother() async throws {
        let a = try await open("A"), b = try await open("B"), c = try await open("C"), d = try await open("D")
        let first = try await store.addToSplit(b.id, with: a.id)
        let second = try await store.addToSplit(d.id, with: c.id)
        try await store.addToSplit(b.id, with: c.id)
        #expect(try await panes(second.id) == ["C", "D", "B"])
        #expect(try await store.splits(in: space.id) == [second], "The first split ended with one tab")
        _ = first
    }

    @Test func tabsInOtherSpacesCantJoin() async throws {
        let a = try await open("A")
        let other = try await store.createSpace(name: "Work", profileID: space.profileID)
        let elsewhere = try await store.openTab(url: URL(string: "https://example.com/x")!, in: other.id)
        await #expect(throws: TabStoreError.anchorInDifferentSpace(a.id)) {
            try await store.addToSplit(elsewhere.id, with: a.id)
        }
    }
}
