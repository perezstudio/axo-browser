import AxoCore
import AxoWeb
import SwiftUI

// Mac only for now; iPhone and iPad have their own chrome.
#if os(macOS)
/// The root view of a browser window: the sidebar on the left and web content on the right.
public struct BrowserWindow: View {
    @Bindable private var model: BrowserModel
    @AppStorage(NavigationBarPlacement.storageKey) private var navigationBarPlacement = NavigationBarPlacement.sidebar
    @AppStorage(AddressBarSettings.showsSidebarAddressBarKey) private var showsSidebarAddressBar = true
    @AppStorage(AddressEditingPlacement.storageKey) private var addressEditingPlacement = AddressEditingPlacement.commandBar
    /// The split view's columns; the top row's Hide Sidebar sets them.
    @State private var columns = NavigationSplitViewVisibility.automatic
    /// Whether the sidebar is collapsed, however it got there (Hide Sidebar, View › Toggle
    /// Sidebar, the divider, a narrow window, or a collapsed sidebar AppKit restored), read from
    /// the split view itself (`SidebarCollapseObserver`), since the binding starts `.automatic`.
    @State private var isSidebarCollapsed = false
    /// Whether the window is in full screen, where the toolbar comes back: the title bar's area
    /// isn't there to hold the sidebar's top row.
    @State private var isWindowFullScreen = false
    /// The split view's controller, which Hide Sidebar collapses as View › Toggle Sidebar does.
    @State private var splitController: WeakSplitController = WeakSplitController()
    /// Whether the hidden sidebar floats over the page (#67), from the pointer reaching the
    /// window's left edge until it leaves the card.
    @State private var isSidebarFloating = false
    /// Whether the pointer is over the floating sidebar.
    @State private var isPointerOverFloatingSidebar = false
    /// The wait that lets the floating sidebar go, replaced by each newer one.
    @State private var floatingSidebarRelease: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether the window has no toolbar (#67): with the navigation bar in the sidebar and its
    /// address bar shown, outside full screen (where the title bar's area isn't there). The page
    /// reaches the window's top edge and the page's tools are in the sidebar. With the sidebar's
    /// address bar hidden, or in full screen, the toolbar comes back with the page's tools.
    /// Above the page (#170), the page's control bar stands in for the toolbar, always.
    private var hidesToolbar: Bool {
        guard !isWindowFullScreen else { return false }
        switch navigationBarPlacement {
        case .sidebar: return showsSidebarAddressBar
        case .page: return true
        }
    }

    /// Whether the page's control bar sits at the top of the page's area (#170): above the page,
    /// while the window has no toolbar.
    private var showsControlBar: Bool {
        hidesToolbar && navigationBarPlacement == .page
    }

    /// Shows the sidebar again, as View › Show Sidebar does.
    private func showSidebar() {
        dismissFloatingSidebar()
        if let controller = splitController.controller {
            controller.toggleSidebar(nil)
        } else {
            withAnimation { columns = .all }
        }
        // The button clicked (the floating card's, which goes) held keyboard focus: the page
        // takes it, so View › Toggle Sidebar (⌃⌘S) still finds the split view in the responder
        // chain rather than nothing.
        model.focusPage()
    }

    /// Whether the sidebar's top row stands in for the window toolbar: while the sidebar shows.
    private var sidebarReplacesToolbar: Bool {
        hidesToolbar && !isSidebarCollapsed
    }

    /// Whether the hidden sidebar floats in from the window's left edge, as on the board, while
    /// the page fills the window.
    private var floatsSidebar: Bool {
        hidesToolbar && isSidebarCollapsed
    }

    /// Creates a window showing `model`.
    public init(model: BrowserModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            // Puts the window in full screen while a page fills it.
            PageFullscreenWindow(isFullscreen: model.fullscreenTabID != nil) { model.exitPageFullscreen() }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            // A page filling the screen (element.requestFullscreen()) shows alone, in place of the
            // split view, so the sidebar's own state is left alone.
            if model.fullscreenTabID != nil, let tab = model.shownTab, let space = model.space {
                ZStack { WebViewHost(tab: tab, profileID: space.profileID, pool: model.pool).linkStatus(for: model.selectedPage) }
                    .ignoresSafeArea()
                    .toolbar(.hidden, for: .windowToolbar)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("fullscreenPage")
            } else {
                splitView
                    // Nothing behind first run's card takes clicks, keys, or focus.
                    .disabled(model.firstRun != nil)
                    .accessibilityHidden(model.firstRun != nil)
            }
            // First run (#175), over the whole window until it's done.
            if let firstRun = model.firstRun {
                FirstRunView(model: model, firstRun: firstRun)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: model.firstRun == nil)
        // While first run shows, the toolbar hides and the menus' commands (which need the
        // window's model) are off, so nothing acts on the window behind the card.
        .toolbar(model.firstRun != nil || hidesToolbar ? .hidden : .automatic, for: .windowToolbar)
        .focusedSceneValue(\.browserModel, model.firstRun == nil ? model : nil)
        // ⌘L: with the navigation bar in the sidebar, the address is edited in the command bar,
        // as in Arc (also when the sidebar's address bar is hidden); above the page, its field
        // takes focus itself.
        .onChange(of: model.addressFocusRequest) {
            if navigationBarPlacement == .sidebar { model.editAddress() }
        }
        // View › Show or Hide Address Bar in Sidebar, kept in the window's settings store.
        .onChange(of: model.sidebarAddressBarRequest.count) { showsSidebarAddressBar = model.sidebarAddressBarRequest.shown }
        // A change of the binding (Hide Sidebar, or SwiftUI's own) counts too, in case the split
        // view's item reports later.
        .onChange(of: columns) { if columns == .detailOnly { isSidebarCollapsed = true } }
        .onChange(of: showsSidebarAddressBar, initial: true) { model.isSidebarAddressBarShown = showsSidebarAddressBar }
        .onChange(of: addressEditingPlacement, initial: true) { model.editsAddressInSidebar = addressEditingPlacement == .sidebar }
        // The Space theme editor from the Spaces menu (#137), outside the sidebar so it has the
        // window's appearance, not the theme's.
        .sheet(isPresented: Binding(
            get: { model.themeEditing.map { $0.isOpen && $0.placement == .window } ?? false },
            set: { if !$0, model.themeEditing?.placement == .window { model.closeThemeEditor(save: false) } }
        )) {
            SpaceThemeEditor(model: model)
        }
        .modifier(HandoffActivity(model: model))
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

    private var splitView: some View {
        splitViewColumns
            // The floating sidebar goes once the sidebar is back in the window, and once nothing
            // it opened is showing while the pointer is elsewhere.
            .onChange(of: floatsSidebar) {
                if !floatsSidebar {
                    dismissFloatingSidebar()
                }
            }
            // Something the sidebar shows, opened from a menu (View › Show Downloads, Site
            // Settings) while the sidebar is hidden, brings the card in to show it.
            .onChange(of: FloatingSidebar.isHolding(model)) {
                // Above the page, the control bar shows Downloads, Site Settings, and the summary
                // itself; the card isn't brought in there.
                if FloatingSidebar.isHolding(model), floatsSidebar, navigationBarPlacement == .sidebar {
                    isSidebarFloating = true
                } else {
                    letFloatingSidebarGo()
                }
            }
            .onChange(of: model.fullscreenTabID) { dismissFloatingSidebar() }
            .onChange(of: isSidebarFloating) { model.isFloatingSidebarShown = isSidebarFloating }
    }

    private var splitViewColumns: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(model: model)
                // The top row sits in the title bar's area above the sidebar's content, which
                // keeps the safe area (SwiftUI's hover tracking went wrong in a sidebar that
                // ignored it). Its empty space below takes no hits.
                .overlay(alignment: .top) {
                    if sidebarReplacesToolbar {
                        VStack(spacing: 0) {
                            SidebarTopRow(model: model, showsNavigation: navigationBarPlacement == .sidebar) {
                                // As View › Toggle Sidebar does, so the split view's own state
                                // decides; the binding may be stale after AppKit showed it.
                                if let controller = splitController.controller {
                                    controller.toggleSidebar(nil)
                                } else {
                                    withAnimation { columns = .detailOnly }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .ignoresSafeArea(.container, edges: .top)
                    }
                }
                // The footer's Downloads and the address bar's extensions and summary are the
                // page's tools only while the toolbar is gone.
                .environment(\.pageToolsInSidebar, sidebarReplacesToolbar && navigationBarPlacement == .sidebar)
                // The page's edge, a layer above the sidebar (#67), in the theme's appearance,
                // from the window's top while no toolbar runs across it.
                .pageEdgeShadow(reachesTop: sidebarReplacesToolbar)
                // The shown Space's theme behind the sidebar, its footer, and the toolbar above it.
                .modifier(SpaceThemeModifier(model: model))
                .navigationSplitViewColumnWidth(
                    min: navigationBarPlacement == .sidebar ? SidebarTopRow.minimumSidebarWidth : 180,
                    ideal: navigationBarPlacement == .sidebar ? SidebarTopRow.minimumSidebarWidth : 240,
                    max: 400
                )
        } detail: {
            pageColumn
        }
    }

    /// The page column: the page, its bars, and what floats over it.
    private var pageColumn: some View {
        HStack(spacing: 0) {
            content
            if let panel = model.extensionSidePanel {
                Divider()
                ExtensionSidePanelView(model: model, panel: panel)
            }
        }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let translation = model.selectedTranslation {
                    TranslationBar(model: model, translation: translation)
                }
            }
            // Above the page, its control bar, over the translation bar (#170).
            .safeAreaInset(edge: .top, spacing: 0) {
                if showsControlBar {
                    ControlBar(model: model, isSidebarHidden: isSidebarCollapsed) { showSidebar() }
                }
            }
            // With no toolbar above it, the page reaches the window's top edge (#67). After
            // the translation bar's inset, so the page sits below the bar rather than under it.
            // With the sidebar hidden the page is a card on the Space's theme (#67), inset so
            // the margin around it moves the window, as the board draws it.
            .modifier(PageCard(isCard: floatsSidebar))
            .ignoresSafeArea(.container, edges: hidesToolbar ? .top : [])
            .modifier(PageCardMargin(model: model, isCard: floatsSidebar))
            // The hidden sidebar floats in from the window's left edge (#67).
            .overlay(alignment: .leading) {
                if floatsSidebar { floatingSidebar }
            }
            .background {
                SidebarCollapseObserver(
                    onChange: { isSidebarCollapsed = $0 },
                    onFullScreenChange: { isWindowFullScreen = $0 },
                    onController: { splitController.controller = $0 }
                )
                    .accessibilityHidden(true)
            }
            // In the page column: an overlay on the split view itself couldn't take focus.
            .overlay {
                if let peek = model.peek, let space = model.space {
                    PeekOverlay(model: model, peek: peek, profileID: space.profileID)
                }
            }
            .overlay {
                // An address edited in the sidebar shows its results there instead.
                if model.isCommandBarVisible, !model.isAddressEditedInSidebar {
                    CommandBarView(model: model)
                }
            }
            // Notices for actions with no other visible result, at the page's bottom.
            .overlay(alignment: .bottom) { NoticeView(model: model) }
            .modifier(PageTranslationTask(model: model))
            // Site Settings hangs from the sidebar's address bar; when that isn't on screen
            // (hidden, or the sidebar collapsed), from the top of the page instead.
            .overlay(alignment: .top) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
                    .popover(isPresented: Binding(
                        get: { navigationBarPlacement == .sidebar && !model.isSidebarAddressBarOnScreen && model.isShowingSiteSettings },
                        set: { model.isShowingSiteSettings = $0 }
                    ), arrowEdge: .top) {
                        SiteSettingsView(model: model)
                    }
            }
            // So does a page's summary, which has no button while the sidebar shows (#67):
            // View › Summarize Page and the command bar ask for it.
            .overlay(alignment: .top) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
                    .popover(isPresented: Binding(
                        get: { hidesToolbar && navigationBarPlacement == .sidebar && !model.isSidebarAddressBarOnScreen && model.isShowingSummary },
                        set: { model.isShowingSummary = $0 }
                    ), arrowEdge: .top) {
                        PageSummaryView(state: model.pageSummary ?? .loading)
                    }
            }
            .toolbar {
                NavigationToolbar(model: model, placement: navigationBarPlacement,
                                  showsPageTools: !hidesToolbar)
            }
            // The address field already shows where you are.
            .toolbar(removing: .title)
            // Above the page, the toolbar takes the page's color, as in Safari.
            .modifier(PageToolbarTint(page: model.selectedPage, pool: model.pool, placement: navigationBarPlacement))
    }

    /// The left edge's hover strip and, once the pointer reaches it, the floating sidebar.
    private var floatingSidebar: some View {
        ZStack(alignment: .leading) {
            EdgeHoverDetector { isOver in
                if isOver {
                    floatingSidebarRelease?.cancel()
                    isSidebarFloating = true
                } else {
                    // The pointer passing over the edge on its way out of the window.
                    letFloatingSidebarGo()
                }
            }
            .frame(width: 6)
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
            if isSidebarFloating {
                FloatingSidebar(model: model, showsNavigation: navigationBarPlacement == .sidebar) {
                    showSidebar()
                } onHover: { isOver in
                    isPointerOverFloatingSidebar = isOver
                    if isOver { floatingSidebarRelease?.cancel() } else { letFloatingSidebarGo() }
                }
                .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.26), value: isSidebarFloating)
    }

    /// Lets the floating sidebar go a moment after the pointer leaves it, and only once the
    /// pointer stays away and nothing it shows is open: its popovers and sheets, an extension's
    /// popup, or a menu.
    private func letFloatingSidebarGo() {
        guard isSidebarFloating else { return }
        floatingSidebarRelease?.cancel()
        floatingSidebarRelease = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, !isPointerOverFloatingSidebar else { return }
                let window = splitController.controller?.view.window
                if FloatingSidebar.isHolding(model) || FloatingSidebar.isHolding(window) || Self.isMenuOpen { continue }
                isSidebarFloating = false
                return
            }
        }
    }

    /// Whether a menu (a context menu from the floating sidebar, the menu bar's) is open: the
    /// main run loop runs in its event-tracking mode while one is. Read when needed rather than
    /// followed in state, since a redraw of the window while a menu is open rebuilt the menu
    /// bar's menus and closed it.
    private static var isMenuOpen: Bool {
        RunLoop.main.currentMode == .eventTracking
    }

    /// Takes the floating sidebar away at once, forgetting where the pointer was: a removed
    /// view never hears the pointer leave.
    private func dismissFloatingSidebar() {
        floatingSidebarRelease?.cancel()
        isSidebarFloating = false
        isPointerOverFloatingSidebar = false
    }

    @ViewBuilder
    private var content: some View {
        if let split = model.selectedSplit, let space = model.space {
            SplitPanesView(model: model, split: split, panes: model.panes(of: split.id), profileID: space.profileID)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if model.isFindBarVisible { FindBar(model: model) }
                }
        } else if let tab = model.shownTab, let space = model.space {
            WebViewHost(tab: tab, profileID: space.profileID, pool: model.pool)
                .accessibilityIdentifier("webContent")
                .safeAreaInset(edge: .top, spacing: 0) {
                    if model.isFindBarVisible { FindBar(model: model) }
                }
                .linkStatus(for: model.arePagesCovered ? nil : model.selectedPage)
                .overlay(alignment: .top) { RestoringSnapshot(page: model.selectedPage) }
                .overlay(alignment: .top) { if model.showsPageLoadingBar { LoadingBar(page: model.selectedPage) } }
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
}

/// A split view's panes, side by side or stacked, with resizable dividers. The focused pane has
/// an accent outline; clicking a pane focuses it.
private struct SplitPanesView: View {
    let model: BrowserModel
    let split: TabSplit
    let panes: [AxoCore.Tab]
    let profileID: Profile.ID

    var body: some View {
        Group {
            if split.orientation == .horizontal {
                HSplitView { paneViews }
            } else {
                VSplitView { paneViews }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split view")
        .accessibilityIdentifier("splitView")
    }

    private var paneViews: some View {
        ForEach(Array(panes.enumerated()), id: \.element.id) { index, tab in
            let page = model.pool.state(for: tab.id)
            WebViewHost(tab: tab, profileID: profileID, pool: model.pool)
                .frame(minWidth: 200, minHeight: 150)
                .linkStatus(for: model.arePagesCovered ? nil : page)
                .overlay(alignment: .top) { RestoringSnapshot(page: page) }
                // The focused pane's loading shows in the sidebar's address bar instead, when
                // that's where the address is edited.
                .overlay(alignment: .top) {
                    if tab.id != model.selectedTabID || model.showsPageLoadingBar { LoadingBar(page: page) }
                }
                .overlay {
                    if tab.id == model.selectedTabID {
                        Rectangle()
                            .strokeBorder(.tint, lineWidth: 2)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Pane \(index + 1) of \(panes.count), \(TabRow.displayTitle(for: tab))")
                .accessibilityAddTraits(tab.id == model.selectedTabID ? .isSelected : [])
                .accessibilityIdentifier("splitPane")
        }
    }
}

/// The picture of a page taken when its tab hibernated, shown until the page reloads, so waking
/// a tab feels instant.
private struct RestoringSnapshot: View {
    let page: WebTabState?

    var body: some View {
        if let snapshot = page?.restoringSnapshot {
            Image(platformImage: snapshot)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(.background)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
        }
    }
}

/// A thin progress bar along the top of the page while it loads.
private struct LoadingBar: View {
    let page: WebTabState?

    var body: some View {
        if let page, page.isLoading {
            ProgressView(value: page.estimatedProgress)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .accessibilityLabel("Loading")
        }
    }
}

#Preview {
    BrowserWindow(model: BrowserModel(
        store: try! TabStore.makeInMemory(),
        pool: WebViewPool(makeDataStore: { _ in .nonPersistent() })
    ))
}

/// A weak reference to the window's split view controller, kept in state without redrawing.
final class WeakSplitController {
    weak var controller: NSSplitViewController?
}
#endif
