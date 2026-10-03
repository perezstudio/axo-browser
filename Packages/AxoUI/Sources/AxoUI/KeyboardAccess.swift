import AppKit
import AxoCore
import Foundation

/// Keyboard equivalents for everything the sidebar's mouse gestures and context menus do, so
/// the whole sidebar works without a pointer. Menu commands and VoiceOver actions call these.
extension BrowserModel {
    // MARK: Sidebar selection

    /// The selected sidebar row: a folder when one is selected, otherwise the selected tab.
    public var selectedSidebarItem: PinnedItem? {
        if let selectedFolderID { return .folder(selectedFolderID) }
        // A split's row is its first tab, whichever pane is focused.
        return selectedTabID.map { .tab(sidebarRowTab(for: $0)) }
    }

    /// Selects a sidebar row. Selecting a folder keeps the current tab showing.
    public func selectSidebarItem(_ item: PinnedItem?) {
        switch item {
        case .tab(let id): selectSplitRow(id)
        case .folder(let id): selectedFolderID = id
        case nil: select(nil)
        }
    }

    /// The selected folder, if a folder row is selected.
    public var selectedFolder: Folder? {
        selectedFolderID.flatMap { id in folders.first { $0.id == id } }
    }

    /// The tabs in sidebar order as they appear on screen: pinned tabs (skipping those inside
    /// collapsed folders), then the others.
    public var visibleTabOrder: [AxoCore.Tab.ID] {
        // A split's row stands for all its panes, in pane order.
        func expanded(_ tab: AxoCore.Tab) -> [AxoCore.Tab.ID] {
            split(of: tab.id).map { panes(of: $0.id).map(\.id) } ?? [tab.id]
        }
        func visible(_ nodes: [PinnedNode]) -> [AxoCore.Tab.ID] {
            nodes.flatMap { node -> [AxoCore.Tab.ID] in
                switch node {
                case .tab(let tab): expanded(tab)
                case .folder(let folder, let children): folder.isExpanded ? visible(children) : []
                }
            }
        }
        return visible(pinnedTree) + unpinnedTabs.filter { !isSplitFollower($0) }.flatMap(expanded)
    }

    /// Selects the next (`1`) or previous (`-1`) visible tab, wrapping around.
    public func selectTab(offsetBy offset: Int) {
        let order = visibleTabOrder
        guard !order.isEmpty else { return }
        guard let current = selectedTabID, let index = order.firstIndex(of: current) else {
            select(offset >= 0 ? order.first : order.last)
            return
        }
        select(order[(index + offset + order.count) % order.count])
    }

    // MARK: Acting on the selection

    /// Pins the selected tab, or unpins it if it's pinned.
    public func togglePinSelectedTab() async {
        guard let tab = selectedTab else { return }
        await setPinned(!tab.isPinned, tabID: tab.id)
    }

    /// Moves the selected tab or folder into a folder (`nil` for the top of the pinned section).
    public func moveSelectedItem(toFolder folder: Folder.ID?) async {
        guard let item = selectedSidebarItem else { return }
        await move(item, toFolder: folder)
    }

    /// Asks for a new name for the selected folder.
    public func renameSelectedFolder() {
        guard let folder = selectedFolder else { return }
        namingRequest = .renameFolder(folder)
    }

    /// Deletes the selected folder. What's inside moves up a level.
    public func deleteSelectedFolder() async {
        guard let folder = selectedFolder else { return }
        await deleteFolder(folder.id)
        announce("Deleted \(folder.name)")
    }

    /// Asks for a new folder's name. With a folder selected, the new folder goes inside it.
    public func beginNewFolder() {
        namingRequest = .newFolder(parent: selectedFolderID, moving: nil)
    }

    /// Whether the selected row can move up (`-1`) or down (`1`) within its level.
    public func canMoveSelectedItem(by offset: Int) -> Bool {
        guard let (level, index) = selectedItemLevel() else { return false }
        return level.indices.contains(index + offset)
    }

    /// Moves the selected tab or folder up (`-1`) or down (`1`) one place within its level, the
    /// keyboard version of dragging it.
    public func moveSelectedItem(by offset: Int) async {
        guard let item = selectedSidebarItem, let (level, index) = selectedItemLevel(),
              level.indices.contains(index + offset) else { return }
        // List.onMove destinations: past the next item when moving down, before the previous one
        // when moving up.
        let destination = offset > 0 ? index + 2 : index - 1
        if case .tab(let id) = item, tabs.first(where: { $0.id == id })?.isPinned == false {
            await moveTabs(fromOffsets: IndexSet(integer: index), toOffset: destination, pinned: false)
        } else {
            await movePinnedItems(fromOffsets: IndexSet(integer: index), toOffset: destination, in: parentFolder(of: item))
        }
        announce(offset > 0 ? "Moved down" : "Moved up")
    }

    /// The selected row's level (its siblings, in order) and its position there.
    private func selectedItemLevel() -> (level: [PinnedItem], index: Int)? {
        guard let item = selectedSidebarItem else { return nil }
        let level: [PinnedItem]
        if case .tab(let id) = item, let tab = tabs.first(where: { $0.id == id }), !tab.isPinned {
            level = unpinnedTabs.filter { !isSplitFollower($0) }.map { .tab($0.id) }
        } else {
            level = PinnedNode.items(at: parentFolder(of: item), in: pinnedTree)
        }
        guard let index = level.firstIndex(of: item) else { return nil }
        return (level, index)
    }

    /// The folder a pinned tab or folder is in, or `nil` at the top level.
    func parentFolder(of item: PinnedItem) -> Folder.ID? {
        switch item {
        case .tab(let id):
            let folderID = tabs.first { $0.id == id }?.folderID
            // A tab whose folder is missing shows at the top level.
            return folderID.flatMap { id in folders.contains { $0.id == id } ? id : nil }
        case .folder(let id):
            return folders.first { $0.id == id }?.parentID
        }
    }

    // MARK: Spaces

    /// Asks for a new name for the current Space.
    public func beginRenameSpace() {
        spaceToRename = space
    }

    /// Asks the person to confirm deleting the current Space. The last Space can't be deleted.
    public func beginDeleteSpace() {
        guard spaces.count > 1 else { return }
        spaceToDelete = space
    }

    // MARK: Focus

    /// Gives keyboard focus to the selected page, as after closing the command bar or find bar,
    /// so typing and scrolling go to the page instead of nowhere.
    public func focusPage() {
        guard let selectedTabID else { return }
        let pool = pool
        // Wait a turn, so SwiftUI has removed the overlay that had focus.
        Task { @MainActor in
            guard let webView = pool.liveWebView(for: selectedTabID), let window = webView.window else { return }
            window.makeFirstResponder(webView)
        }
    }
}
