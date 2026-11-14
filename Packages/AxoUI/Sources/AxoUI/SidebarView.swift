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
    /// Which Space's list has keyboard focus, if any (from Full Keyboard Access or VoiceOver).
    /// On a switch it moves to the shown Space's list, so the arrow keys move through the Space
    /// switched to rather than the one left, which is still drawn beside it but takes no input.
    @FocusState private var focusedList: Space.ID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        spacePages
        .sheet(isPresented: $isShowingArchive) {
            ArchivedTabsView(model: model).windowAppearance()
        }
        .sheet(item: Binding(get: { model.pendingExtensionInstall }, set: { if $0 == nil { Task { await model.cancelExtensionInstall() } } })) { prompt in
            ExtensionInstallSheet(model: model, prompt: prompt).windowAppearance()
        }
        .sheet(isPresented: Binding(get: { model.isShowingExtensions }, set: { model.isShowingExtensions = $0 })) {
            ExtensionsView(model: model).windowAppearance()
        }
        .sheet(item: Binding(get: { model.importSession }, set: { model.importSession = $0 })) { session in
            ImportSheet(model: model, session: session).windowAppearance()
        }
        .sheet(item: Binding(get: { model.namingRequest }, set: { model.namingRequest = $0 })) { request in
            folderNameSheet(for: request).windowAppearance()
        }
        .sheet(item: Binding(get: { model.customizationDraft }, set: { model.customizationDraft = $0 })) { draft in
            CustomizeSiteSheet(model: model, customization: draft).windowAppearance()
        }
        .sheet(item: Binding(get: { model.spaceToRename }, set: { model.spaceToRename = $0 })) { space in
            NameSheet(title: "Rename Space", initialName: space.name, confirmTitle: "Rename") { name in
                Task { await model.renameSpace(space.id, to: name) }
            }
            .windowAppearance()
        }
        // Two-finger swipes over the favorites and tabs move between Spaces (not over the
        // address bar, which stays put).
        .background { SidebarSwipeCatcher(model: model, state: swipe) }
        .onChange(of: model.isShowingArchive) { isShowingArchive = model.isShowingArchive }
        .onChange(of: isShowingArchive) { if !isShowingArchive { model.isShowingArchive = false } }
        // Slide to the shown Space's page when it changes some other way (the keyboard, the
        // dots, the menu); after a swipe the pages are already there.
        .onChange(of: model.space?.id, initial: true) {
            followShownSpace(animated: true)
            if focusedList != nil { focusedList = model.space?.id }
        }
        // A hidden Space's list takes no input, so focus that lands on one (Full Keyboard
        // Access's Tab still reaches it) goes to the shown Space's list instead.
        .onChange(of: focusedList) {
            if let focusedList, focusedList != model.space?.id { self.focusedList = model.space?.id }
        }
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
    /// accessibility tree, where its list is the `sidebar` element. No accessibility container
    /// wraps the pages: one around the lists' AppKit views gave them two parents (the audit's
    /// "Parent/Child mismatch").
    private var spacePages: some View {
        GeometryReader { proxy in
            // The pages are an overlay of a sidebar-sized base, so the strip, as wide as all of
            // them, never sets the sidebar's size.
            Color.clear
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        ForEach(Array(model.spaces.enumerated()), id: \.element.id) { index, space in
                            SpacePage(model: model, space: space, isShown: space.id == model.space?.id,
                                      focusedList: $focusedList,
                                      favorites: SpaceSwipe.favoritesPlacement(
                                          forPage: index, resting: swipe.pageIndex, offset: swipe.offset,
                                          width: proxy.size.width, profiles: model.spaces.map(\.profileID)))
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
    }

    /// Rests the pages on the shown Space's, sliding there unless `animated` is off or Reduce
    /// Motion is on. Does nothing when they're already there, as after a swipe.
    private func followShownSpace(animated: Bool) {
        guard let index = SpaceSwipe.restingPage(shown: model.space?.id, in: model.spaces),
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
        // The Space's name, between the favorites and Pinned, styled like a tab row (#171).
        Section {
            SpaceNameRow(model: model, space: data.space, canDelete: model.spaces.count > 1)
        }
        if !data.pinnedTree.isEmpty {
            Section("Pinned") {
                PinnedLevel(model: model, nodes: data.pinnedTree, parent: nil, splitPanes: data.splitPanes,
                            selectedTabID: data.selectedTabID)
            }
            .accessibilityIdentifier("pinnedSection")
        }
        Section {
            ForEach(data.rows) { row in
                let tab = leader(of: row)
                SidebarTabRow(model: model, tab: tab, panes: data.splitPanes[tab.id],
                              isSelected: data.holdsSelection(tab.id))
                    .tag(PinnedItem.tab(tab.id))
                    .contextMenu { TabContextMenu(model: model, tab: tab) }
                    .sidebarMoveActions(model: model, item: .tab(tab.id))
            }
            .onMove { source, destination in
                Task { await model.moveTabs(fromOffsets: source, toOffset: destination, pinned: false) }
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


/// The Space's name, between the favorites and Pinned, styled like a tab row: its icon and name
/// (#171). It's a heading for VoiceOver, and its menu offers the Space's actions, as its dot's
/// does. It isn't selectable.
struct SpaceNameRow: View {
    let model: BrowserModel
    let space: Space
    /// Whether the Space can be deleted (it isn't the only one), from the parent, so a change to
    /// another Space doesn't redraw every page's row.
    let canDelete: Bool

    var body: some View {
        Label {
            // The name is the row's element for VoiceOver and UI tests: a heading, as text.
            Text(space.name)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("spaceNameRow")
        } icon: {
            Image(systemName: space.icon ?? "square.stack")
                .accessibilityHidden(true)
        }
        .fontWeight(.medium)
        .contextMenu {
            Button("Rename…") { model.spaceToRename = space }
            Button("Edit Theme…") { model.beginEditingTheme(for: space.id, in: .sidebar) }
            Button("Delete Space…", role: .destructive) { model.spaceToDelete = space }
                .disabled(!canDelete)
        }
    }
}

/// A sidebar row for a tab, or for a split view when the tab's split stands behind it (`panes`,
/// in pane order, from the Space's rows), with a
/// close (or, for a pinned tab, unload) button while the pointer is over it (#69), a spinner
/// while its page loads (#70), and dimmed while it has no live page (#72).
struct SidebarTabRow: View {
    let model: BrowserModel
    let tab: AxoCore.Tab
    /// The split's panes, in pane order, when the row stands for a split.
    var panes: [AxoCore.Tab]?
    /// Whether the row holds the selection, from the parent, so rows don't each read it.
    let isSelected: Bool
    @State private var isHovering = false

    /// What the button and the accessibility action are called. On a split row it closes the
    /// row's tab, the first pane, so it names it.
    private var closeTitle: String {
        let verb = tab.isPinned ? "Unload" : "Close"
        return panes == nil ? "\(verb) Tab" : "\(verb) \(TabRow.displayTitle(for: tab))"
    }

    var body: some View {
        HStack(spacing: 4) {
            content
                // On the row's own element, which VoiceOver focuses, and always there.
                .accessibilityActions {
                    if isAwayFromHome {
                        Button("Go to Pinned Page") { goHome() }
                    }
                    Button(closeTitle) { close() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            // A pinned tab away from its pinned page shows it at a glance, as in Arc, with a
            // control that goes back (#73).
            if isAwayFromHome {
                Button { goHome() } label: {
                    TabRowCloseSquare(systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Go to Pinned Page")
                .accessibilityLabel("Go to Pinned Page")
                .accessibilityIdentifier("goToPinnedPageButton")
            }
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
        if let panes {
            SplitRow(panes: panes, favicon: model.favicon(for:),
                     isLoading: panes.contains { model.isTabLoading($0.id) },
                     // Dimmed only when every pane is unloaded.
                     isDimmed: panes.allSatisfy { model.isTabDimmed($0.id, isSelected: isSelected) })
        } else {
            TabRow(tab: tab, favicon: model.favicon(for: tab),
                   isLoading: model.isTabLoading(tab.id), isDimmed: model.isTabDimmed(tab.id, isSelected: isSelected))
        }
    }

    /// Whether the row is a pinned tab away from its pinned page. A split row shows its panes
    /// instead.
    private var isAwayFromHome: Bool { panes == nil && tab.hasLeftHome }

    /// Goes back to the pinned page, as the context menu's Go to Pinned Page does.
    private func goHome() {
        Task { await model.goToPinnedHome(tab.id) }
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
        Button("Duplicate Tab") { Task { await model.duplicateTab(tab.id) } }
        Button("Copy Link") { model.copyLink(of: tab.id) }
        Button("Add to Favorites") { Task { await model.addToFavorites(tab.id) } }
        if model.canMoveToSpace(tab.id) {
            Menu("Move to Space") {
                ForEach(model.spacesToMoveTabsTo) { space in
                    Button(space.name) { Task { await model.moveTab(tab.id, toSpace: space.id) } }
                }
            }
        }
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
            Button("Close Other Tabs") { Task { await model.closeOtherTabs(than: tab.id) } }
                .disabled(model.otherUnpinnedTabs(than: tab.id).isEmpty)
            Button("Close Tabs Below") { Task { await model.closeTabs(below: tab.id) } }
                .disabled(model.unpinnedTabs(below: tab.id).isEmpty)
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
    /// The tab the page's Space shows, whose row (or split's row) holds the selection.
    var selectedTabID: AxoCore.Tab.ID?

    /// Whether `tab`'s row holds the selection: it's the selected tab, or its split has it.
    private func holdsSelection(_ tab: AxoCore.Tab, _ selected: AxoCore.Tab.ID) -> Bool {
        tab.id == selected || splitPanes[tab.id]?.contains { $0.id == selected } == true
    }

    var body: some View {
        ForEach(nodes) { node in
            switch node {
            case .tab(let tab):
                SidebarTabRow(model: model, tab: tab, panes: splitPanes[tab.id],
                              isSelected: selectedTabID.map { holdsSelection(tab, $0) } ?? false)
                    .tag(PinnedItem.tab(tab.id))
                    .contextMenu { TabContextMenu(model: model, tab: tab) }
                    .sidebarMoveActions(model: model, item: .tab(tab.id))
            case .folder(let folder, let children):
                DisclosureGroup(isExpanded: Binding(
                    get: { folder.isExpanded },
                    set: { expanded in Task { await model.setFolderExpanded(expanded, id: folder.id) } }
                )) {
                    // Type-erased because the view contains itself.
                    AnyView(PinnedLevel(model: model, nodes: children, parent: folder.id, splitPanes: splitPanes,
                                        selectedTabID: selectedTabID))
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
        .help(Self.tooltip(for: tab))
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

    /// The row's tooltip: its title, and for a pinned tab away from its pinned page, that page
    /// too (#73).
    static func tooltip(for tab: AxoCore.Tab) -> String {
        guard tab.hasLeftHome, let home = tab.homeURL else { return displayTitle(for: tab) }
        // The site, or for a page without one (a data: page holds a whole file), the start of
        // its address.
        let page = home.host() ?? String(home.absoluteString.prefix(80))
        return "\(displayTitle(for: tab))\nPinned page: \(page)"
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
