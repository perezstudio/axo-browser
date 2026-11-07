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

    var body: some View {
        // Folders are selectable too, so the keyboard can reach, open, and act on them.
        List(selection: Binding(get: { model.selectedSidebarItem }, set: { model.selectSidebarItem($0) })) {
            if !model.pinnedTree.isEmpty {
                Section("Pinned") {
                    PinnedLevel(model: model, nodes: model.pinnedTree, parent: nil)
                }
                .accessibilityIdentifier("pinnedSection")
            }
            Section {
                rows(for: model.unpinnedTabs.filter { !model.isSplitFollower($0) }, pinned: false)
            } header: {
                if let space = model.space, let icon = space.icon {
                    Label(space.name, systemImage: icon)
                } else {
                    Text(model.space?.name ?? "Tabs")
                }
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
        .sheet(item: Binding(get: { model.customizationDraft }, set: { model.customizationDraft = $0 })) { draft in
            CustomizeSiteSheet(model: model, customization: draft)
        }
        .sheet(item: Binding(get: { model.spaceToRename }, set: { model.spaceToRename = $0 })) { space in
            NameSheet(title: "Rename Space", initialName: space.name, confirmTitle: "Rename") { name in
                Task { await model.renameSpace(space.id, to: name) }
            }
        }
        .onChange(of: model.isShowingArchive) { isShowingArchive = model.isShowingArchive }
        .onChange(of: isShowingArchive) { if !isShowingArchive { model.isShowingArchive = false } }
        .accessibilityIdentifier("sidebar")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SpaceSwitcher(model: model)
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                // Like Arc, the address bar can sit at the top of the sidebar.
                if navigationBarPlacement == .sidebar, showsAddressBar {
                    SidebarAddressBar(model: model)
                }
                // Favorites sit above the pinned tabs, shared by the profile's Spaces.
                FavoritesGrid(model: model)
            }
            .padding(.horizontal, 10)
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
    /// The rows of one section, reorderable within it.
    @ViewBuilder
    private func rows(for tabs: [AxoCore.Tab], pinned: Bool) -> some View {
        ForEach(tabs) { tab in
            SidebarTabRow(model: model, tab: tab, isSelected: model.rowHoldsSelection(tab))
                .tag(PinnedItem.tab(tab.id))
                .contextMenu { menu(for: tab) }
                .sidebarMoveActions(model: model, item: .tab(tab.id))
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
#endif


/// A sidebar row for a tab, or for a split view when the tab's split stands behind it, with a
/// close (or, for a pinned tab, unload) button while the pointer is over it (#69), a spinner
/// while its page loads (#70), and dimmed while it has no live page (#72).
struct SidebarTabRow: View {
    let model: BrowserModel
    let tab: AxoCore.Tab
    /// Whether the row holds the selection, from the parent, so rows don't each read it.
    let isSelected: Bool
    @State private var isHovering = false

    /// What the button and the accessibility action are called. On a split row it closes the
    /// row's tab, the first pane, so it names it.
    private var closeTitle: String {
        let verb = tab.isPinned ? "Unload" : "Close"
        return model.split(of: tab.id) == nil ? "\(verb) Tab" : "\(verb) \(TabRow.displayTitle(for: tab))"
    }

    var body: some View {
        HStack(spacing: 4) {
            content
                // On the row's own element, which VoiceOver focuses, and always there.
                .accessibilityActions {
                    Button(closeTitle) { close() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            if isHovering {
                // A borderless button in a List row gets its click without selecting the row
                // first; the square is drawn in its label.
                Button { close() } label: {
                    TabRowCloseSquare(systemImage: tab.isPinned ? "minus" : "xmark")
                }
                .buttonStyle(.borderless)
                .help(closeTitle)
                .accessibilityLabel(closeTitle)
                // Shown only under the pointer; VoiceOver and the keyboard also get the row's
                // action, which is always there.
                .accessibilityIdentifier("tabRowCloseButton")
            }
        }
        // The whole row's width counts as over it, not just its icon and title, for every row
        // (hibernated ones included).
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var content: some View {
        if let split = model.split(of: tab.id) {
            let panes = model.panes(of: split.id)
            SplitRow(panes: panes, favicon: model.favicon(for:),
                     isLoading: panes.contains { model.isTabLoading($0.id) },
                     // Dimmed only when every pane is unloaded.
                     isDimmed: panes.allSatisfy { model.isTabDimmed($0.id, isSelected: isSelected) })
        } else {
            TabRow(tab: tab, favicon: model.favicon(for: tab),
                   isLoading: model.isTabLoading(tab.id), isDimmed: model.isTabDimmed(tab.id, isSelected: isSelected))
        }
    }

    /// Closes the tab, or unloads a pinned one, as its context menu does (for a split, the
    /// row's tab, whose pane leaves the split).
    private func close() {
        Task { await model.closeTab(tab.id, byPerson: true) }
    }
}

/// One split view in the sidebar: its tabs' icons and titles in pane order.
struct SplitRow: View {
    let panes: [AxoCore.Tab]
    let favicon: (AxoCore.Tab) -> PlatformImage?
    var isLoading = false
    var isDimmed = false

    var body: some View {
        Label {
            Text(panes.map(TabRow.displayTitle(for:)).joined(separator: " | "))
                .foregroundStyle(isDimmed ? .secondary : .primary)
        } icon: {
            HStack(spacing: 2) {
                if isLoading {
                    TabRowSpinner()
                } else {
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
            }
            .opacity(isDimmed ? TabRow.dimmedIconOpacity : 1)
            .accessibilityHidden(true)
        }
        .lineLimit(1)
        // Only when there's state to tell: a value replaces the text a row exposes.
        .modifier(StateValue(description: TabRow.stateDescription(isLoading: isLoading, isDimmed: isDimmed)))
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
            Button("Unload Tab") { Task { await model.closeTab(tab.id, byPerson: true) } }
        } else {
            Button("Pin Tab") { Task { await model.setPinned(true, tabID: tab.id) } }
            Divider()
            Button("Close Tab") { Task { await model.closeTab(tab.id, byPerson: true) } }
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
                SidebarTabRow(model: model, tab: tab, isSelected: model.rowHoldsSelection(tab))
                    .tag(PinnedItem.tab(tab.id))
                    .contextMenu { TabContextMenu(model: model, tab: tab) }
                    .sidebarMoveActions(model: model, item: .tab(tab.id))
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
    /// Whether its page is loading: a spinner takes the icon's place.
    var isLoading = false
    /// Whether it has no live page: the icon fades and the title turns secondary, which keeps
    /// it readable in light and dark mode.
    var isDimmed = false

    /// How faded a dimmed row's icon is.
    static let dimmedIconOpacity = 0.5

    var body: some View {
        Label {
            Text(Self.displayTitle(for: tab))
                .foregroundStyle(isDimmed ? .secondary : .primary)
        } icon: {
            Group {
                if isLoading {
                    TabRowSpinner()
                } else if let favicon {
                    Image(platformImage: favicon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 16, height: 16)
                        .clipShape(.rect(cornerRadius: 3))
                } else {
                    Image(systemName: "globe")
                }
            }
            .opacity(isDimmed ? Self.dimmedIconOpacity : 1)
            .accessibilityHidden(true)
        }
        .lineLimit(1)
        .help(Self.displayTitle(for: tab))
        // The title is the label, so a value can add state without replacing it.
        .accessibilityLabel(Self.displayTitle(for: tab))
        .accessibilityValue(Self.stateDescription(
            isLoading: isLoading, isDimmed: isDimmed, isAwayFromHome: tab.hasLeftHome))
        .accessibilityIdentifier("tabRow")
    }

    /// The row's state for VoiceOver: "Loading", "Unloaded", and "Away from pinned page", as
    /// they apply.
    static func stateDescription(isLoading: Bool, isDimmed: Bool, isAwayFromHome: Bool = false) -> String {
        [isLoading ? "Loading" : nil, isDimmed ? "Unloaded" : nil, isAwayFromHome ? "Away from pinned page" : nil]
            .compactMap(\.self)
            .joined(separator: ", ")
    }

    /// The page title, or the host (or full URL) for pages without one.
    static func displayTitle(for tab: AxoCore.Tab) -> String {
        if !tab.title.isEmpty { return tab.title }
        return tab.url.host() ?? tab.url.absoluteString
    }
}

/// The small spinner a row shows in place of its icon while its page loads, as Arc does.
struct TabRowSpinner: View {
    var body: some View {
        ProgressView()
            .controlSize(.mini)
            .frame(width: 16, height: 16)
    }
}

/// The row's close button's face: a small square with rounded corners, like an app icon, on a
/// light fill that darkens under the pointer.
struct TabRowCloseSquare: View {
    let systemImage: String
    @State private var isHovering = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .background(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quaternary.opacity(0.5)),
                        in: .rect(cornerRadius: 5, style: .continuous))
            .contentShape(.rect(cornerRadius: 5, style: .continuous))
            .onHover { isHovering = $0 }
    }
}

/// Adds a row's state as its accessibility value, but only when there's some: an empty value
/// would still replace the text the row exposes.
private struct StateValue: ViewModifier {
    let description: String

    func body(content: Content) -> some View {
        if description.isEmpty {
            content
        } else {
            content.accessibilityValue(description)
        }
    }
}
