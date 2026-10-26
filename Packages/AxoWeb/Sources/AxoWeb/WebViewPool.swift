import AxoCore
import Foundation
#if os(macOS)
import AppKit
#endif

/// Owns every page in Axo and decides when each one lives or hibernates.
///
/// SwiftUI never creates or destroys pages; it asks the pool for a tab's page and mounts its view
/// with ``WebViewHost``. That keeps pages alive across view updates. The pool's ``engine`` makes
/// the pages (Chromium on the Mac, WebKit on iPhone and iPad; see `docs/chromium-engine.md`) and keeps each profile's website data
/// separate, so cookies and storage never leak between profiles.
///
/// A tab is in one of three states:
/// - **Live:** it has a page. Visible tabs are always live.
/// - **Hibernated:** its page was discarded to free memory, but its back and forward history
///   (``EnginePage/interactionState``) is kept so it restores instantly when shown again.
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

    /// The engine that makes the pool's pages.
    public let engine: any WebEngine

    /// Every download started from the pool's pages.
    public let downloads: DownloadManager

    /// Called when a live tab's URL or title changes, so the app can persist it with `TabStore`.
    public var onPageChange: ((Tab.ID, URL, String) -> Void)?

    /// Called with a page's icon as a normalized 64 px PNG after it loads, so the app can save it
    /// for the page's host. The URL is the page the icon belongs to.
    public var onFaviconChange: ((Tab.ID, URL, Data) -> Void)?

    /// Asked when a page wants the camera, microphone, or location. Return the person's answer.
    /// Requests are denied when this is `nil`. Each answer is remembered for the profile, origin,
    /// and kind until the pool is deallocated (that is, until Axo quits).
    public var onPermissionRequest: ((PermissionRequest) async -> PermissionDecision)?

    /// Asked when a page calls `alert()`, `confirm()`, or `prompt()`. Return the person's answer.
    /// Dialogs are cancelled when this is `nil`.
    public var onJavaScriptDialog: ((JavaScriptDialog) async -> JavaScriptDialogResult)?

    /// Asked when a page's file input wants files. Return the chosen files, or `nil` to cancel.
    /// File selection is cancelled when this is `nil`.
    public var onFileSelection: ((FileSelectionRequest) async -> [URL]?)?

    /// Whether visible pages report their usage to Screen Time. Turn it off in tests, so test
    /// pages never count as the person's usage. Screen Time still blocks sites over their limit.
    public var reportsScreenTimeUsage = true

    /// Applies per-site custom CSS and JavaScript to every page: new ones, and live ones from
    /// their next page load (reload a page to see changes right away). Turned-off customizations
    /// are skipped.
    public func setSiteCustomizations(_ customizations: [SiteCustomization]) {
        engine.setSiteCustomizations(customizations)
    }

    /// Asked when the person clicks a link in a tab's page (main frame only, not downloads).
    /// Return `true` to handle the click yourself, for example to open the link in Peek; the page
    /// then doesn't navigate. Links that target a new window go to ``onOpenInNewTab`` instead.
    public var onLinkClick: ((LinkClick) -> Bool)?

    /// Called when a tab's page takes keyboard focus, for example when it's clicked. With
    /// several pages on screen (a split view), this says which one the person is using.
    public var onWebViewFocus: ((Tab.ID) -> Void)?

    /// Called when a page asks to open a link in a new tab or window (for example
    /// `target="_blank"` or `window.open`). The second argument is the tab that asked.
    public var onOpenInNewTab: ((URL, Tab.ID) -> Void)?
    /// Called when a page opened another that's already loading and connected to it (Chromium's
    /// `window.open`), with the tab that opened it. Without a handler, the new page closes and
    /// its URL goes to ``onOpenInNewTab``.
    public var onPageOpened: ((OpenedPage, Tab.ID) -> Void)?
    /// Called when a tab's page asks to fill the screen, or to stop (Chromium's
    /// `element.requestFullscreen()`).
    public var onPageFullscreen: ((Tab.ID, Bool) -> Void)?

    /// Called when a page is right-clicked, for engines that leave the menu to Axo (Chromium).
    /// Show the menu and return `true`; without a handler, no menu shows.
    public var onContextMenu: ((any PageContextMenu, Tab.ID) -> Bool)?

    /// Called when the engine opened a page on its own (an extension's `chrome.tabs.create`).
    /// Make a tab for it and call ``adopt(_:as:profileID:)``; without a handler the page closes.
    public var onEngineOpenedPage: ((EngineOpenedPage) -> Void)?

    /// Called when the engine opened a page in a popup window of its own (an extension's
    /// `chrome.windows.create`). Show it in a small window and call ``adopt(_:as:profileID:)``;
    /// without a handler the page closes. ``onEngineClosedTab`` reports when the engine closes it.
    public var onEnginePopupWindow: ((EnginePopupWindow) -> Void)?

    /// Called when the engine closed a tab's page on its own (an extension's `chrome.tabs.remove`).
    /// The page is already gone; close the tab.
    public var onEngineClosedTab: ((Tab.ID) -> Void)?

    /// Called when the engine selected a tab on its own (an extension's `chrome.tabs.update`).
    public var onEngineActivatedTab: ((Tab.ID) -> Void)?

    /// The tabs each profile's window last showed, as sent to ``setWindowTabs(_:selected:profileID:)``.
    private var windowTabs: [Profile.ID: [Tab.ID]] = [:]
    /// Pages the engine opened that are live under their tab ID but not yet adopted into the
    /// sidebar, with their profile. They stay in the engine's window meanwhile.
    private var awaitingAdoption: [Tab.ID: Profile.ID] = [:]

    private let now: () -> Date
    private var live: [Tab.ID: LiveTab] = [:]
    private var hibernated: [Tab.ID: HibernatedTab] = [:]
    private var visibleCounts: [Tab.ID: Int] = [:]
    /// Saves permission answers across launches. Set by the app. When it's `nil`, answers are
    /// remembered in memory until Axo quits.
    public var permissionStore: (any PermissionDecisionStore)?
    /// Permission answers for this session, by profile, origin, and kind, when there's no
    /// ``permissionStore``.
    private var permissionDecisions: [PermissionKey: PermissionDecision] = [:]
    /// Normalized icons by icon URL, so tabs on the same site don't refetch them.
    private var faviconCache: [URL: Data] = [:]
    private var hibernationTask: Task<Void, Never>?

    /// Creates a pool.
    ///
    /// - Parameters:
    ///   - engine: Makes the pool's pages and owns each profile's website data.
    ///   - configuration: Hibernation settings.
    ///   - downloads: Tracks downloads and decides where files go. Defaults to the user's
    ///     Downloads folder.
    ///   - now: The current time. Override in tests.
    public init(
        engine: any WebEngine,
        configuration: Configuration = Configuration(),
        downloads: DownloadManager = DownloadManager(),
        now: @escaping () -> Date = Date.init
    ) {
        self.engine = engine
        self.configuration = configuration
        self.downloads = downloads
        self.now = now
        engine.delegate = self
    }

    isolated deinit {
        hibernationTask?.cancel()
    }

    // MARK: Pages

    /// Returns the tab's page, creating or waking it if needed.
    ///
    /// A new page loads `tab.url`; a hibernated one restores its history instead.
    ///
    /// - Parameters:
    ///   - tab: The tab to show.
    ///   - profileID: The profile of the tab's Space, which decides its website data.
    @discardableResult
    public func page(for tab: Tab, profileID: Profile.ID) -> any EnginePage {
        if let existing = live[tab.id] {
            existing.lastUsed = now()
            return existing.page
        }

        let page = engine.makePage(profileID: profileID)
        let liveTab = LiveTab(tabID: tab.id, profileID: profileID, page: page, pool: self, lastUsed: now())
        live[tab.id] = liveTab

        if let saved = hibernated.removeValue(forKey: tab.id), let interactionState = saved.interactionState {
            liveTab.state.restoringSnapshot = saved.snapshot.flatMap(PlatformImage.init(data:))
            page.restore(interactionState: interactionState)
        } else {
            page.load(tab.url)
        }
        return page
    }

    /// Makes `page`, which the engine opened on its own, the live page of `tab`, without
    /// loading anything. Call it from ``onEngineOpenedPage`` once the tab exists.
    public func adopt(_ page: any EnginePage, as tab: Tab, profileID: Profile.ID) {
        awaitingAdoption[tab.id] = nil
        hibernated[tab.id] = nil
        if let existing = live[tab.id] {
            // A page the engine opened is already live under its tab's ID.
            if existing.page === page { return }
            existing.tearDown()
        }
        // The page live under another ID (adopted under a new one) moves, without closing.
        for (otherID, other) in live where other.page === page {
            live[otherID] = nil
            awaitingAdoption[otherID] = nil
        }
        live[tab.id] = LiveTab(tabID: tab.id, profileID: profileID, page: page, pool: self, lastUsed: now())
    }

    /// Whether `tabID` is a page the engine opened that isn't in the sidebar yet.
    public func isAwaitingAdoption(_ tabID: Tab.ID) -> Bool {
        awaitingAdoption[tabID] != nil
    }

    /// Tells the engine which tabs a window shows, in sidebar order, and which is selected: the
    /// Space's tabs. Only live tabs are passed on; the others have no page. Engines with a window
    /// model (Chromium's extension APIs) show them as that window's tabs.
    public func setWindowTabs(_ tabIDs: [Tab.ID], selected: Tab.ID?, profileID: Profile.ID) {
        // Pages waiting to join the sidebar stay in the window until they do.
        let waiting = awaitingAdoption.filter { $0.value == profileID && !tabIDs.contains($0.key) }.keys.sorted { $0.uuidString < $1.uuidString }
        let liveIDs = (tabIDs + waiting).filter { live[$0] != nil }
        windowTabs[profileID] = liveIDs
        engine.setWindowPages(
            liveIDs.compactMap { live[$0]?.page },
            active: selected.flatMap { live[$0]?.page },
            profileID: profileID
        )
    }

    /// The tab whose live page is `page`.
    private func tabID(of page: any EnginePage) -> Tab.ID? {
        live.first { $0.value.page === page }?.key
    }

    /// The tab's page if it is live, without creating one.
    public func livePage(for tabID: Tab.ID) -> (any EnginePage)? {
        live[tabID]?.page
    }

    /// The observable state of the tab's page, or `nil` if it isn't live.
    public func state(for tabID: Tab.ID) -> WebTabState? {
        live[tabID]?.state
    }

    /// Whether the tab currently has a page.
    public func isLive(_ tabID: Tab.ID) -> Bool {
        live[tabID] != nil
    }

    /// Whether the tab's page was discarded and its history saved for later.
    public func isHibernated(_ tabID: Tab.ID) -> Bool {
        hibernated[tabID] != nil
    }

    /// The JPEG snapshot taken when the tab hibernated, or `nil` if it isn't hibernated or
    /// the engine couldn't capture one.
    public func snapshot(for tabID: Tab.ID) -> Data? {
        hibernated[tabID]?.snapshot
    }

    /// The IDs of every tab with a live page.
    public var liveTabIDs: Set<Tab.ID> {
        Set(live.keys)
    }

    // MARK: Navigation

    /// Loads `url` in the tab's live page. Does nothing if the tab isn't live.
    public func load(_ url: URL, in tabID: Tab.ID) {
        live[tabID]?.page.load(url)
    }

    /// Downloads `url` using the tab's page (and so its profile's cookies). Does nothing if the
    /// tab isn't live.
    public func startDownload(_ url: URL, in tabID: Tab.ID) {
        live[tabID]?.page.startDownload(url)
    }

    /// Goes back in the tab's history.
    public func goBack(in tabID: Tab.ID) {
        live[tabID]?.page.goBack()
    }

    /// Goes forward in the tab's history.
    public func goForward(in tabID: Tab.ID) {
        live[tabID]?.page.goForward()
    }

    /// Reloads the tab's current page.
    public func reload(_ tabID: Tab.ID) {
        live[tabID]?.page.reload()
    }

    /// Stops loading the tab's current page.
    public func stopLoading(_ tabID: Tab.ID) {
        live[tabID]?.page.stopLoading()
    }

    // MARK: Find and print

    /// Finds the next (or previous) occurrence of `text` in the tab's page, highlights it, and
    /// scrolls to it. Matching ignores case and wraps around the page.
    ///
    /// - Returns: Whether a match was found. `false` if the tab isn't live or `text` is empty.
    public func find(_ text: String, in tabID: Tab.ID, backwards: Bool = false) async -> Bool {
        guard !text.isEmpty, let page = live[tabID]?.page else { return false }
        return await page.find(text, backwards: backwards)
    }

    /// Removes the highlight a find left on the tab's page.
    public func clearFind(in tabID: Tab.ID) async {
        guard let page = live[tabID]?.page else { return }
        // Find marks its match as the page selection. Clearing it from Axo's own isolated world
        // doesn't run or expose anything to the page's scripts.
        _ = try? await page.callJavaScript("window.getSelection()?.removeAllRanges()", arguments: [:], in: "AxoFind")
    }

    #if os(macOS)
    /// A print operation for the tab's page, titled with the page title, or `nil` if the tab
    /// isn't live. Run it modally for the tab's window to show the print sheet.
    public func printOperation(for tabID: Tab.ID) -> NSPrintOperation? {
        guard let page = live[tabID]?.page else { return nil }
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        let operation = page.printOperation(with: printInfo)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.jobTitle = page.title.isEmpty ? (page.url?.host() ?? "Page") : page.title
        return operation
    }
    #endif

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

    /// Snapshots the page, then discards the tab's page and keeps its history so it can
    /// wake later.
    ///
    /// Does nothing if the tab isn't live or is visible. If the tab is shown, closed, or
    /// hibernated again while the snapshot is taken, the page is kept.
    ///
    /// - Returns: Whether the tab hibernated.
    @discardableResult
    public func hibernate(_ tabID: Tab.ID) async -> Bool {
        guard !isVisible(tabID), let liveTab = live[tabID] else { return false }
        let snapshot = await PageSnapshot.capture(liveTab.page)
        guard live[tabID] === liveTab, !isVisible(tabID) else { return false }
        live[tabID] = nil
        hibernated[tabID] = HibernatedTab(interactionState: liveTab.page.interactionState, snapshot: snapshot)
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

    /// Takes a tab's page out of full screen (it asked for it; the person left another way).
    public func exitFullscreen(_ tabID: Tab.ID) {
        live[tabID]?.page.exitFullscreen()
    }

    /// Forgets a tab entirely, for example when it closes. Its page and saved history are
    /// discarded.
    public func discard(_ tabID: Tab.ID) {
        awaitingAdoption[tabID] = nil
        hibernated[tabID] = nil
        visibleCounts[tabID] = nil
        live.removeValue(forKey: tabID)?.tearDown()
    }

    // MARK: Permissions

    /// Returns the remembered answer for this profile, origin, and kind, or asks the app and
    /// remembers its answer for the rest of the session.
    func decidePermission(
        _ kind: PermissionKind,
        origin: PageOrigin,
        tabID: Tab.ID,
        profileID: Profile.ID
    ) async -> PermissionDecision {
        let key = PermissionKey(profileID: profileID, origin: origin, kind: kind)
        if let permissionStore {
            if let saved = await permissionStore.savedDecision(for: kind, origin: origin, profileID: profileID) {
                return saved
            }
        } else if let remembered = permissionDecisions[key] {
            return remembered
        }
        guard let handler = onPermissionRequest else { return .deny }
        let decision = await handler(PermissionRequest(tabID: tabID, origin: origin, kind: kind))
        if let permissionStore {
            await permissionStore.saveDecision(decision, for: kind, origin: origin, profileID: profileID)
        } else {
            permissionDecisions[key] = decision
        }
        return decision
    }

    /// The remembered answer for a profile, origin, and kind, if any.
    public func rememberedPermission(_ kind: PermissionKind, origin: PageOrigin, profileID: Profile.ID) -> PermissionDecision? {
        permissionDecisions[PermissionKey(profileID: profileID, origin: origin, kind: kind)]
    }

    /// Forgets every remembered permission answer, so pages ask again.
    public func forgetPermissionDecisions() {
        permissionDecisions.removeAll()
    }

    // MARK: Favicons

    /// Finds, fetches, and reports the icon of the tab's current page.
    func loadFavicon(for tabID: Tab.ID) {
        guard let liveTab = live[tabID], let pageURL = liveTab.page.url else { return }
        Task { [weak self] in
            let candidates = await FaviconLoader.candidates(in: liveTab.page)
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

    /// Removes a profile's cookies, caches, and other website data, signing it out of sites.
    /// Its open pages keep what they already loaded.
    public func clearWebsiteData(for profileID: Profile.ID) async {
        await engine.clearWebsiteData(for: profileID)
    }

    /// Deletes a deleted profile's website data for good, after discarding any page still
    /// using it.
    public func removeWebsiteData(for profileID: Profile.ID) async {
        for (tabID, liveTab) in live where liveTab.profileID == profileID {
            discard(tabID)
        }
        try? await engine.removeWebsiteData(for: profileID)
    }
}

// MARK: - Engine events

extension WebViewPool: WebEngineDelegate {
    public func engine(_ engine: any WebEngine, didOpen page: any EnginePage, profileID: Profile.ID, at index: Int) {
        guard let handler = onEngineOpenedPage else {
            page.close()
            return
        }
        let window = windowTabs[profileID] ?? []
        let previous = index > 0 && index - 1 < window.count ? window[index - 1] : nil
        // Live under its tab's ID at once, so the engine activating it next (as it does for a new
        // active tab) finds it.
        let tabID = Tab.ID()
        live[tabID] = LiveTab(tabID: tabID, profileID: profileID, page: page, pool: self, lastUsed: now())
        awaitingAdoption[tabID] = profileID
        handler(EngineOpenedPage(page: page, profileID: profileID, after: previous, tabID: tabID))
    }

    public func engine(_ engine: any WebEngine, didClose page: any EnginePage) {
        guard let tabID = tabID(of: page) else { return }
        // The engine already closed the page; forget it without closing it again.
        awaitingAdoption[tabID] = nil
        live[tabID] = nil
        hibernated[tabID] = nil
        visibleCounts[tabID] = nil
        onEngineClosedTab?(tabID)
    }

    public func engine(_ engine: any WebEngine, didActivate page: any EnginePage) {
        guard let tabID = tabID(of: page) else { return }
        onEngineActivatedTab?(tabID)
    }

    public func engine(_ engine: any WebEngine, didOpenPopupWindowWith page: any EnginePage, size: CGSize, profileID: Profile.ID) {
        guard let handler = onEnginePopupWindow else {
            page.close()
            return
        }
        handler(EnginePopupWindow(page: page, profileID: profileID, size: size))
    }
}

/// A popup window the engine opened on its own, for ``WebViewPool/onEnginePopupWindow``.
public struct EnginePopupWindow {
    /// The window's page, already loading. Pass it to ``WebViewPool/adopt(_:as:profileID:)``.
    public let page: any EnginePage
    /// The profile it opened in.
    public let profileID: Profile.ID
    /// The size the window asked for, in points, or zero when it didn't say.
    public let size: CGSize

    /// Creates the description of a popup window.
    public init(page: any EnginePage, profileID: Profile.ID, size: CGSize) {
        self.page = page
        self.profileID = profileID
        self.size = size
    }
}

/// A page the engine opened on its own, for ``WebViewPool/onEngineOpenedPage``.
public struct EngineOpenedPage {
    /// The page, already loading. Pass it to ``WebViewPool/adopt(_:as:profileID:)``.
    public let page: any EnginePage
    /// The profile whose window it opened in.
    public let profileID: Profile.ID
    /// The tab before it in the window, if any, so it can go next to it in the sidebar.
    public let after: Tab.ID?
    /// The ID its sidebar tab must have: the page is already live under it. If it doesn't join
    /// the sidebar, ``WebViewPool/discard(_:)`` it.
    public let tabID: Tab.ID

    /// Creates the description of an opened page.
    public init(page: any EnginePage, profileID: Profile.ID, after: Tab.ID?, tabID: Tab.ID = Tab.ID()) {
        self.page = page
        self.profileID = profileID
        self.after = after
        self.tabID = tabID
    }
}

/// Identifies a remembered permission answer.
private struct PermissionKey: Hashable {
    var profileID: Profile.ID
    var origin: PageOrigin
    var kind: PermissionKind
}

/// What the pool keeps for a hibernated tab.
private struct HibernatedTab {
    /// The page's opaque back and forward state, from ``EnginePage/interactionState``.
    var interactionState: Any?
    /// A JPEG of the page when it hibernated.
    var snapshot: Data?
}

/// A link the person clicked in a tab's page.
public struct LinkClick: Sendable {
    /// The tab whose page has the link.
    public var tabID: Tab.ID
    /// Where the link goes.
    public var url: URL
    /// The page the link is on, if it has finished loading one.
    public var sourceURL: URL?
    /// Keys held while clicking, such as Command.
    public var modifiers: LinkModifiers

    /// Creates a click.
    public init(tabID: Tab.ID, url: URL, sourceURL: URL?, modifiers: LinkModifiers = []) {
        self.tabID = tabID
        self.url = url
        self.sourceURL = sourceURL
        self.modifiers = modifiers
    }

    /// Whether the link leads to another site than the page it's on: a different host (ignoring
    /// a leading "www."), or any web link from a page without a host.
    public var leavesSite: Bool {
        func site(_ url: URL?) -> String? {
            guard let host = url?.host()?.lowercased(), !host.isEmpty else { return nil }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return site(url) != site(sourceURL)
    }
}
