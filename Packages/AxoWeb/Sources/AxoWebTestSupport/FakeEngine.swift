import AxoCore
import AxoWeb
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// An engine with no browser behind it, so pool tests can check the pool's own logic and drive
/// page events directly.
@MainActor
public final class FakeEngine: WebEngine {
    public private(set) var pages: [FakePage] = []
    public private(set) var siteCustomizations: [SiteCustomization] = []
    public private(set) var clearedProfiles: [Profile.ID] = []
    public private(set) var removedProfiles: [Profile.ID] = []
    public weak var delegate: (any WebEngineDelegate)?
    /// The last window pages and active page the pool sent, by profile.
    public private(set) var windowPages: [Profile.ID: (pages: [any EnginePage], active: (any EnginePage)?)] = [:]

    public func setWindowPages(_ pages: [any EnginePage], active: (any EnginePage)?, profileID: Profile.ID) {
        windowPages[profileID] = (pages, active)
    }

    /// The lasting permission answers the pool set, in order.
    public private(set) var lastingPermissions: [(kind: PermissionKind, origin: PageOrigin, decision: PermissionDecision?, profileID: Profile.ID)] = []

    public func setLastingPermission(_ kind: PermissionKind, origin: PageOrigin, decision: PermissionDecision?, profileID: Profile.ID) {
        lastingPermissions.append((kind, origin, decision, profileID))
    }

    /// The answers each profile's lasting permissions were last replaced with.
    public private(set) var replacedLastingPermissions: [Profile.ID: [LastingPermission]] = [:]
    public func replaceLastingPermissions(_ answers: [LastingPermission], profileID: Profile.ID) {
        replacedLastingPermissions[profileID] = answers
    }

    /// The kinds this engine asks about: every kind, as Chromium does, unless a test sets others.
    public var askedPermissionKinds = Set(PermissionKind.allCases)

    /// Plays the engine opening `page` on its own, as an extension's `chrome.tabs.create` would.
    public func openPageOnItsOwn(_ page: any EnginePage, profileID: Profile.ID, at index: Int) {
        delegate?.engine(self, didOpen: page, profileID: profileID, at: index)
    }

    /// Plays the engine opening `page` in a popup window, as an extension's
    /// `chrome.windows.create({type: "popup"})` would.
    public func openPopupWindowOnItsOwn(_ page: any EnginePage, size: CGSize, profileID: Profile.ID) {
        delegate?.engine(self, didOpenPopupWindowWith: page, size: size, profileID: profileID)
    }

    /// Plays the engine closing `page` on its own, as `chrome.tabs.remove` would.
    public func closePageOnItsOwn(_ page: any EnginePage) {
        delegate?.engine(self, didClose: page)
    }

    /// Plays the engine selecting `page` on its own.
    public func activatePageOnItsOwn(_ page: any EnginePage) {
        delegate?.engine(self, didActivate: page)
    }

    /// Creates an engine with no pages.
    public init() {}

    public func makePage(profileID: Profile.ID) -> any EnginePage {
        let page = FakePage(profileID: profileID)
        pages.append(page)
        return page
    }

    public func setSiteCustomizations(_ customizations: [SiteCustomization]) {
        siteCustomizations = customizations
    }

    public func clearWebsiteData(for profileID: Profile.ID) async {
        clearedProfiles.append(profileID)
    }

    public func removeWebsiteData(for profileID: Profile.ID) async throws {
        removedProfiles.append(profileID)
    }
}

/// A page that records what the pool asks of it. Tests change its state with ``navigate(to:title:)``
/// and send events through ``delegate``.
@MainActor
public final class FakePage: EnginePage {
    /// The profile the page was made for.
    public let profileID: Profile.ID
    public weak var delegate: (any EnginePageDelegate)?
    public let view = PlatformView()
    /// Whether the page reports developer tools open.
    public var hasDevTools = false

    public private(set) var url: URL?
    public private(set) var title = ""
    public var isLoading = false
    public var estimatedProgress = 0.0
    public var canGoBack = false
    public var canGoForward = false

    /// Every URL passed to ``load(_:)``, in order.
    public private(set) var loads: [URL] = []
    /// The history passed to ``restore(interactionState:)``.
    public private(set) var restoredState: String?
    /// "back", "forward", "reload", and "stop", in the order asked.
    public private(set) var navigation: [String] = []
    /// Every find, in order.
    public private(set) var finds: [(text: String, backwards: Bool)] = []
    /// Every script run, with its world, in order.
    public private(set) var scripts: [(body: String, world: String)] = []
    /// Every URL passed to ``startDownload(_:)``.
    public private(set) var downloadRequests: [URL] = []
    /// Whether the pool closed the page.
    public private(set) var isClosed = false
    /// What every script run returns (`nil` by default).
    public var scriptResult: Any?
    /// Whether scripts wait for ``answerHeldScript()`` instead of answering at once.
    public var holdsScripts = false
    /// How many scripts are waiting for ``answerHeldScript()``.
    public var heldScriptCount: Int { heldScripts.count }
    private var heldScripts: [CheckedContinuation<Void, Never>] = []
    /// What ``snapshot(width:)`` returns.
    public var snapshotImage: PlatformImage?
    /// How many snapshots the pool asked for.
    public private(set) var snapshotCount = 0
    /// Whether snapshots wait for ``answerHeldSnapshot()`` instead of answering at once.
    public var holdsSnapshots = false
    private var heldSnapshots: [CheckedContinuation<Void, Never>] = []

    /// Answers the oldest held snapshot with ``snapshotImage``.
    public func answerHeldSnapshot() {
        heldSnapshots.removeFirst().resume()
    }
    /// What ``find(_:backwards:)`` returns.
    public var findResult = true
    /// Whether finds wait for ``answerHeldFind(_:)`` instead of answering ``findResult`` at once.
    public var holdsFinds = false
    private var heldFinds: [CheckedContinuation<Bool, Never>] = []
    /// How many finds are waiting for ``answerHeldFind(_:)``.
    public var heldFindCount: Int { heldFinds.count }

    /// Creates a page for `profileID`'s profile.
    public init(profileID: Profile.ID) {
        self.profileID = profileID
    }

    /// Commits a navigation to `url` and tells the delegate.
    public func navigate(to url: URL, title: String) {
        self.url = url
        self.title = title
        delegate?.pageStateDidChange(self)
    }

    /// Fails loading the page and tells the delegate.
    public func failLoad() {
        isLoading = false
        delegate?.pageDidFailLoad(self)
    }

    /// Whether ``discard()`` works, as on Chromium (WebKit pages can't be discarded).
    public var canDiscard = false
    /// Whether the page is discarded, and how many times it loaded again afterwards.
    public private(set) var isDiscarded = false
    public private(set) var discardedLoads = 0

    public func discard() -> Bool {
        guard canDiscard, !isDiscarded, !discardIsSkipped else { return false }
        isDiscarded = true
        // Engines report it on a later turn.
        Task { @MainActor [weak self] in
            guard let self, self.isDiscarded else { return }
            self.delegate?.pageWasDiscarded(self)
        }
        return true
    }

    public func loadIfDiscarded() {
        guard isDiscarded else { return }
        isDiscarded = false
        discardedLoads += 1
    }

    /// Asks to be shown, as a page does after a click on one of its notifications.
    public func askToBeShown() {
        delegate?.pageWantsToBeShown(self)
    }

    /// Discards the page as the engine does on its own (an extension's `chrome.tabs.discard`),
    /// reporting it at once.
    public func discardOnItsOwn() {
        isDiscarded = true
        delegate?.pageWasDiscarded(self)
    }

    /// Loads a discarded page again on the engine's own (an extension's `chrome.tabs.reload`).
    public func reloadOnItsOwn() {
        isDiscarded = false
        delegate?.pageStateDidChange(self)
        finishLoad()
    }

    /// Whether ``discard()`` reports the page discarded but leaves it live, as Chromium does when
    /// a navigation is about to commit.
    public var discardIsSkipped = false

    /// Finishes loading the page and tells the delegate.
    public func finishLoad() {
        isLoading = false
        delegate?.pageDidFinishLoad(self)
    }

    public var interactionState: Any? { url.map { "history:\($0.absoluteString)" } }

    public func restore(interactionState: Any) {
        restoredState = interactionState as? String
    }

    public func load(_ url: URL) {
        loads.append(url)
    }

    /// Plays a right-click in the page, as an engine that leaves the menu to Axo reports it.
    @discardableResult
    public func rightClick(_ menu: any PageContextMenu) -> Bool {
        delegate?.page(self, showContextMenu: menu) ?? false
    }

    /// Plays a File System Access picker, as an engine that leaves its panel to Axo reports it.
    public func showFilePanel(_ panel: FilePanel) async -> [URL]? {
        await delegate?.page(self, showsFilePanel: panel)
    }

    /// Plays the page asking to open a link in another app.
    public func openExternal(_ url: URL, origin: PageOrigin?, userGesture: Bool = true) {
        delegate?.page(self, opensExternalURL: url, origin: origin, userGesture: userGesture)
    }

    /// Plays the engine giving up on the page's file panel.
    public func dismissFilePanel() {
        delegate?.pageDismissesFilePanel(self)
    }

    /// Plays a File System Access question, as an engine that asks Axo reports it.
    public func askAboutFileAccess(_ question: FileAccessQuestion) async -> Bool? {
        await delegate?.page(self, asksAboutFileAccess: question) ?? nil
    }

    public func goBack() { navigation.append("back") }
    public func goForward() { navigation.append("forward") }
    public func reload() { navigation.append("reload") }
    public func stopLoading() { navigation.append("stop") }

    public func find(_ text: String, backwards: Bool) async -> Bool {
        finds.append((text, backwards))
        guard holdsFinds else { return findResult }
        return await withCheckedContinuation { heldFinds.append($0) }
    }

    /// Answers the oldest held find with `found`.
    public func answerHeldFind(_ found: Bool) {
        heldFinds.removeFirst().resume(returning: found)
    }

    public private(set) var endedFinds = 0
    public func endFind() async { endedFinds += 1 }

    public func callJavaScript(_ functionBody: String, arguments: [String: Any], in world: String) async throws -> Any? {
        scripts.append((functionBody, world))
        guard holdsScripts else { return scriptResult }
        await withCheckedContinuation { heldScripts.append($0) }
        return scriptResult
    }

    /// Answers the oldest held script with ``scriptResult``.
    public func answerHeldScript() {
        guard !heldScripts.isEmpty else { return }
        heldScripts.removeFirst().resume()
    }

    public func snapshot(width: CGFloat) async -> PlatformImage? {
        snapshotCount += 1
        guard holdsSnapshots else { return snapshotImage }
        await withCheckedContinuation { heldSnapshots.append($0) }
        return snapshotImage
    }

    public func startDownload(_ url: URL) {
        downloadRequests.append(url)
    }

    #if os(macOS)
    public func printOperation(with printInfo: NSPrintInfo) -> NSPrintOperation {
        NSPrintOperation(view: view, printInfo: printInfo)
    }
    #endif

    public private(set) var exitedFullscreen = 0
    public func exitFullscreen() { exitedFullscreen += 1 }

    /// Asks to fill the screen, or to stop, as a page's `requestFullscreen()` would.
    public func setFullscreen(_ fullscreen: Bool) {
        delegate?.page(self, setsFullscreen: fullscreen)
    }

    /// Reports the link under the pointer, or `nil` once the pointer leaves it.
    public func hoverLink(_ url: URL?) {
        delegate?.page(self, hoversLinkTo: url)
    }

    /// Opens another page, as a page's `window.open` would.
    public func open(_ opened: FakePage, url: URL, as kind: OpenedPage.Kind) {
        opened.url = url
        delegate?.page(self, didOpen: OpenedPage(page: opened, url: url, kind: kind))
    }

    public func close() {
        isClosed = true
    }
}

/// A right-click for tests: what was clicked is set directly, and actions are recorded.
@MainActor
public final class FakeContextMenu: PageContextMenu {
    public var linkURL: URL?
    public var linkText = ""
    public var media = PageContextMenuMedia.none
    public var sourceURL: URL?
    public var hasImageContents = false
    public var selectionText = ""
    public var isEditable = false
    public var edits: PageEdits = []
    public var misspelledWord = ""
    public var suggestions: [String] = []
    public var location = CGPoint(x: 10, y: 10)
    public var extensionItems: [PageContextMenuItem] = []

    /// What the menu did, in order, such as "copy", "replace teh", or "item Mark".
    public private(set) var performed: [String] = []
    public private(set) var closedLink: URL??

    public init() {}

    public func perform(_ edit: PageEdit) { performed.append("\(edit)") }
    public func replaceMisspelling(with word: String) { performed.append("replace \(word)") }
    public func copyImage() { performed.append("copy image") }
    public func download(_ url: URL) { performed.append("download \(url.absoluteString)") }
    public func lookUpSelection() { performed.append("look up") }
    public func perform(_ item: PageContextMenuItem) { performed.append("item \(item.title)") }
    public func closed(followingLink url: URL?) { closedLink = .some(url) }
}
