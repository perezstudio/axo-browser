import AxoPersistence
import Foundation
import GRDB
import Testing
@testable import AxoCore

struct FolderTests {
    let store: TabStore
    let space: Space

    init() async throws {
        store = try TabStore.makeInMemory()
        space = try await store.bootstrap()
    }

    private func pinnedTab(_ name: String) async throws -> Tab {
        let tab = try await store.openTab(url: URL(string: "https://example.com/\(name)")!, title: name, in: space.id)
        try await store.setPinned(true, tabID: tab.id)
        return try #require(try await store.tab(id: tab.id))
    }

    /// The pinned tree as nested names, e.g. ["Work[Docs, Mail]", "News"].
    private func tree() async throws -> [String] {
        let folders = try await store.folders(in: space.id)
        let tabs = try await store.tabs(in: space.id).filter(\.isPinned)
        func level(_ parent: Folder.ID?) -> [String] {
            let items: [(String, String)] =
                folders.filter { $0.parentID == parent }.map { ($0.sortKey, "\($0.name)[\(level($0.id).joined(separator: ", "))]") }
                + tabs.filter { $0.folderID == parent }.map { ($0.sortKey, $0.title) }
            return items.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return level(nil)
    }

    @Test func foldersAndPinnedTabsShareOneOrderPerLevel() async throws {
        _ = try await pinnedTab("Mail")
        try await store.createFolder(named: "Work", in: space.id)
        _ = try await pinnedTab("News")

        #expect(try await tree() == ["Mail", "Work[]", "News"])
    }

    @Test func tabsAndFoldersMoveIntoFoldersAndNest() async throws {
        let mail = try await pinnedTab("Mail")
        let docs = try await pinnedTab("Docs")
        let work = try await store.createFolder(named: "Work", in: space.id)
        let archive = try await store.createFolder(named: "Archive", in: space.id)

        try await store.movePinnedItem(.tab(docs.id), into: work.id, after: nil)
        try await store.movePinnedItem(.tab(mail.id), into: work.id, after: .tab(docs.id))
        try await store.movePinnedItem(.folder(archive.id), into: work.id, after: nil)

        #expect(try await tree() == ["Work[Archive[], Docs, Mail]"])
    }

    @Test func movingAnUnpinnedTabIntoAFolderPinsIt() async throws {
        let loose = try await store.openTab(url: URL(string: "https://example.com/loose")!, title: "Loose", in: space.id)
        let folder = try await store.createFolder(named: "Reading", in: space.id)

        try await store.movePinnedItem(.tab(loose.id), into: folder.id, after: nil)

        let moved = try #require(try await store.tab(id: loose.id))
        #expect(moved.isPinned && moved.folderID == folder.id && moved.homeURL == loose.url)
    }

    @Test func unpinningTakesATabOutOfItsFolder() async throws {
        let tab = try await pinnedTab("Mail")
        let folder = try await store.createFolder(named: "Work", in: space.id)
        try await store.movePinnedItem(.tab(tab.id), into: folder.id, after: nil)

        try await store.setPinned(false, tabID: tab.id)

        #expect(try await store.tab(id: tab.id)?.folderID == nil)
    }

    @Test func aFolderCannotMoveIntoItself() async throws {
        let outer = try await store.createFolder(named: "Outer", in: space.id)
        let inner = try await store.createFolder(named: "Inner", in: space.id, parent: outer.id)

        await #expect(throws: TabStoreError.folderCycle(outer.id)) {
            try await store.movePinnedItem(.folder(outer.id), into: inner.id, after: nil)
        }
        await #expect(throws: TabStoreError.folderCycle(outer.id)) {
            try await store.movePinnedItem(.folder(outer.id), into: outer.id, after: nil)
        }
    }

    @Test func anchorsMustBeAtTheTargetLevel() async throws {
        let mail = try await pinnedTab("Mail")
        let folder = try await store.createFolder(named: "Work", in: space.id)
        let docs = try await pinnedTab("Docs")

        await #expect(throws: TabStoreError.anchorInDifferentSection(mail.id)) {
            try await store.movePinnedItem(.tab(docs.id), into: folder.id, after: .tab(mail.id))
        }
    }

    @Test func deletingAFolderMovesItsContentsUpInOrder() async throws {
        let first = try await pinnedTab("First")
        let work = try await store.createFolder(named: "Work", in: space.id)
        let a = try await pinnedTab("A")
        let b = try await pinnedTab("B")
        try await store.movePinnedItem(.tab(a.id), into: work.id, after: nil)
        try await store.movePinnedItem(.tab(b.id), into: work.id, after: .tab(a.id))
        let sub = try await store.createFolder(named: "Sub", in: space.id, parent: work.id)
        _ = first

        try await store.deleteFolder(id: work.id)

        #expect(try await tree() == ["First", "A", "B", "Sub[]"])
        #expect(try await store.folders(in: space.id).map(\.id) == [sub.id])
    }

    @Test func foldersRenameAndRememberWhetherTheyAreExpanded() async throws {
        let folder = try await store.createFolder(named: "Wrok", in: space.id)
        try await store.renameFolder(id: folder.id, to: "Work")
        try await store.setFolderExpanded(false, id: folder.id)

        let saved = try #require(try await store.folders(in: space.id).first)
        #expect(saved.name == "Work" && saved.isExpanded == false)
    }

    @Test func foldersBelongToOneSpace() async throws {
        let other = try await store.createSpace(name: "Work", profileID: space.profileID)
        let folder = try await store.createFolder(named: "Here", in: space.id)

        await #expect(throws: TabStoreError.folderInDifferentSpace(folder.id)) {
            try await store.createFolder(named: "There", in: other.id, parent: folder.id)
        }
        try await store.deleteSpace(id: space.id)
        #expect(try await store.folders(in: space.id).isEmpty)
    }

    @Test func pinningStillAddsToTheEndOfTheTopLevelAfterFolders() async throws {
        try await store.createFolder(named: "Work", in: space.id)
        _ = try await pinnedTab("Mail")
        #expect(try await tree() == ["Work[]", "Mail"])
    }
}
