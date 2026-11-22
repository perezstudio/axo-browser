#if os(iOS)
import AxoCore
import AxoWeb
import SwiftUI

/// The browser on iPhone and iPad.
///
/// On iPhone (compact width) the first screen is the tabs view (#182): the Space's favorites,
/// pinned tabs, and today's tabs as cards, each opening its page with a zoom; the page has the
/// iPhone's bar (#181). On iPad a sidebar lists the Space's tabs beside the page, like the Mac,
/// with the address bar at the top. New tabs start in the command bar, as on the Mac.
/// Everything else comes from the shared ``BrowserModel``.
public struct MobileBrowserView: View {
    @Bindable private var model: BrowserModel
    /// On iPad, whether the tab list or the page is showing in compact width (split screen).
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    /// The cards' zoom source (#182), shared with the page they open.
    @Namespace private var cards
    /// The tab whose page showed last, outlined in the tabs view.
    @State private var lastShownTabID: AxoCore.Tab.ID?
    @AppStorage(MobileAddressBarPlacement.storageKey) private var barPlacement: MobileAddressBarPlacement = .bottom

    /// Creates the browser showing `model`.
    public init(model: BrowserModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            // By device, not width: a Max iPhone turned sideways is regular width, and an iPad in
            // split screen compact, and neither should swap layouts mid-use.
            if UIDevice.current.userInterfaceIdiom == .phone {
                // iPhone (#182): the tabs view, and the page zooming up out of its card.
                NavigationStack {
                    MobileTabsView(model: model, namespace: cards, highlighted: lastShownTabID)
                        .navigationDestination(item: Binding(
                            get: { model.selectedTabID },
                            set: { if $0 == nil { model.select(nil) } }
                        )) { id in
                            MobilePage(model: model, showTabs: { model.select(nil) })
                                .modifier(ZoomFromCard(id: id, namespace: cards))
                                .navigationBarBackButtonHidden()
                        }
                }
            } else {
                NavigationSplitView(preferredCompactColumn: $compactColumn) {
                    MobileSidebar(model: model)
                } detail: {
                    MobilePage(model: model, showTabs: {
                        compactColumn = .sidebar
                        model.select(nil)
                    })
                }
                .onChange(of: model.selectedTabID) {
                    if model.selectedTabID != nil { compactColumn = .detail }
                }
            }
        }
        .onChange(of: model.selectedTabID) {
            if let id = model.selectedTabID { lastShownTabID = id }
        }
        .overlay {
            if model.isCommandBarVisible {
                // On iPhone with the bar at the bottom it rises from there, with the keyboard (#182).
                CommandBarView(model: model, risesFromBottom: UIDevice.current.userInterfaceIdiom == .phone && barPlacement == .bottom)
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

/// The page zooming up out of its card and back into it (#182), or the system's push with
/// Reduce Motion.
struct ZoomFromCard: ViewModifier {
    let id: AxoCore.Tab.ID
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
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
            ToolbarItem(placement: .topBarLeading) { MobileSpacesMenu(model: model) }
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
    /// The iPhone's bar (#181) on iPhone in any orientation; the iPad's bar on iPad.
    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    @AppStorage(MobileAddressBarPlacement.storageKey) private var barPlacement: MobileAddressBarPlacement = .bottom

    var body: some View {
        Group {
            if let tab = model.shownTab, let space = model.space {
                WebViewHost(tab: tab, profileID: space.profileID, pool: model.pool)
                    // Under the status bar with the bar at the bottom, but never under the find bar.
                    .ignoresSafeArea(edges: isPhone && barPlacement == .bottom && !model.isFindBarVisible ? .top : [])
                    .accessibilityIdentifier("webContent")
                    .pageProblem(for: tab.id, model: model)
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if isPhone {
                if barPlacement == .top { MobileBar(model: model, placement: .top, showTabs: showTabs) }
            } else {
                MobileAddressBar(model: model, showTabs: nil)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isPhone, barPlacement == .bottom {
                MobileBar(model: model, placement: .bottom, showTabs: showTabs)
            }
        }
        // Notices (Link copied, a closed tab with Undo) just above the page's bottom edge.
        .overlay(alignment: .bottom) { MobileNoticeView(model: model) }
        // Find on Page, from the iPhone's menu, above the page.
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.isFindBarVisible { FindBar(model: model) }
        }
        .sheet(isPresented: Binding(get: { model.isShowingSiteSettings }, set: { model.isShowingSiteSettings = $0 })) {
            NavigationStack {
                ScrollView { SiteSettingsView(model: model) }
                    .navigationTitle("Site Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { model.isShowingSiteSettings = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isPhone ? .hidden : .automatic, for: .navigationBar)
    }
}

/// The iPhone's bar (#181), as the iPhone board draws it: the ••• menu, the address with the
/// Space's dots under it, and the tabs button, at the bottom near the thumb or at the top, with
/// the page's loading line in the Space's tint along its edge nearest the page.
struct MobileBar: View {
    let model: BrowserModel
    let placement: MobileAddressBarPlacement
    let showTabs: () -> Void
    @AppStorage(MobileAddressBarPlacement.storageKey) private var storedPlacement: MobileAddressBarPlacement = .bottom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How far the bar is being dragged sideways, toward the next or previous Space (#182).
    @State private var swipe: CGFloat = 0

    /// Whether scrolling has shrunk the bar to its pill (#182).
    private var isCompact: Bool { model.selectedPage?.prefersCompactChrome == true }

    var body: some View {
        VStack(spacing: 0) {
            if placement == .bottom { loadingLine }
            Group {
                if isCompact {
                    compactPill
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    HStack(spacing: 10) {
                        menu
                        address
                        Button("Tabs", systemImage: "square.on.square", action: showTabs)
                            .labelStyle(.iconOnly)
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .accessibilityIdentifier("showTabsButton")
                    }
                    .offset(x: reduceMotion ? 0 : swipe)
                    .gesture(spaceSwipe)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, isCompact ? 2 : 6)
            if placement == .top { loadingLine }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15), value: isCompact)
    }

    /// The shrunk bar: the site alone, small; a tap brings the whole bar back.
    private var compactPill: some View {
        Button {
            model.expandChrome()
        } label: {
            Text(model.mobileAddressText ?? "Search or enter address")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 26)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("Address")
        .accessibilityValue(model.shownPageURL?.absoluteString ?? "")
        .accessibilityHint("Shows the browser's controls")
        .accessibilityIdentifier("compactAddressBar")
    }

    /// Dragging the bar sideways past a third of its width goes to the next or previous Space
    /// (#182), as the iPhone board draws it; a shorter drag springs back.
    private var spaceSwipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height), model.spaces.count > 1 else { return }
                swipe = value.translation.width
            }
            .onEnded { value in
                let distance = value.translation.width
                withAnimation(reduceMotion ? nil : .spring(duration: 0.3)) { swipe = 0 }
                guard abs(distance) > 110, abs(distance) > abs(value.translation.height) else { return }
                Task { await model.selectAdjacentSpace(by: distance < 0 ? 1 : -1) }
            }
    }

    /// A thin line in the Space's tint while the page loads.
    @ViewBuilder
    private var loadingLine: some View {
        if let page = model.selectedPage, page.isLoading {
            ProgressView(value: page.estimatedProgress)
                .progressViewStyle(.linear)
                .tint(model.space?.markerColor ?? .accentColor)
                .padding(.horizontal, 24)
                .accessibilityLabel("Loading")
        }
    }

    /// The ••• menu, which grows from the button, nearest first (iOS keeps a menu's first items
    /// nearest the button it opens from).
    private var menu: some View {
        Menu {
            let groups = model.mobileMenu(placement: storedPlacement)
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index == 0 {
                    // Back, Forward, Reload, and Share: one row, nearest the thumb.
                    ControlGroup {
                        ForEach(group, id: \.item) { entry in item(entry) }
                    }
                    // A row of icons, which fits all four (the default style fits three).
                    .controlGroupStyle(.palette)
                } else {
                    Section {
                        ForEach(group, id: \.item) { entry in item(entry) }
                    }
                }
            }
        } label: {
            Label("Menu", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Menu")
        .accessibilityIdentifier("pageMenuButton")
    }

    @ViewBuilder
    private func item(_ entry: MobileMenuEntry) -> some View {
        switch entry.item {
        case .share:
            if let url = model.shownPageURL, entry.isEnabled {
                ShareLink(item: url) { Label(entry.item.title, systemImage: entry.item.systemImage) }
                    .accessibilityIdentifier("menuShare")
            } else {
                Button(entry.item.title, systemImage: entry.item.systemImage) {}
                    .disabled(true)
            }
        case .addressBarPlacement(let placement):
            Button(entry.item.title, systemImage: entry.item.systemImage) { storedPlacement = placement }
                .accessibilityIdentifier("menuAddressBarPlacement")
        default:
            Button(entry.item.title, systemImage: entry.item.systemImage) { model.performMobileMenu(entry.item) }
                .disabled(!entry.isEnabled)
        }
    }

    /// The site, with a lock for a secure page, and the Space's dots under it; a tap edits the
    /// address in the command bar.
    private var address: some View {
        Button {
            if model.shownTab != nil { model.editAddress() } else { model.beginNewTab() }
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    if model.connectionIndicator == .secure {
                        Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text(model.mobileAddressText ?? "Search or enter address")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(model.mobileAddressText == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if model.spaces.count > 1 {
                    HStack(spacing: 5) {
                        ForEach(model.spaces) { space in
                            Circle()
                                .frame(width: 5, height: 5)
                                .opacity(space.id == model.space?.id ? 1 : 0.4)
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("Address")
        .accessibilityValue(spaceValue + (model.connectionIndicator?.addressPrefix ?? "") + (model.shownPageURL?.absoluteString ?? "No page"))
        .accessibilityHint("Edits the address. Swipe up or down to change Spaces.")
        // VoiceOver's swipe up and down change Spaces, as dragging the bar sideways does.
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: Task { await model.selectAdjacentSpace(by: 1) }
            case .decrement: Task { await model.selectAdjacentSpace(by: -1) }
            @unknown default: break
            }
        }
        .accessibilityIdentifier("mobileAddressBar")
    }

    /// Which Space shows, for VoiceOver, when there's more than one.
    private var spaceValue: String {
        guard model.spaces.count > 1, let space = model.space,
              let index = model.spaces.firstIndex(where: { $0.id == space.id }) else { return "" }
        return "\(space.name), Space \(index + 1) of \(model.spaces.count), "
    }
}

/// A brief notice over the page's bottom edge, with Undo (or its action) when it has one, as the
/// Mac's notice shows them.
struct MobileNoticeView: View {
    let model: BrowserModel

    var body: some View {
        if let notice = model.notice {
            HStack(spacing: 12) {
                Text(notice.message).font(.subheadline).lineLimit(2)
                if notice.undo != nil {
                    Button(notice.actionTitle) { Task { await model.undoNotice() } }
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("noticeUndoButton")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 8)
            .transition(.opacity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("notice")
        }
    }
}

/// Back, forward, the address field, and reload (iPad, until its own layouts, #183).
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
