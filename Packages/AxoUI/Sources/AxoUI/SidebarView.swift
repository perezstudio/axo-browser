import AxoCore
import SwiftUI

/// The sidebar: the address field, the Space's pinned tabs, and its other tabs.
struct SidebarView: View {
    let model: BrowserModel
    @State private var isShowingArchive = false

    var body: some View {
        List(selection: Binding(get: { model.selectedTabID }, set: { model.select($0) })) {
            if !model.pinnedTree.isEmpty {
                Section("Pinned") {
                    PinnedLevel(model: model, nodes: model.pinnedTree, parent: nil)
                }
                .accessibilityIdentifier("pinnedSection")
            }
            Section(model.space?.name ?? "Tabs") {
                rows(for: model.unpinnedTabs, pinned: false)
            }
        }
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
        .onChange(of: model.isShowingArchive) { isShowingArchive = model.isShowingArchive }
        .onChange(of: isShowingArchive) { if !isShowingArchive { model.isShowingArchive = false } }
        .accessibilityIdentifier("sidebar")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SpaceSwitcher(model: model)
        }
        .safeAreaInset(edge: .top) {
            // Like Arc, the address field sits at the top of the sidebar.
            AddressField(model: model)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        }
        .toolbar {
            ToolbarItem {
                Button("New Tab", systemImage: "plus") { model.beginNewTab() }
                    .help("New Tab")
                    .accessibilityIdentifier("newTabButton")
            }
        }
    }
}

extension SidebarView {
    /// The rows of one section, reorderable within it.
    @ViewBuilder
    private func rows(for tabs: [AxoCore.Tab], pinned: Bool) -> some View {
        ForEach(tabs) { tab in
            TabRow(tab: tab, favicon: model.favicon(for: tab))
                .tag(tab.id)
                .contextMenu { menu(for: tab) }
        }
        .onMove { source, destination in
            Task { await model.moveTabs(fromOffsets: source, toOffset: destination, pinned: pinned) }
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

    @ViewBuilder
    private func menu(for tab: AxoCore.Tab) -> some View {
        TabContextMenu(model: model, tab: tab)
    }
}

/// The actions for a tab in the sidebar.
struct TabContextMenu: View {
    let model: BrowserModel
    let tab: AxoCore.Tab

    var body: some View {
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

    var body: some View {
        ForEach(nodes) { node in
            switch node {
            case .tab(let tab):
                TabRow(tab: tab, favicon: model.favicon(for: tab))
                    .tag(tab.id)
                    .contextMenu { TabContextMenu(model: model, tab: tab) }
            case .folder(let folder, let children):
                DisclosureGroup(isExpanded: Binding(
                    get: { folder.isExpanded },
                    set: { expanded in Task { await model.setFolderExpanded(expanded, id: folder.id) } }
                )) {
                    // Type-erased because the view contains itself.
                    AnyView(PinnedLevel(model: model, nodes: children, parent: folder.id))
                } label: {
                    Label(folder.name, systemImage: folder.isExpanded ? "folder" : "folder.fill")
                        .lineLimit(1)
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

/// "Move to Folder" with every folder (indented by depth), the top level, and a new folder.
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
            ForEach(PinnedNode.flattenedFolders(model.pinnedTree), id: \.folder.id) { entry in
                Button(String(repeating: "    ", count: entry.depth) + entry.folder.name) {
                    Task { await model.move(item, toFolder: entry.folder.id) }
                }
                .disabled(entry.folder.id == current || excluding.contains(entry.folder.id))
            }
            Divider()
            Button("New Folder…") { model.namingRequest = .newFolder(parent: nil, moving: item) }
        }
    }
}

/// One tab in the sidebar: the site's icon (or a globe) and the page title.
struct TabRow: View {
    let tab: AxoCore.Tab
    let favicon: NSImage?

    var body: some View {
        Label {
            Text(Self.displayTitle(for: tab))
        } icon: {
            if let favicon {
                Image(nsImage: favicon)
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
        .accessibilityIdentifier("tabRow")
    }

    /// The page title, or the host (or full URL) for pages without one.
    static func displayTitle(for tab: AxoCore.Tab) -> String {
        if !tab.title.isEmpty { return tab.title }
        return tab.url.host() ?? tab.url.absoluteString
    }
}
