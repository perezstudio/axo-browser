import AxoCore
import AxoWeb
import Foundation
import Testing
@testable import AxoUI

@MainActor
struct FolderModelTests {
    let store: TabStore
    let model: BrowserModel
    let directory: URL

    init() async throws {
        store = try TabStore.makeInMemory()
        model = BrowserModel(store: store, pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        directory = FileManager.default.temporaryDirectory
            .appending(path: "AxoFolderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await model.start()
    }

    private func pinned(_ name: String) async throws -> AxoCore.Tab {
        let url = directory.appending(path: "\(name).html")
        try "<title>\(name)</title>".write(to: url, atomically: true, encoding: .utf8)
        await model.openTab(url: url)
        let tab = try #require(model.tabs.last)
        await model.setPinned(true, tabID: tab.id)
        return tab
    }

    /// The tree as nested names, using each tab's file name.
    private func describe(_ nodes: [PinnedNode]) -> [String] {
        nodes.map { node in
            switch node {
            case .tab(let tab): tab.url.deletingPathExtension().lastPathComponent
            case .folder(let folder, let children): "\(folder.name)[\(describe(children).joined(separator: ", "))]"
            }
        }
    }

    private func folder(named name: String) throws -> Folder {
        try #require(model.folders.first { $0.name == name })
    }

    @Test func creatingAFolderCanMoveATabIntoIt() async throws {
        let mail = try await pinned("mail")
        _ = try await pinned("news")

        await model.createFolder(named: "Work", moving: .tab(mail.id))

        #expect(describe(model.pinnedTree) == ["news", "Work[mail]"])
    }

    @Test func movingToAFolderAppendsAndCanMoveBackOut() async throws {
        let a = try await pinned("a")
        let b = try await pinned("b")
        await model.createFolder(named: "Work")
        let work = try folder(named: "Work")

        await model.move(.tab(a.id), toFolder: work.id)
        await model.move(.tab(b.id), toFolder: work.id)
        #expect(describe(model.pinnedTree) == ["Work[a, b]"])

        await model.move(.tab(a.id), toFolder: nil)
        #expect(describe(model.pinnedTree) == ["Work[b]", "a"])
    }

    @Test func unpinnedTabsMovedIntoAFolderBecomePinned() async throws {
        let url = directory.appending(path: "loose.html")
        try "<title>loose</title>".write(to: url, atomically: true, encoding: .utf8)
        await model.openTab(url: url)
        let loose = try #require(model.tabs.last)
        await model.createFolder(named: "Reading")

        await model.move(.tab(loose.id), toFolder: try folder(named: "Reading").id)

        #expect(model.unpinnedTabs.isEmpty)
        #expect(describe(model.pinnedTree) == ["Reading[loose]"])
    }

    @Test func dragsReorderOneLevel() async throws {
        _ = try await pinned("a")
        await model.createFolder(named: "Work")
        _ = try await pinned("b")

        await model.movePinnedItems(fromOffsets: IndexSet(integer: 2), toOffset: 0, in: nil)

        #expect(describe(model.pinnedTree) == ["b", "a", "Work[]"])
    }

    @Test func foldersNestRenameCollapseAndDelete() async throws {
        let a = try await pinned("a")
        await model.createFolder(named: "Outer")
        let outer = try folder(named: "Outer")
        await model.createFolder(named: "Inner", parent: outer.id, moving: .tab(a.id))
        #expect(describe(model.pinnedTree) == ["Outer[Inner[a]]"])

        await model.renameFolder(outer.id, to: "Work")
        await model.setFolderExpanded(false, id: outer.id)
        #expect(try folder(named: "Work").isExpanded == false)

        await model.deleteFolder(outer.id)
        #expect(describe(model.pinnedTree) == ["Inner[a]"])
    }

    @Test func folderMenusListFoldersByDepthAndExcludeAFoldersOwnSubtree() async throws {
        await model.createFolder(named: "Outer")
        let outer = try folder(named: "Outer")
        await model.createFolder(named: "Inner", parent: outer.id)
        await model.createFolder(named: "Other")

        let flattened = PinnedNode.flattenedFolders(model.pinnedTree)
        #expect(flattened.map(\.folder.name) == ["Outer", "Inner", "Other"])
        #expect(flattened.map(\.depth) == [0, 1, 0])
        #expect(PinnedNode.folderAndDescendants(outer.id, in: model.pinnedTree)
            == Set([outer.id, try folder(named: "Inner").id]))
    }

    @Test func eachSpaceShowsItsOwnFolders() async throws {
        await model.createFolder(named: "Home folder")
        await model.createSpace(name: "Work")
        #expect(model.folders.isEmpty)
        await model.selectSpace(at: 0)
        #expect(model.folders.map(\.name) == ["Home folder"])
    }
}
