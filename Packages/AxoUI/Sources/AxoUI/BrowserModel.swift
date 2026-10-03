import AppKit
import AxoCore
import AxoWeb
import Foundation
import Observation
import os

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
    /// The tab shown in the window.
    public private(set) var selectedTabID: AxoCore.Tab.ID?
    /// The live state of the selected tab's web view.
    public private(set) var selectedPage: WebTabState?
    /// Whether the address field is composing a new tab rather than editing the selected one.
    public private(set) var isComposingNewTab = false
    /// Incremented to ask the address field to take focus.
    public private(set) var addressFocusRequest = 0
    /// A problem worth telling the user about, such as the database failing to open.
    public var alertMessage: String?
    /// Whether the downloads list is open.
    public var isShowingDownloads = false
    /// Whether the archived tabs list is open.
    public var isShowingArchive = false
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

    @ObservationIgnored private let store: TabStore
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var spacesObservationTask: Task<Void, Never>?
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
    @ObservationIgnored private let prompts = PagePromptQueue()
    /// Hosts whose saved icon was already looked up, so each is read from the database once.
    @ObservationIgnored private var lookedUpFaviconHosts: Set<String> = []
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
        pool.onPermissionRequest = { [weak self] request in
            await self?.prompts.ask(request) ?? .deny
        }
        pool.onJavaScriptDialog = { [weak self] dialog in
            await self?.prompts.ask(dialog) ?? .cancelled
        }
        pool.onFileSelection = { [weak self] request in
            await self?.chooseFiles(for: request)
        }
        pool.onOpenInNewTab = { [weak self] url, sourceID in
            guard let self else { return }
            Task { await self.openTab(url: url, at: .after(sourceID)) }
        }
    }

    isolated deinit {
        observationTask?.cancel()
        spacesObservationTask?.cancel()
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
            observeSpaces()
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
        do {
            let closedTabs = try await store.deleteSpace(id: id)
            for tabID in closedTabs {
                prompts.dismissAll(from: tabID)
                pool.discard(tabID)
            }
            selectedTabBySpace[id] = nil
            spaces = try await store.spaces()
            if space?.id == id {
                try await show(spaces[min(index, spaces.count - 1)])
            }
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
        let remembered = selectedTabBySpace[target.id].flatMap { id in tabs.first { $0.id == id }?.id }
        select(remembered ?? tabs.first?.id)
        observeTabs(in: target.id)
        await loadSavedFavicons()
        onSpaceChange?(target.id)
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

    private func observeSpaces() {
        spacesObservationTask?.cancel()
        let observation = store.observeSpaces()
        spacesObservationTask = Task { [weak self] in
            do {
                for try await spaces in observation {
                    self?.spaces = spaces
                }
            } catch {
                self?.logger.error("Space observation failed: \(error)")
            }
        }
    }

    // MARK: Selection

    /// Shows the tab with `id`, or nothing if `id` is `nil`.
    public func select(_ id: AxoCore.Tab.ID?) {
        isComposingNewTab = false
        if id != selectedTabID, isFindBarVisible {
            closeFindBar()
        }
        // Both the tab being left and the one being shown were just in use.
        markActive([selectedTabID, id].compactMap { $0 })
        selectedTabID = id
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

    /// Starts composing a new tab: the address field clears and takes focus.
    public func beginNewTab() {
        isComposingNewTab = true
        focusAddressField()
    }

    /// Asks the address field to take focus.
    public func focusAddressField() {
        addressFocusRequest += 1
    }

    /// Stops composing a new tab without opening one.
    public func cancelNewTab() {
        isComposingNewTab = false
    }

    /// Handles text submitted from the address field: opens a new tab when composing one or when
    /// no tab is selected, and otherwise loads it in the selected tab.
    public func submitAddress(_ text: String) async {
        guard let url = AddressInput.url(from: text) else { return }
        if isComposingNewTab || selectedTabID == nil {
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
        prompts.dismissAll(from: id)
        pool.discard(id)
        do {
            if tab.isPinned {
                try await store.resetPinnedTab(id: id)
            } else {
                try await store.archiveTab(id: id, at: now())
            }
            tabs = try await store.tabs(in: space.id)
        } catch {
            report(error, "Axo couldn't close the tab.")
            return
        }
        guard selectedTabID == id else { return }
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
            select(id)
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

    /// Moves a tab within its section after a drag in the sidebar, using `List.onMove` indices
    /// relative to that section.
    public func moveTabs(fromOffsets source: IndexSet, toOffset destination: Int, pinned: Bool) async {
        let section = pinned ? pinnedTabs : unpinnedTabs
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

    // MARK: Find and print

    /// Shows the find bar (or focuses it if it's already showing).
    public func showFindBar() {
        guard selectedTabID != nil else { return }
        isFindBarVisible = true
        findFocusRequest += 1
    }

    /// Hides the find bar and clears its highlight from the page.
    public func closeFindBar() {
        isFindBarVisible = false
        findHasNoMatches = false
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
                for try await tabs in observation {
                    // Ignore a list that arrives after the window switched to another Space.
                    guard self?.space?.id == spaceID else { return }
                    self?.tabs = tabs
                    await self?.loadSavedFavicons()
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

    private func persistPageChange(tabID: AxoCore.Tab.ID, url: URL, title: String) {
        Task {
            do {
                try await store.updateTab(id: tabID, url: url, title: title)
            } catch TabStoreError.tabNotFound {
                // The tab closed before its last page change was saved.
            } catch {
                logger.error("Couldn't save page change: \(error)")
            }
        }
    }

    private func report(_ error: Error, _ message: String) {
        logger.error("\(message) \(error)")
        alertMessage = message
    }
}
