import AppKit
import AxoCore
import AxoWeb
import Foundation
import Observation
import os
import SwiftUI

/// The state behind a browser window: the current Space, its tabs, and the selected tab.
///
/// The model connects the persisted sidebar (``TabStore``) to live web views (``WebViewPool``):
/// it asks the pool for the selected tab's web view and saves page changes the pool reports.
@Observable
public final class BrowserModel {
    /// Every Space, in switcher order.
    public private(set) var spaces: [Space] = []
    /// The Space shown in the sidebar, once ``start()`` finishes.
    public private(set) var space: Space?
    /// The Space's tabs in sidebar order, kept current as the database changes.
    public private(set) var tabs: [AxoCore.Tab] = []
    /// The Space's folders, kept current as the database changes.
    public private(set) var folders: [Folder] = []
    /// The Space's split views, kept current as the database changes.
    public internal(set) var splits: [TabSplit] = []
    /// The page open in Peek, a temporary card over the current tab, if any.
    public internal(set) var peek: Peek?
    /// Pages open in mini windows (links from other apps), oldest first.
    public internal(set) var miniWindows: [MiniWindow] = []
    /// Shows a mini window on screen. The default makes an AppKit window; tests record instead.
    @ObservationIgnored public var presentMiniWindow: ((MiniWindow) -> Void)?
    /// Brings the browser window forward, reopening it if it was closed, so a tab added from
    /// outside it (a routed link, Open in Axo) is on screen. Set by the app.
    @ObservationIgnored public var showBrowserWindow: (() -> Void)?
    /// Closes a mini window's AppKit window after its page moved to a tab.
    @ObservationIgnored public var dismissMiniWindow: ((MiniWindow.ID) -> Void)?
    /// The tab the next command bar choice joins in a split view (Add Split View).
    public internal(set) var pendingSplitAnchor: AxoCore.Tab.ID?
    /// A name the sidebar should ask for, such as a new folder's.
    public var namingRequest: NamingRequest?
    /// The tab shown in the window.
    public private(set) var selectedTabID: AxoCore.Tab.ID?
    /// The folder selected in the sidebar, if a folder row is selected instead of a tab. The
    /// selected tab keeps showing.
    public internal(set) var selectedFolderID: Folder.ID?
    /// A Space waiting to be renamed, which shows the Rename Space sheet.
    public var spaceToRename: Space?
    /// A Space waiting for the person to confirm deleting it.
    public var spaceToDelete: Space?
    /// The live state of the selected tab's web view.
    public private(set) var selectedPage: WebTabState?
    /// Incremented to ask the address field to take focus.
    public private(set) var addressFocusRequest = 0
    /// A problem worth telling the user about, such as the database failing to open.
    public var alertMessage: String?
    /// Whether the downloads list is open.
    public var isShowingDownloads = false
    /// Whether the archived tabs list is open.
    public var isShowingArchive = false
    /// Whether the New Space sheet is open.
    public var isCreatingSpace = false
    /// Whether Axo is the default browser, as of the last check. `nil` when there's no way to
    /// check (no ``defaultBrowser``).
    public private(set) var isDefaultBrowser: Bool?
    /// Whether the command bar is showing.
    public private(set) var isCommandBarVisible = false
    /// What's typed in the command bar.
    public private(set) var commandQuery = ""
    /// The command bar's rows, best first.
    public private(set) var commandResults: [CommandResult] = []
    /// The highlighted row.
    public private(set) var commandSelection = 0
    /// Whether the find bar is showing above the page.
    public private(set) var isFindBarVisible = false
    /// The text to find in the selected page.
    public var findText = ""
    /// Whether the last search found nothing.
    public private(set) var findHasNoMatches = false
    /// Incremented to ask the find field to take focus.
    public private(set) var findFocusRequest = 0
    /// The page question to show now (a permission request or a JavaScript dialog), if any.
    public private(set) var currentPrompt: PagePrompt?
    /// Site icons by lowercased host, for the tabs in the sidebar.
    public private(set) var favicons: [String: NSImage] = [:]

    /// The web view pool that owns this window's web views.
    public let pool: WebViewPool

    @ObservationIgnored let store: TabStore
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var spacesObservationTask: Task<Void, Never>?
    @ObservationIgnored private var foldersObservationTask: Task<Void, Never>?
    @ObservationIgnored private var splitsObservationTask: Task<Void, Never>?
    /// The pane each split last had focused, so selecting the split's row returns to it.
    @ObservationIgnored var focusedPaneBySplit: [TabSplit.ID: AxoCore.Tab.ID] = [:]
    /// The tab each Space had selected, so switching back returns to it.
    @ObservationIgnored private var selectedTabBySpace: [Space.ID: AxoCore.Tab.ID] = [:]
    /// The Space to show at launch, if it still exists.
    @ObservationIgnored private let initialSpaceID: Space.ID?
    /// Called with the Space's ID whenever the window switches Spaces, so the app can reopen it.
    @ObservationIgnored public var onSpaceChange: ((Space.ID) -> Void)?
    /// How long an unpinned tab can go unshown before it's archived. Defaults to 12 hours.
    @ObservationIgnored public var archiveAfter: TimeInterval = 12 * 60 * 60
    /// How often to look for idle tabs to archive while Axo runs.
    @ObservationIgnored public var archiveCheckInterval: Duration = .seconds(60 * 60)
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var archiveTask: Task<Void, Never>?
    @ObservationIgnored private var commandSearchTask: Task<Void, Never>?
    /// Opens the Web Inspector. Set by the app.
    @ObservationIgnored public var developerTools: (any DeveloperToolsProviding)?
    /// Installs and manages extensions. Set by the app.
    @ObservationIgnored public var extensionManagement: (any ExtensionManaging)?
    /// An extension waiting for the person to agree to add it.
    public internal(set) var pendingExtensionInstall: ExtensionInstallPrompt?
    /// Whether the Extensions window is open.
    public var isShowingExtensions = false
    /// Extension toolbar buttons. Set by the app.
    @ObservationIgnored public var extensionToolbar: (any ExtensionToolbarProviding)?
    /// Called for tab and window events extensions hear about. Set by the app.
    @ObservationIgnored public var onTabEvent: ((TabEvent) -> Void)?
    /// The views behind extension toolbar buttons, by extension ID, for showing popups.
    @ObservationIgnored var extensionAnchors: [String: NSView] = [:]
    /// Asks macOS for location access when the person first allows a site's location request.
    /// Set by the app.
    @ObservationIgnored public var locationAuthorization: (any LocationAuthorizing)?
    /// Whether the Site Settings popover is open.
    public var isShowingSiteSettings = false
    /// The saved permission answers for the selected page's site, while Site Settings is open.
    public internal(set) var sitePermissions: [SitePermission.Kind: SitePermission.Decision] = [:]
    /// Reads and imports other browsers' data. Set by the app.
    @ObservationIgnored public var browserImporter: (any BrowserImporting)?
    /// The open Import sheet's state, if it's open.
    public var importSession: ImportSession?
    /// Checks and changes the default browser. Set by the app.
    @ObservationIgnored public var defaultBrowser: (any DefaultBrowserSetting)? {
        didSet { refreshDefaultBrowserStatus() }
    }
    /// Links that arrived before the model finished starting.
    @ObservationIgnored private var pendingExternalURLs: [(url: URL, sourceApp: String?)] = []
    /// Whether the window offers its page to the person's other devices through Handoff. Off in
    /// UI testing, so test pages never reach real devices.
    public var isHandoffEnabled = true
    /// The Space shown before a Focus filter switched Spaces, to return to when the Focus ends.
    @ObservationIgnored var spaceBeforeFocus: Space.ID?
    /// Per-site custom CSS and JavaScript, kept current and applied to every web view.
    public internal(set) var siteCustomizations: [SiteCustomization] = []
    /// The customization being edited in the window's editor sheet, if it's open.
    public var customizationDraft: SiteCustomization?
    @ObservationIgnored private var siteCustomizationsObservationTask: Task<Void, Never>?
    /// Link routing rules, kept current for Settings.
    public internal(set) var linkRoutes: [LinkRoute] = []
    @ObservationIgnored private var linkRoutesObservationTask: Task<Void, Never>?
    /// The most recent page-change save; each new one waits for it, keeping saves in order.
    @ObservationIgnored private var pageChangeSave: Task<Void, Never>?
    /// Tabs whose current page was already counted as a visit since launch. A tab's first page
    /// change counts even if its saved URL is unchanged, since that's a fresh load.
    @ObservationIgnored private var hasRecordedVisit: Set<AxoCore.Tab.ID> = []
    @ObservationIgnored let prompts = PagePromptQueue()
    /// Hosts whose saved icon was already looked up, so each is read from the database once.
    @ObservationIgnored private var lookedUpFaviconHosts: Set<String> = []
    /// Speaks a short message to VoiceOver users. Tests replace it to record messages.
    @ObservationIgnored public var announce: (String) -> Void = { message in
        AccessibilityNotification.Announcement(message).post()
    }
    @ObservationIgnored private let logger = Logger(subsystem: "com.perezstudio.Axo", category: "BrowserModel")

    /// Creates a model. Call ``start()`` before showing it.
    ///
    /// - Parameter initialSpaceID: The Space to open at launch, such as the last one used. The
    ///   first Space opens if it's `nil` or no longer exists.
    public init(
        store: TabStore,
        pool: WebViewPool,
        alertMessage: String? = nil,
        initialSpaceID: Space.ID? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.pool = pool
        self.now = now
        self.alertMessage = alertMessage
        self.initialSpaceID = initialSpaceID
        pool.onPageChange = { [weak self] tabID, url, title in
            self?.persistPageChange(tabID: tabID, url: url, title: title)
        }
        pool.onFaviconChange = { [weak self] _, pageURL, data in
            self?.saveFavicon(data, for: pageURL)
        }
        prompts.onChange = { [weak self] prompt in self?.currentPrompt = prompt }
        pool.permissionStore = SitePermissionAdapter(store: store.sitePermissions)
        pool.downloads.onEnd = { [weak self] item in
            switch item.state {
            case .finished: self?.announce("Downloaded \(item.filename)")
            case .failed: self?.announce("Download failed: \(item.filename)")
            default: break
            }
        }
        pool.onPermissionRequest = { [weak self] request in
            guard let self else { return .deny }
            let decision = await self.prompts.ask(request)
            // macOS asks about location once, after the person allows a site in Axo.
            if request.kind == .location, decision == .allow { self.locationAuthorization?.requestIfNeeded() }
            return decision
        }
        pool.onJavaScriptDialog = { [weak self] dialog in
            await self?.prompts.ask(dialog) ?? .cancelled
        }
        pool.onFileSelection = { [weak self] request in
            await self?.chooseFiles(for: request)
        }
        pool.onWebViewFocus = { [weak self] tabID in self?.paneDidTakeFocus(tabID) }
        presentMiniWindow = { [weak self] mini in
            guard let self else { return }
            MiniWindowController.show(mini, model: self)
        }
        dismissMiniWindow = { id in MiniWindowController.dismiss(id) }
        pool.onOpenInNewTab = { [weak self] url, sourceID in
            guard let self else { return }
            if self.peek?.tab.id == sourceID || self.miniWindows.contains(where: { $0.id == sourceID }) {
                // New-window links in Peek or a mini window stay there.
                self.pool.load(url, in: sourceID)
            } else if self.tabs.first(where: { $0.id == sourceID })?.isPinned == true {
                self.openPeek(url, from: sourceID)
            } else {
                Task { await self.openTab(url: url, at: .after(sourceID)) }
            }
        }
        pool.onLinkClick = { [weak self] click in
            self?.handleLinkClick(click) ?? false
        }
    }

    isolated deinit {
        observationTask?.cancel()
        spacesObservationTask?.cancel()
        linkRoutesObservationTask?.cancel()
        siteCustomizationsObservationTask?.cancel()
        foldersObservationTask?.cancel()
        splitsObservationTask?.cancel()
        archiveTask?.cancel()
    }

    /// The selected tab's record.
    public var selectedTab: AxoCore.Tab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// The icon for a tab's site, if Axo has one.
    public func favicon(for tab: AxoCore.Tab) -> NSImage? {
        Favicon.key(for: tab.url).flatMap { favicons[$0] }
    }

    /// Loads the Spaces, opens the initial Space with its first tab selected, and starts
    /// observing changes.
    public func start() async {
        guard space == nil else { return }
        do {
            let first = try await store.bootstrap()
            spaces = try await store.spaces()
            let initial = spaces.first { $0.id == initialSpaceID } ?? first
            try await show(initial)
            let pending = pendingExternalURLs
            pendingExternalURLs = []
            for link in pending {
                await openExternalURL(link.url, sourceApp: link.sourceApp)
            }
            observeSpaces()
            observeLinkRoutes()
            observeSiteCustomizations()
            pool.startHibernationTimer()
            startArchiving()
        } catch {
            report(error, "Axo couldn't load your tabs.")
        }
    }

    // MARK: Spaces

    /// Switches the window to another Space, returning to the tab it had selected.
    public func selectSpace(_ id: Space.ID) async {
        guard id != space?.id, let target = spaces.first(where: { $0.id == id }) else { return }
        do {
            try await show(target)
            announce("Switched to \(target.name)")
        } catch {
            report(error, "Axo couldn't open that Space.")
        }
    }

    /// Switches to the Space at `index` in the switcher, if there is one.
    public func selectSpace(at index: Int) async {
        guard spaces.indices.contains(index) else { return }
        await selectSpace(spaces[index].id)
    }

    /// Switches to the next Space, wrapping around.
    public func selectNextSpace() async {
        await selectSpace(offsetBy: 1)
    }

    /// Switches to the previous Space, wrapping around.
    public func selectPreviousSpace() async {
        await selectSpace(offsetBy: -1)
    }

    private func selectSpace(offsetBy offset: Int) async {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == space?.id }) else { return }
        await selectSpace(at: (index + offset + spaces.count) % spaces.count)
    }

    /// Creates a Space and switches to it.
    ///
    /// - Parameters:
    ///   - name: The Space's name.
    ///   - newProfileName: A name for a new profile with its own cookies and website data, or
    ///     `nil` to share the current Space's profile.
    public func createSpace(name: String, newProfileName: String? = nil) async {
        guard let current = space else { return }
        do {
            let profileID = if let newProfileName {
                try await store.createProfile(name: newProfileName).id
            } else {
                current.profileID
            }
            let created = try await store.createSpace(name: name, profileID: profileID)
            spaces = try await store.spaces()
            try await show(created)
        } catch {
            report(error, "Axo couldn't create the Space.")
        }
    }

    /// Renames a Space.
    public func renameSpace(_ id: Space.ID, to name: String) async {
        do {
            try await store.renameSpace(id: id, to: name)
            spaces = try await store.spaces()
            if space?.id == id { space = spaces.first { $0.id == id } }
        } catch {
            report(error, "Axo couldn't rename the Space.")
        }
    }

    /// Deletes a Space and closes its tabs. If it was showing, the window switches to the Space
    /// next to it. The last Space can't be deleted.
    public func deleteSpace(_ id: Space.ID) async {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let name = spaces[index].name
        do {
            let closedTabs = try await store.deleteSpace(id: id)
            for tabID in closedTabs {
                prompts.dismissAll(from: tabID)
                pool.discard(tabID)
                onTabEvent?(.closed(tabID))
            }
            selectedTabBySpace[id] = nil
            spaces = try await store.spaces()
            if space?.id == id {
                try await show(spaces[min(index, spaces.count - 1)])
            }
            announce("Deleted \(name)")
        } catch {
            report(error, "Axo couldn't delete the Space.")
        }
    }

    /// The profiles a new Space could use, by name.
    public func profiles() async -> [Profile] {
        (try? await store.profiles()) ?? []
    }

    /// Shows `target` in the window: its tabs, its remembered selection, and live updates.
    private func show(_ target: Space) async throws {
        if let current = space {
            selectedTabBySpace[current.id] = selectedTabID
        }
        space = target
        tabs = try await store.tabs(in: target.id)
        folders = try await store.folders(in: target.id)
        splits = try await store.splits(in: target.id)
        observeFolders(in: target.id)
        observeSplits(in: target.id)
        let remembered = selectedTabBySpace[target.id].flatMap { id in tabs.first { $0.id == id }?.id }
        select(remembered ?? tabs.first?.id)
        observeTabs(in: target.id)
        await loadSavedFavicons()
        onSpaceChange?(target.id)
        onTabEvent?(.spaceChanged)
    }

    /// Archives idle tabs now and then every ``archiveCheckInterval``.
    private func startArchiving() {
        archiveTask?.cancel()
        let interval = archiveCheckInterval
        archiveTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.archiveInactiveTabs()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func observeSiteCustomizations() {
        siteCustomizationsObservationTask?.cancel()
        let observation = store.siteCustomizations.observe()
        siteCustomizationsObservationTask = Task { [weak self] in
            do {
                for try await customizations in observation {
                    guard let self else { return }
                    self.siteCustomizations = customizations
                    self.pool.setSiteCustomizations(customizations)
                }
            } catch {
                self?.logger.error("Site customization observation failed: \(error)")
            }
        }
    }

    private func observeLinkRoutes() {
        linkRoutesObservationTask?.cancel()
        let observation = store.linkRoutes.observeRoutes()
        linkRoutesObservationTask = Task { [weak self] in
            do {
                for try await routes in observation {
                    self?.linkRoutes = routes
                }
            } catch {
                self?.logger.error("Link route observation failed: \(error)")
            }
        }
    }

    private func observeSpaces() {
        spacesObservationTask?.cancel()
        let observation = store.observeSpaces()
        spacesObservationTask = Task { [weak self] in
            do {
                for try await _ in observation {
                    // Re-read for the same reason as tabs: never apply a stale list.
                    guard let self else { return }
                    self.spaces = try await self.store.spaces()
                }
            } catch {
                self?.logger.error("Space observation failed: \(error)")
            }
        }
    }

    // MARK: Selection

    /// Shows the tab with `id`, or nothing if `id` is `nil`.
    public func select(_ id: AxoCore.Tab.ID?) {
        if id != selectedTabID, isFindBarVisible {
            closeFindBar()
        }
        if let peek, id != peek.sourceTabID {
            closePeek()
        }
        // Both the tab being left and the one being shown were just in use.
        markActive([selectedTabID, id].compactMap { $0 })
        let previous = selectedTabID
        selectedTabID = id
        if id != nil { selectedFolderID = nil }
        if previous != id { onTabEvent?(.activated(id, previous: previous)) }
        rememberFocusedPane()
        activateSelectedTab()
    }

    /// Asks the pool for the selected tab's web view, so its state is ready for the toolbar.
    private func activateSelectedTab() {
        guard let tab = selectedTab, let space else {
            selectedPage = nil
            return
        }
        _ = pool.webView(for: tab, profileID: space.profileID)
        selectedPage = pool.state(for: tab.id)
    }

    // MARK: Tabs

    /// Starts a new tab by opening the command bar, like Arc.
    public func beginNewTab() {
        showCommandBar()
    }

    /// Asks the address field to take focus, with its address selected.
    public func focusAddressField() {
        addressFocusRequest += 1
    }

    /// Handles text submitted from the address field: loads it in the selected tab, or opens a
    /// new tab when none is selected.
    public func submitAddress(_ text: String) async {
        guard let url = AddressInput.url(from: text) else { return }
        if selectedTabID == nil {
            await openTab(url: url)
        } else if let tabID = selectedTabID {
            pool.load(url, in: tabID)
        }
    }

    /// Opens `url` in a new tab and selects it.
    public func openTab(url: URL, at position: TabPosition = .end) async {
        guard let space else { return }
        do {
            let tab = try await store.openTab(url: url, in: space.id, at: position)
            tabs = try await store.tabs(in: space.id)
            onTabEvent?(.opened(tab.id))
            select(tab.id)
        } catch {
            report(error, "Axo couldn't open a new tab.")
        }
    }

    /// Closes a tab, the way Arc does: an unpinned tab is archived (⇧⌘T or the archive brings
    /// it back), and a pinned tab stays in the sidebar but unloads and returns to its home page.
    /// If the tab was selected, the tab below it (or above, if it was last) is selected.
    public func closeTab(_ id: AxoCore.Tab.ID) async {
        guard let space, let tab = tabs.first(where: { $0.id == id }) else { return }
        let visibleOrder = tabs.map(\.id)
        let otherPanes = tab.splitID.map { splitID in tabs.filter { $0.splitID == splitID && $0.id != id }.map(\.id) } ?? []
        prompts.dismissAll(from: id)
        pool.discard(id)
        do {
            if tab.isPinned {
                try await store.resetPinnedTab(id: id)
            } else {
                try await store.archiveTab(id: id, at: now())
                onTabEvent?(.closed(id))
            }
            tabs = try await store.tabs(in: space.id)
        } catch {
            report(error, "Axo couldn't close the tab.")
            return
        }
        announce(tab.isPinned ? "Unloaded \(TabRow.displayTitle(for: tab))" : "Closed \(TabRow.displayTitle(for: tab))")
        guard selectedTabID == id else { return }
        // Closing one pane of a split keeps the rest of the split on screen.
        if !tab.isPinned, let pane = otherPanes.first(where: { remaining in tabs.contains { $0.id == remaining } }) {
            select(pane)
            return
        }
        select(Self.neighbor(of: id, in: visibleOrder, among: tabs.map(\.id).filter { $0 != id }))
    }

    /// The tab to select after `id` goes away: the next one in `order`, else the previous one.
    private static func neighbor(of id: AxoCore.Tab.ID, in order: [AxoCore.Tab.ID], among remaining: [AxoCore.Tab.ID]) -> AxoCore.Tab.ID? {
        guard let index = order.firstIndex(of: id) else { return remaining.first }
        let candidates = Set(remaining)
        let after = order[(index + 1)...].first { candidates.contains($0) }
        let before = order[..<index].last { candidates.contains($0) }
        return after ?? before
    }

    /// Closes the selected tab, if any.
    public func closeSelectedTab() async {
        guard let selectedTabID else { return }
        await closeTab(selectedTabID)
    }

    /// Brings back the most recently closed (archived) tab in this Space and selects it.
    public func reopenLastClosedTab() async {
        guard let space else { return }
        do {
            guard let last = try await store.archivedTabs(in: space.id).first else { return }
            await restoreTab(last.id)
        } catch {
            report(error, "Axo couldn't reopen the tab.")
        }
    }

    /// The Space's archived tabs, most recently archived first.
    public func archivedTabs() async -> [AxoCore.Tab] {
        guard let space else { return [] }
        return (try? await store.archivedTabs(in: space.id)) ?? []
    }

    /// Puts an archived tab back in the sidebar and selects it.
    public func restoreTab(_ id: AxoCore.Tab.ID) async {
        guard let space else { return }
        do {
            try await store.restoreTab(id: id, at: now())
            tabs = try await store.tabs(in: space.id)
            onTabEvent?(.opened(id))
            select(id)
            if let tab = selectedTab { announce("Reopened \(TabRow.displayTitle(for: tab))") }
        } catch {
            report(error, "Axo couldn't restore the tab.")
        }
    }

    /// Archives unpinned tabs, in every Space, that haven't been shown for ``archiveAfter``.
    /// The selected tab is never archived.
    public func archiveInactiveTabs() async {
        do {
            let keeping: Set<AxoCore.Tab.ID> = selectedTabID.map { [$0] } ?? []
            let archived = try await store.archiveInactiveTabs(
                lastActiveBefore: now().addingTimeInterval(-archiveAfter),
                keeping: keeping,
                at: now()
            )
            for id in archived {
                prompts.dismissAll(from: id)
                pool.discard(id)
                onTabEvent?(.closed(id))
            }
            if let space, !archived.isEmpty {
                tabs = try await store.tabs(in: space.id)
            }
        } catch {
            logger.error("Couldn't archive idle tabs: \(error)")
        }
    }

    // MARK: Pinning

    /// The Space's pinned tabs, in order.
    public var pinnedTabs: [AxoCore.Tab] { tabs.filter(\.isPinned) }

    /// The Space's unpinned tabs, in order.
    public var unpinnedTabs: [AxoCore.Tab] { tabs.filter { !$0.isPinned } }

    /// Pins or unpins a tab. Pinning makes its current page the tab's home page.
    public func setPinned(_ pinned: Bool, tabID: AxoCore.Tab.ID) async {
        guard let space else { return }
        do {
            try await store.setPinned(pinned, tabID: tabID)
            tabs = try await store.tabs(in: space.id)
            if let tab = tabs.first(where: { $0.id == tabID }) {
                announce(pinned ? "Pinned \(TabRow.displayTitle(for: tab))" : "Unpinned \(TabRow.displayTitle(for: tab))")
            }
        } catch {
            report(error, pinned ? "Axo couldn't pin the tab." : "Axo couldn't unpin the tab.")
        }
    }

    /// Takes a pinned tab back to its home page.
    public func goToPinnedHome(_ tabID: AxoCore.Tab.ID) async {
        guard let space else { return }
        do {
            guard let home = try await store.resetPinnedTab(id: tabID) else { return }
            tabs = try await store.tabs(in: space.id)
            pool.load(home, in: tabID)
        } catch {
            report(error, "Axo couldn't go to the pinned page.")
        }
    }

    /// Makes a pinned tab's current page its new home page.
    public func makeCurrentPagePinnedHome(_ tabID: AxoCore.Tab.ID) async {
        guard let space, let url = tabs.first(where: { $0.id == tabID })?.url else { return }
        do {
            try await store.setHomeURL(url, tabID: tabID)
            tabs = try await store.tabs(in: space.id)
        } catch {
            report(error, "Axo couldn't update the pinned page.")
        }
    }

    // MARK: Folders

    /// The pinned section as a tree: folders (with their contents) and pinned tabs, each level
    /// in order.
    public var pinnedTree: [PinnedNode] {
        // A split shows as one row: its first tab stands for the others.
        PinnedNode.tree(folders: folders, pinnedTabs: pinnedTabs.filter { !isSplitFollower($0) })
    }

    /// Creates a folder at the end of a level of the pinned section, optionally moving a tab or
    /// folder into it.
    public func createFolder(named name: String, parent: Folder.ID? = nil, moving item: PinnedItem? = nil) async {
        guard let space else { return }
        do {
            let folder = try await store.createFolder(named: name, in: space.id, parent: parent)
            if let item {
                try await store.movePinnedItem(item, into: folder.id, after: nil)
            }
            try await refreshSidebar()
        } catch {
            report(error, "Axo couldn't create the folder.")
        }
    }

    /// Renames a folder.
    public func renameFolder(_ id: Folder.ID, to name: String) async {
        await changeFolders("Axo couldn't rename the folder.") { try await self.store.renameFolder(id: id, to: name) }
    }

    /// Deletes a folder. Its tabs and subfolders move up a level.
    public func deleteFolder(_ id: Folder.ID) async {
        if selectedFolderID == id { selectedFolderID = nil }
        await changeFolders("Axo couldn't delete the folder.") { try await self.store.deleteFolder(id: id) }
    }

    /// Expands or collapses a folder.
    public func setFolderExpanded(_ expanded: Bool, id: Folder.ID) async {
        if let index = folders.firstIndex(where: { $0.id == id }) {
            folders[index].isExpanded = expanded
        }
        await changeFolders("Axo couldn't update the folder.") { try await self.store.setFolderExpanded(expanded, id: id) }
    }

    /// Moves a tab or folder to the end of a folder (or the top level when `folder` is `nil`).
    /// Moving an unpinned tab pins it.
    public func move(_ item: PinnedItem, toFolder folder: Folder.ID?) async {
        let anchor = PinnedNode.items(at: folder, in: pinnedTree).last { $0 != item }
        await changeFolders("Axo couldn't move that.") {
            try await self.store.movePinnedItem(item, into: folder, after: anchor)
        }
        let name = folder.flatMap { id in folders.first { $0.id == id }?.name }
        announce(name.map { "Moved to \($0)" } ?? "Moved to Pinned")
    }

    /// Reorders a level of the pinned section after a drag, using `List.onMove` indices.
    public func movePinnedItems(fromOffsets source: IndexSet, toOffset destination: Int, in parent: Folder.ID?) async {
        let level = PinnedNode.items(at: parent, in: pinnedTree)
        guard let sourceIndex = source.first, source.count == 1, level.indices.contains(sourceIndex) else { return }
        var remaining = level
        let moving = remaining.remove(at: sourceIndex)
        let insertIndex = destination > sourceIndex ? destination - 1 : destination
        guard insertIndex != sourceIndex else { return }
        let anchor = insertIndex == 0 ? nil : remaining[insertIndex - 1]
        await changeFolders("Axo couldn't move that.") {
            try await self.store.movePinnedItem(moving, into: parent, after: anchor)
        }
    }

    private func changeFolders(_ failure: String, _ change: @escaping () async throws -> Void) async {
        do {
            try await change()
            try await refreshSidebar()
        } catch {
            report(error, failure)
        }
    }

    func refreshSidebar() async throws {
        guard let space else { return }
        tabs = try await store.tabs(in: space.id)
        folders = try await store.folders(in: space.id)
        splits = try await store.splits(in: space.id)
    }

    private func observeSplits(in spaceID: Space.ID) {
        splitsObservationTask?.cancel()
        let observation = store.observeSplits(in: spaceID)
        splitsObservationTask = Task { [weak self] in
            do {
                for try await _ in observation {
                    // Re-read for the same reason as tabs: never apply a stale list.
                    guard let self, self.space?.id == spaceID else { return }
                    let current = try await self.store.splits(in: spaceID)
                    guard self.space?.id == spaceID else { return }
                    self.splits = current
                }
            } catch {
                self?.logger.error("Split observation failed: \(error)")
            }
        }
    }

    private func observeFolders(in spaceID: Space.ID) {
        foldersObservationTask?.cancel()
        let observation = store.observeFolders(in: spaceID)
        foldersObservationTask = Task { [weak self] in
            do {
                for try await _ in observation {
                    // Re-read for the same reason as tabs: never apply a stale list.
                    guard let self, self.space?.id == spaceID else { return }
                    let current = try await self.store.folders(in: spaceID)
                    guard self.space?.id == spaceID else { return }
                    self.folders = current
                }
            } catch {
                self?.logger.error("Folder observation failed: \(error)")
            }
        }
    }

    /// Moves a tab within its section after a drag in the sidebar, using `List.onMove` indices
    /// relative to that section.
    public func moveTabs(fromOffsets source: IndexSet, toOffset destination: Int, pinned: Bool) async {
        let section = (pinned ? pinnedTabs : unpinnedTabs).filter { !isSplitFollower($0) }
        guard let space, let sourceIndex = source.first, source.count == 1, section.indices.contains(sourceIndex) else { return }
        let moving = section[sourceIndex]
        var remaining = section
        remaining.remove(at: sourceIndex)
        let insertIndex = destination > sourceIndex ? destination - 1 : destination
        guard insertIndex != sourceIndex else { return }
        let position: TabPosition = insertIndex == 0 ? .start : .after(remaining[insertIndex - 1].id)
        do {
            try await store.moveTab(id: moving.id, to: position)
            tabs = try await store.tabs(in: space.id)
        } catch {
            report(error, "Axo couldn't move the tab.")
        }
    }

    // MARK: Navigation

    /// Goes back in the selected tab.
    public func goBack() {
        if let selectedTabID { pool.goBack(in: selectedTabID) }
    }

    /// Goes forward in the selected tab.
    public func goForward() {
        if let selectedTabID { pool.goForward(in: selectedTabID) }
    }

    /// Reloads the selected tab, or stops it if it's loading.
    public func reloadOrStop() {
        guard let selectedTabID else { return }
        if selectedPage?.isLoading == true {
            pool.stopLoading(selectedTabID)
        } else {
            pool.reload(selectedTabID)
        }
    }

    // MARK: Page prompts

    /// Answers the current permission request.
    public func answerPermission(_ decision: PermissionDecision) {
        prompts.answerCurrent(with: decision)
    }

    /// Answers the current JavaScript dialog.
    public func answerDialog(_ result: JavaScriptDialogResult) {
        prompts.answerCurrent(with: result)
    }

    /// Shows an Open panel for a page's file input, as a sheet on the tab's window.
    private func chooseFiles(for request: FileSelectionRequest) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = request.allowsMultipleSelection
        panel.canChooseDirectories = request.allowsDirectories
        panel.canChooseFiles = true
        panel.prompt = "Choose"
        let response: NSApplication.ModalResponse
        if let window = pool.liveWebView(for: request.tabID)?.window {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await withCheckedContinuation { continuation in
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        return response == .OK ? panel.urls : nil
    }

    // MARK: Default browser and links from other apps

    /// Opens a link another app sent (as the default browser). A link routing rule for its
    /// domain or for the app that sent it opens it as a tab in the rule's Space, switching to that
    /// Space. Otherwise it opens in a mini window, which can move into the current Space as a tab.
    /// Links that arrive during launch open once Axo is ready.
    ///
    /// - Parameter sourceApp: The bundle ID of the app that sent the link, if known.
    public func openExternalURL(_ url: URL, sourceApp: String? = nil) async {
        guard space != nil else {
            pendingExternalURLs.append((url, sourceApp))
            return
        }
        let routes = (try? await store.linkRoutes.routes()) ?? linkRoutes
        if let route = LinkRoute.route(for: url, from: sourceApp, in: routes),
           spaces.contains(where: { $0.id == route.spaceID }) {
            hideCommandBar()
            await selectSpace(route.spaceID)
            await openTab(url: url)
            showBrowserWindow?()
            return
        }
        openMiniWindow(url)
    }

    /// Checks again whether Axo is the default browser.
    public func refreshDefaultBrowserStatus() {
        isDefaultBrowser = defaultBrowser?.isDefault
    }

    /// Asks macOS to make Axo the default browser. If the person declines in macOS's dialog,
    /// nothing changes and nothing else is shown.
    public func makeDefaultBrowser() async {
        guard let defaultBrowser else { return }
        do {
            try await defaultBrowser.makeDefault()
        } catch {
            logger.info("Default browser not changed: \(error)")
        }
        refreshDefaultBrowserStatus()
    }

    // MARK: Extensions

    /// Shows an extension's popup under its toolbar button (or the window's top edge if the
    /// button isn't on screen).
    public func presentExtensionPopup(_ popover: NSPopover, extensionID: String) {
        if let anchor = extensionAnchors[extensionID], anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else if let content = NSApp.keyWindow?.contentView {
            let top = NSRect(x: content.bounds.maxX - 60, y: content.bounds.maxY - 1, width: 1, height: 1)
            popover.show(relativeTo: top, of: content, preferredEdge: .minY)
        }
    }

    // MARK: Command bar

    /// Opens the command bar with an empty query.
    public func showCommandBar() {
        refreshDefaultBrowserStatus()
        isCommandBarVisible = true
        commandQuery = ""
        refreshCommandResults()
    }

    /// Closes the command bar.
    public func hideCommandBar() {
        commandSearchTask?.cancel()
        let wasVisible = isCommandBarVisible
        isCommandBarVisible = false
        pendingSplitAnchor = nil
        if wasVisible { focusPage() }
    }

    /// Updates the query and its results: typed-text, tab, and action rows right away, then
    /// history from the full-text index.
    public func setCommandQuery(_ query: String) {
        // A text field commits its value again on Return; that's not a new query, and treating
        // it as one would reset the highlight before the highlighted row runs.
        guard query != commandQuery else { return }
        commandQuery = query
        refreshCommandResults()
    }

    /// Recomputes the results for the current query and highlights the first one.
    private func refreshCommandResults() {
        let query = commandQuery
        commandResults = CommandRanking.immediateResults(for: query, tabs: tabs, availableActions: availableActions)
        commandSelection = 0
        commandSearchTask?.cancel()
        guard let profileID = space?.profileID, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let history = store.history
        commandSearchTask = Task { [weak self] in
            let items = (try? await history.search(query, profileID: profileID)) ?? []
            guard let self, !Task.isCancelled, self.commandQuery == query else { return }
            self.commandResults += CommandRanking.historyResults(items, excludingOpen: self.tabs)
        }
    }

    /// Moves the highlight up or down, staying within the results.
    public func moveCommandSelection(by offset: Int) {
        guard !commandResults.isEmpty else { return }
        commandSelection = min(max(commandSelection + offset, 0), commandResults.count - 1)
        // Focus stays in the text field, so say which row is highlighted.
        let result = commandResults[commandSelection]
        announce("\(result.title), \(result.hint)")
    }

    /// Runs the highlighted row (or `index`), then closes the command bar.
    public func runCommand(at index: Int? = nil) async {
        let index = index ?? commandSelection
        guard commandResults.indices.contains(index) else { return }
        let result = commandResults[index]
        // Add Split View: what's chosen joins this tab in a split.
        let splitAnchor = pendingSplitAnchor
        hideCommandBar()
        switch result {
        case .open(let url, _, _):
            await openTab(url: url)
            await completePendingSplit(with: selectedTabID, anchor: splitAnchor)
        case .tab(let tab):
            if splitAnchor != nil {
                await completePendingSplit(with: tab.id, anchor: splitAnchor)
            } else {
                select(tab.id)
            }
        case .history(let item):
            await openTab(url: item.url)
            await completePendingSplit(with: selectedTabID, anchor: splitAnchor)
        case .action(let action):
            await perform(action)
        }
    }

    /// Actions that make sense right now; for example, Pin Tab needs an unpinned selected tab.
    var availableActions: [CommandAction] {
        CommandAction.allCases.filter { action in
            switch action {
            case .pinTab: selectedTab.map { !$0.isPinned } ?? false
            case .unpinTab: selectedTab?.isPinned ?? false
            case .findInPage, .printPage: selectedTabID != nil
            case .makeDefaultBrowser: isDefaultBrowser == false
            case .importBrowserData: browserImporter != nil
            case .deleteSpace: spaces.count > 1
            case .renameFolder, .deleteFolder: selectedFolderID != nil
            case .addSplitView: canAddToSplit
            case .separateSplitView, .rotateSplitView: selectedSplit != nil
            default: true
            }
        }
    }

    private func perform(_ action: CommandAction) async {
        switch action {
        case .newSpace: isCreatingSpace = true
        case .newFolder: beginNewFolder()
        case .reopenClosedTab: await reopenLastClosedTab()
        case .showArchivedTabs: isShowingArchive = true
        case .showDownloads: isShowingDownloads = true
        case .pinTab: if let id = selectedTabID { await setPinned(true, tabID: id) }
        case .unpinTab: if let id = selectedTabID { await setPinned(false, tabID: id) }
        case .findInPage: showFindBar()
        case .printPage: printSelectedTab()
        case .makeDefaultBrowser: await makeDefaultBrowser()
        case .importBrowserData: beginImport()
        case .renameSpace: beginRenameSpace()
        case .deleteSpace: beginDeleteSpace()
        case .renameFolder: renameSelectedFolder()
        case .deleteFolder: await deleteSelectedFolder()
        case .addSplitView: beginSplitWithNewTab()
        case .separateSplitView: await separateSelectedSplit()
        case .rotateSplitView: await toggleSplitOrientation()
        }
    }

    // MARK: Find and print

    /// Shows the find bar (or focuses it if it's already showing).
    public func showFindBar() {
        guard selectedTabID != nil else { return }
        isFindBarVisible = true
        findFocusRequest += 1
    }

    /// Hides the find bar and clears its highlight from the page.
    public func closeFindBar() {
        let wasVisible = isFindBarVisible
        isFindBarVisible = false
        findHasNoMatches = false
        if wasVisible { focusPage() }
        if let selectedTabID {
            let pool = pool
            Task { await pool.clearFind(in: selectedTabID) }
        }
    }

    /// Finds the next match of ``findText`` in the selected page.
    public func findNext() async {
        await find(backwards: false)
    }

    /// Finds the previous match of ``findText`` in the selected page.
    public func findPrevious() async {
        await find(backwards: true)
    }

    private func find(backwards: Bool) async {
        guard let selectedTabID, !findText.isEmpty else {
            findHasNoMatches = false
            return
        }
        if !isFindBarVisible { showFindBar() }
        let found = await pool.find(findText, in: selectedTabID, backwards: backwards)
        if !found, !findHasNoMatches { announce("No matches") }
        findHasNoMatches = !found
    }

    /// Shows the print sheet for the selected page in its window.
    public func printSelectedTab() {
        guard let selectedTabID,
              let operation = pool.printOperation(for: selectedTabID),
              let window = pool.liveWebView(for: selectedTabID)?.window else { return }
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: Persistence

    private func markActive(_ ids: [AxoCore.Tab.ID]) {
        guard !ids.isEmpty else { return }
        let date = now()
        Task {
            for id in ids {
                try? await store.markActive(id: id, at: date)
            }
        }
    }

    private func observeTabs(in spaceID: Space.ID) {
        observationTask?.cancel()
        let observation = store.observeTabs(in: spaceID)
        observationTask = Task { [weak self] in
            do {
                for try await _ in observation {
                    // Re-read instead of using the observed list: a list observed before one of
                    // this model's own writes can arrive after it and would undo it briefly.
                    guard let self, self.space?.id == spaceID else { return }
                    let current = try await self.store.tabs(in: spaceID)
                    guard self.space?.id == spaceID else { return }
                    self.tabs = current
                    await self.loadSavedFavicons()
                }
            } catch {
                self?.logger.error("Tab observation failed: \(error)")
            }
        }
    }

    /// Reads saved icons for hosts in the sidebar that haven't been looked up yet.
    private func loadSavedFavicons() async {
        let hosts = Set(tabs.compactMap { Favicon.key(for: $0.url) }).subtracting(lookedUpFaviconHosts)
        guard !hosts.isEmpty else { return }
        lookedUpFaviconHosts.formUnion(hosts)
        do {
            for (host, data) in try await store.favicons(forHosts: hosts) where favicons[host] == nil {
                favicons[host] = NSImage(data: data)
            }
        } catch {
            logger.error("Couldn't load favicons: \(error)")
        }
    }

    private func saveFavicon(_ data: Data, for pageURL: URL) {
        guard let host = Favicon.key(for: pageURL), let image = NSImage(data: data) else { return }
        favicons[host] = image
        lookedUpFaviconHosts.insert(host)
        Task {
            do {
                try await store.saveFavicon(data, for: pageURL)
            } catch {
                logger.error("Couldn't save favicon: \(error)")
            }
        }
    }

    /// Saves a page change to the tab and to the profile's history. A new URL counts as a
    /// visit; a title for the same URL only updates the title.
    ///
    /// Changes are saved strictly in order. A load usually reports its URL and then its title
    /// moments apart; saving them concurrently let both read the old URL and count two visits.
    private func persistPageChange(tabID: AxoCore.Tab.ID, url: URL, title: String) {
        let previousSave = pageChangeSave
        pageChangeSave = Task {
            await previousSave?.value
            do {
                if isTemporaryPage(tabID) {
                    // Peek and mini windows aren't in the sidebar, but their pages are history.
                    if let profileID = space?.profileID {
                        try await store.history.recordVisit(to: url, title: title, profileID: profileID, at: now())
                    }
                    return
                }
                let previous = try await store.tab(id: tabID)
                try await store.updateTab(id: tabID, url: url, title: title)
                onTabEvent?(.changed(tabID))
                guard let previous,
                      let profileID = spaces.first(where: { $0.id == previous.spaceID })?.profileID else { return }
                if previous.url != url || !hasRecordedVisit.contains(tabID) {
                    hasRecordedVisit.insert(tabID)
                    try await store.history.recordVisit(to: url, title: title, profileID: profileID, at: now())
                } else {
                    try await store.history.updateTitle(title, for: url, profileID: profileID)
                }
            } catch TabStoreError.tabNotFound {
                // The tab closed before its last page change was saved.
            } catch {
                logger.error("Couldn't save page change: \(error)")
            }
        }
    }

    func report(_ error: Error, _ message: String) {
        logger.error("\(message) \(error)")
        alertMessage = message
    }
}
