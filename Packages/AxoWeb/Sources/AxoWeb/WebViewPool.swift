import AxoCore
import Foundation
import WebKit

/// Owns every `WKWebView` in Axo and decides when each one lives or hibernates.
///
/// SwiftUI never creates or destroys web views; it asks the pool for a tab's web view and mounts
/// it with ``WebViewHost``. That keeps pages alive across view updates. Each profile gets its own
/// website data store, so cookies and storage never leak between profiles.
///
/// A tab is in one of three states:
/// - **Live:** it has a web view. Visible tabs are always live.
/// - **Hibernated:** its web view was discarded to free memory, but its back and forward history
///   (`interactionState`) is kept so it restores instantly when shown again.
/// - **Unloaded:** the pool knows nothing about it yet; it loads from the tab's URL when shown.
@MainActor
public final class WebViewPool {
    /// Tuning for the pool.
    public struct Configuration: Sendable {
        /// How long a hidden tab may stay live before it hibernates. Defaults to 30 minutes.
        public var hibernationTimeout: TimeInterval
        /// How often the pool checks for idle tabs once ``startHibernationTimer()`` runs.
        public var hibernationCheckInterval: Duration

        /// Creates a configuration.
        public init(hibernationTimeout: TimeInterval = 30 * 60, hibernationCheckInterval: Duration = .seconds(60)) {
            self.hibernationTimeout = hibernationTimeout
            self.hibernationCheckInterval = hibernationCheckInterval
        }
    }

    /// The pool's settings.
    public var configuration: Configuration

    /// Every download started from the pool's web views.
    public let downloads: DownloadManager

    /// Called when a live tab's URL or title changes, so the app can persist it with `TabStore`.
    public var onPageChange: ((Tab.ID, URL, String) -> Void)?

    /// Called with a page's icon as a normalized 64 px PNG after it loads, so the app can save it
    /// for the page's host. The URL is the page the icon belongs to.
    public var onFaviconChange: ((Tab.ID, URL, Data) -> Void)?

    /// Called when a page asks to open a link in a new tab or window (for example
    /// `target="_blank"` or `window.open`). The second argument is the tab that asked.
    public var onOpenInNewTab: ((URL, Tab.ID) -> Void)?

    private let makeDataStore: (Profile.ID) -> WKWebsiteDataStore
    private let now: () -> Date
    private var dataStores: [Profile.ID: WKWebsiteDataStore] = [:]
    private var live: [Tab.ID: LiveTab] = [:]
    private var hibernated: [Tab.ID: HibernatedTab] = [:]
    private var visibleCounts: [Tab.ID: Int] = [:]
    /// Normalized icons by icon URL, so tabs on the same site don't refetch them.
    private var faviconCache: [URL: Data] = [:]
    private var hibernationTask: Task<Void, Never>?

    /// Creates a pool.
    ///
    /// - Parameters:
    ///   - configuration: Hibernation settings.
    ///   - makeDataStore: Returns the website data store for a profile. Called once per profile.
    ///     Defaults to a persistent `WKWebsiteDataStore(forIdentifier:)` keyed by the profile ID.
    ///   - downloads: Tracks downloads and decides where files go. Defaults to the user's
    ///     Downloads folder.
    ///   - now: The current time. Override in tests.
    public init(
        configuration: Configuration = Configuration(),
        makeDataStore: @escaping (Profile.ID) -> WKWebsiteDataStore = { WKWebsiteDataStore(forIdentifier: $0) },
        downloads: DownloadManager = DownloadManager(),
        now: @escaping () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.downloads = downloads
        self.makeDataStore = makeDataStore
        self.now = now
    }

    isolated deinit {
        hibernationTask?.cancel()
    }

    // MARK: Web views

    /// Returns the tab's web view, creating or waking it if needed.
    ///
    /// A new web view loads `tab.url`; a hibernated one restores its history instead.
    ///
    /// - Parameters:
    ///   - tab: The tab to show.
    ///   - profileID: The profile of the tab's Space, which decides its website data store.
    public func webView(for tab: Tab, profileID: Profile.ID) -> WKWebView {
        if let existing = live[tab.id] {
            existing.lastUsed = now()
            return existing.webView
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore(for: profileID)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true

        let liveTab = LiveTab(tabID: tab.id, profileID: profileID, webView: webView, lastUsed: now())
        liveTab.delegate.onOpenInNewTab = { [weak self] url in self?.onOpenInNewTab?(url, tab.id) }
        liveTab.delegate.onDownload = { [weak self] download in self?.downloads.track(download, sourceTabID: tab.id) }
        liveTab.onPageChange = { [weak self] url, title in self?.onPageChange?(tab.id, url, title) }
        liveTab.onLoadFinished = { [weak self] in self?.loadFavicon(for: tab.id) }
        live[tab.id] = liveTab

        if let saved = hibernated.removeValue(forKey: tab.id), let interactionState = saved.interactionState {
            liveTab.state.restoringSnapshot = saved.snapshot.flatMap(NSImage.init(data:))
            webView.interactionState = interactionState
        } else {
            Self.load(tab.url, in: webView)
        }
        return webView
    }

    /// The tab's web view if it is live, without creating one.
    public func liveWebView(for tabID: Tab.ID) -> WKWebView? {
        live[tabID]?.webView
    }

    /// The observable state of the tab's web view, or `nil` if it isn't live.
    public func state(for tabID: Tab.ID) -> WebTabState? {
        live[tabID]?.state
    }

    /// Whether the tab currently has a web view.
    public func isLive(_ tabID: Tab.ID) -> Bool {
        live[tabID] != nil
    }

    /// Whether the tab's web view was discarded and its history saved for later.
    public func isHibernated(_ tabID: Tab.ID) -> Bool {
        hibernated[tabID] != nil
    }

    /// The JPEG snapshot taken when the tab hibernated, or `nil` if it isn't hibernated or
    /// WebKit couldn't capture one.
    public func snapshot(for tabID: Tab.ID) -> Data? {
        hibernated[tabID]?.snapshot
    }

    /// The IDs of every tab with a live web view.
    public var liveTabIDs: Set<Tab.ID> {
        Set(live.keys)
    }

    // MARK: Navigation

    /// Loads `url` in the tab's live web view. Does nothing if the tab isn't live.
    public func load(_ url: URL, in tabID: Tab.ID) {
        guard let webView = live[tabID]?.webView else { return }
        Self.load(url, in: webView)
    }

    /// Downloads `url` using the tab's web view (and so its profile's cookies). Does nothing if
    /// the tab isn't live.
    public func startDownload(_ url: URL, in tabID: Tab.ID) {
        guard let webView = live[tabID]?.webView else { return }
        // Track inside the completion handler: WebKit only guarantees delivering events to a
        // delegate set there, so tracking after an `await` could miss an early failure.
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            self?.downloads.track(download, sourceTabID: tabID)
        }
    }

    /// Goes back in the tab's history.
    public func goBack(in tabID: Tab.ID) {
        live[tabID]?.webView.goBack()
    }

    /// Goes forward in the tab's history.
    public func goForward(in tabID: Tab.ID) {
        live[tabID]?.webView.goForward()
    }

    /// Reloads the tab's current page.
    public func reload(_ tabID: Tab.ID) {
        live[tabID]?.webView.reload()
    }

    /// Stops loading the tab's current page.
    public func stopLoading(_ tabID: Tab.ID) {
        live[tabID]?.webView.stopLoading()
    }

    // MARK: Find and print

    /// Finds the next (or previous) occurrence of `text` in the tab's page, highlights it, and
    /// scrolls to it. Matching ignores case and wraps around the page.
    ///
    /// - Returns: Whether a match was found. `false` if the tab isn't live or `text` is empty.
    public func find(_ text: String, in tabID: Tab.ID, backwards: Bool = false) async -> Bool {
        guard !text.isEmpty, let webView = live[tabID]?.webView else { return false }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        return (try? await webView.find(text, configuration: configuration).matchFound) ?? false
    }

    /// Removes the highlight a find left on the tab's page.
    public func clearFind(in tabID: Tab.ID) async {
        guard let webView = live[tabID]?.webView else { return }
        // Find marks its match as the page selection. Clearing it from Axo's own content world
        // doesn't run or expose anything to the page's scripts.
        _ = try? await webView.callAsyncJavaScript(
            "window.getSelection()?.removeAllRanges()",
            contentWorld: .world(name: "AxoFind")
        )
    }

    /// A print operation for the tab's page, titled with the page title, or `nil` if the tab
    /// isn't live. Run it modally for the tab's window to show the print sheet.
    public func printOperation(for tabID: Tab.ID) -> NSPrintOperation? {
        guard let webView = live[tabID]?.webView else { return nil }
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.jobTitle = webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? webView.url?.host() ?? "Page"
        // WebKit's print view needs a frame, or it prints blank pages.
        operation.view?.frame = webView.bounds
        return operation
    }

    private static func load(_ url: URL, in webView: WKWebView) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    // MARK: Visibility and hibernation

    /// Marks a tab as shown on screen. Visible tabs never hibernate.
    ///
    /// Calls are counted, so a tab shown in two places stays visible until both call
    /// ``endShowing(_:)``. ``WebViewHost`` calls these for you.
    public func beginShowing(_ tabID: Tab.ID) {
        visibleCounts[tabID, default: 0] += 1
        live[tabID]?.lastUsed = now()
    }

    /// Marks a tab as no longer shown in one place. Its idle timer starts now.
    public func endShowing(_ tabID: Tab.ID) {
        guard let count = visibleCounts[tabID] else { return }
        if count <= 1 {
            visibleCounts[tabID] = nil
        } else {
            visibleCounts[tabID] = count - 1
        }
        live[tabID]?.lastUsed = now()
    }

    /// Whether the tab is shown anywhere.
    public func isVisible(_ tabID: Tab.ID) -> Bool {
        visibleCounts[tabID] != nil
    }

    /// Snapshots the page, then discards the tab's web view and keeps its history so it can
    /// wake later.
    ///
    /// Does nothing if the tab isn't live or is visible. If the tab is shown, closed, or
    /// hibernated again while the snapshot is taken, the web view is kept.
    ///
    /// - Returns: Whether the tab hibernated.
    @discardableResult
    public func hibernate(_ tabID: Tab.ID) async -> Bool {
        guard !isVisible(tabID), let liveTab = live[tabID] else { return false }
        let snapshot = await PageSnapshot.capture(liveTab.webView)
        guard live[tabID] === liveTab, !isVisible(tabID) else { return false }
        live[tabID] = nil
        hibernated[tabID] = HibernatedTab(interactionState: liveTab.webView.interactionState, snapshot: snapshot)
        liveTab.tearDown()
        return true
    }

    /// Hibernates every hidden tab that has been idle longer than the timeout.
    ///
    /// - Returns: The IDs of the tabs that hibernated.
    @discardableResult
    public func hibernateIdleTabs() async -> Set<Tab.ID> {
        let cutoff = now().addingTimeInterval(-configuration.hibernationTimeout)
        let idle = live.values
            .filter { !isVisible($0.tabID) && $0.lastUsed <= cutoff }
            .map(\.tabID)
        var hibernatedIDs: Set<Tab.ID> = []
        for tabID in idle where await hibernate(tabID) {
            hibernatedIDs.insert(tabID)
        }
        return hibernatedIDs
    }

    /// Starts checking for idle tabs every ``Configuration/hibernationCheckInterval``.
    ///
    /// Calling it again restarts the timer. The timer stops when the pool is deallocated.
    public func startHibernationTimer() {
        hibernationTask?.cancel()
        let interval = configuration.hibernationCheckInterval
        hibernationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.hibernateIdleTabs()
            }
        }
    }

    /// Stops the idle check started by ``startHibernationTimer()``.
    public func stopHibernationTimer() {
        hibernationTask?.cancel()
        hibernationTask = nil
    }

    /// Forgets a tab entirely, for example when it closes. Its web view and saved history are
    /// discarded.
    public func discard(_ tabID: Tab.ID) {
        hibernated[tabID] = nil
        visibleCounts[tabID] = nil
        live.removeValue(forKey: tabID)?.tearDown()
    }

    // MARK: Favicons

    /// Finds, fetches, and reports the icon of the tab's current page.
    private func loadFavicon(for tabID: Tab.ID) {
        guard let liveTab = live[tabID], let pageURL = liveTab.webView.url else { return }
        Task { [weak self] in
            let candidates = await FaviconLoader.candidates(in: liveTab.webView)
            guard let self, let iconURL = FaviconLoader.bestIconURL(from: candidates, pageURL: pageURL) else { return }
            let icon: Data
            if let cached = self.faviconCache[iconURL] {
                icon = cached
            } else {
                guard let downloaded = await FaviconLoader.download(iconURL),
                      let normalized = FaviconLoader.normalize(downloaded) else { return }
                self.faviconCache[iconURL] = normalized
                icon = normalized
            }
            self.onFaviconChange?(tabID, pageURL, icon)
        }
    }

    // MARK: Profiles

    /// The website data store for a profile, created on first use and shared by all its tabs.
    public func dataStore(for profileID: Profile.ID) -> WKWebsiteDataStore {
        if let store = dataStores[profileID] {
            return store
        }
        let store = makeDataStore(profileID)
        dataStores[profileID] = store
        return store
    }
}

/// What the pool keeps for a hibernated tab.
private struct HibernatedTab {
    /// The web view's opaque back and forward state.
    var interactionState: Any?
    /// A JPEG of the page when it hibernated.
    var snapshot: Data?
}
