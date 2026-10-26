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
    private weak var pool: WebViewPool?

    init(tabID: Tab.ID, profileID: Profile.ID, page: any EnginePage, pool: WebViewPool, lastUsed: Date) {
        self.tabID = tabID
        self.profileID = profileID
        self.page = page
        self.pool = pool
        self.lastUsed = lastUsed
        page.delegate = self
        syncState()
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
        state.url = url
        state.title = title
        if let url {
            pool?.onPageChange?(tabID, url, title)
        }
    }

    /// Stops the page and detaches it so it can be deallocated.
    func tearDown() {
        page.delegate = nil
        page.close()
    }

    // MARK: EnginePageDelegate

    func pageStateDidChange(_ page: any EnginePage) {
        syncState()
    }

    func pageDidFinishLoad(_ page: any EnginePage) {
        state.restoringSnapshot = nil
        pool?.loadFavicon(for: tabID)
    }

    func pageDidFailLoad(_ page: any EnginePage) {
        state.restoringSnapshot = nil
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

    func page(_ page: any EnginePage, requestsPermission kind: PermissionKind, origin: PageOrigin) async -> PermissionDecision {
        await pool?.decidePermission(kind, origin: origin, tabID: tabID, profileID: profileID) ?? .deny
    }

    func page(_ page: any EnginePage, showsDialog kind: JavaScriptDialog.Kind, message: String, origin: PageOrigin) async -> JavaScriptDialogResult {
        guard let handler = pool?.onJavaScriptDialog else { return .cancelled }
        return await handler(JavaScriptDialog(tabID: tabID, origin: origin, message: message, kind: kind))
    }

    func page(_ page: any EnginePage, selectsFilesAllowingMultiple allowsMultipleSelection: Bool, directories allowsDirectories: Bool) async -> [URL]? {
        guard let handler = pool?.onFileSelection else { return nil }
        return await handler(FileSelectionRequest(tabID: tabID, allowsMultipleSelection: allowsMultipleSelection, allowsDirectories: allowsDirectories))
    }
}
