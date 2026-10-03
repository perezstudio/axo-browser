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
    /// Site icons by lowercased host, for the tabs in the sidebar.
    public private(set) var favicons: [String: NSImage] = [:]

    /// The web view pool that owns this window's web views.
    public let pool: WebViewPool

    @ObservationIgnored private let store: TabStore
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    /// Hosts whose saved icon was already looked up, so each is read from the database once.
    @ObservationIgnored private var lookedUpFaviconHosts: Set<String> = []
    @ObservationIgnored private let logger = Logger(subsystem: "com.perezstudio.Axo", category: "BrowserModel")

    /// Creates a model. Call ``start()`` before showing it.
    public init(store: TabStore, pool: WebViewPool, alertMessage: String? = nil) {
        self.store = store
        self.pool = pool
        self.alertMessage = alertMessage
        pool.onPageChange = { [weak self] tabID, url, title in
            self?.persistPageChange(tabID: tabID, url: url, title: title)
        }
        pool.onFaviconChange = { [weak self] _, pageURL, data in
            self?.saveFavicon(data, for: pageURL)
        }
        pool.onOpenInNewTab = { [weak self] url, sourceID in
            guard let self else { return }
            Task { await self.openTab(url: url, at: .after(sourceID)) }
        }
    }

    isolated deinit {
        observationTask?.cancel()
    }

    /// The selected tab's record.
    public var selectedTab: AxoCore.Tab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// The icon for a tab's site, if Axo has one.
    public func favicon(for tab: AxoCore.Tab) -> NSImage? {
        Favicon.key(for: tab.url).flatMap { favicons[$0] }
    }

    /// Loads the first Space and its tabs, selects the first tab, and starts observing changes.
    public func start() async {
        guard space == nil else { return }
        do {
            let space = try await store.bootstrap()
            self.space = space
            tabs = try await store.tabs(in: space.id)
            select(tabs.first?.id)
            await loadSavedFavicons()
            observeTabs(in: space.id)
            pool.startHibernationTimer()
        } catch {
            report(error, "Axo couldn't load your tabs.")
        }
    }

    // MARK: Selection

    /// Shows the tab with `id`, or nothing if `id` is `nil`.
    public func select(_ id: AxoCore.Tab.ID?) {
        isComposingNewTab = false
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

    /// Closes a tab. If it was selected, the tab below it (or above, if it was last) is selected.
    public func closeTab(_ id: AxoCore.Tab.ID) async {
        guard let space else { return }
        let index = tabs.firstIndex { $0.id == id }
        pool.discard(id)
        do {
            try await store.closeTab(id: id)
            tabs = try await store.tabs(in: space.id)
        } catch {
            report(error, "Axo couldn't close the tab.")
            return
        }
        guard selectedTabID == id else { return }
        if let index, !tabs.isEmpty {
            select(tabs[min(index, tabs.count - 1)].id)
        } else {
            select(nil)
        }
    }

    /// Closes the selected tab, if any.
    public func closeSelectedTab() async {
        guard let selectedTabID else { return }
        await closeTab(selectedTabID)
    }

    /// Moves tabs after a drag in the sidebar, using `List.onMove` indices.
    public func moveTabs(fromOffsets source: IndexSet, toOffset destination: Int) async {
        guard let space, let sourceIndex = source.first, source.count == 1 else { return }
        let moving = tabs[sourceIndex]
        var remaining = tabs
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

    // MARK: Persistence

    private func observeTabs(in spaceID: Space.ID) {
        observationTask?.cancel()
        let observation = store.observeTabs(in: spaceID)
        observationTask = Task { [weak self] in
            do {
                for try await tabs in observation {
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
