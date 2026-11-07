import AxoCore
import AxoWeb
import SwiftUI
// The Mac sidebar; iPhone and iPad have their own chrome.
#if os(macOS)

/// The sidebar: the address bar, the Space's pinned tabs, and its other tabs.
struct SidebarView: View {
    let model: BrowserModel
    @State private var isShowingArchive = false
    @AppStorage(NavigationBarPlacement.storageKey) private var navigationBarPlacement = NavigationBarPlacement.sidebar
    @AppStorage(AddressBarSettings.showsSidebarAddressBarKey) private var showsAddressBar = true
    /// The Spaces' pages and a swipe between them as it happens (#84).
    @State private var swipe = SidebarSwipeState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        spacePages
        .sheet(isPresented: $isShowingArchive) {
            ArchivedTabsView(model: model)
        }
        .sheet(item: Binding(get: { model.pendingExtensionInstall }, set: { if $0 == nil { Task { await model.cancelExtensionInstall() } } })) { prompt in
            ExtensionInstallSheet(model: model, prompt: prompt)
        }
        .sheet(isPresented: Binding(get: { model.isShowingExtensions }, set: { model.isShowingExtensions = $0 })) {
            ExtensionsView(model: model)
        }
        .sheet(item: Binding(get: { model.importSession }, set: { model.importSession = $0 })) { session in
            ImportSheet(model: model, session: session)
        }
        .sheet(item: Binding(get: { model.namingRequest }, set: { model.namingRequest = $0 })) { request in
            folderNameSheet(for: request)
        }
        .sheet(item: Binding(get: { model.customizationDraft }, set: { model.customizationDraft = $0 })) { draft in
            CustomizeSiteSheet(model: model, customization: draft)
        }
        .sheet(item: Binding(get: { model.spaceToRename }, set: { model.spaceToRename = $0 })) { space in
            NameSheet(title: "Rename Space", initialName: space.name, confirmTitle: "Rename") { name in
                Task { await model.renameSpace(space.id, to: name) }
            }
        }
        // Two-finger swipes over the favorites and tabs move between Spaces (not over the
        // address bar, which stays put).
        .background { SidebarSwipeCatcher(model: model, state: swipe) }
        .onChange(of: model.isShowingArchive) { isShowingArchive = model.isShowingArchive }
        .onChange(of: isShowingArchive) { if !isShowingArchive { model.isShowingArchive = false } }
        // Slide to the shown Space's page when it changes some other way (the keyboard, the
        // dots, the menu); after a swipe the pages are already there.
        .onChange(of: model.space?.id, initial: true) { followShownSpace(animated: true) }
        .onChange(of: model.spaces.map(\.id)) { followShownSpace(animated: false) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SpaceSwitcher(model: model)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 8) {
                // Like Arc, the address bar can sit at the top of the sidebar; it stays put while
                // the Spaces' pages slide beneath it.
                if navigationBarPlacement == .sidebar, showsAddressBar {
                    SidebarAddressBar(model: model)
                        .padding(.horizontal, 10)
                }
            }
            .padding(.bottom, 6)
        }
        // An address edited in the sidebar: its suggestions hang below the bar, over the
        // favorites and tabs, as in Dia.
        .overlayPreferenceValue(AddressBarBounds.self, alignment: .topLeading) { anchor in
            if let anchor, model.isAddressEditedInSidebar {
                GeometryReader { proxy in
                    let bar = proxy[anchor]
                    AddressSuggestions(model: model)
                        .frame(width: bar.width)
                        .offset(x: bar.minX, y: bar.maxY + 6)
                }
            }
        }
        .toolbar {
            if navigationBarPlacement == .sidebar {
                SidebarNavigationToolbar(model: model)
            }
            ToolbarItem {
                Button("New Tab", systemImage: "plus") { model.beginNewTab() }
                    .help("New Tab")
                    .accessibilityIdentifier("newTabButton")
            }
        }
    }
}

extension SidebarView {
    /// Every Space's page side by side, resting on the shown Space's and moved by a swipe that
    /// locks onto a page when the fingers lift. Only the shown page takes clicks and is in the
    /// accessibility tree.
    private var spacePages: some View {
        GeometryReader { proxy in
            // The pages are an overlay of a sidebar-sized base, so the strip, as wide as all of
            // them, never sets the sidebar's size.
            Color.clear
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        ForEach(Array(model.spaces.enumerated()), id: \.element.id) { index, space in
                            SpacePage(model: model, space: space, isShown: space.id == model.space?.id,
                                      favoritesOffset: favoritesOffset(forPage: index, width: proxy.size.width))
                                .frame(width: proxy.size.width, height: proxy.size.height)
                        }
                    }
                    // Only the width: each page's height is the sidebar's. Fixing the height
                    // too let an empty Space's list set it, pushing the window's layout up.
                    .fixedSize(horizontal: true, vertical: false)
                    .offset(x: -CGFloat(swipe.pageIndex) * proxy.size.width + swipe.offset)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar")
    }

    /// How far page `index`'s favorites shift against its movement. Between the resting page and
    /// the one coming in, when both are the same profile's (the same favorites), all the way, so
    /// they stay still where they are; otherwise not at all, and they slide with their page.
    private func favoritesOffset(forPage index: Int, width: CGFloat) -> CGFloat {
        let spaces = model.spaces
        let resting = swipe.pageIndex
        guard swipe.offset != 0, spaces.indices.contains(resting) else { return 0 }
        let incoming = resting + (swipe.offset < 0 ? 1 : -1)
        guard index == resting || index == incoming, spaces.indices.contains(incoming),
              spaces[incoming].profileID == spaces[resting].profileID else { return 0 }
        // The page sits at (index - resting) widths plus the swipe; this undoes that.
        return -(CGFloat(index - resting) * width + swipe.offset)
    }

    /// Rests the pages on the shown Space's, sliding there unless `animated` is off or Reduce
    /// Motion is on. Does nothing when they're already there, as after a swipe.
    private func followShownSpace(animated: Bool) {
        guard let index = model.spaces.firstIndex(where: { $0.id == model.space?.id }),
              index != swipe.pageIndex || swipe.offset != 0 else { return }
        if animated, !reduceMotion {
            withAnimation(.spring(duration: 0.3, bounce: 0)) {
                swipe.pageIndex = index
                swipe.offset = 0
            }
        } else {
            swipe.pageIndex = index
            swipe.offset = 0
        }
    }


    @ViewBuilder
    private func folderNameSheet(for request: NamingRequest) -> some View {
        switch request {
        case .newFolder(let parent, let moving):
            NameSheet(title: "New Folder", initialName: "", confirmTitle: "Create") { name in
                Task { await model.createFolder(named: name, parent: parent, moving: moving) }
            }
        case .renameFolder(let folder):
            NameSheet(title: "Rename Folder", initialName: folder.name, confirmTitle: "Rename") { name in
                Task { await model.renameFolder(folder.id, to: name) }
            }
        }
    }

}

/// A Space's sections in its sidebar page: pinned tabs and folders, then its other tabs, with
/// their menus and actions. Every page uses these, built from the Space's rows
/// (``SpaceSidebarPreview``: the model's for the shown Space, the kept ones for the others), so
/// a page turning live when its Space is shown keeps the same rows and nothing reloads (#84).
/// Only the shown page takes clicks, so only its menus and moves can be used.
struct SidebarSections: View {
    let model: BrowserModel
    let data: SpaceSidebarPreview

    var body: some View {
        if !data.pinnedTree.isEmpty {
            Section("Pinned") {
                PinnedLevel(model: model, nodes: data.pinnedTree, parent: nil, splitPanes: data.splitPanes)
            }
            .accessibilityIdentifier("pinnedSection")
        }
        Section {
            ForEach(data.rows) { row in
                let tab = leader(of: row)
                SidebarTabRow(model: model, tab: tab, panes: data.splitPanes[tab.id])
                    .tag(PinnedItem.tab(tab.id))
                    .contextMenu { TabContextMenu(model: model, tab: tab) }
                    .sidebarMoveActions(model: model, item: .tab(tab.id))
            }
            .onMove { source, destination in
                Task { await model.moveTabs(fromOffsets: source, toOffset: destination, pinned: false) }
            }
        } header: {
            if let icon = data.space.icon {
                Label(data.space.name, systemImage: icon)
            } else {
                Text(data.space.name)
            }
        }
    }

    /// The tab a row stands for: a split's first tab in sidebar order.
    private func leader(of row: SpaceSidebarPreview.Row) -> AxoCore.Tab {
        switch row {
        case .tab(let tab): tab
        case .split(let leader, let panes): panes.first { $0.id == leader } ?? panes[0]
        }
    }
}
#endif


/// A sidebar row for a tab, or for a split view when the tab's split stands behind it (`panes`,
/// in pane order, from the Space's rows).
struct SidebarTabRow: View {
    let model: BrowserModel
    let tab: AxoCore.Tab
    var panes: [AxoCore.Tab]?

    var body: some View {
        if let panes {
            SplitRow(panes: panes, favicon: model.favicon(for:))
        } else {
            TabRow(tab: tab, favicon: model.favicon(for: tab))
        }
    }
}

/// One split view in the sidebar: its tabs' icons and titles in pane order.
struct SplitRow: View {
    let panes: [AxoCore.Tab]
    let favicon: (AxoCore.Tab) -> PlatformImage?

    var body: some View {
        Label {
            Text(panes.map(TabRow.displayTitle(for:)).joined(separator: " | "))
        } icon: {
            HStack(spacing: 2) {
                ForEach(panes) { pane in
                    if let image = favicon(pane) {
                        Image(platformImage: image).resizable().interpolation(.high)
                            .frame(width: 14, height: 14)
                            .clipShape(.rect(cornerRadius: 3))
                    } else {
                        Image(systemName: "globe").font(.system(size: 11))
                    }
                }
            }
            .accessibilityHidden(true)
        }
        .lineLimit(1)
        .help(panes.map(TabRow.displayTitle(for:)).joined(separator: "\n"))
        .accessibilityLabel("Split view: " + panes.map(TabRow.displayTitle(for:)).formatted(.list(type: .and)))
        .accessibilityIdentifier("splitRow")
    }
}

/// The actions for a tab in the sidebar.
struct TabContextMenu: View {
    let model: BrowserModel
    let tab: AxoCore.Tab

    var body: some View {
        if let split = model.split(of: tab.id) {
            Button("Separate Split View") {
                model.selectSidebarItem(.tab(tab.id))
                Task { await model.separateSelectedSplit() }
            }
            Button(split.orientation == .horizontal ? "Stack Panes" : "Show Panes Side by Side") {
                model.selectSidebarItem(.tab(tab.id))
                Task { await model.toggleSplitOrientation() }
            }
            Divider()
        } else if model.canAddToSplit, let selected = model.selectedTabID, selected != tab.id {
            Button("Add to Split View") { Task { await model.addToSplit(tab.id) } }
            Divider()
        }
        Button("Add to Favorites") { Task { await model.addToFavorites(tab.id) } }
        Divider()
        if tab.isPinned {
            Button("Go to Pinned Page") { Task { await model.goToPinnedHome(tab.id) } }
                .disabled(!tab.hasLeftHome)
            Button("Pin This Page Instead") { Task { await model.makeCurrentPagePinnedHome(tab.id) } }
                .disabled(!tab.hasLeftHome)
            Button("Unpin Tab") { Task { await model.setPinned(false, tabID: tab.id) } }
            Divider()
            Button("Unload Tab") { Task { await model.closeTab(tab.id) } }
        } else {
            Button("Pin Tab") { Task { await model.setPinned(true, tabID: tab.id) } }
            Divider()
            Button("Close Tab") { Task { await model.closeTab(tab.id) } }
        }
        Divider()
        MoveToFolderMenu(model: model, item: .tab(tab.id), current: tab.isPinned ? tab.folderID : nil, excluding: [])
    }
}

/// One level of the pinned section: folders (expandable) and pinned tabs, reorderable.
struct PinnedLevel: View {
    let model: BrowserModel
    let nodes: [PinnedNode]
    let parent: Folder.ID?
    /// Each split's panes, by the tab whose row stands for it.
    var splitPanes: [AxoCore.Tab.ID: [AxoCore.Tab]] = [:]

    var body: some View {
        ForEach(nodes) { node in
            switch node {
            case .tab(let tab):
                SidebarTabRow(model: model, tab: tab, panes: splitPanes[tab.id])
                    .tag(PinnedItem.tab(tab.id))
                    .contextMenu { TabContextMenu(model: model, tab: tab) }
                    .sidebarMoveActions(model: model, item: .tab(tab.id))
            case .folder(let folder, let children):
                DisclosureGroup(isExpanded: Binding(
                    get: { folder.isExpanded },
                    set: { expanded in Task { await model.setFolderExpanded(expanded, id: folder.id) } }
                )) {
                    // Type-erased because the view contains itself.
                    AnyView(PinnedLevel(model: model, nodes: children, parent: folder.id, splitPanes: splitPanes))
                } label: {
                    Label(folder.name, systemImage: folder.isExpanded ? "folder" : "folder.fill")
                        .lineLimit(1)
                        .tag(PinnedItem.folder(folder.id))
                        // The name is the label, so the value can add the item count.
                        .accessibilityLabel(folder.name)
                        .accessibilityValue(children.count == 1 ? "1 item" : "\(children.count) items")
                        .accessibilityAction(named: folder.isExpanded ? "Collapse" : "Expand") {
                            Task { await model.setFolderExpanded(!folder.isExpanded, id: folder.id) }
                        }
                        .sidebarMoveActions(model: model, item: .folder(folder.id))
                        .accessibilityIdentifier("folderRow")
                        .contextMenu { FolderContextMenu(model: model, folder: folder) }
                }
            }
        }
        .onMove { source, destination in
            Task { await model.movePinnedItems(fromOffsets: source, toOffset: destination, in: parent) }
        }
    }
}

/// The actions for a folder in the sidebar.
struct FolderContextMenu: View {
    let model: BrowserModel
    let folder: Folder

    var body: some View {
        Button("New Folder Inside…") { model.namingRequest = .newFolder(parent: folder.id, moving: nil) }
        Button("Rename…") { model.namingRequest = .renameFolder(folder) }
        MoveToFolderMenu(
            model: model,
            item: .folder(folder.id),
            current: folder.parentID,
            excluding: PinnedNode.folderAndDescendants(folder.id, in: model.pinnedTree)
        )
        Divider()
        Button("Delete Folder") { Task { await model.deleteFolder(folder.id) } }
            .help("Delete the folder and move what's inside it up a level")
    }
}

/// "Move to Folder" with every folder (by its path), the top level, and a new folder.
struct MoveToFolderMenu: View {
    let model: BrowserModel
    let item: PinnedItem
    /// The folder the item is in now, if any.
    let current: Folder.ID?
    /// Folders the item can't move into, such as a folder itself and its subfolders.
    let excluding: Set<Folder.ID>

    var body: some View {
        Menu("Move to Folder") {
            if current != nil {
                Button("Pinned (No Folder)") { Task { await model.move(item, toFolder: nil) } }
                Divider()
            }
            // Each folder by its path ("Work › Drafts"), which VoiceOver reads too.
            ForEach(PinnedNode.flattenedFolders(model.pinnedTree), id: \.folder.id) { entry in
                Button(entry.path) {
                    Task { await model.move(item, toFolder: entry.folder.id) }
                }
                .disabled(entry.folder.id == current || excluding.contains(entry.folder.id))
            }
            Divider()
            Button("New Folder…") { model.namingRequest = .newFolder(parent: nil, moving: item) }
        }
    }
}

extension View {
    /// VoiceOver actions to move a sidebar row up or down within its level, the equivalent of
    /// dragging it. Selecting the row first makes the model's move commands act on it.
    func sidebarMoveActions(model: BrowserModel, item: PinnedItem) -> some View {
        accessibilityAction(named: "Move Up") {
            model.selectSidebarItem(item)
            Task { await model.moveSelectedItem(by: -1) }
        }
        .accessibilityAction(named: "Move Down") {
            model.selectSidebarItem(item)
            Task { await model.moveSelectedItem(by: 1) }
        }
    }
}

/// One tab in the sidebar: the site's icon (or a globe) and the page title.
struct TabRow: View {
    let tab: AxoCore.Tab
    let favicon: PlatformImage?

    var body: some View {
        Label {
            Text(Self.displayTitle(for: tab))
        } icon: {
            if let favicon {
                Image(platformImage: favicon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                    .clipShape(.rect(cornerRadius: 3))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "globe")
            }
        }
        .lineLimit(1)
        .help(Self.displayTitle(for: tab))
        // The title is the label, so a value can add state without replacing it.
        .accessibilityLabel(Self.displayTitle(for: tab))
        .accessibilityValue(tab.hasLeftHome ? "Away from pinned page" : "")
        .accessibilityIdentifier("tabRow")
    }

    /// The page title, or the host (or full URL) for pages without one.
    static func displayTitle(for tab: AxoCore.Tab) -> String {
        if !tab.title.isEmpty { return tab.title }
        return tab.url.host() ?? tab.url.absoluteString
    }
}
