import AxoCore
import Foundation
#if os(macOS)
import AppKit
#endif

/// The browser engine behind ``WebViewPool``: a Chromium fork on the Mac and WebKit on iPhone
/// and iPad (see `docs/chromium-engine.md`).
///
/// An engine makes pages for a profile and owns each profile's website data. The pool decides
/// when Axo's pages live or die. An engine with its own window model (Chromium's extension APIs)
/// can also open and close pages itself; it reports those to its ``delegate``, and the pool adopts
/// or forgets them.
@MainActor
public protocol WebEngine: AnyObject {
    /// Creates an empty page for a tab in `profileID`'s profile. The pool sets its delegate, then
    /// loads a URL or restores saved history.
    func makePage(profileID: Profile.ID) -> any EnginePage

    /// Applies per-site custom CSS and JavaScript to new pages, and to live pages from their next
    /// load. Turned-off customizations are skipped.
    func setSiteCustomizations(_ customizations: [SiteCustomization])

    /// Removes a profile's cookies, caches, and other website data, signing it out of sites.
    func clearWebsiteData(for profileID: Profile.ID) async

    /// Deletes a deleted profile's website data for good. The pool closes the profile's pages
    /// first.
    func removeWebsiteData(for profileID: Profile.ID) async throws

    /// Hears about tabs the engine changes on its own. ``WebViewPool`` sets it.
    var delegate: (any WebEngineDelegate)? { get set }

    /// The pages of the tabs a window shows (its Space's), in sidebar order, and the selected one,
    /// for engines with a window model of their own. Chromium's extension APIs see these as one
    /// window's tabs. WebKit has no such model and ignores it.
    func setWindowPages(_ pages: [any EnginePage], active: (any EnginePage)?, profileID: Profile.ID)

    /// Sets a site's lasting answer in the engine's own settings, for kinds the engine keeps an
    /// answer for itself (``PermissionKind/lastsInEngine``); `nil` clears it, so the site asks
    /// again. Engines that ask every time (WebKit) ignore it.
    func setLastingPermission(_ kind: PermissionKind, origin: PageOrigin, decision: PermissionDecision?, profileID: Profile.ID)
    /// Replaces every lasting answer the engine keeps for a profile with `answers`, forgetting any
    /// it has that Axo doesn't (Axo's are the ones that count).
    func replaceLastingPermissions(_ answers: [LastingPermission], profileID: Profile.ID)
    /// The kinds of permission the engine asks Axo about. Site Settings offers only these.
    var askedPermissionKinds: Set<PermissionKind> { get }
}

extension WebEngine {
    public func setWindowPages(_ pages: [any EnginePage], active: (any EnginePage)?, profileID: Profile.ID) {}
    public func setLastingPermission(_ kind: PermissionKind, origin: PageOrigin, decision: PermissionDecision?, profileID: Profile.ID) {}
    public func replaceLastingPermissions(_ answers: [LastingPermission], profileID: Profile.ID) {}
    public var askedPermissionKinds: Set<PermissionKind> { [.camera, .microphone, .cameraAndMicrophone, .location] }
}

/// Tabs an engine changed on its own, such as through Chromium's extension APIs
/// (`chrome.tabs.create`, `chrome.tabs.remove`). ``WebViewPool`` implements it and passes the
/// changes on as tab IDs.
@MainActor
public protocol WebEngineDelegate: AnyObject {
    /// The engine opened `page`, already loading, at `index` in `profileID`'s window.
    func engine(_ engine: any WebEngine, didOpen page: any EnginePage, profileID: Profile.ID, at index: Int)
    /// The engine closed `page`, which can't be used anymore.
    func engine(_ engine: any WebEngine, didClose page: any EnginePage)
    /// The engine made `page` the selected one.
    func engine(_ engine: any WebEngine, didActivate page: any EnginePage)
    /// The engine opened `page`, already loading, in a popup window of its own (an extension's
    /// `chrome.windows.create` with `type: "popup"`), `size` points big (zero when unspecified).
    /// The engine closing the page (``engine(_:didClose:)``) closes the window.
    func engine(_ engine: any WebEngine, didOpenPopupWindowWith page: any EnginePage, size: CGSize, profileID: Profile.ID)
    /// The engine started a download with no tab to report it to, such as an extension's
    /// background download. Return the item to report its progress to; `cancel` stops the
    /// engine's download when the person cancels it.
    func engine(_ engine: any WebEngine, didStartDownloadFrom sourceURL: URL?, profileID: Profile.ID, cancel: @escaping @MainActor () -> Void) -> DownloadItem
}

/// One tab's page in a ``WebEngine``. Owned by ``WebViewPool``.
///
/// State changes and requests from the page go to its ``delegate``.
@MainActor
public protocol EnginePage: AnyObject {
    /// Receives the page's events. The pool sets it before the first load.
    var delegate: (any EnginePageDelegate)? { get set }

    /// The view that draws the page. ``WebViewHost`` mounts it.
    var view: PlatformView { get }

    /// The URL of the current page, or `nil` before the first navigation commits.
    var url: URL? { get }
    /// The current page's title, or an empty string if it has none.
    var title: String { get }
    /// Whether the page is loading.
    var isLoading: Bool { get }
    /// The current load's progress, from 0 to 1.
    var estimatedProgress: Double { get }
    /// Whether there is a page to go back to.
    var canGoBack: Bool { get }
    /// Whether there is a page to go forward to.
    var canGoForward: Bool { get }

    /// The page's back and forward history in the engine's own opaque form, kept while a tab
    /// hibernates and handed back to ``restore(interactionState:)``.
    var interactionState: Any? { get }

    /// Restores history saved from ``interactionState`` and loads its current page.
    func restore(interactionState: Any)

    /// Loads `url`. File URLs may read their own folder.
    func load(_ url: URL)
    /// Goes back in history.
    func goBack()
    /// Goes forward in history.
    func goForward()
    /// Reloads the current page.
    func reload()
    /// Stops loading the current page.
    func stopLoading()

    /// Finds the next (or previous) occurrence of `text`, ignoring case and wrapping, highlights
    /// it, and scrolls to it. Returns whether there was a match.
    func find(_ text: String, backwards: Bool) async -> Bool
    /// Ends find: removes the highlight it left, and the next find starts over.
    func endFind() async

    /// Runs `functionBody` as the body of an async JavaScript function with `arguments` as its
    /// parameters, in the isolated world named `world`, so the page's own scripts can't see or
    /// interfere with it. A world keeps what earlier calls left in it while the page stays.
    /// Returns the function's result as Foundation values.
    func callJavaScript(_ functionBody: String, arguments: [String: Any], in world: String) async throws -> Any?

    /// A picture of the visible page, `width` points wide, or `nil` if the engine can't take one.
    func snapshot(width: CGFloat) async -> PlatformImage?

    /// Downloads `url` with the page's profile (and so its cookies).
    func startDownload(_ url: URL)

    #if os(macOS)
    /// A print operation for the page with `printInfo`.
    func printOperation(with printInfo: NSPrintInfo) -> NSPrintOperation
    #endif

    /// Leaves page full screen (``EnginePageDelegate/page(_:setsFullscreen:)``), when the person
    /// leaves full screen some other way than the page.
    func exitFullscreen()

    /// Stops the page and releases what it holds. The pool never uses it again.
    func close()

    /// Opens or closes the engine's own developer tools for the page, docked beside it in the
    /// page's view. Returns `false` when the engine has none (WebKit, whose Web Inspector Axo
    /// opens itself through AxoInspector).
    func toggleDevTools() -> Bool
    /// Opens the engine's developer tools on the JavaScript console. Returns `false` when the
    /// engine has none.
    func showDevToolsConsole() -> Bool
    /// Whether the engine's developer tools are open for the page, docked or in a window of their
    /// own. The pool doesn't hibernate an idle tab while they are: an undocked DevTools window
    /// stays in use while its tab is hidden.
    var hasDevTools: Bool { get }

    /// Frees the page's memory but keeps the page, its back and forward history, and its place in
    /// the engine's window, as Chrome discards tabs. Returns whether it did: engines that can't
    /// (WebKit) return `false`, and the pool closes the page and keeps ``interactionState``
    /// instead. The pool only discards a page that isn't showing.
    func discard() -> Bool
    /// Loads a discarded page's current history entry again; does nothing otherwise.
    func loadIfDiscarded()
    /// Whether the page is discarded (``discard()``), until it loads again.
    var isDiscarded: Bool { get }
}

extension EnginePage {
    public func discard() -> Bool { false }
    public func loadIfDiscarded() {}
    public var isDiscarded: Bool { false }
    public func toggleDevTools() -> Bool { false }
    public func showDevToolsConsole() -> Bool { false }
    public var hasDevTools: Bool { false }
}

/// Receives a ``EnginePage``'s events. ``WebViewPool`` implements it for each live tab.
@MainActor
public protocol EnginePageDelegate: AnyObject {
    /// The page's URL, title, loading state, progress, or history changed. Read the new values
    /// from the page.
    func pageStateDidChange(_ page: any EnginePage)
    /// A main-frame load finished successfully.
    func pageDidFinishLoad(_ page: any EnginePage)
    /// A main-frame load failed.
    func pageDidFailLoad(_ page: any EnginePage)
    /// The page took keyboard focus.
    func pageDidTakeFocus(_ page: any EnginePage)

    /// The person clicked a link in the main frame. Return `true` to take the click, so the page
    /// doesn't navigate. Answer right away, without closing or navigating this page from inside
    /// the call: engines ask in the middle of the navigation.
    func page(_ page: any EnginePage, shouldHandleLinkTo url: URL, modifiers: LinkModifiers) -> Bool
    /// The page asked to open `url` in a new tab or window (`target="_blank"`, `window.open`).
    func page(_ page: any EnginePage, wantsToOpenInNewTab url: URL)

    /// The page started a download. Return the item to report its progress to; `cancel` stops
    /// the engine's download when the person cancels it.
    func page(_ page: any EnginePage, didStartDownloadFrom sourceURL: URL?, cancel: @escaping @MainActor () -> Void) -> DownloadItem

    /// The page wants a device or capability (``PermissionKind``). `nil` is no answer (Axo
    /// couldn't ask, or the prompt went away unanswered): engines that keep answers record nothing.
    func page(_ page: any EnginePage, requestsPermission kind: PermissionKind, origin: PageOrigin) async -> PermissionDecision?
    /// The page called `alert()`, `confirm()`, or `prompt()`.
    func page(_ page: any EnginePage, showsDialog kind: JavaScriptDialog.Kind, message: String, origin: PageOrigin) async -> JavaScriptDialogResult
    /// The page's file input wants files. Return them, or `nil` to cancel.
    func page(_ page: any EnginePage, selectsFilesAllowingMultiple allowsMultipleSelection: Bool, directories allowsDirectories: Bool) async -> [URL]?
    /// The page opened a File System Access picker, for engines that leave its panel to Axo.
    /// Return the chosen files (one, except for ``FilePanel/Kind/openFiles``), or `nil` to cancel.
    func page(_ page: any EnginePage, showsFilePanel panel: FilePanel) async -> [URL]?
    /// The engine gave up on the panel the page's picker asked for (the page navigated, was
    /// hidden, or closed). Close it if it's still open.
    func pageDismissesFilePanel(_ page: any EnginePage)
    /// A File System Access question for the person, for engines that ask Axo. Answer as
    /// ``FileAccessRequest/Kind`` says, or `nil` for no answer (no one could ask, or the question
    /// went away unanswered), which engines that keep answers don't record.
    func page(_ page: any EnginePage, asksAboutFileAccess question: FileAccessQuestion) async -> Bool?
    /// A right-click, for engines that leave the menu to Axo. Show Axo's menu and return `true`,
    /// or return `false` to show none.
    func page(_ page: any EnginePage, showContextMenu menu: any PageContextMenu) -> Bool
    /// The page asked to fill the screen (`element.requestFullscreen()`), or to stop, for engines
    /// that leave that to Axo.
    func page(_ page: any EnginePage, setsFullscreen fullscreen: Bool)
    /// The link under the pointer, or with keyboard focus, changed: `url` is where it goes, or
    /// `nil` once there's none. Axo shows it in a status label over the page.
    func page(_ page: any EnginePage, hoversLinkTo url: URL?)
    /// The engine discarded the page (``EnginePage/discard()``), or did so on its own (Chrome, for
    /// an extension's `chrome.tabs.discard` or under memory pressure).
    func pageWasDiscarded(_ page: any EnginePage)
    /// The page asked to be shown: `window.focus()` after a click on one of its notifications, a
    /// service worker's `clients.focus()`, but also entering full screen, a media "raise", or an
    /// extension reloading a page that posted a form, which the person didn't necessarily start.
    func pageWantsToBeShown(_ page: any EnginePage)
    /// The page opened another page that's already loading (`window.open`, a `target="_blank"`
    /// link), for engines that keep the new page connected to its opener.
    func page(_ page: any EnginePage, didOpen opened: OpenedPage)
}

/// A page another page opened, already loading, with its opener (`window.opener`) and the
/// request it carried. Show it, or close it.
public struct OpenedPage {
    /// Where the page shows.
    public enum Kind: Hashable, Sendable {
        /// A tab, in the background when the person asked for that (⌘-click).
        case tab(inBackground: Bool)
        /// A small window (`window.open` with a size, as sign-in pages use), of `size` when the
        /// page gave one.
        case popup(size: CGSize)
    }

    /// The new page.
    public let page: any EnginePage
    /// What it's loading.
    public let url: URL
    public let kind: Kind

    /// Creates the description of an opened page.
    public init(page: any EnginePage, url: URL, kind: Kind) {
        self.page = page
        self.url = url
        self.kind = kind
    }
}
