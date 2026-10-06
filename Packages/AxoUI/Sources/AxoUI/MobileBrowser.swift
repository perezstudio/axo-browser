#if os(iOS)
import AxoCore
import AxoWeb
import SwiftUI

/// The browser on iPhone and iPad.
///
/// A sidebar lists the Space's pinned tabs (with folders) and open tabs, with a menu to switch
/// Spaces. On iPad it sits beside the page, like the Mac; on iPhone it's the first screen, and
/// choosing a tab shows its page. The page has an address bar (at the bottom on iPhone, at the
/// top on iPad) with back, forward, and reload. New tabs start in the command bar, as on the
/// Mac. Everything else comes from the shared ``BrowserModel``.
public struct MobileBrowserView: View {
    @Bindable private var model: BrowserModel
    /// On iPhone, whether the tab list or the page is showing.
    @State private var compactColumn = NavigationSplitViewColumn.sidebar

    /// Creates the browser showing `model`.
    public init(model: BrowserModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            MobileSidebar(model: model)
        } detail: {
            MobilePage(model: model, showTabs: {
                // In compact width the list's selection keeps the page pushed, so going back to
                // the list clears it. The tab stays open, and choosing it shows it again.
                compactColumn = .sidebar
                model.select(nil)
            })
        }
        // Choosing or opening a tab shows its page on iPhone.
        .onChange(of: model.selectedTabID) {
            if model.selectedTabID != nil { compactColumn = .detail }
        }
        .overlay {
            if model.isCommandBarVisible {
                CommandBarView(model: model)
            }
        }
        .pagePrompts(model: model)
        .task { await model.start() }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            ),
            presenting: model.alertMessage
        ) { _ in
            Button("OK") { model.alertMessage = nil }
        } message: { message in
            Text(message)
        }
    }
}

/// The Space's pinned tabs and open tabs, with Space switching and New Tab.
struct MobileSidebar: View {
    let model: BrowserModel

    var body: some View {
        List(selection: Binding(get: { model.selectedTabID }, set: { model.select($0) })) {
            if !model.favorites.isEmpty, let space = model.space {
                Section("Favorites") {
                    ForEach(model.favorites) { favorite in
                        TabRow(tab: favorite.tab(in: space.id), favicon: model.favicon(for: favorite.tab(in: space.id)))
                            .tag(favorite.id)
                            .swipeActions {
                                Button("Remove", systemImage: "star.slash", role: .destructive) {
                                    Task { await model.removeFavorite(favorite.id) }
                                }
                            }
                    }
                }
            }
            if !model.pinnedTree.isEmpty {
                Section("Pinned") {
                    MobilePinnedLevel(model: model, nodes: model.pinnedTree)
                }
            }
            Section("Tabs") {
                ForEach(model.unpinnedTabs) { tab in
                    TabRow(tab: tab, favicon: model.favicon(for: tab))
                        .tag(tab.id)
                        .swipeActions {
                            Button("Close", systemImage: "xmark", role: .destructive) {
                                Task { await model.closeTab(tab.id) }
                            }
                        }
                }
                Button("New Tab", systemImage: "plus") { model.beginNewTab() }
                    .accessibilityIdentifier("sidebarNewTabButton")
            }
        }
        .navigationTitle(model.space?.name ?? "Axo")
        .accessibilityIdentifier("sidebar")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(model.spaces) { space in
                        Button {
                            Task { await model.selectSpace(space.id) }
                        } label: {
                            if space.id == model.space?.id {
                                Label(space.name, systemImage: "checkmark")
                            } else {
                                Text(space.name)
                            }
                        }
                    }
                } label: {
                    Label("Spaces", systemImage: "square.stack")
                }
                .accessibilityIdentifier("spacesMenu")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New Tab", systemImage: "plus") { model.beginNewTab() }
                    .accessibilityIdentifier("newTabButton")
            }
        }
    }
}

/// One level of the pinned section: folders (expandable) and pinned tabs.
struct MobilePinnedLevel: View {
    let model: BrowserModel
    let nodes: [PinnedNode]

    var body: some View {
        ForEach(nodes) { node in
            switch node {
            case .tab(let tab):
                TabRow(tab: tab, favicon: model.favicon(for: tab))
                    .tag(tab.id)
            case .folder(let folder, let children):
                DisclosureGroup {
                    MobilePinnedLevel(model: model, nodes: children)
                } label: {
                    Label(folder.name, systemImage: "folder")
                        .accessibilityIdentifier("folderRow")
                }
            }
        }
    }
}

/// The selected tab's page with its address bar, or an empty state.
struct MobilePage: View {
    let model: BrowserModel
    /// Shows the tab list (iPhone).
    let showTabs: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if let tab = model.shownTab, let space = model.space {
                WebViewHost(tab: tab, profileID: space.profileID, pool: model.pool)
                    .ignoresSafeArea(edges: sizeClass == .compact ? .top : [])
                    .accessibilityIdentifier("webContent")
            } else {
                ContentUnavailableView {
                    Label("No Tab Open", systemImage: "safari")
                } description: {
                    Text("Open a tab to start browsing.")
                } actions: {
                    Button("New Tab") { model.beginNewTab() }
                        .accessibilityIdentifier("emptyStateNewTabButton")
                }
                .accessibilityIdentifier("emptyState")
            }
        }
        .safeAreaInset(edge: sizeClass == .compact ? .bottom : .top, spacing: 0) {
            MobileAddressBar(model: model, showTabs: sizeClass == .compact ? showTabs : nil)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(sizeClass == .compact ? .hidden : .automatic, for: .navigationBar)
    }
}

/// Back, forward, the address field, and reload.
struct MobileAddressBar: View {
    let model: BrowserModel
    /// Shows the tab list, on iPhone, where the list and the page take turns.
    let showTabs: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if let progress = model.selectedPage?.estimatedProgress, model.selectedPage?.isLoading == true {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Loading")
            }
            HStack(spacing: 12) {
                Button("Back", systemImage: "chevron.backward") { model.goBack() }
                    .disabled(model.selectedPage?.canGoBack != true)
                    .accessibilityIdentifier("backButton")
                Button("Forward", systemImage: "chevron.forward") { model.goForward() }
                    .disabled(model.selectedPage?.canGoForward != true)
                    .accessibilityIdentifier("forwardButton")
                AddressField(model: model)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                let isLoading = model.selectedPage?.isLoading == true
                Button(isLoading ? "Stop" : "Reload", systemImage: isLoading ? "xmark" : "arrow.clockwise") {
                    model.reloadOrStop()
                }
                .disabled(model.selectedTabID == nil)
                .accessibilityIdentifier("reloadButton")
                if let showTabs {
                    Button("Tabs", systemImage: "square.on.square", action: showTabs)
                        .accessibilityIdentifier("showTabsButton")
                }
            }
            .labelStyle(.iconOnly)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}
#endif
