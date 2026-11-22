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

    /// Removes one site's cookies, caches, and other website data in a profile: `url`'s site (its
    /// registrable domain, such as `github.com` for `gist.github.com`, with its subdomains),
    /// signing the profile out of it. History and permission answers stay.
    func clearWebsiteData(forSite url: URL, profileID: Profile.ID) async

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
    /// Sets what sites without an answer of their own get for a kind the engine keeps answers
    /// for itself (``PermissionKind/lastsInEngine``), or `nil` to ask (#133). Engines that ask
    /// every time (WebKit) ignore it; Axo answers those from its own defaults.
    func setDefaultPermission(_ kind: PermissionKind, decision: PermissionDecision?, profileID: Profile.ID)
    /// The kinds of permission the engine asks Axo about. Site Settings offers only these.
    var askedPermissionKinds: Set<PermissionKind> { get }
}

extension WebEngine {
    public func setWindowPages(_ pages: [any EnginePage], active: (any EnginePage)?, profileID: Profile.ID) {}
    public func setLastingPermission(_ kind: PermissionKind, origin: PageOrigin, decision: PermissionDecision?, profileID: Profile.ID) {}
    public func replaceLastingPermissions(_ answers: [LastingPermission], profileID: Profile.ID) {}
    public func setDefaultPermission(_ kind: PermissionKind, decision: PermissionDecision?, profileID: Profile.ID) {}
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

    /// Whether the page plays sound, whether it's muted, and what it uses (the camera, the
    /// microphone, the screen, the person's location), for its tab's row (#71, #74). Engines
    /// report changes through ``EnginePageDelegate/pageMediaDidChange(_:)``.
    var media: PageMedia { get }
    /// Mutes the page's sound, or unmutes it.
    func setAudioMuted(_ muted: Bool)
    /// Stops the page using the camera, the microphone, or location, for when the person's
    /// answer for its site changes to deny (#133). Engines stop what they can (WebKit: the camera
    /// and microphone); the screen isn't stopped this way.
    func stopCapture(_ kinds: PageCapture)

    /// Whether the page stopped working, and why (#75): its content process crashed or ran out of
    /// memory, or it stopped responding. A crash lasts until the page loads again (``reload()``,
    /// or another address); not responding lasts until it responds. Engines report changes
    /// through ``EnginePageDelegate/pageProblemDidChange(_:)``. ``reload()`` recovers either.
    var problem: PageProblem? { get }
    /// Gives a page that stopped responding more time; the engine reports it again if it still
    /// doesn't respond. Does nothing otherwise.
    func waitForResponse()

    /// How secure the page's connection is, and its server's certificates (#96). Engines report
    /// changes through ``EnginePageDelegate/pageSecurityDidChange(_:)``.
    var security: PageSecurity { get }

    /// Why the page's last load failed, while the engine's error page shows (#178); nil once a
    /// page loads. Engines report changes through ``EnginePageDelegate/pageErrorDidChange(_:)``.
    var loadError: PageLoadError? { get }
    /// The warning the engine shows in place of the page (an untrusted certificate, a dangerous
    /// site), if any (#178).
    var warning: PageWarning? { get }
    /// Leaves the warning for the page before (the warning's "Go Back"). Does nothing without one.
    func leaveWarning()
    /// Goes on to the site despite the warning; does nothing when ``PageWarning/allowsVisiting``
    /// is false.
    func visitDespiteWarning()
    /// Leaves a failed load: back to the page before, or (an engine that keeps the page that was
    /// showing, WebKit) that page again.
    func leaveLoadError()
    /// Tries the failed load again (Try Again): Chromium reloads its error page's entry, which
    /// tries the original request again; others load the failed address.
    func retryFailedLoad()

    /// The pages Back would go to, the nearest first, for Back's history menu (#112).
    var backHistory: [HistoryEntry] { get }
    /// The pages Forward would go to, the nearest first.
    var forwardHistory: [HistoryEntry] { get }
    /// Goes `offset` entries back (negative) or forward (positive) at once. Does nothing out of
    /// range.
    func goToHistoryOffset(_ offset: Int)
}

extension EnginePage {
    /// Nothing known, for engines that can't tell.
    public var media: PageMedia { PageMedia() }
    /// Does nothing, for engines that can't mute.
    public func setAudioMuted(_ muted: Bool) {}
    /// Does nothing, for engines that can't stop capture.
    public func stopCapture(_ kinds: PageCapture) {}
    /// Nothing known, for engines that can't tell.
    public var problem: PageProblem? { nil }
    /// Does nothing, for engines that can't tell a page stopped responding.
    public func waitForResponse() {}
    /// Nothing known, for engines that can't tell.
    public var security: PageSecurity { PageSecurity() }
    /// Nothing known, for engines that can't tell.
    public var loadError: PageLoadError? { nil }
    /// Nothing known, for engines that can't tell.
    public var warning: PageWarning? { nil }
    public func leaveWarning() {}
    public func visitDespiteWarning() {}
    public func leaveLoadError() {}
    public func retryFailedLoad() {
        if let url = loadError?.url { load(url) }
    }
    public var backHistory: [HistoryEntry] { [] }
    public var forwardHistory: [HistoryEntry] { [] }
    public func goToHistoryOffset(_ offset: Int) {}
    public func discard() -> Bool { false }
    public func loadIfDiscarded() {}
    public var isDiscarded: Bool { false }
    public func toggleDevTools() -> Bool { false }
    public func showDevToolsConsole() -> Bool { false }
    public var hasDevTools: Bool { false }
}

/// How secure a page's connection is (#96), as the address bar shows it, with the certificates
/// its server sent.
public struct PageSecurity: Equatable, @unchecked Sendable {
    // @unchecked: SecCertificate is an immutable Core Foundation object, safe to share.

    public enum Level: Hashable, Sendable {
        /// Nothing to show: not a web page (`about:`, `data:`, a file), this Mac, or no page yet.
        case none
        /// https with a valid certificate and nothing loaded over plain http.
        case secure
        /// Plain http, or https showing content loaded over http.
        case notSecure
        /// https whose certificate isn't trusted (on Chromium, visited anyway; see
        /// ``PageSecurity/hasCertificateError``), or that ran content loaded over http.
        case broken
    }

    public var level: Level
    /// The server's certificates, the site's first; empty without a secure connection.
    public var certificates: [SecCertificate]
    /// Whether the certificate itself has an error, as opposed to a page that's broken only for
    /// running content loaded over http.
    public var hasCertificateError: Bool

    public init(level: Level = .none, certificates: [SecCertificate] = [], hasCertificateError: Bool = false) {
        self.level = level
        self.certificates = certificates
        self.hasCertificateError = hasCertificateError
    }
}

/// One page in a tab's back or forward history (#112).
public struct HistoryEntry: Hashable, Sendable {
    public var title: String
    public var url: URL

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }
}

/// Why a page couldn't load (#178), for Axo's own Can't Connect page.
public struct PageLoadError: Equatable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// This Mac isn't connected to the internet.
        case offline
        /// No server has the site's name.
        case serverNotFound
        /// The server didn't answer in time.
        case timedOut
        /// The server refused or dropped the connection.
        case cantConnect
        /// Something else went wrong.
        case other
    }

    public var kind: Kind
    /// The engine's name for the error, such as `ERR_NAME_NOT_RESOLVED` or `NSURLErrorDomain -1003`.
    public var code: String
    /// The address that didn't load.
    public var url: URL?

    public init(kind: Kind, code: String, url: URL?) {
        self.kind = kind
        self.code = code
        self.url = url
    }

    /// The kind for one of Chromium's `net::Error` codes.
    public static func kind(chromiumCode code: Int) -> Kind {
        switch code {
        case -106: .offline                          // ERR_INTERNET_DISCONNECTED
        case -105, -137: .serverNotFound             // ERR_NAME_NOT_RESOLVED, ERR_NAME_RESOLUTION_FAILED
        case -7, -118: .timedOut                     // ERR_TIMED_OUT, ERR_CONNECTION_TIMED_OUT
        case -100, -101, -102, -104, -109: .cantConnect // closed, reset, refused, failed, unreachable
        default: .other
        }
    }

    /// The kind for one of Foundation's `NSURLError` codes, as WebKit reports them.
    public static func kind(urlErrorCode code: Int) -> Kind {
        switch code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed: .offline
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: .serverNotFound
        case NSURLErrorTimedOut: .timedOut
        case NSURLErrorCannotConnectToHost: .cantConnect
        default: .other
        }
    }
}

/// A warning shown in place of a page (#178), for Axo's own warning page.
public struct PageWarning: Equatable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// The site's certificate isn't trusted.
        case certificate
        /// Safe Browsing lists the site as deceptive (phishing).
        case deceptiveSite
        /// Safe Browsing lists the site as harmful (malware, unwanted software).
        case harmfulSite
        /// Another warning the engine shows.
        case other
    }

    public var kind: Kind
    /// The address the warning is about.
    public var url: URL?
    /// The engine's name for the problem, such as `ERR_CERT_COMMON_NAME_INVALID`.
    public var code: String?
    /// Whether the person may go on to the site anyway: not for certificate errors that can't be
    /// skipped, nor on engines that refuse untrusted certificates (WebKit).
    public var allowsVisiting: Bool

    public init(kind: Kind, url: URL?, code: String?, allowsVisiting: Bool) {
        self.kind = kind
        self.url = url
        self.code = code
        self.allowsVisiting = allowsVisiting
    }
}

/// Why a page stopped working (#75), as Chrome's sad tab and "Page unresponsive" dialog tell.
public enum PageProblem: Hashable, Sendable {
    /// Its content process crashed or was ended, with the process's exit code when the engine
    /// gives one.
    case crashed(errorCode: Int?)
    /// Its content process ran out of memory.
    case outOfMemory
    /// It stopped responding to input. It may recover on its own;
    /// ``EnginePage/waitForResponse()`` gives it more time.
    case unresponsive
}

/// What a page uses that its tab's row shows (#74), as Chrome's tab strip does.
public struct PageCapture: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The camera.
    public static let camera = PageCapture(rawValue: 1 << 0)
    /// The microphone.
    public static let microphone = PageCapture(rawValue: 1 << 1)
    /// The screen, a window, or a tab, shared by the page.
    public static let screen = PageCapture(rawValue: 1 << 2)
    /// The person's location.
    public static let location = PageCapture(rawValue: 1 << 3)
}

/// A page's sound and what it uses (#71, #74).
public struct PageMedia: Hashable, Sendable {
    /// Whether the page plays sound, muted or not.
    public var isPlayingAudio = false
    /// Whether its sound is muted.
    public var isMuted = false
    /// What it uses now.
    public var capture: PageCapture = []

    public init(isPlayingAudio: Bool = false, isMuted: Bool = false, capture: PageCapture = []) {
        self.isPlayingAudio = isPlayingAudio
        self.isMuted = isMuted
        self.capture = capture
    }
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
    /// The page asks to open a link in another app (``ExternalLinks/isExternal(_:)``), from any of
    /// its frames. The engine hasn't opened it: Axo asks the person and opens it.
    func page(_ page: any EnginePage, opensExternalURL url: URL, origin: PageOrigin?, userGesture: Bool)
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
    /// The page started or stopped playing sound, was muted or unmuted, or started or stopped
    /// using a device. Read ``EnginePage/media``.
    func pageMediaDidChange(_ page: any EnginePage)
    /// The page stopped working, or works again. Read ``EnginePage/problem``.
    func pageProblemDidChange(_ page: any EnginePage)
    /// The page's connection security or certificates changed. Read ``EnginePage/security``.
    func pageSecurityDidChange(_ page: any EnginePage)
    /// A load failed, a warning shows, or a page loaded again. Read ``EnginePage/loadError`` and
    /// ``EnginePage/warning``.
    func pageErrorDidChange(_ page: any EnginePage)
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

extension PageSecurity {
    /// A WebKit page's security: https whose content all came over https is secure, with the
    /// server's certificates; https showing http content, or plain http (but not this Mac), isn't.
    /// Only for the page that committed: while another loads (`url` differs from `committedURL`),
    /// the content and trust are still the old page's, so there's nothing to show yet.
    static func webKit(url: URL?, committedURL: URL?, hasOnlySecureContent: Bool, serverTrust: SecTrust?) -> PageSecurity {
        guard let url, url == committedURL, let scheme = url.scheme?.lowercased() else { return PageSecurity() }
        switch scheme {
        case "https":
            let certificates = serverTrust.flatMap { SecTrustCopyCertificateChain($0) as? [SecCertificate] } ?? []
            return PageSecurity(level: hasOnlySecureContent ? .secure : .notSecure, certificates: certificates)
        case "http":
            return PageSecurity(level: isThisMac(url) ? .none : .notSecure)
        default:
            return PageSecurity()
        }
    }

    /// Whether the page is served from this Mac, which needs no encryption: `localhost` and its
    /// subdomains, and loopback addresses (127.0.0.0/8, ::1), not names that only start like one.
    static func isThisMac(_ url: URL) -> Bool {
        guard var host = url.host(percentEncoded: false)?.lowercased() else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host == "::1" || host == "[::1]" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCIIDigit) }),
              parts.allSatisfy({ (Int($0) ?? 256) <= 255 }) else { return false }
        return parts[0] == "127"
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
