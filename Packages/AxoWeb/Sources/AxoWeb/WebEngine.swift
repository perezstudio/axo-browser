import AxoCore
import Foundation
#if os(macOS)
import AppKit
#endif

/// The browser engine behind ``WebViewPool``: WebKit today, and a Chromium fork on the Mac later
/// (see `docs/chromium-engine.md`).
///
/// An engine makes pages for a profile and owns each profile's website data. It never decides
/// when pages live or die; the pool does, so an engine's pages are created only by
/// ``WebViewPool`` and closed by it.
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
}

extension WebEngine {
    public func setWindowPages(_ pages: [any EnginePage], active: (any EnginePage)?, profileID: Profile.ID) {}
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

    /// Runs `functionBody` as the body of an async JavaScript function with `arguments` as its
    /// parameters, in the isolated world named `world`, so the page's own scripts can't see or
    /// interfere with it. Returns the function's result as Foundation values.
    func callJavaScript(_ functionBody: String, arguments: [String: Any], in world: String) async throws -> Any?

    /// A picture of the visible page, `width` points wide, or `nil` if the engine can't take one.
    func snapshot(width: CGFloat) async -> PlatformImage?

    /// Downloads `url` with the page's profile (and so its cookies).
    func startDownload(_ url: URL)

    #if os(macOS)
    /// A print operation for the page with `printInfo`.
    func printOperation(with printInfo: NSPrintInfo) -> NSPrintOperation
    #endif

    /// Stops the page and releases what it holds. The pool never uses it again.
    func close()
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
    /// doesn't navigate.
    func page(_ page: any EnginePage, shouldHandleLinkTo url: URL, modifiers: LinkModifiers) -> Bool
    /// The page asked to open `url` in a new tab or window (`target="_blank"`, `window.open`).
    func page(_ page: any EnginePage, wantsToOpenInNewTab url: URL)

    /// The page started a download. Return the item to report its progress to; `cancel` stops
    /// the engine's download when the person cancels it.
    func page(_ page: any EnginePage, didStartDownloadFrom sourceURL: URL?, cancel: @escaping @MainActor () -> Void) -> DownloadItem

    /// The page wants the camera, microphone, or location.
    func page(_ page: any EnginePage, requestsPermission kind: PermissionKind, origin: PageOrigin) async -> PermissionDecision
    /// The page called `alert()`, `confirm()`, or `prompt()`.
    func page(_ page: any EnginePage, showsDialog kind: JavaScriptDialog.Kind, message: String, origin: PageOrigin) async -> JavaScriptDialogResult
    /// The page's file input wants files. Return them, or `nil` to cancel.
    func page(_ page: any EnginePage, selectsFilesAllowingMultiple allowsMultipleSelection: Bool, directories allowsDirectories: Bool) async -> [URL]?
}
