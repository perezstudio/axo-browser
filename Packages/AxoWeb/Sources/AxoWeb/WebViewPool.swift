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

    /// Called when a live tab's URL or title changes, so the app can persist it with `TabStore`.
    public var onPageChange: ((Tab.ID, URL, String) -> Void)?

    /// Called when a page asks to open a link in a new tab or window (for example
    /// `target="_blank"` or `window.open`). The second argument is the tab that asked.
    public var onOpenInNewTab: ((URL, Tab.ID) -> Void)?

    private let makeDataStore: (Profile.ID) -> WKWebsiteDataStore
    private let now: () -> Date
    private var dataStores: [Profile.ID: WKWebsiteDataStore] = [:]
    private var live: [Tab.ID: LiveTab] = [:]
    private var hibernated: [Tab.ID: HibernatedTab] = [:]
    private var visibleCounts: [Tab.ID: Int] = [:]
    private var hibernationTask: Task<Void, Never>?

    /// Creates a pool.
    ///
    /// - Parameters:
    ///   - configuration: Hibernation settings.
    ///   - makeDataStore: Returns the website data store for a profile. Called once per profile.
    ///     Defaults to a persistent `WKWebsiteDataStore(forIdentifier:)` keyed by the profile ID.
    ///   - now: The current time. Override in tests.
    public init(
        configuration: Configuration = Configuration(),
        makeDataStore: @escaping (Profile.ID) -> WKWebsiteDataStore = { WKWebsiteDataStore(forIdentifier: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.configuration = configuration
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
        liveTab.onPageChange = { [weak self] url, title in self?.onPageChange?(tab.id, url, title) }
        live[tab.id] = liveTab

        if let saved = hibernated.removeValue(forKey: tab.id), let interactionState = saved.interactionState {
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

    /// Discards the tab's web view and keeps its history so it can wake later.
    ///
    /// Does nothing if the tab isn't live or is visible.
    public func hibernate(_ tabID: Tab.ID) {
        guard !isVisible(tabID), let liveTab = live.removeValue(forKey: tabID) else { return }
        hibernated[tabID] = HibernatedTab(interactionState: liveTab.webView.interactionState)
        liveTab.tearDown()
    }

    /// Hibernates every hidden tab that has been idle longer than the timeout.
    ///
    /// - Returns: The IDs of the tabs that hibernated.
    @discardableResult
    public func hibernateIdleTabs() -> Set<Tab.ID> {
        let cutoff = now().addingTimeInterval(-configuration.hibernationTimeout)
        let idle = live.values
            .filter { !isVisible($0.tabID) && $0.lastUsed <= cutoff }
            .map(\.tabID)
        for tabID in idle {
            hibernate(tabID)
        }
        return Set(idle)
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
                self.hibernateIdleTabs()
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
}
