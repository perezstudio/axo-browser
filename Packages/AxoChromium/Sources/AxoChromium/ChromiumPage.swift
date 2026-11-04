import AppKit
import AxoCore
import AxoEngineAPI
import AxoWeb
import Foundation

/// One tab's page in the Chromium engine: an ``EnginePage`` around an `AXOPage`.
///
/// Its ``view`` exists from the start, so the pool can mount it before the engine is ready. The
/// Chromium page's view goes inside it once ``attach(_:)`` is called; until then the page
/// remembers what it was asked to load.
@MainActor
final class ChromiumPage: NSObject, EnginePage {
    let profileID: Profile.ID
    weak var delegate: (any EnginePageDelegate)?
    /// The engine, which wraps the pages this one opens.
    weak var engine: ChromiumEngine?
    let view: PlatformView = ChromiumPageView()
    private(set) var page: (any AXOPage)?
    /// The page's docked DevTools, while it shows in ``view``.
    private var shownDevTools: NSView?
    private(set) var isClosed = false
    /// What to load once attached: the last URL or history asked for before the engine was ready.
    private var pendingLoad: PendingLoad?
    /// The observers of downloads in progress. The engine holds observers weakly, and a download
    /// outlives its page (the tab can close or hibernate while it runs), so they're kept here
    /// until the download ends.
    private static var downloads: [ObjectIdentifier: DownloadObserver] = [:]

    private enum PendingLoad {
        case url(URL)
        case history(Data)
    }

    init(profileID: Profile.ID) {
        self.profileID = profileID
        super.init()
        (view as? ChromiumPageView)?.onResize = { [weak self] in self?.layOutDevTools() }
        (view as? ChromiumPageView)?.onSwipe = { [weak self] deltaX in self?.swiped(deltaX: deltaX) }
    }

    /// Puts the Chromium page inside ``view`` and loads whatever was asked for before.
    func attach(_ page: any AXOPage) {
        guard !isClosed, self.page == nil else { return }
        self.page = page
        page.delegate = self
        let pageView = page.view
        pageView.frame = view.bounds
        pageView.autoresizingMask = [.width, .height]
        view.addSubview(pageView)
        switch pendingLoad {
        case .url(let url): page.load(url)
        case .history(let data): page.restoreNavigationState(data)
        case nil: break
        }
        pendingLoad = nil
        delegate?.pageStateDidChange(self)
    }

    // MARK: State

    var url: URL? { page?.url }
    var title: String { page?.title ?? "" }
    var isLoading: Bool { page?.isLoading ?? (pendingLoad != nil) }
    var estimatedProgress: Double { page?.estimatedProgress ?? 0 }
    var canGoBack: Bool { page?.canGoBack ?? false }
    var canGoForward: Bool { page?.canGoForward ?? false }

    /// The engine's serialized history, or `nil` while Chromium doesn't support saving it yet.
    /// Hibernation doesn't need it: Chromium pages are discarded (``discard()``), which keeps
    /// their history.
    var interactionState: Any? { page?.navigationState }

    /// Discards the page as Chrome discards a tab: its renderer goes, the page stays, with its
    /// history and its tab in the engine's window.
    func discard() -> Bool {
        page?.discard() ?? false
    }

    func loadIfDiscarded() {
        page?.loadIfDiscarded()
    }

    var isDiscarded: Bool { page?.isDiscarded ?? false }

    func restore(interactionState: Any) {
        guard let data = interactionState as? Data else { return }
        if let page {
            page.restoreNavigationState(data)
        } else {
            pendingLoad = .history(data)
        }
    }

    // MARK: Navigation

    func load(_ url: URL) {
        if let page {
            page.load(url)
        } else {
            pendingLoad = .url(url)
        }
    }

    func goBack() { page?.goBack() }
    func goForward() { page?.goForward() }
    func reload() { page?.reload() }
    func stopLoading() { page?.stopLoading() }

    func find(_ text: String, backwards: Bool) async -> Bool {
        guard let page else { return false }
        return await page.find(text, backwards: backwards)
    }

    /// Chromium's find clears its own highlight.
    func endFind() async {
        page?.stopFinding()
    }

    func callJavaScript(_ functionBody: String, arguments: [String: Any], in world: String) async throws -> Any? {
        guard let page else { throw ChromiumPageError.notReady }
        return try await page.callFunctionBody(functionBody, arguments: arguments, inWorld: world) as Any?
    }

    func snapshot(width: CGFloat) async -> PlatformImage? {
        await page?.snapshot(withWidth: width)
    }

    func startDownload(_ url: URL) {
        page?.startDownload(from: url)
    }

    func exitFullscreen() {
        page?.exitFullscreen()
    }

    // MARK: Swipes

    /// Where a three-finger swipe goes: AppKit's `deltaX` is positive for a swipe toward the
    /// right (Back) and negative toward the left (Forward), as Chrome maps it.
    enum SwipeNavigation: Equatable {
        case back, forward
    }

    static func swipeNavigation(deltaX: CGFloat) -> SwipeNavigation? {
        if deltaX > 0 { return .back }
        if deltaX < 0 { return .forward }
        return nil
    }

    /// A three-finger swipe ("Swipe with three fingers" in System Settings) reached the page's
    /// view: Chromium's page view leaves `swipeWithEvent:` to its superviews (Chrome handles it in
    /// its Views window, which Axo doesn't have). Two-finger swipes are Chrome's own history
    /// swiper's, inside the page view.
    func swiped(deltaX: CGFloat) {
        switch Self.swipeNavigation(deltaX: deltaX) {
        case .back where canGoBack: goBack()
        case .forward where canGoForward: goForward()
        default: break
        }
    }

    // MARK: DevTools

    func toggleDevTools() -> Bool {
        page?.toggleDevTools()
        return true
    }

    func showDevToolsConsole() -> Bool {
        page?.showDevToolsConsole()
        return true
    }

    var hasDevTools: Bool { page?.hasDevTools ?? false }

    /// Lays out the page and its docked DevTools in ``view``: DevTools fills it, and the page
    /// sits on top where DevTools puts it (DevTools draws its own divider and dock-side menu
    /// around the page). Without DevTools, the page fills ``view``. Frames and autoresizing
    /// only, never Auto Layout: DevTools moves the page as the person drags its divider.
    func layOutDevTools() {
        guard let page else { return }
        let devTools = page.devToolsView
        // Chrome reuses DevTools' view when it docks again after being undocked, so it may be in
        // DevTools' own window now: take it back whenever it isn't here, and remove only from here.
        if shownDevTools !== devTools, shownDevTools?.superview === view {
            shownDevTools?.removeFromSuperview()
        }
        shownDevTools = devTools
        if let devTools {
            if devTools.superview !== view {
                devTools.autoresizingMask = [.width, .height]
                view.addSubview(devTools, positioned: .below, relativeTo: page.view)
            }
            devTools.frame = view.bounds
        }
        page.view.frame = devTools == nil ? view.bounds : page.devToolsPageFrame(inBounds: view.bounds)
        page.view.autoresizingMask = devTools == nil ? [.width, .height] : []
    }

    func printOperation(with printInfo: NSPrintInfo) -> NSPrintOperation {
        page?.printOperation(with: printInfo) ?? NSPrintOperation(view: view, printInfo: printInfo)
    }

    /// The engine closed the page itself (an extension's `chrome.tabs.remove`). Lets go of it
    /// without closing it again.
    func closedByEngine() {
        isClosed = true
        page?.delegate = nil
        shownDevTools?.removeFromSuperview()
        shownDevTools = nil
        page?.view.removeFromSuperview()
        page = nil
        pendingLoad = nil
    }

    func close() {
        isClosed = true
        page?.delegate = nil
        shownDevTools?.removeFromSuperview()
        shownDevTools = nil
        page?.close()
        page?.view.removeFromSuperview()
        page = nil
        pendingLoad = nil
    }
}

/// Why a Chromium page couldn't do something.
enum ChromiumPageError: Error {
    /// The engine hasn't started yet, so the page has nothing to run in.
    case notReady
}

// MARK: AXOPageDelegate

extension ChromiumPage: AXOPageDelegate {
    func pageStateDidChange(_ page: any AXOPage) {
        delegate?.pageStateDidChange(self)
    }

    func pageDidFinishLoad(_ page: any AXOPage) {
        delegate?.pageDidFinishLoad(self)
    }

    func pageDidFailLoad(_ page: any AXOPage) {
        delegate?.pageDidFailLoad(self)
    }

    func pageDidTakeFocus(_ page: any AXOPage) {
        delegate?.pageDidTakeFocus(self)
    }

    func pageDevToolsDidChange(_ page: any AXOPage) {
        layOutDevTools()
    }

    func page(_ page: any AXOPage, shouldHandleLinkTo url: URL, modifiers: AXOLinkModifiers) -> Bool {
        // AXOLinkModifiers uses the same bits as LinkModifiers.
        delegate?.page(self, shouldHandleLinkTo: url, modifiers: LinkModifiers(rawValue: Int(modifiers.rawValue))) ?? false
    }

    func page(_ page: any AXOPage, wantsToOpenURLInNewTab url: URL) {
        delegate?.page(self, wantsToOpenInNewTab: url)
    }

    /// A permission request. With no answer (no delegate, an origin Axo doesn't ask about, a kind
    /// from a newer engine, or the prompt went away unanswered) the engine records nothing.
    func page(_ page: any AXOPage, requestsPermission kind: AXOPermissionKind, origin: URL, completion: @escaping (AXOPermissionSetting) -> Void) {
        guard let delegate, let pageOrigin = PageOrigin(url: origin) else {
            completion(.ask)
            return
        }
        let permission: PermissionKind
        switch kind {
        case .camera: permission = .camera
        case .microphone: permission = .microphone
        case .cameraAndMicrophone: permission = .cameraAndMicrophone
        case .location: permission = .location
        case .notifications: permission = .notifications
        case .clipboard: permission = .clipboard
        @unknown default:
            // A kind from a newer engine: never mistaken for another.
            completion(.ask)
            return
        }
        Task {
            switch await delegate.page(self, requestsPermission: permission, origin: pageOrigin) {
            case .allow: completion(.allow)
            case .deny: completion(.block)
            case nil: completion(.ask)
            }
        }
    }


    func page(
        _ page: any AXOPage,
        showsDialog kind: AXODialogKind,
        message: String,
        defaultText: String?,
        origin: URL,
        completion: @escaping (Bool, String?) -> Void
    ) {
        guard let delegate else {
            completion(false, nil)
            return
        }
        let dialog: JavaScriptDialog.Kind = switch kind {
        case .confirm: .confirm
        case .prompt: .prompt(defaultText: defaultText ?? "")
        default: .alert
        }
        let pageOrigin = PageOrigin(url: origin) ?? PageOrigin(scheme: origin.scheme ?? "", host: origin.host() ?? "")
        Task {
            let result = await delegate.page(self, showsDialog: dialog, message: message, origin: pageOrigin)
            completion(result.accepted, result.text)
        }
    }

    func page(
        _ page: any AXOPage,
        selectsFilesAllowingMultiple allowsMultiple: Bool,
        directories allowsDirectories: Bool,
        completion: @escaping ([URL]?) -> Void
    ) {
        guard let delegate else {
            completion(nil)
            return
        }
        Task {
            completion(await delegate.page(self, selectsFilesAllowingMultiple: allowsMultiple, directories: allowsDirectories))
        }
    }

    func page(_ page: any AXOPage, didStart download: any AXODownload) {
        guard let delegate else {
            download.cancel()
            return
        }
        let item = delegate.page(self, didStartDownloadFrom: download.sourceURL) { download.cancel() }
        Self.follow(download, reportingTo: item)
    }

    /// Reports `download` to `item` until it ends. The engine holds its observer weakly and a
    /// download outlives its tab, so the observer is kept here, not with the page.
    static func follow(_ download: any AXODownload, reportingTo item: DownloadItem) {
        let key = ObjectIdentifier(download)
        let observer = DownloadObserver(item: item) { downloads[key] = nil }
        downloads[key] = observer
        download.observer = observer
    }

    /// A right-click: Axo shows its own menu for it.
    func page(_ page: any AXOPage, showContextMenu menu: any AXOContextMenu) -> Bool {
        delegate?.page(self, showContextMenu: ChromiumContextMenu(menu)) ?? false
    }

    func page(_ page: any AXOPage, setsFullscreen fullscreen: Bool) {
        delegate?.page(self, setsFullscreen: fullscreen)
    }

    /// The link under the pointer, or with keyboard focus, changed.
    func page(_ page: any AXOPage, hoversLinkTo url: URL?) {
        delegate?.page(self, hoversLinkTo: url)
    }

    func pageWantsToBeShown(_ page: any AXOPage) {
        delegate?.pageWantsToBeShown(self)
    }

    func pageWasDiscarded(_ page: any AXOPage) {
        delegate?.pageWasDiscarded(self)
    }

    /// A page this one opened (`window.open`, `target="_blank"`), already loading and connected
    /// to it.
    func page(_ page: any AXOPage, didOpen newPage: any AXOPage, url: URL, popup: Bool, size: NSSize, inBackground: Bool) {
        guard let engine, let delegate else {
            newPage.close()
            return
        }
        let opened = engine.wrap(newPage, profileID: profileID)
        let kind: OpenedPage.Kind = popup ? .popup(size: CGSize(width: size.width, height: size.height)) : .tab(inBackground: inBackground)
        delegate.page(self, didOpen: OpenedPage(page: opened, url: url, kind: kind))
    }

    /// Key presses the page didn't use, such as ⌘ shortcuts, go to the app's menu, so Axo's
    /// shortcuts (and extensions' shortcuts in it) work while the page has keyboard focus.
    func page(_ page: any AXOPage, didNotHandleKeyEvent event: NSEvent) -> Bool {
        ChromiumPage.handleUnusedKeyEvent(event)
    }

    /// Where unused key presses go: the app's main menu. Tests replace it.
    static var handleUnusedKeyEvent: (NSEvent) -> Bool = { event in
        NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }
}

/// Reports a Chromium download's progress to its ``DownloadItem``.
@MainActor
final class DownloadObserver: NSObject, AXODownloadObserver {
    private let item: DownloadItem
    private let onEnd: () -> Void

    init(item: DownloadItem, onEnd: @escaping () -> Void) {
        self.item = item
        self.onEnd = onEnd
    }

    func download(_ download: any AXODownload, destinationForSuggestedFilename suggestedFilename: String, expectedLength: Int64) -> URL? {
        let destination = item.chooseDestination(suggestedFilename: suggestedFilename, expectedLength: expectedLength)
        if destination == nil { onEnd() }
        return destination
    }

    func download(_ download: any AXODownload, didReceiveBytes completed: Int64, ofTotal total: Int64) {
        item.reportProgress(completedBytes: completed, totalBytes: total)
    }

    func downloadDidFinish(_ download: any AXODownload) {
        item.reportFinished()
        onEnd()
    }

    func download(_ download: any AXODownload, didFailWithMessage message: String) {
        item.reportFailed(message)
        onEnd()
    }
}

/// ``ChromiumPage``'s view: holds the Chromium page's view and, while it's open, its docked
/// DevTools, laying them out again when it resizes.
final class ChromiumPageView: NSView {
    /// Called after the view resizes.
    var onResize: (() -> Void)?
    /// Called with a three-finger swipe's `deltaX`.
    var onSwipe: ((CGFloat) -> Void)?

    override func swipe(with event: NSEvent) {
        onSwipe?(event.deltaX)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        onResize?()
    }
}
