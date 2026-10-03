import Foundation
import Testing
@testable import AxoCore

struct SidebarImportTests {
    let store: TabStore
    let home: Space

    init() async throws {
        store = try TabStore.makeInMemory()
        home = try await store.bootstrap()
    }

    private func page(_ name: String) -> ImportedItem {
        .tab(title: name, url: URL(string: "https://example.com/\(name)")!)
    }

    /// A Space's pinned tree as nested names, e.g. ["Work[Docs, Mail]", "News"].
    private func tree(_ spaceID: Space.ID) async throws -> [String] {
        let folders = try await store.folders(in: spaceID)
        let tabs = try await store.tabs(in: spaceID).filter(\.isPinned)
        func level(_ parent: Folder.ID?) -> [String] {
            let items: [(String, String)] =
                folders.filter { $0.parentID == parent }.map { ($0.sortKey, "\($0.name)[\(level($0.id).joined(separator: ", "))]") }
                + tabs.filter { $0.folderID == parent }.map { ($0.sortKey, $0.title) }
            return items.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return level(nil)
    }

    @Test func importedSpacesComeAfterExistingOnesWithTheirTabsAndFolders() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let spaces = try await store.importSpaces([
            ImportedSpace(
                name: "Work",
                profileID: home.profileID,
                pinned: [page("Mail"), .folder(name: "Docs", children: [page("Spec"), .folder(name: "Old", children: [page("Notes")])])],
                unpinned: [page("Search"), .folder(name: "Split", children: [page("Left"), page("Right")])]
            ),
            ImportedSpace(name: "Play", profileID: home.profileID, pinned: []),
        ], at: now)

        #expect(try await store.spaces().map(\.name) == ["Home", "Work", "Play"])
        let work = spaces[0]
        #expect(try await tree(work.id) == ["Mail", "Docs[Spec, Old[Notes]]"])

        let tabs = try await store.tabs(in: work.id)
        let pinned = tabs.filter(\.isPinned)
        #expect(pinned.allSatisfy { $0.homeURL == $0.url }, "Pinned pages are their tabs' home pages")
        let unpinned = tabs.filter { !$0.isPinned }
        #expect(unpinned.map(\.title) == ["Search", "Left", "Right"], "Folders in the unpinned section are flattened")
        #expect(unpinned.allSatisfy { $0.lastActiveAt == now && $0.folderID == nil })
    }

    @Test func aFailedImportAddsNothing() async throws {
        await #expect(throws: TabStoreError.profileNotFound(home.id)) {
            try await store.importSpaces([
                ImportedSpace(name: "Fine", profileID: home.profileID, pinned: [page("A")]),
                ImportedSpace(name: "Broken", profileID: home.id, pinned: [page("B")]),
            ])
        }
        #expect(try await store.spaces().map(\.name) == ["Home"])
    }

    @Test func importedPinnedItemsGoAfterTheExistingOnes() async throws {
        let tab = try await store.openTab(url: URL(string: "https://example.com/Existing")!, title: "Existing", in: home.id)
        try await store.setPinned(true, tabID: tab.id)

        try await store.importPinned([.folder(name: "Imported from Chrome", children: [page("Bookmark")])], into: home.id)

        #expect(try await tree(home.id) == ["Existing", "Imported from Chrome[Bookmark]"])
        await #expect(throws: TabStoreError.spaceNotFound(home.profileID)) {
            try await store.importPinned([page("A")], into: home.profileID)
        }
    }

    @Test func itemsCountAndFlattenTheirPages() {
        let item = ImportedItem.folder(name: "A", children: [page("1"), .folder(name: "B", children: [page("2"), page("3")])])
        #expect(item.tabCount == 3)
        #expect(item.flattenedTabs.map(\.title) == ["1", "2", "3"])
    }
}
