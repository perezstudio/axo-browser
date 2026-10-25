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
    let view: PlatformView = NSView()
    private(set) var page: (any AXOPage)?
    private(set) var isClosed = false
    /// What to load once attached: the last URL or history asked for before the engine was ready.
    private var pendingLoad: PendingLoad?
    /// Downloads still running, kept so their observers live as long as they do.
    private var downloads: [ObjectIdentifier: DownloadObserver] = [:]

    private enum PendingLoad {
        case url(URL)
        case history(Data)
    }

    init(profileID: Profile.ID) {
        self.profileID = profileID
        super.init()
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

    /// The engine's serialized history, or `nil` while Chromium doesn't support saving it yet;
    /// a hibernated tab then reloads its URL when it wakes.
    var interactionState: Any? { page?.navigationState }

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

    func printOperation(with printInfo: NSPrintInfo) -> NSPrintOperation {
        page?.printOperation(with: printInfo) ?? NSPrintOperation(view: view, printInfo: printInfo)
    }

    /// The engine closed the page itself (an extension's `chrome.tabs.remove`). Lets go of it
    /// without closing it again.
    func closedByEngine() {
        isClosed = true
        page?.delegate = nil
        page?.view.removeFromSuperview()
        page = nil
        pendingLoad = nil
    }

    func close() {
        isClosed = true
        page?.delegate = nil
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

    func page(_ page: any AXOPage, shouldHandleLinkTo url: URL, modifiers: AXOLinkModifiers) -> Bool {
        // AXOLinkModifiers uses the same bits as LinkModifiers.
        delegate?.page(self, shouldHandleLinkTo: url, modifiers: LinkModifiers(rawValue: Int(modifiers.rawValue))) ?? false
    }

    func page(_ page: any AXOPage, wantsToOpenURLInNewTab url: URL) {
        delegate?.page(self, wantsToOpenInNewTab: url)
    }

    func page(_ page: any AXOPage, requestsPermission kind: AXOPermissionKind, origin: URL, completion: @escaping (Bool) -> Void) {
        guard let delegate, let pageOrigin = PageOrigin(url: origin) else {
            completion(false)
            return
        }
        let permission: PermissionKind = switch kind {
        case .camera: .camera
        case .microphone: .microphone
        case .location: .location
        default: .cameraAndMicrophone
        }
        Task {
            let decision = await delegate.page(self, requestsPermission: permission, origin: pageOrigin)
            completion(decision == .allow)
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
        let key = ObjectIdentifier(download)
        let observer = DownloadObserver(item: item) { [weak self] in self?.downloads[key] = nil }
        downloads[key] = observer
        download.observer = observer
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
