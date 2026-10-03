import AxoCore
import AxoWeb
import Foundation
import Testing
@testable import AxoUI

/// Everything the sidebar's mouse gestures and context menus do also works from the keyboard
/// (and VoiceOver), and important changes are announced.
@MainActor
struct KeyboardAccessTests {
    let store: TabStore
    let model: BrowserModel
    let directory: URL
    /// What the model announced to VoiceOver, in order.
    let announcements = Announcements()

    final class Announcements {
        var messages: [String] = []
    }

    init() async throws {
        store = try TabStore.makeInMemory()
        model = BrowserModel(store: store, pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        directory = FileManager.default.temporaryDirectory
            .appending(path: "AxoKeyboardTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await model.start()
        let announcements = announcements
        model.announce = { announcements.messages.append($0) }
    }

    /// Adds a tab that already has its title (so tests don't wait for pages to load) and,
    /// unless `select` is false, selects it.
    private func open(_ name: String, select: Bool = true) async throws -> AxoCore.Tab {
        let url = directory.appending(path: "\(name).html")
        try "<title>\(name)</title>".write(to: url, atomically: true, encoding: .utf8)
        let space = try #require(model.space)
        let tab = try await store.openTab(url: url, title: name, in: space.id)
        try await waitUntil { model.tabs.contains { $0.id == tab.id } }
        if select { model.select(tab.id) }
        return tab
    }

    private func name(_ id: AxoCore.Tab.ID?) -> String? {
        model.tabs.first { $0.id == id }?.url.deletingPathExtension().lastPathComponent
    }

    private func names(_ tabs: [AxoCore.Tab]) -> [String] {
        tabs.map { $0.url.deletingPathExtension().lastPathComponent }
    }

    // MARK: Selection

    @Test func foldersCanBeSelectedWhileTheTabKeepsShowing() async throws {
        let tab = try await open("one")
        await model.createFolder(named: "Work")
        let folder = try #require(model.folders.first)

        model.selectSidebarItem(.folder(folder.id))
        #expect(model.selectedSidebarItem == .folder(folder.id))
        #expect(model.selectedFolder == folder)
        #expect(model.selectedTabID == tab.id, "The page stays on screen")

        model.selectSidebarItem(.tab(tab.id))
        #expect(model.selectedFolderID == nil)
        #expect(model.selectedSidebarItem == .tab(tab.id))
    }

    @Test func nextAndPreviousTabFollowTheSidebarAndSkipCollapsedFolders() async throws {
        let a = try await open("a"), b = try await open("b"), c = try await open("c"), d = try await open("d")
        await model.setPinned(true, tabID: a.id)
        await model.createFolder(named: "Closed", moving: .tab(b.id))
        let closed = try #require(model.folders.first)
        await model.setFolderExpanded(false, id: closed.id)
        #expect(model.visibleTabOrder.map(name) == ["a", "c", "d"])

        model.select(c.id)
        model.selectTab(offsetBy: 1)
        #expect(name(model.selectedTabID) == "d")
        model.selectTab(offsetBy: 1)
        #expect(name(model.selectedTabID) == "a", "Wraps around")
        model.selectTab(offsetBy: -1)
        #expect(name(model.selectedTabID) == "d")
        _ = d
    }

    // MARK: Acting on the selection

    @Test func pinningTheSelectedTabToggles() async throws {
        let tab = try await open("Mail")
        await model.togglePinSelectedTab()
        #expect(model.tabs.first { $0.id == tab.id }?.isPinned == true)
        await model.togglePinSelectedTab()
        #expect(model.tabs.first { $0.id == tab.id }?.isPinned == false)
    }

    @Test func pinningIsAnnounced() async throws {
        // Not selected, so no page load changes the title mid-test.
        let tab = try await open("Mail", select: false)
        await model.setPinned(true, tabID: tab.id)
        await model.setPinned(false, tabID: tab.id)
        #expect(announcements.messages == ["Pinned Mail", "Unpinned Mail"])
    }

    @Test func movingUpAndDownReordersWithinTheLevel() async throws {
        _ = try await open("a")
        _ = try await open("b")
        let c = try await open("c")
        #expect(model.canMoveSelectedItem(by: -1) && !model.canMoveSelectedItem(by: 1))

        await model.moveSelectedItem(by: -1)
        #expect(names(model.unpinnedTabs) == ["a", "c", "b"])
        await model.moveSelectedItem(by: -1)
        #expect(names(model.unpinnedTabs) == ["c", "a", "b"])
        #expect(!model.canMoveSelectedItem(by: -1))
        await model.moveSelectedItem(by: 1)
        #expect(names(model.unpinnedTabs) == ["a", "c", "b"])
        #expect(model.selectedTabID == c.id)
        #expect(announcements.messages.suffix(3) == ["Moved up", "Moved up", "Moved down"])
    }

    @Test func pinnedTabsAndFoldersMoveWithinTheirLevel() async throws {
        let a = try await open("a")
        await model.setPinned(true, tabID: a.id)
        await model.createFolder(named: "Work")
        let work = try #require(model.folders.first)
        let topLevel = { PinnedNode.items(at: nil, in: model.pinnedTree) }
        #expect(topLevel() == [.tab(a.id), .folder(work.id)])

        model.selectSidebarItem(.folder(work.id))
        await model.moveSelectedItem(by: -1)
        #expect(topLevel() == [.folder(work.id), .tab(a.id)])
        #expect(model.selectedSidebarItem == .folder(work.id), "The folder stays selected")
    }

    @Test func theSelectionMovesIntoFoldersAndFoldersRenameAndDelete() async throws {
        let tab = try await open("Docs")
        await model.createFolder(named: "Work")
        let work = try #require(model.folders.first)

        model.select(tab.id)
        await model.moveSelectedItem(toFolder: work.id)
        #expect(model.tabs.first { $0.id == tab.id }?.folderID == work.id, "Moving into a folder pins the tab")
        #expect(announcements.messages.last == "Moved to Work")

        model.selectSidebarItem(.folder(work.id))
        model.renameSelectedFolder()
        #expect(model.namingRequest == .renameFolder(work))
        model.namingRequest = nil
        model.beginNewFolder()
        #expect(model.namingRequest == .newFolder(parent: work.id, moving: nil), "New Folder goes inside the selected folder")
        model.namingRequest = nil

        await model.deleteSelectedFolder()
        #expect(model.folders.isEmpty)
        #expect(model.selectedFolderID == nil)
        #expect(model.tabs.first { $0.id == tab.id }?.folderID == nil, "Its tab moves up a level")
        #expect(announcements.messages.last == "Deleted Work")
    }

    @Test func folderCommandsAreOnlyOfferedWithAFolderSelected() async throws {
        #expect(!model.availableActions.contains(.renameFolder))
        await model.createFolder(named: "Work")
        model.selectSidebarItem(.folder(try #require(model.folders.first).id))
        #expect(model.availableActions.contains(.renameFolder) && model.availableActions.contains(.deleteFolder))
    }

    // MARK: Spaces

    @Test func spacesCanBeRenamedAndDeletedFromCommands() async throws {
        model.beginDeleteSpace()
        #expect(model.spaceToDelete == nil, "The last Space can't be deleted")
        #expect(!model.availableActions.contains(.deleteSpace))

        await model.createSpace(name: "Work")
        model.beginRenameSpace()
        #expect(model.spaceToRename?.name == "Work")
        model.beginDeleteSpace()
        #expect(model.spaceToDelete?.name == "Work")

        await model.deleteSpace(try #require(model.spaceToDelete).id)
        #expect(announcements.messages.last == "Deleted Work")
    }

    // MARK: Announcements

    @Test func closingAndReopeningTabsIsAnnounced() async throws {
        let tab = try await open("Recipes", select: false)
        await model.closeTab(tab.id)
        await model.reopenLastClosedTab()
        #expect(announcements.messages == ["Closed Recipes", "Reopened Recipes"])
    }

    @Test func movingTheCommandBarHighlightSaysWhichRow() async throws {
        model.showCommandBar()
        model.setCommandQuery("downloads")
        model.moveCommandSelection(by: 1)
        let highlighted = model.commandResults[model.commandSelection]
        #expect(announcements.messages.last == "\(highlighted.title), \(highlighted.hint)")
    }

    @Test func findingNothingIsAnnouncedOnce() async throws {
        let url = directory.appending(path: "pond.html")
        try "<title>Pond</title><p>Axolotls live in lakes.</p>".write(to: url, atomically: true, encoding: .utf8)
        await model.openTab(url: url)
        try await waitUntil { model.selectedPage?.title == "Pond" && model.selectedPage?.isLoading == false }

        model.findText = "ocean"
        await model.findNext()
        await model.findNext()
        #expect(announcements.messages.filter { $0 == "No matches" }.count == 1)
    }
}
