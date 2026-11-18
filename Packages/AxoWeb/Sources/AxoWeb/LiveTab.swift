import AxoCore
import Foundation

/// A tab's live page and the bookkeeping that goes with it. Owned by ``WebViewPool``.
///
/// It is the page's delegate: it mirrors the page into ``state`` and passes requests on to the
/// pool's handlers, tagged with the tab.
@MainActor
final class LiveTab: EnginePageDelegate {
    let tabID: Tab.ID
    let profileID: Profile.ID
    let page: any EnginePage
    let state = WebTabState()
    var lastUsed: Date
    /// Goes up whenever the page navigates or finishes loading, so the pool knows a snapshot it
    /// took before is out of date.
    private(set) var contentVersion = 0
    /// The latest snapshot of the page (JPEG), taken when it was last hidden, and the
    /// ``contentVersion`` it shows (`nil` when it came from before the tab last hibernated).
    var snapshot: Data?
    var snapshotVersion: Int?
    /// The snapshot being taken, if any.
    var snapshotTask: Task<Void, Never>?
    /// How many times the page has finished loading. Page colors are read once per load, and a
    /// read for an earlier load is dropped.
    private(set) var finishedLoads = 0
    /// The load ``state``'s `pageColors` were fully read for, if any.
    var colorsLoad: Int?
    /// The page colors being read, if any.
    var colorsTask: Task<Void, Never>?
    /// Set while the pool discards the page, so the page's own events meanwhile aren't taken for
    /// it loading again.
    var isBeingDiscarded = false
    private weak var pool: WebViewPool?

    init(tabID: Tab.ID, profileID: Profile.ID, page: any EnginePage, pool: WebViewPool, lastUsed: Date) {
        self.tabID = tabID
        self.profileID = profileID
        self.page = page
        self.pool = pool
        self.lastUsed = lastUsed
        page.delegate = self
        // A tab muted before it hibernated, or before its page was replaced, stays muted.
        if pool.mutedTabs.contains(tabID) { page.setAudioMuted(true) }
        syncState()
        state.media = page.media
        state.problem = page.problem
        state.security = page.security
        state.loadError = page.loadError
        state.warning = page.warning
    }

    /// Copies the page's state into ``state``, reporting URL and title changes to the pool.
    private func syncState() {
        if state.isLoading != page.isLoading { state.isLoading = page.isLoading }
        if state.estimatedProgress != page.estimatedProgress { state.estimatedProgress = page.estimatedProgress }
        if state.canGoBack != page.canGoBack { state.canGoBack = page.canGoBack }
        if state.canGoForward != page.canGoForward { state.canGoForward = page.canGoForward }
        let url = page.url
        let title = page.title
        guard url != state.url || title != state.title else { return }
        if url != state.url {
            contentVersion += 1
            // A new address's security comes with it (none until its page commits), never the
            // old page's lock (#96).
            let security = page.security
            if state.security != security { state.security = security }
        }
        state.url = url
        state.title = title
        if let url {
            pool?.onPageChange?(tabID, url, title)
        }
    }

    /// Stops the page and detaches it so it can be deallocated.
    func tearDown() {
        snapshotTask?.cancel()
        snapshotTask = nil
        colorsTask?.cancel()
        page.delegate = nil
        page.close()
    }

    // MARK: EnginePageDelegate

    func pageStateDidChange(_ page: any EnginePage) {
        syncState()
        pool?.keptPageMayHaveWoken(self)
        // Engines report problems themselves; a page that moved on without a report (another
        // site after a crash) mustn't keep showing one.
        if state.problem != nil { pageProblemDidChange(page) }
    }

    func pageDidFinishLoad(_ page: any EnginePage) {
        if state.problem != nil { pageProblemDidChange(page) }
        contentVersion += 1
        state.restoringSnapshot = nil
        pool?.keptPageMayHaveWoken(self)
        pool?.loadFavicon(for: tabID)
        finishedLoads += 1
        pool?.refreshPageColors(of: self)
    }

    func pageMediaDidChange(_ page: any EnginePage) {
        let media = page.media
        guard state.media != media else { return }
        // Muting changed by the engine itself (an extension, say) lasts like the person's.
        if media.isMuted != state.media.isMuted { pool?.pageChangedMuting(media.isMuted, tabID: tabID) }
        state.media = media
    }

    func pageErrorDidChange(_ page: any EnginePage) {
        let loadError = page.loadError
        let warning = page.warning
        guard state.loadError != loadError || state.warning != warning else { return }
        state.loadError = loadError
        state.warning = warning
        pool?.onPageError?(tabID)
    }

    func pageSecurityDidChange(_ page: any EnginePage) {
        let security = page.security
        if state.security != security { state.security = security }
    }

    func pageProblemDidChange(_ page: any EnginePage) {
        let problem = page.problem
        guard state.problem != problem else { return }
        state.problem = problem
        pool?.onPageProblem?(tabID, problem)
    }

    /// Whether the page plays sound (unmuted) or uses a device, so hibernating it would end a
    /// song or a call, as Chrome never discards such tabs on its own.
    var isInUse: Bool {
        (state.media.isPlayingAudio && !state.media.isMuted) || !state.media.capture.isEmpty
    }

    func pageWantsToBeShown(_ page: any EnginePage) {
        pool?.onPageWantsToBeShown?(tabID)
    }

    func pageWasDiscarded(_ page: any EnginePage) {
        pool?.pageWasDiscarded(self)
    }

    func pageDidFailLoad(_ page: any EnginePage) {
        contentVersion += 1
        state.restoringSnapshot = nil
        // Page colors stay: a stopped or failed navigation leaves the page that was showing.
    }

    func pageDidTakeFocus(_ page: any EnginePage) {
        pool?.onWebViewFocus?(tabID)
    }

    func page(_ page: any EnginePage, shouldHandleLinkTo url: URL, modifiers: LinkModifiers) -> Bool {
        guard let handler = pool?.onLinkClick else { return false }
        return handler(LinkClick(tabID: tabID, url: url, sourceURL: page.url, modifiers: modifiers))
    }

    func page(_ page: any EnginePage, wantsToOpenInNewTab url: URL) {
        pool?.onOpenInNewTab?(url, tabID)
    }

    func page(_ page: any EnginePage, showContextMenu menu: any PageContextMenu) -> Bool {
        pool?.onContextMenu?(menu, tabID) ?? false
    }

    func page(_ page: any EnginePage, setsFullscreen fullscreen: Bool) {
        pool?.onPageFullscreen?(tabID, fullscreen)
    }

    func page(_ page: any EnginePage, hoversLinkTo url: URL?) {
        // Chromium allows addresses of up to 2 MB; the label only needs the start.
        var link = url
        if let url, url.absoluteString.utf8.count > HoveredLinks.maxLength {
            link = URL(string: String(url.absoluteString.prefix(HoveredLinks.maxLength)))
        }
        if state.hoveredLink != link { state.hoveredLink = link }
    }

    func page(_ page: any EnginePage, didOpen opened: OpenedPage) {
        guard let handler = pool?.onPageOpened else {
            opened.page.close()
            pool?.onOpenInNewTab?(opened.url, tabID)
            return
        }
        handler(opened, tabID)
    }

    func page(_ page: any EnginePage, didStartDownloadFrom sourceURL: URL?, cancel: @escaping @MainActor () -> Void) -> DownloadItem {
        guard let pool else {
            // The pool is gone, so nothing would show the download. Stop it.
            cancel()
            return DownloadManager().begin(sourceURL: sourceURL, sourceTabID: tabID) {}
        }
        return pool.downloads.begin(sourceURL: sourceURL, sourceTabID: tabID, cancel: cancel)
    }

    func page(_ page: any EnginePage, requestsPermission kind: PermissionKind, origin: PageOrigin) async -> PermissionDecision? {
        await pool?.decidePermission(kind, origin: origin, tabID: tabID, profileID: profileID)
    }

    func page(_ page: any EnginePage, showsDialog kind: JavaScriptDialog.Kind, message: String, origin: PageOrigin) async -> JavaScriptDialogResult {
        guard let handler = pool?.onJavaScriptDialog else { return .cancelled }
        return await handler(JavaScriptDialog(tabID: tabID, origin: origin, message: message, kind: kind))
    }

    func page(_ page: any EnginePage, selectsFilesAllowingMultiple allowsMultipleSelection: Bool, directories allowsDirectories: Bool) async -> [URL]? {
        guard let handler = pool?.onFileSelection else { return nil }
        return await handler(FileSelectionRequest(tabID: tabID, allowsMultipleSelection: allowsMultipleSelection, allowsDirectories: allowsDirectories))
    }

    func page(_ page: any EnginePage, showsFilePanel panel: FilePanel) async -> [URL]? {
        guard let handler = pool?.onFileSelection else { return nil }
        let chosen = await handler(FileSelectionRequest(tabID: tabID, panel: panel))
        // A picker that chooses one file or folder gets one, whatever the handler returned.
        return panel.kind == .openFiles ? chosen : chosen.map { Array($0.prefix(1)) }
    }

    func page(_ page: any EnginePage, opensExternalURL url: URL, origin: PageOrigin?, userGesture: Bool) {
        pool?.onExternalLink?(ExternalLinkRequest(tabID: tabID, url: url, origin: origin, userGesture: userGesture))
    }

    func pageDismissesFilePanel(_ page: any EnginePage) {
        pool?.onFileSelectionDismissed?(tabID)
    }

    func page(_ page: any EnginePage, asksAboutFileAccess question: FileAccessQuestion) async -> Bool? {
        guard let handler = pool?.onFileAccess else { return nil }
        return await handler(FileAccessRequest(
            tabID: tabID, origin: question.origin, kind: question.kind,
            name: question.url?.lastPathComponent, isDirectory: question.isDirectory
        ))
    }
}
