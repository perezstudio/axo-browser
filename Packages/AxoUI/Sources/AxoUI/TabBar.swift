import AxoCore
import AxoWeb
import SwiftUI

/// How the tab bar lays out a Space's rows (#136), in the sidebar's order: its favorites, the
/// top-level pinned tabs as one group, each top-level pinned folder as a collapsed group, then
/// the other tabs, a split as one tab.
/// Shared with iOS, where its tests run too; only the bar that draws it is Mac only.
struct TabBarSections {
    /// The favorites, in order.
    let favorites: [Favorite]
    /// The pinned tabs outside any folder, in order.
    let pinnedTabs: [AxoCore.Tab]
    /// The top-level pinned folders, in order, with what's inside each.
    let folders: [(folder: Folder, children: [PinnedNode])]
    /// The other tabs, a split as one row.
    let today: [SpaceSidebarPreview.Row]

    init(_ rows: SpaceSidebarPreview) {
        favorites = rows.favorites
        pinnedTabs = rows.pinnedTree.compactMap { node in
            if case .tab(let tab) = node { tab } else { nil }
        }
        folders = rows.pinnedTree.compactMap { node in
            if case .folder(let folder, let children) = node { (folder, children) } else { nil }
        }
        today = rows.rows
    }
}

// Mac only; iPhone and iPad have their own chrome.
#if os(macOS)
/// The tab bar with tabs at the top (#136), as the board draws it: the window's controls, the
/// favorites as icon-only tabs in a container named after the Space (its name opens the Spaces
/// menu), the pinned tabs as a group, each pinned folder as a collapsed group that opens a menu,
/// then the Space's other tabs and New Tab. It reads the same rows the sidebar draws
/// (`shownSpaceRows`), so switching between the layouts changes nothing in the data. Dragging its
/// empty space moves the window, and a double click zooms it.
struct TabBar: View {
    let model: BrowserModel
    /// Whether this is the bar floating in over the page while it's hidden.
    var isFloating = false

    /// The bar's height, the board's 44 pt.
    static let height: CGFloat = 44
    /// A group's and a tab's height.
    static let itemHeight: CGFloat = 30
    /// The widest a tab gets.
    static let tabMaxWidth: CGFloat = 180

    var body: some View {
        let rows = model.shownSpaceRows
        HStack(spacing: 6) {
            WindowControls()
                .frame(width: WindowControls.size.width, height: WindowControls.size.height)
                .padding(.leading, isFloating ? 0 : 8)
                .padding(.trailing, 8)
            FavoritesGroup(model: model, favorites: rows?.favorites ?? [])
            if let rows {
                // Everything after the favorites scrolls sideways once it doesn't fit, so many
                // pinned tabs never push the window's controls off or widen the window.
                ScrollingTabs(model: model, rows: rows)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: Self.height)
        .font(.system(size: 12.5))
        .background {
            // The bar's empty space moves the window, and a double click zooms it.
            Color.clear
                .contentShape(.rect)
                .gesture(WindowDragGesture())
                .onTapGesture(count: 2) { NSApp.keyWindow?.performZoom(nil) }
                .allowsWindowActivationEvents(true)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab bar")
        .accessibilityIdentifier("tabBar")
    }
}

/// A group's look on the bar, as the board draws it: a rounded rectangle with a faint fill and a
/// hairline edge, which reads on any Space theme.
private struct TabBarGroupStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(height: TabBar.itemHeight)
            .background(.primary.opacity(0.1), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.primary.opacity(0.26), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}

/// The favorites as icon-only tabs, after the Space's name, which opens the Spaces menu.
private struct FavoritesGroup: View {
    let model: BrowserModel
    let favorites: [Favorite]

    var body: some View {
        HStack(spacing: 2) {
            SpaceMenu(model: model)
            ForEach(favorites) { favorite in
                let title = BrowserModel.title(of: favorite)
                let isSelected = model.selectedTabID == favorite.id
                Button { model.select(favorite.id) } label: {
                    TabIcon(image: model.favicon(for: favorite.tab(in: model.space?.id ?? favorite.id)))
                        .frame(width: 28, height: 24)
                        .background(isSelected ? AnyShapeStyle(.primary.opacity(0.14)) : AnyShapeStyle(.clear),
                                    in: .rect(cornerRadius: 6))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(title)
                .accessibilityLabel(title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityAction(named: "Move Left") { Task { await model.moveFavorite(favorite.id, by: -1) } }
                .accessibilityAction(named: "Move Right") { Task { await model.moveFavorite(favorite.id, by: 1) } }
                .contextMenu {
                    FavoriteContextMenu(model: model, favorite: favorite, hasLeftHome: model.favoriteHasLeftHome(favorite),
                                        isLive: model.pool.isLive(favorite.id))
                }
                .accessibilityIdentifier("tabBarFavorite")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .modifier(TabBarGroupStyle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Favorites of \(model.space?.name ?? "this Space")")
    }
}

/// The Space's name, which opens a menu of the Spaces (⌃1–9 switch from the keyboard) and New
/// Space.
private struct SpaceMenu: View {
    let model: BrowserModel

    var body: some View {
        Menu {
            // A picker, so the shown Space is checked as a selected item, for VoiceOver too.
            Picker("Spaces", selection: Binding(
                get: { model.space?.id },
                set: { id in if let id { Task { await model.selectSpace(id) } } }
            )) {
                // ⌃1–9 switch Spaces from anywhere, through the Spaces menu.
                ForEach(model.spaces) { space in
                    Text(space.name).tag(Optional(space.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("New Space…") { model.isCreatingSpace = true }
            Button("Show Archived Tabs") { model.isShowingArchive = true }
        } label: {
            Text(model.space?.name ?? "Space")
                .font(.system(size: 12.5, weight: .bold))
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.trailing, 4)
        .help("Spaces")
        .accessibilityLabel("Space")
        .accessibilityValue(model.space?.name ?? "")
        .accessibilityIdentifier("tabBarSpaceMenu")
    }
}

/// The pinned tabs as a group: its label, a divider, and the tabs.
private struct PinnedGroup: View {
    let model: BrowserModel
    let tabs: [AxoCore.Tab]
    let splitPanes: [AxoCore.Tab.ID: [AxoCore.Tab]]

    var body: some View {
        HStack(spacing: 2) {
            Label("Pinned", systemImage: "pin")
                .font(.system(size: 12.5, weight: .bold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 6)
                .fixedSize()
            Rectangle()
                .fill(.primary.opacity(0.24))
                .frame(width: 1, height: 14)
                .accessibilityHidden(true)
            ForEach(tabs) { tab in
                TopTab(model: model, tab: tab, panes: splitPanes[tab.id], isSelected: model.selectedTabID == tab.id,
                       style: .inGroup)
            }
        }
        .padding(.horizontal, 3)
        .modifier(TabBarGroupStyle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pinned tabs")
        .accessibilityIdentifier("tabBarPinned")
    }
}

/// A pinned folder as a collapsed group: its name opens a menu of its tabs and folders.
private struct FolderChip: View {
    let model: BrowserModel
    let folder: Folder
    let children: [PinnedNode]

    var body: some View {
        Menu {
            FolderMenuItems(model: model, children: children)
        } label: {
            Label(folder.name, systemImage: "folder")
                .font(.system(size: 12.5, weight: .bold))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 9)
        .modifier(TabBarGroupStyle())
        .contextMenu { FolderContextMenu(model: model, folder: folder) }
        .help(folder.name)
        .accessibilityLabel("\(folder.name) folder")
        .accessibilityValue(Self.count(children))
        .accessibilityIdentifier("tabBarFolder")
    }

    /// "1 tab", "3 tabs", for VoiceOver.
    static func count(_ children: [PinnedNode]) -> String {
        let tabs = PinnedNode.allTabs(in: children).count
        return tabs == 1 ? "1 tab" : "\(tabs) tabs"
    }
}

/// A folder's tabs, and its folders as submenus.
private struct FolderMenuItems: View {
    let model: BrowserModel
    let children: [PinnedNode]

    var body: some View {
        if children.isEmpty {
            Text("No Tabs")
        }
        ForEach(children) { node in
            switch node {
            case .tab(let tab):
                Button {
                    model.select(tab.id)
                } label: {
                    Label {
                        Text(TabRow.displayTitle(for: tab))
                    } icon: {
                        if let favicon = model.favicon(for: tab) { Image(platformImage: favicon) } else { Image(systemName: "globe") }
                    }
                }
            case .folder(let folder, let grandchildren):
                Menu(folder.name) {
                    FolderMenuItems(model: model, children: grandchildren)
                }
            }
        }
    }
}

/// The pinned group, the folders, the Space's other tabs, and New Tab, scrolling sideways once
/// they don't fit, with the selected tab kept in view. The empty space after them still moves the
/// window, as the bar's other empty space does.
private struct ScrollingTabs: View {
    let model: BrowserModel
    let rows: SpaceSidebarPreview
    @State private var width: CGFloat = 0

    var body: some View {
        let sections = TabBarSections(rows)
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    if !sections.pinnedTabs.isEmpty {
                        PinnedGroup(model: model, tabs: sections.pinnedTabs, splitPanes: rows.splitPanes)
                    }
                    ForEach(sections.folders, id: \.folder.id) { entry in
                        FolderChip(model: model, folder: entry.folder, children: entry.children)
                    }
                    HStack(spacing: 6) {
                        ForEach(sections.today) { row in
                            switch row {
                            case .tab(let tab):
                                TopTab(model: model, tab: tab, panes: nil, isSelected: isSelected(row), style: .regular)
                            case .split(let leader, let panes):
                                // The row stands for its first tab in sidebar order, as the
                                // sidebar's split row does, so its menu and close act on the same tab.
                                if let tab = panes.first(where: { $0.id == leader }) ?? panes.first {
                                    TopTab(model: model, tab: tab, panes: panes, isSelected: isSelected(row), style: .regular)
                                }
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Tabs")
                    .accessibilityIdentifier("tabBarTabs")
                    Button {
                        // A turn later: the click's own handling in the scroll view took keyboard
                        // focus back from the command bar's field, which then took no typing.
                        Task { @MainActor in model.beginNewTab() }
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 30, height: 30)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("New Tab")
                    .accessibilityLabel("New Tab")
                    .accessibilityIdentifier("tabBarNewTabButton")
                }
                .padding(.vertical, 4)
                .frame(minWidth: width, alignment: .leading)
                .background {
                    Color.clear
                        .contentShape(.rect)
                        .gesture(WindowDragGesture())
                        .onTapGesture(count: 2) { NSApp.keyWindow?.performZoom(nil) }
                        .allowsWindowActivationEvents(true)
                        .accessibilityHidden(true)
                }
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollPhaseChange { _, phase in model.setSidebarScrolling(phase.isScrolling) }
            // Switching to the sidebar mid-scroll mustn't leave the flag set.
            .onDisappear { model.setSidebarScrolling(false) }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onChange(of: model.selectedTabID, initial: true) { scroll(proxy) }
            // A tab opened past the edge arrives in the rows after the selection does.
            .onChange(of: rows.rows.map(\.id)) { scroll(proxy) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let selected = model.selectedTabID else { return }
        withAnimation { proxy.scrollTo(model.sidebarRowTab(for: selected)) }
    }

    /// Whether the row holds the selection: its tab, or for a split, any of its panes.
    private func isSelected(_ row: SpaceSidebarPreview.Row) -> Bool {
        guard let selected = model.selectedTabID else { return false }
        switch row {
        case .tab(let tab): return tab.id == selected
        case .split(_, let panes): return panes.contains { $0.id == selected }
        }
    }
}

/// One tab on the bar: its icon (a split's icons side by side) and title, raised when selected,
/// with a close button under the pointer and the sidebar row's context menu.
private struct TopTab: View {
    enum Style { case regular, inGroup }

    let model: BrowserModel
    let tab: AxoCore.Tab
    let panes: [AxoCore.Tab]?
    let isSelected: Bool
    let style: Style
    @State private var isHovering = false
    /// The tab's frame in the window, where its hover card goes, kept outside SwiftUI's state.
    @State private var frame = TabPreviewFrame()

    private var title: String {
        if let panes, panes.count > 1 {
            return panes.map(TabRow.displayTitle(for:)).joined(separator: " | ")
        }
        return TabRow.displayTitle(for: tab)
    }

    /// On a split's tab it closes the row's tab, which leaves the split, so it names it, as the
    /// sidebar's split row does.
    private var closeTitle: String {
        let verb = tab.isPinned ? "Unload" : "Close"
        return panes == nil ? "\(verb) Tab" : "\(verb) \(TabRow.displayTitle(for: tab))"
    }

    /// Dimmed only when every pane is unloaded, as the sidebar's split row is.
    private var isDimmed: Bool {
        (panes ?? [tab]).allSatisfy { model.isTabDimmed($0.id, isSelected: isSelected) }
    }

    var body: some View {
        Button {
            model.select(tab.id)
            // A click hands keyboard focus to the page, as a sidebar row's does; Full Keyboard
            // Access and VoiceOver leave it where it is.
            if SidebarClick.isClick(NSApp.currentEvent?.type) { model.focusPage() }
        } label: {
            HStack(spacing: 6) {
                ForEach(panes ?? [tab]) { pane in
                    if model.isTabLoading(pane.id) {
                        TabRowSpinner()
                    } else {
                        TabIcon(image: model.favicon(for: pane))
                            .opacity(model.isTabDimmed(pane.id, isSelected: isSelected) || problem != nil
                                     ? TabRow.dimmedIconOpacity : 1)
                    }
                }
                Text(title)
                    .lineLimit(1)
                    .foregroundStyle(isDimmed || problem != nil ? .secondary : .primary)
                Spacer(minLength: 0)
                // Room for the speaker, dot, and warning, drawn over the tab's end with the close
                // button.
                if indicatorsWidth > 0 {
                    Color.clear.frame(width: indicatorsWidth, height: 1)
                }
            }
            // The same width hovered or not, so tabs never shift under the pointer; the close
            // button covers the title's end.
            .padding(.horizontal, 9)
            .frame(height: style == .regular ? TabBar.itemHeight : 24)
            .frame(maxWidth: TabBar.tabMaxWidth)
            .background(background)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: TabBar.tabMaxWidth)
        // On the tab's own button only, so the close button keeps its own label and identifier.
        // Resting the pointer on it shows its card (#76) below it, in place of a tooltip.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.rect = $0 }
        .accessibilityLabel(title)
        .accessibilityCustomContent(Text(panes == nil ? "Address" : "Addresses"),
                                    Text(verbatim: (panes ?? [tab]).map(\.url.absoluteString).formatted(.list(type: .and))))
        .modifier(PinnedPageContent(tab: tab))
        .accessibilityValue(stateDescription)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: closeTitle) { close() }
        .accessibilityActions {
            if media.hasSound {
                Button(media.muteTitle) { toggleMute() }
            }
            if problem != nil {
                Button("Reload Page") { model.reloadStoppedPages(tabIDs) }
            }
        }
        .accessibilityAction(named: "Move Left") { move(by: -1) }
        .accessibilityAction(named: "Move Right") { move(by: 1) }
        .accessibilityAction(named: tab.isPinned ? "Unpin" : "Pin") {
            Task { await model.setPinned(!tab.isPinned, tabID: tab.id) }
        }
        .accessibilityIdentifier("topTab")
        .overlay(alignment: .trailing) {
            HStack(spacing: 2) {
                // As in a sidebar row: the dot gives way to the close button.
                if !media.capture.isEmpty, !isHovering {
                    TabCaptureDot(media: media)
                }
                if isHovering {
                    Button { close() } label: {
                        TabRowCloseSquare(systemImage: tab.isPinned ? "minus" : "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help(closeTitle)
                    .accessibilityLabel(closeTitle)
                    .accessibilityIdentifier("tabBarCloseButton")
                }
                // After the close button, so neither moves under the pointer when it appears.
                if let problem {
                    TabProblemButton(problem: problem) { model.reloadStoppedPages(tabIDs) }
                }
                if media.hasSound {
                    TabMuteButton(media: media) { toggleMute() }
                }
            }
            .padding(.trailing, 5)
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                model.beginTabPreview(tabIDs, anchor: frame.rect, edge: .bottom)
            } else {
                model.endTabPreview(tabIDs)
            }
        }
        .onDisappear { model.endTabPreview(tabIDs) }
        .contextMenu { TabContextMenu(model: model, tab: tab, media: media) }
    }

    /// The tab's pages: a split's panes, or the tab.
    private var tabIDs: [AxoCore.Tab.ID] { (panes ?? [tab]).map(\.id) }

    /// What the tab's pages play and use (#71, #74).
    private var media: PageMedia { model.tabMedia(tabIDs) }

    /// Why the tab's page (a split's, any pane's) stopped working (#75).
    private var problem: PageProblem? { model.tabProblem(tabIDs) }

    /// The speaker, dot, and warning's width, which the title leaves free.
    private var indicatorsWidth: CGFloat {
        (media.hasSound ? 22 : 0) + (media.capture.isEmpty ? 0 : 22) + (problem == nil ? 0 : 22)
    }

    private func toggleMute() { model.toggleMuted(tabIDs) }

    /// The tab's state for VoiceOver: the sidebar row's, and pinned.
    private var stateDescription: String {
        let state = TabRow.stateDescription(isLoading: model.isTabLoading(tab.id), isDimmed: isDimmed,
                                            isAwayFromHome: tab.hasLeftHome, media: media, problem: problem)
        return [tab.isPinned ? "Pinned" : nil, state.isEmpty ? nil : state].compactMap(\.self).joined(separator: ", ")
    }

    /// Moves the tab one place along the bar, as the sidebar's Move Up and Move Down do.
    private func move(by offset: Int) {
        model.selectSidebarItem(.tab(tab.id))
        Task { await model.moveSelectedItem(by: offset) }
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: style == .regular ? 8 : 6)
        if isSelected {
            // Raised, as the board's selected tab: the page's surface with a small shadow.
            shape.fill(.background).shadow(color: .black.opacity(0.18), radius: 1, y: 1)
        } else if style == .regular {
            shape.fill(.primary.opacity(0.1))
                .overlay { shape.strokeBorder(.primary.opacity(0.26), lineWidth: 0.5) }
        } else {
            shape.fill(.clear)
        }
    }

    private func close() {
        Task { await model.closeTab(tab.id, byPerson: true) }
    }
}

/// A tab's 15 pt icon, or a globe without one.
private struct TabIcon: View {
    let image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 15, height: 15)
                    .clipShape(.rect(cornerRadius: 4))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
    }
}
#endif
